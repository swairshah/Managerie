import SwiftUI
import AppKit
import ServiceManagement
import Carbon.HIToolbox
import Network
import Darwin
import CoreAudio
import AVFoundation

// Notification for mic activity changes
extension Notification.Name {
    static let micActivityChanged = Notification.Name("ManagerieMicActivityChanged")
}

// Debug logging - only prints when MANAGERIE_DEBUG=1
fileprivate let debugEnabled = ProcessInfo.processInfo.environment["MANAGERIE_DEBUG"] == "1"
fileprivate func debugLog(_ message: String) {
    if debugEnabled {
        print(message)
    }
}

@main
struct ManagerieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = VoiceMonitor()

    var body: some Scene {
        // MenuBarExtra with window style (like pi-statusbar)
        MenuBarExtra {
            StatusBarContentView(monitor: monitor)
        } label: {
            StatusBarIcon(summary: monitor.summary, serverOnline: monitor.serverOnline, serverEnabled: monitor.serverEnabled)
        }
        .menuBarExtraStyle(.window)

        // Settings scene
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Shared instance for access from SwiftUI views
    static var shared: AppDelegate?

    // Menu bar UI is handled by SwiftUI MenuBarExtra
    var settingsWindow: NSWindow?

    // Dock icon visibility (defaults to true so window is accessible)
    var showDockIcon: Bool {
        get {
            if UserDefaults.standard.object(forKey: "showDockIcon") == nil {
                return true  // Default to showing dock icon
            }
            return UserDefaults.standard.bool(forKey: "showDockIcon")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "showDockIcon")
            updateDockIconVisibility()
        }
    }

    // Server enabled state - persisted (inverted storage as "serverDisabled")
    var serverEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "serverDisabled") }
        set { UserDefaults.standard.set(!newValue, forKey: "serverDisabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — writing to a closed socket/pipe must not crash the app.
        signal(SIGPIPE, SIG_IGN)

        // Set shared instance for access from SwiftUI
        AppDelegate.shared = self

        // Connect every coding agent the user has (pi, claude-code, codex) so
        // a fresh install works with no manual setup. Idempotent, and skips
        // integrations the user explicitly removed in Settings > Integrations.
        DispatchQueue.global(qos: .utility).async {
            IntegrationsManager.shared.autoInstallIfNeeded()
        }

        // Menu bar is now handled by SwiftUI MenuBarExtra
        setupKeyboardShortcuts()
        updateDockIconVisibility()

        // Notification-first: register categories + request authorization.
        AgentNotificationManager.shared.setup()

        // Only start event ingestion if the server toggle is enabled
        if serverEnabled {
            startEventSpool()
        } else {
            debugLog("Managerie: Server disabled, event spool not started")
        }

        // Start remote runtime (WebSocket control API for companion iOS app).
        remoteRuntime = ManagerieRemoteRuntime(appDelegate: self)
        remoteRuntime?.startIfEnabled()

        runFirstLaunchSetupIfNeeded()
    }

    /// On a fresh install, ask for the permissions Managerie actually needs.
    ///
    /// macOS only lists an app under System Settings > Privacy & Security once
    /// it has *requested* the permission, so an app that never asks is invisible
    /// there and looks broken. We request the microphone (voice replies) and
    /// then show the Permissions pane, where Accessibility can be granted too.
    private func runFirstLaunchSetupIfNeeded() {
        let key = "didRunFirstLaunchSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        Task { @MainActor in
            // Let the menu bar item settle before stacking a system dialog.
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            // 1. Microphone — modal, returns once the user answers.
            _ = await PermissionsManager.requestMicrophone()

            // 2. Accessibility — needed to focus terminals and inject replies.
            //    AXIsProcessTrustedWithOptions is what registers Managerie in
            //    System Settings > Privacy & Security > Accessibility; without
            //    this call the app is absent from that list entirely. Wait a
            //    beat so it doesn't land on top of the microphone dialog.
            if PermissionsManager.checkAccessibility() != .granted {
                try? await Task.sleep(nanoseconds: 700_000_000)
                PermissionsManager.requestAccessibility()
            }

            openSettings(pane: .permissions)
        }
    }

    /// Pending dock-reopen window open, deferred so a notification tap can
    /// cancel it (see below).
    private var pendingReopen: DispatchWorkItem?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Tapping a notification also activates the app, and AppKit may send
        // this *before* the notification delegate runs — so we can't just
        // check a flag. Instead the window open is deferred briefly; a
        // notification interaction cancels it. A real dock click has no
        // notification response, so it opens after the short delay.
        if AgentNotificationManager.shouldSuppressReopen {
            debugLog("Managerie: reopen suppressed (notification activation)")
            return true
        }

        pendingReopen?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !AgentNotificationManager.shouldSuppressReopen else {
                debugLog("Managerie: reopen suppressed (notification activation)")
                return
            }
            self.openSettings()
        }
        pendingReopen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        return true
    }

    /// Called when a notification is tapped/actioned so a queued dock-reopen
    /// never turns into a surprise window.
    func cancelPendingReopen() {
        pendingReopen?.cancel()
        pendingReopen = nil
    }

    func updateDockIconVisibility() {
        if showDockIcon {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        remoteRuntime?.stop()
        eventSpool?.stop()
        KeyboardShortcutManager.shared.unregisterAll()
    }

    // MARK: - Global Keyboard Shortcuts

    func setupKeyboardShortcuts() {
        let manager = KeyboardShortcutManager.shared

        // Wire up action handlers
        manager.setHandler(for: .toggleWindow) {
            Self.toggleMenuBarWindow()
        }

        // Register all hotkeys with Carbon
        manager.registerAll()
    }

    /// Programmatically click the menu bar button to toggle the MenuBarExtra window.
    static func toggleMenuBarWindow() {
        for window in NSApp.windows {
            guard window.className.contains("NSStatusBarWindow") else { continue }
            if let statusItem = window.value(forKey: "statusItem") as? NSStatusItem {
                statusItem.button?.performClick(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }
        debugLog("Managerie: Could not find status bar button to toggle")
    }

    var remoteRuntime: ManagerieRemoteRuntime?
    var eventSpool: EventSpoolWatcher?

    /// The only local transport: the file event spool. No ports, no sockets —
    /// this works even if every TCP port on the machine is taken, and events
    /// written while the app is closed are delivered on the next launch.
    func startEventSpool() {
        guard eventSpool == nil else {
            debugLog("Managerie: Event spool already running, skipping start")
            return
        }
        let processor = BrokerRequestProcessor()
        let spool = EventSpoolWatcher { line in
            _ = processor.process(line)
        }
        spool.start()
        eventSpool = spool
        debugLog("Managerie: Event spool watching \(EventSpool.eventsDir.path)")
    }

    func stopEventSpool() {
        eventSpool?.stop()
        eventSpool = nil
        debugLog("Managerie: Event spool stopped")
    }

    @objc func toggleDockIcon() {
        showDockIcon = !showDockIcon
    }

    // MARK: - Actions

    @objc func openSettings() {
        openSettings(pane: nil)
    }

    func openSettings(pane: MainPane?) {
        if let pane {
            UserDefaults.standard.set(pane.rawValue, forKey: "mainWindowPane")
        }
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Managerie"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 900, height: 640))
            window.minSize = NSSize(width: 780, height: 560)
            window.center()

            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Local Broker & Playback

struct BrokerRequest: Decodable {
    let type: String
    let text: String?
    /// Older clients still send this; decoded so their payloads don't fail, then ignored.
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    // Status event fields (type: "status")
    let status: String?
    let detail: String?
    let project: String?
    let cwd: String?
    let contextPercent: Int?
}

struct BrokerResponse: Encodable {
    let ok: Bool
    let error: String?
    let queued: Int?
    let pending: Int?
    let playing: Bool?
    let currentQueue: String?

    static func success(
        queued: Int? = nil,
        pending: Int? = nil,
        playing: Bool? = nil,
        currentQueue: String? = nil
    ) -> BrokerResponse {
        BrokerResponse(
            ok: true,
            error: nil,
            queued: queued,
            pending: pending,
            playing: playing,
            currentQueue: currentQueue
        )
    }

    static func failure(_ message: String) -> BrokerResponse {
        BrokerResponse(ok: false, error: message, queued: nil, pending: nil, playing: nil, currentQueue: nil)
    }
}

/// Delivery state of an agent message. Playback-era cases (`playing`,
/// `played`, `interrupted`) are kept decodable so existing history files
/// still load, but nothing produces them any more.
enum RequestPlaybackStatus: String, Codable {
    case queued
    case notified
    case cancelled
    case failed

    // Legacy, decode-only.
    case playing
    case played
    case interrupted

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .notified: return "Notified"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case .playing: return "Playing"
        case .played: return "Delivered"
        case .interrupted: return "Interrupted"
        }
    }

    var isInQueue: Bool {
        self == .queued
    }

    var tintColor: Color {
        switch self {
        case .queued: return .secondary
        case .notified: return .green
        case .cancelled: return .orange
        case .failed: return .red
        case .playing: return .blue
        case .played: return .green
        case .interrupted: return .orange
        }
    }
}

struct RequestHistoryEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let text: String
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    var status: RequestPlaybackStatus

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        text: String,
        sourceApp: String?,
        sessionId: String?,
        pid: Int?,
        status: RequestPlaybackStatus
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.sourceApp = sourceApp
        self.sessionId = sessionId
        self.pid = pid
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, text, sourceApp, sessionId, pid, status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        text = try container.decode(String.self, forKey: .text)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        // Entries written before delivery statuses existed.
        status = try container.decodeIfPresent(RequestPlaybackStatus.self, forKey: .status) ?? .notified
    }
}

final class RequestHistoryStore: ObservableObject {
    static let shared = RequestHistoryStore()

    @Published private(set) var entries: [RequestHistoryEntry] = []

    private let maxEntries = 250
    private let historyFileURL: URL
    private let storageQueue = DispatchQueue(label: "managerie.request-history.store")
    private var storageEntries: [RequestHistoryEntry] = []
    private var pendingPersistWorkItem: DispatchWorkItem?
    private let persistDebounceSeconds: TimeInterval = 0.08

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let loquiDir = appSupport.appendingPathComponent("Managerie", isDirectory: true)
        historyFileURL = loquiDir.appendingPathComponent("request-history.json")

        var initial = loadFromDisk()

        // One-time migration: absorb the old PiTalk app's history so sessions
        // still running the legacy extension show their last messages.
        if !UserDefaults.standard.bool(forKey: "legacyHistoryImported") {
            let legacyURL = appSupport
                .appendingPathComponent("PiTalk", isDirectory: true)
                .appendingPathComponent("request-history.json")
            if let data = try? Data(contentsOf: legacyURL),
               let legacy = try? JSONDecoder().decode([RequestHistoryEntry].self, from: data) {
                let known = Set(initial.map(\.id))
                let merged = (initial + legacy.filter { !known.contains($0.id) })
                    .sorted { $0.timestamp > $1.timestamp }
                initial = Array(merged.prefix(maxEntries))
                debugLog("Managerie: imported \(legacy.count) legacy PiTalk history entries")
            }
            UserDefaults.standard.set(true, forKey: "legacyHistoryImported")
        }

        storageEntries = initial
        publishSnapshot(initial)
        storageQueue.sync { schedulePersistLocked() }
    }

    @discardableResult
    func add(text: String, sourceApp: String?, sessionId: String?, pid: Int?, status: RequestPlaybackStatus = .notified) -> UUID {
        let entry = RequestHistoryEntry(
            timestamp: Date(),
            text: text,
            sourceApp: sourceApp,
            sessionId: sessionId,
            pid: pid,
            status: status
        )

        let snapshot = storageQueue.sync { () -> [RequestHistoryEntry] in
            storageEntries.insert(entry, at: 0)
            if storageEntries.count > maxEntries {
                storageEntries.removeLast(storageEntries.count - maxEntries)
            }
            schedulePersistLocked()
            return storageEntries
        }

        publishSnapshot(snapshot)
        return entry.id
    }

    func updateStatus(
        id: UUID,
        to newStatus: RequestPlaybackStatus,
        unlessCurrentIn blockedStatuses: Set<RequestPlaybackStatus> = []
    ) {
        let snapshot = storageQueue.sync { () -> [RequestHistoryEntry]? in
            guard let index = storageEntries.firstIndex(where: { $0.id == id }) else {
                return nil
            }

            let current = storageEntries[index].status
            if blockedStatuses.contains(current) {
                return nil
            }

            guard current != newStatus else {
                return nil
            }

            storageEntries[index].status = newStatus
            schedulePersistLocked()
            return storageEntries
        }

        if let snapshot {
            publishSnapshot(snapshot)
        }
    }

    func clear() {
        let snapshot = storageQueue.sync { () -> [RequestHistoryEntry] in
            storageEntries.removeAll()
            schedulePersistLocked()
            return storageEntries
        }

        publishSnapshot(snapshot)
    }

    /// Cancel all entries that are currently queued or playing (stale entries)
    func cancelAllPending() {
        let snapshot = storageQueue.sync { () -> [RequestHistoryEntry]? in
            var changed = false
            for i in storageEntries.indices {
                if storageEntries[i].status == .queued || storageEntries[i].status == .playing {
                    storageEntries[i].status = .cancelled
                    changed = true
                }
            }

            guard changed else { return nil }
            schedulePersistLocked()
            return storageEntries
        }

        if let snapshot {
            publishSnapshot(snapshot)
        }
    }

    private func schedulePersistLocked() {
        dispatchPrecondition(condition: .onQueue(storageQueue))

        pendingPersistWorkItem?.cancel()
        let snapshot = storageEntries
        let work = DispatchWorkItem { [weak self] in
            self?.persist(snapshot)
        }
        pendingPersistWorkItem = work
        storageQueue.asyncAfter(deadline: .now() + persistDebounceSeconds, execute: work)
    }

    private func publishSnapshot(_ snapshot: [RequestHistoryEntry]) {
        if Thread.isMainThread {
            entries = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.entries = snapshot
            }
        }
    }

    private func loadFromDisk() -> [RequestHistoryEntry] {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: historyFileURL)
            let decoded = try JSONDecoder().decode([RequestHistoryEntry].self, from: data)

            // Clean up stale "playing" and "queued" entries (from crashes or bugs)
            let staleCutoff = Date().addingTimeInterval(-120)  // 2 minutes
            return decoded.prefix(maxEntries).map { entry -> RequestHistoryEntry in
                if (entry.status == .playing || entry.status == .queued) && entry.timestamp < staleCutoff {
                    var fixed = entry
                    fixed.status = entry.status == .playing ? .interrupted : .cancelled
                    return fixed
                }
                return entry
            }
        } catch {
            print("Managerie: Failed to load request history: \(error)")
            return []
        }
    }

    private func persist(_ entries: [RequestHistoryEntry]) {
        do {
            let directory = historyFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: historyFileURL, options: [.atomic])
        } catch {
            print("Managerie: Failed to persist request history: \(error)")
        }
    }
}





/// Shared request pipeline for both transports: the file event spool (primary)
/// and the TCP broker (legacy compat for old pi-talk sessions).
final class BrokerRequestProcessor {
    private let decoder = JSONDecoder()

    /// Record an agent message: history entry + macOS notification.
    /// `speak` is the legacy wire verb; it means "deliver this message".
    @discardableResult
    static func deliver(text: String, sourceApp: String?, sessionId: String?, pid: Int?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        RequestHistoryStore.shared.add(
            text: trimmed,
            sourceApp: sourceApp,
            sessionId: sessionId,
            pid: pid
        )
        AgentNotificationManager.shared.postAgentMessage(
            text: trimmed,
            sourceApp: sourceApp,
            sessionId: sessionId,
            pid: pid
        )
        return true
    }

    func process(_ line: Data) -> BrokerResponse {
        guard !line.isEmpty else {
            debugLog("Managerie Broker: received empty request")
            return .failure("Empty request")
        }

        let request: BrokerRequest
        do {
            request = try decoder.decode(BrokerRequest.self, from: line)
            debugLog("Managerie Broker: received request type=\(request.type), text=\(request.text?.prefix(50) ?? "nil")")
        } catch {
            debugLog("Managerie Broker: invalid JSON: \(String(data: line, encoding: .utf8) ?? "?")")
            return .failure("Invalid JSON request")
        }

        switch request.type {
        case "health":
            return .success()

        case "speak":
            guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                debugLog("Managerie Broker: message request missing text")
                return .failure("Missing text")
            }

            Self.deliver(
                text: text,
                sourceApp: request.sourceApp,
                sessionId: request.sessionId,
                pid: AgentProcessResolver.canonicalPid(for: request.pid, sourceApp: request.sourceApp)
            )
            return .success()

        case "stop":
            // Retained as a no-op so existing clients don't error.
            return .success()

        case "status":
            guard let pid = AgentProcessResolver.canonicalPid(for: request.pid, sourceApp: request.sourceApp) else {
                return .failure("Missing pid for status")
            }
            if request.status == "remove" {
                AgentStatusStore.shared.remove(pid: pid)
            } else {
                AgentStatusStore.shared.update(
                    pid: pid,
                    sourceApp: request.sourceApp,
                    sessionId: request.sessionId,
                    project: request.project,
                    cwd: request.cwd,
                    status: request.status ?? "unknown",
                    detail: request.detail,
                    contextPercent: request.contextPercent
                )
            }
            return .success()

        default:
            return .failure("Unknown command: \(request.type)")
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        MainWindowView()
    }
}

// MARK: - Sessions Tab (Main View)

struct SessionsTabView: View {
    @ObservedObject var monitor: VoiceMonitor
    @StateObject private var audioRecorder = AudioRecorder()
    @State private var recordingSessionId: String? = nil
    /// Which row's reply field owns the keyboard (session id).
    @FocusState private var focusedRow: String?

    var body: some View {
        VStack(spacing: 0) {
            // Pane header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sessions")
                        .font(.system(size: 20, weight: .bold))
                    Text(headerSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { monitor.serverEnabled },
                    set: { newValue in
                        monitor.serverEnabled = newValue
                        monitor.handleServerToggle(enabled: newValue)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(monitor.serverEnabled ? "Listening — agents can reach Managerie" : "Paused")
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 14)

            // Sessions list
            if monitor.sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("The menagerie is quiet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Start pi, claude-code, or codex — sessions appear here")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(monitor.sessions) { session in
                            SessionRowView(
                                session: session,
                                monitor: monitor,
                                isRecordingThis: audioRecorder.isRecording && recordingSessionId == session.id,
                                onMicPress: {
                                    recordingSessionId = session.id
                                    audioRecorder.startRecording()
                                },
                                onMicRelease: {
                                    let target = session
                                    if let audioData = audioRecorder.stopRecording() {
                                        monitor.reportVoiceInputStatus("Transcribing voice input…")
                                        SpeechToText.transcribe(audioData: audioData) { result in
                                            if result.success, let text = result.text, !text.isEmpty {
                                                monitor.sendText(to: target, text: text)
                                            } else {
                                                let error = result.error ?? "No speech recognized"
                                                monitor.reportVoiceInputStatus("Voice input failed: \(error)")
                                            }
                                        }
                                    } else {
                                        monitor.reportVoiceInputStatus("No audio recorded — check microphone permission")
                                    }
                                    recordingSessionId = nil
                                },
                                focusedRow: $focusedRow
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            }

            // Footer
            HStack(spacing: 10) {

                if let message = monitor.lastMessage, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .onAppear { monitor.start() }
    }

    private var headerSubtitle: String {
        var parts = ["\(monitor.sessions.count) active"]
        if monitor.totalQueuedItems > 0 { parts.append("\(monitor.totalQueuedItems) queued") }
        return parts.joined(separator: " · ")
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(8)
    }
}

/// Monochrome tag pill for the main window (mirrors the dropdown's TagPill).
struct WindowTagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct SessionRowView: View {
    let session: VoiceSession
    @ObservedObject var monitor: VoiceMonitor
    let isRecordingThis: Bool
    let onMicPress: () -> Void
    let onMicRelease: () -> Void

    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var draft = ""
    /// Focus lives in the parent, keyed by session id, so moving the mouse
    /// from one row to the next hands the keyboard over cleanly. With a
    /// per-row @FocusState the row being left would resign first responder
    /// *after* the new row claimed it, and focus fell on the floor.
    var focusedRow: FocusState<String?>.Binding
    private var inputFocused: Bool { focusedRow.wrappedValue == session.id }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var displayName: String {
        session.project.flatMap { looksReadable($0) ? $0 : nil }
            ?? session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? session.sourceApp
    }

    private func looksReadable(_ s: String) -> Bool {
        // Filter out UUIDs and hex-heavy strings
        if UUID(uuidString: s) != nil { return false }
        let hexDash = s.filter { $0.isHexDigit || $0 == "-" }
        return !(hexDash.count > s.count / 2 && s.count > 8)
    }

    private var messagePreview: String? {
        if session.activity.isWorkStatus, let detail = session.statusDetail, !detail.isEmpty {
            return detail
        }
        if let text = session.currentText ?? session.lastSpokenText {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        // Live status text is cleared when a session goes idle, which used to
        // blank the row. History still holds the last thing the agent said, so
        // the message persists while the session waits.
        return historyMessage?.replacingOccurrences(of: "\n", with: " ")
    }

    /// Last message this session produced, straight from persisted history.
    private var historyMessage: String? {
        monitor.lastHistoryMessage(for: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card face
            HStack(alignment: .top, spacing: 11) {
                // Content — click to expand
                Button {
                    withAnimation(WindowTheme.Motion.smooth) { isExpanded.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: 11) {
                        AgentGlyph(sourceApp: session.sourceApp)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(displayName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(session.activity.label.lowercased())
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                if session.queuedCount > 0 {
                                    WindowTagPill(text: "\(session.queuedCount) queued")
                                }

                                Spacer(minLength: 8)

                                if let lastAt = session.lastSpokenAt {
                                    Text(Self.relativeFormatter.localizedString(for: lastAt, relativeTo: Date()))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            if let preview = messagePreview {
                                Text(preview)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    // Hover reveals more of the message without
                                    // committing to the full expanded card.
                                    .lineLimit(isExpanded ? 8 : (isHovered ? 6 : 2))
                                    .truncationMode(.tail)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }

                            if isExpanded {
                                HStack(spacing: 10) {
                                    if let pid = session.pid {
                                        Text("pid \(String(pid))")
                                    }
                                    if let cwd = session.cwd {
                                        Text(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    if let sid = session.sessionId, looksReadable(sid) {
                                        Text(String(sid.prefix(24)))
                                            .lineLimit(1)
                                    }
                                }
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 3)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Actions — always on the face, outside the expand button
                if session.pid != nil {
                    HStack(spacing: 5) {
                        Button {
                            monitor.jump(to: session)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.07))
                                )
                        }
                        .buttonStyle(PressableIconStyle())
                        .help("Jump to this agent's terminal")

                        MicButton(
                            isRecording: isRecordingThis,
                            onPress: onMicPress,
                            onRelease: onMicRelease
                        )
                        .help("Hold to dictate — speech is transcribed and sent")
                    }
                    .padding(.top, 1)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)

            // Reply bar: shown when expanded, and on hover so you can point at
            // a row, type, and hit Return without clicking anything. It sticks
            // around while there's a draft or the field has focus, so moving
            // the mouse never eats what you were typing.
            if session.pid != nil, isExpanded || isHovered || inputFocused || !draft.isEmpty {
                HStack(spacing: 6) {
                    TextField("Message \(session.sourceApp)…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused(focusedRow, equals: session.id)
                        .onSubmit(sendDraft)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(inputFocused ? 0.18 : 0.08), lineWidth: 1)
                        )

                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.secondary.opacity(0.4)
                                : Color.accentColor)
                    }
                    .buttonStyle(PressableIconStyle())
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Send to session (Return)")
                }
                .padding(.horizontal, 13)
                .padding(.bottom, 11)
                .onAppear { focusedRow.wrappedValue = session.id }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isExpanded || isHovered ? 0.06 : 0.03))
        )
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering {
                // Hover hands the keyboard to this row's field. Deferred so the
                // field exists (it's revealed by this same hover) before focus
                // lands on it.
                DispatchQueue.main.async { focusedRow.wrappedValue = session.id }
            } else if inputFocused, draft.trimmingCharacters(in: .whitespaces).isEmpty, !isExpanded {
                // Only give up focus if it's still ours — another row may have
                // already taken it as the pointer moved across.
                DispatchQueue.main.async {
                    if focusedRow.wrappedValue == session.id { focusedRow.wrappedValue = nil }
                }
            }
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        monitor.sendText(to: session, text: text)
        draft = ""
    }
}

/// Small agent identity glyph — anchors each session row.
/// pi gets its pixel wordmark; other agents get a quiet two-letter mark.
struct AgentGlyph: View {
    let sourceApp: String

    private var textSymbol: String? {
        switch sourceApp.lowercased() {
        case "pi": return nil  // pixel mark
        case "claude-code", "claude": return "cl"
        case "codex": return "cx"
        case "mnote": return "mn"
        default: return String(sourceApp.prefix(2)).lowercased()
        }
    }

    var body: some View {
        Group {
            if let textSymbol {
                Text(textSymbol)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                PiMarkShape()
                    .fill(Color.secondary)
                    .frame(width: 13, height: 13)
            }
        }
        .frame(width: 28, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

/// Pi's pixel wordmark — a 4×4 cell grid forming "Pi".
/// Drawn as a shape so it stays crisp at any size and tints like text.
struct PiMarkShape: Shape {
    /// Filled cells (col, row) of the mark:
    /// ███·   P top bar
    /// █·█·   bowl sides
    /// ██·█   bowl bottom + i
    /// █··█   stem + i
    static let cells: [(col: Int, row: Int)] = [
        (0, 0), (1, 0), (2, 0),
        (0, 1), (2, 1),
        (0, 2), (1, 2), (3, 2),
        (0, 3), (3, 3),
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cell = min(rect.width, rect.height) / 4
        let originX = rect.midX - cell * 2
        let originY = rect.midY - cell * 2
        // Cells overlap by a hair to avoid antialiased seams between neighbors.
        let bleed = cell * 0.02
        for (col, row) in Self.cells {
            path.addRect(CGRect(
                x: originX + CGFloat(col) * cell,
                y: originY + CGFloat(row) * cell,
                width: cell + bleed,
                height: cell + bleed
            ))
        }
        return path
    }
}

// MARK: - Settings Tab (renamed from General)

// MARK: - Settings UI Components

/// Section header with uppercase text and line
struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .tracking(0.5)

            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 1)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// A single settings row with label on left, control on right
struct SettingsRow<Content: View>: View {
    let label: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(_ label: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            content()
        }
        .padding(.vertical, 10)
    }
}

struct SettingsTabView: View {
    @AppStorage("notificationsEnabled") var notificationsEnabled = true
    @AppStorage("notifyOnlyWhenIdle") var notifyOnlyWhenIdle = false
    @AppStorage("notificationChimeEnabled") var notificationChimeEnabled = true
    @AppStorage(AgentNotificationManager.soundKey) var notificationSoundRaw = NotificationSound.pop.rawValue
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("showDockIcon") var showDockIcon = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // NOTIFICATIONS
                Group {
                    SettingsSectionHeader(title: "Notifications")

                    SettingsRow("Show Notifications", subtitle: "Agent messages appear in Notification Center — click one to jump to its session") {
                        Toggle("", isOn: $notificationsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if notificationsEnabled {
                        SettingsRow("Only When Idle", subtitle: "Only show the final message when a session finishes — suppress mid-turn notifications") {
                            Toggle("", isOn: $notifyOnlyWhenIdle)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }

                    SettingsRow("Notification Sound", subtitle: "Chime played when a session finishes and waits for you — independent of banners") {
                        Toggle("", isOn: $notificationChimeEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if notificationChimeEnabled {
                        SettingsRow("Chime Sound", subtitle: "Which system sound to play") {
                            Picker("", selection: $notificationSoundRaw) {
                                ForEach(NotificationSound.allCases, id: \.rawValue) { sound in
                                    Text(sound.rawValue).tag(sound.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                            .onChange(of: notificationSoundRaw) { newValue in
                                NotificationSound(rawValue: newValue)?.play()
                            }
                        }
                    }
                }

                // GENERAL
                SettingsSectionHeader(title: "General")

                SettingsRow("Launch at Login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: launchAtLogin) { newValue in
                            setLaunchAtLogin(enabled: newValue)
                        }
                }

                SettingsRow("Show Dock Icon") {
                    Toggle("", isOn: $showDockIcon)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: showDockIcon) { _ in
                            updateDockIcon()
                        }
                }

                // SHORTCUTS
                KeyboardShortcutsSettingsSection()

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    func updateDockIcon() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.updateDockIconVisibility()
        }
    }

    func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to set launch at login: \(error)")
            }
        }
    }
}

struct HistoryView: View {
    @StateObject private var historyStore = RequestHistoryStore.shared
    @State private var searchText = ""
    @State private var selectedAppFilter = Self.allAppsToken
    @State private var selectedSessionFilter = Self.allSessionsToken
    @State private var derivedState = DerivedState.empty

    private static let allAppsToken = "__all_apps__"
    private static let allSessionsToken = "__all_sessions__"
    private static let noSessionToken = "__no_session__"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private struct DerivedState {
        let totalEntryCount: Int
        let appFilterOptions: [String]
        let sessionFilterOptions: [String]
        let isFiltering: Bool
        let filteredEntries: [RequestHistoryEntry]
        let queueEntries: [RequestHistoryEntry]
        let completedEntries: [RequestHistoryEntry]

        static let empty = DerivedState(
            totalEntryCount: 0,
            appFilterOptions: [HistoryView.allAppsToken],
            sessionFilterOptions: [HistoryView.allSessionsToken],
            isFiltering: false,
            filteredEntries: [],
            queueEntries: [],
            completedEntries: []
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("\(derivedState.queueEntries.count) queued · \(derivedState.completedEntries.count) completed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if derivedState.isFiltering {
                        Button("Reset Filters") {
                            searchText = ""
                            selectedAppFilter = Self.allAppsToken
                            selectedSessionFilter = Self.allSessionsToken
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                    Button {
                        historyStore.clear()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(derivedState.totalEntryCount == 0)
                    .help("Clear all history")
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("Search text, app, or session...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                HStack(spacing: 8) {
                    Picker("App", selection: $selectedAppFilter) {
                        ForEach(derivedState.appFilterOptions, id: \.self) { option in
                            Text(appFilterLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("Session", selection: $selectedSessionFilter) {
                        ForEach(derivedState.sessionFilterOptions, id: \.self) { option in
                            Text(sessionFilterLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()

            Divider()

            if derivedState.totalEntryCount == 0 {
                emptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No requests yet",
                    subtitle: "Speech requests will appear here"
                )
            } else if derivedState.filteredEntries.isEmpty {
                emptyState(
                    icon: "magnifyingglass",
                    title: "No matches",
                    subtitle: "Try adjusting your search or filters"
                )
            } else {
                List {
                    if !derivedState.queueEntries.isEmpty {
                        Section {
                            ForEach(derivedState.queueEntries) { entry in
                                entryRow(entry)
                            }
                        } header: {
                            Label("Queue", systemImage: "play.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section {
                        ForEach(derivedState.completedEntries) { entry in
                            entryRow(entry)
                        }
                    } header: {
                        Label("Completed", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { recomputeDerivedState() }
        .onReceive(historyStore.$entries) { _ in recomputeDerivedState() }
        .onChange(of: searchText) { _ in recomputeDerivedState() }
        .onChange(of: selectedAppFilter) { _ in recomputeDerivedState() }
        .onChange(of: selectedSessionFilter) { _ in recomputeDerivedState() }
    }

    private func recomputeDerivedState() {
        let entries = historyStore.entries

        let appOptions = [Self.allAppsToken] + Set(entries.map { normalizedAppName($0.sourceApp) }).sorted()

        var sessionOptions = [Self.allSessionsToken]
        if entries.contains(where: { normalizedSessionId($0.sessionId) == nil }) {
            sessionOptions.append(Self.noSessionToken)
        }
        sessionOptions.append(contentsOf: Set(entries.compactMap { normalizedSessionId($0.sessionId) }).sorted())

        var resolvedAppFilter = selectedAppFilter
        var resolvedSessionFilter = selectedSessionFilter

        if resolvedAppFilter != Self.allAppsToken && !appOptions.contains(resolvedAppFilter) {
            resolvedAppFilter = Self.allAppsToken
        }
        if resolvedSessionFilter != Self.allSessionsToken && !sessionOptions.contains(resolvedSessionFilter) {
            resolvedSessionFilter = Self.allSessionsToken
        }

        let searchLower = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filteredEntries = entries.filter { entry in
            if !searchLower.isEmpty {
                let textMatches = entry.text.lowercased().contains(searchLower)
                let appMatches = normalizedAppName(entry.sourceApp).lowercased().contains(searchLower)
                let sessionMatches = (entry.sessionId?.lowercased().contains(searchLower) ?? false)
                if !textMatches && !appMatches && !sessionMatches {
                    return false
                }
            }

            if resolvedAppFilter != Self.allAppsToken,
               normalizedAppName(entry.sourceApp) != resolvedAppFilter {
                return false
            }

            if resolvedSessionFilter == Self.noSessionToken {
                return normalizedSessionId(entry.sessionId) == nil
            }

            if resolvedSessionFilter != Self.allSessionsToken,
               normalizedSessionId(entry.sessionId) != resolvedSessionFilter {
                return false
            }

            return true
        }

        let queueEntries = filteredEntries
            .filter { $0.status.isInQueue }
            .sorted { $0.timestamp < $1.timestamp }
        let completedEntries = filteredEntries.filter { !$0.status.isInQueue }
        let isFiltering = !searchLower.isEmpty || resolvedAppFilter != Self.allAppsToken || resolvedSessionFilter != Self.allSessionsToken

        derivedState = DerivedState(
            totalEntryCount: entries.count,
            appFilterOptions: appOptions,
            sessionFilterOptions: sessionOptions,
            isFiltering: isFiltering,
            filteredEntries: filteredEntries,
            queueEntries: queueEntries,
            completedEntries: completedEntries
        )

        if selectedAppFilter != resolvedAppFilter {
            selectedAppFilter = resolvedAppFilter
        }
        if selectedSessionFilter != resolvedSessionFilter {
            selectedSessionFilter = resolvedSessionFilter
        }
    }

    private func normalizedAppName(_ sourceApp: String?) -> String {
        let trimmed = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "Unknown"
    }

    private func normalizedSessionId(_ sessionId: String?) -> String? {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = trimmed, !value.isEmpty else { return nil }
        if UUID(uuidString: value) != nil { return nil }
        let hexDash = value.filter { $0.isHexDigit || $0 == "-" }
        if hexDash.count > value.count / 2 && value.count > 8 { return nil }
        return value
    }

    private func appFilterLabel(_ option: String) -> String {
        option == Self.allAppsToken ? "All apps" : option
    }

    private func sessionFilterLabel(_ option: String) -> String {
        if option == Self.allSessionsToken { return "All sessions" }
        if option == Self.noSessionToken { return "No session" }
        return String(option.prefix(12)) + (option.count > 12 ? "…" : "")
    }

    @ViewBuilder
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func entryRow(_ entry: RequestHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(normalizedAppName(entry.sourceApp))
                    .font(.subheadline)
                    .fontWeight(.medium)

                statusBadge(for: entry.status)

                Spacer()

                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(entry.text)
                .font(.callout)
                .lineLimit(3)
                .foregroundColor(.primary.opacity(0.9))

            HStack(spacing: 8) {
                if let sessionId = normalizedSessionId(entry.sessionId) {
                    Label(String(sessionId.prefix(8)), systemImage: "number")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(for status: RequestPlaybackStatus) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(status.tintColor)
                .frame(width: 6, height: 6)
            Text(status.displayName)
                .font(.caption2)
                .foregroundColor(status.tintColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(status.tintColor.opacity(0.12))
        .cornerRadius(4)
    }
}


struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                helpSection(title: "Connecting Your Agents", icon: "terminal") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Managerie works with pi, claude-code, and codex:")
                            .font(.callout)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("1. Keep Managerie running in the menu bar.")
                            Text("2. Open the Integrations tab and install the connectors you use.")
                            Text("3. Restart your agent sessions — their messages appear as notifications.")
                            Text("4. Click a session in the menu bar to reply by text or voice.")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)

                        Text("Pi-only commands (with the extension installed):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 4) {
                            CodeRow(code: "/managerie-status", description: "Check extension + app status")
                        }
                    }
                }

                helpSection(title: "CLI Usage", icon: "chevron.left.forwardslash.chevron.right") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use mnote in Terminal:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            CodeRow(code: "mnote \"Build finished\"", description: "Send a notification")
                            CodeRow(code: "echo \"Hello\" | mnote", description: "Pipe input")
                            CodeRow(code: "mnote -S <id> \"Hi\"", description: "Attach a session id")
                        }
                    }
                }

                helpSection(title: "Event Spool (port-free API)", icon: "tray.and.arrow.down") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Agents talk to Managerie by dropping JSON files — no ports or sockets. Write to a .tmp file first, then rename to .json:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        CodeRow(code: "~/.pi/agent/managerie/events/", description: "Drop NDJSON event files here")
                        CodeRow(code: "{\"type\":\"speak\",\"text\":\"Hi\",\"sourceApp\":\"claude-code\",\"pid\":123}", description: "Send a notification")
                        CodeRow(code: "{\"type\":\"status\",\"status\":\"working\",\"pid\":123}", description: "Live session status")
                        CodeRow(code: "~/.pi/agent/managerie/app.alive", description: "App heartbeat — mtime < 30s means running")
                        Text("Events sent while the app is closed are delivered on next launch.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func helpSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Permissions View

struct PermissionsView: View {
    @State private var microphoneStatus: PermissionsManager.PermissionStatus = .notDetermined
    @State private var accessibilityStatus: PermissionsManager.PermissionStatus = .notDetermined

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("Permissions")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Grant or review permissions anytime.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)

                // Permission rows
                VStack(spacing: 12) {
                    PermissionRowView(
                        title: "Microphone",
                        description: "Required for dictation — transcribed on-device",
                        status: microphoneStatus,
                        onRequest: {
                            Task {
                                switch microphoneStatus {
                                case .notDetermined:
                                    _ = await PermissionsManager.requestMicrophone()
                                    refreshStatus()
                                case .denied:
                                    PermissionsManager.openMicrophoneSettings()
                                case .granted:
                                    break
                                }
                            }
                        }
                    )

                    PermissionRowView(
                        title: "Accessibility",
                        description: "Needed for Jump feature to focus terminal windows",
                        status: accessibilityStatus,
                        onRequest: {
                            PermissionsManager.requestAccessibility()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                PermissionsManager.openAccessibilitySettings()
                            }
                        }
                    )
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear { refreshStatus() }
        .onReceive(timer) { _ in refreshStatus() }
    }

    private func refreshStatus() {
        microphoneStatus = PermissionsManager.checkMicrophone()
        accessibilityStatus = PermissionsManager.checkAccessibility()
    }
}

struct PermissionRowView: View {
    let title: String
    let description: String
    let status: PermissionsManager.PermissionStatus
    let onRequest: () -> Void

    private var isGranted: Bool {
        status == .granted
    }

    var body: some View {
        HStack(spacing: 16) {
            // Status icon
            Image(systemName: isGranted ? "checkmark" : "circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(isGranted ? .green : .secondary.opacity(0.5))
                .frame(width: 24)

            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Action button
            if !isGranted {
                Button(status == .notDetermined ? "Allow" : "Open Settings") {
                    onRequest()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isGranted ? Color.green.opacity(0.05) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isGranted ? Color.green.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Hero
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 14, y: 6)

                    Text("Managerie")
                        .font(.system(size: 26, weight: .bold))

                    Text("A menagerie of coding agents in your menubar")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    Text("Version \(version)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .padding(.top, 2)

                    // Link pills
                    HStack(spacing: 8) {
                        AboutLinkPill(label: "GitHub", icon: "chevron.left.forwardslash.chevron.right", url: "https://github.com/swairshah/Managerie")
                        AboutLinkPill(label: "Issues", icon: "ant", url: "https://github.com/swairshah/Managerie/issues")
                        AboutLinkPill(label: "Releases", icon: "shippingbox", url: "https://github.com/swairshah/Managerie/releases")
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 36)

                VStack(alignment: .leading, spacing: 14) {
                    AboutCard(title: "What it does", icon: "bell.badge") {
                        Text("Managerie watches your pi, claude-code, and codex sessions. When an agent finishes and needs you, it chimes and posts a notification — click it to jump straight to that terminal. Reply by text or voice without leaving what you’re doing.")
                    }

                    AboutCard(title: "Connect your agents", icon: "puzzlepiece.extension") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("One click per agent in **Integrations** — it installs the pi extension, claude-code hooks, and codex notify for you. Agents talk to the app through a file spool: no ports, no servers.")
                            CodeRow(code: "brew install --cask swairshah/tap/managerie", description: "Install / update")
                        }
                    }

                    AboutCard(title: "Credits", icon: "heart") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Status/jump UX inspired by Pi Status Bar.")
                            Link("github.com/jademind/pi-statusbar", destination: URL(string: "https://github.com/jademind/pi-statusbar")!)
                                .font(.system(size: 12))
                        }
                    }
                }
                .frame(maxWidth: 520)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }
}

private struct AboutLinkPill: View {
    let label: String
    let icon: String
    let url: String

    @State private var isHovering = false

    var body: some View {
        Button {
            if let target = URL(string: url) { NSWorkspace.shared.open(target) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(isHovering ? 0.1 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(WindowTheme.Motion.hover) { isHovering = hovering }
        }
    }
}

private struct AboutCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            content
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}


struct CodeRow: View {
    let code: String
    var description: String? = nil

    var body: some View {
        HStack {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)

            if let desc = description {
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
        }
    }
}

struct KeyboardShortcutView: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
            }

            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}
