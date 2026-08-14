import SwiftUI
import AppKit

struct StatusBarContentView: View {
    @ObservedObject var monitor: VoiceMonitor
    @StateObject private var audioRecorder = AudioRecorder()
    @State private var recordingForSession: VoiceSession? = nil
    @State private var expandedSessionId: String? = nil
    @State private var sessionsContentHeight: CGFloat = 0

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    // MARK: - Helpers

    private func sessionTitle(_ session: VoiceSession) -> String {
        session.project
            ?? session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? session.sessionId.flatMap { looksLikeId($0) ? nil : $0 }
            ?? session.sourceApp
    }

    /// Detect UUIDs and hex-heavy strings that aren't useful session labels
    private func looksLikeId(_ string: String) -> Bool {
        if UUID(uuidString: string) != nil { return true }
        let hexDash = string.filter { $0.isHexDigit || $0 == "-" }
        return hexDash.count > string.count / 2 && string.count > 8
    }

    private func trimmedText(_ text: String, maxLength: Int = 60) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }

    private func lastMessage(for session: VoiceSession) -> String? {
        session.currentText ?? session.lastSpokenText
    }

    private struct RecentSessionItem: Identifiable {
        let id: String
        let label: String
        let preview: String
        let timestamp: Date
    }

    private func sessionKey(pid: Int?, sourceApp: String?, sessionId: String?) -> String {
        if let pid { return "pid-\(pid)" }
        let app = (sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? sourceApp!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "unknown"
        let sid = (sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? sessionId!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "__none__"
        return "\(app)::\(sid)"
    }

    private func recentInactiveSessions() -> [RecentSessionItem] {
        let now = Date()
        let minRecentAge: TimeInterval = 2 * 60

        let activeKeys = Set(monitor.sessions.map { session in
            sessionKey(pid: session.pid, sourceApp: session.sourceApp, sessionId: session.sessionId)
        })
        let activePids = Set(monitor.sessions.compactMap(\.pid))
        let activeLabels = Set(monitor.sessions.map { sessionTitle($0) })

        var seen = Set<String>()
        var result: [RecentSessionItem] = []

        for entry in monitor.recentHistory.sorted(by: { $0.timestamp > $1.timestamp }) {
            if now.timeIntervalSince(entry.timestamp) < minRecentAge { continue }
            if let pid = entry.pid, activePids.contains(pid) { continue }

            let key = sessionKey(pid: entry.pid, sourceApp: entry.sourceApp, sessionId: entry.sessionId)
            if activeKeys.contains(key) || seen.contains(key) { continue }

            let sessionLabel = entry.sessionId
                .flatMap { looksLikeId($0) ? nil : $0 }
                ?? entry.sourceApp
                ?? "Unknown"
            if activeLabels.contains(sessionLabel) { continue }

            seen.insert(key)
            result.append(RecentSessionItem(
                id: key,
                label: sessionLabel,
                preview: trimmedText(entry.text, maxLength: 40),
                timestamp: entry.timestamp
            ))
        }

        return result
    }

    /// Most recent message text for a session, straight from history (works
    /// even when live status events aren't flowing yet).
    private func historyMessage(for session: VoiceSession) -> String? {
        if let pid = session.pid {
            if let entry = monitor.recentHistory.first(where: { $0.pid == pid }) {
                return entry.text
            }
        }
        if let sid = session.sessionId {
            if let entry = monitor.recentHistory.first(where: { $0.sessionId == sid }) {
                return entry.text
            }
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            sessionsList
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            let recentSessions = recentInactiveSessions()
            if !recentSessions.isEmpty {
                Divider()
                    .opacity(0.4)
                recentsSection(recentSessions)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            Divider()
                .opacity(0.4)

            footer(recentCount: recentSessions.count)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if let msg = monitor.lastMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 360)
        .background(MenuWindowTopPin())
        .onAppear { monitor.start() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image("MenuBarIconOff", bundle: .module)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 22)
                .foregroundStyle(.primary)

            Text("Managerie")
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            Toggle("", isOn: Binding(
                get: { monitor.serverEnabled },
                set: { newValue in
                    monitor.serverEnabled = newValue
                    monitor.handleServerToggle(enabled: newValue)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(monitor.serverEnabled ? "Listening — agents can reach Managerie" : "Paused — agent events wait in the spool")
        }
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionsList: some View {
        if monitor.sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("The menagerie is quiet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Agent sessions appear here when they check in")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        } else {
            // Trackie-style: the MenuBarExtra panel measures its host view at
            // content-size, where a ScrollView collapses to zero — it needs an
            // explicit height. We measure the card stack's natural height via
            // a preference key and clamp it, so short lists stay short and
            // long ones scroll.
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(monitor.sessions) { session in
                    MenuSessionCard(
                        session: session,
                        title: sessionTitle(session),
                        lastMessage: lastMessage(for: session) ?? historyMessage(for: session),
                        isExpanded: expandedSessionId == session.id,
                        relativeFormatter: Self.relativeDateFormatter,
                        isRecordingThis: audioRecorder.isRecording && recordingForSession?.id == session.id,
                        onToggle: {
                            expandedSessionId = (expandedSessionId == session.id) ? nil : session.id
                        },
                        onJump: { monitor.jump(to: session) },
                        onSend: { text in monitor.sendText(to: session, text: text) },
                        onMicPress: {
                            recordingForSession = session
                            audioRecorder.startRecording()
                        },
                        onMicRelease: {
                            let targetSession = session
                            if let audioData = audioRecorder.stopRecording() {
                                monitor.reportVoiceInputStatus("Transcribing voice input…")
                                SpeechToText.transcribe(audioData: audioData) { result in
                                    if result.success, let text = result.text, !text.isEmpty {
                                        monitor.sendText(to: targetSession, text: text)
                                    } else {
                                        let error = result.error ?? "No speech recognized"
                                        monitor.reportVoiceInputStatus("Voice input failed: \(error)")
                                    }
                                }
                            } else {
                                monitor.reportVoiceInputStatus("No audio recorded — check microphone permission")
                            }
                            recordingForSession = nil
                        }
                    )
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SessionsHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .onPreferenceChange(SessionsHeightKey.self) { sessionsContentHeight = $0 }
            .frame(height: min(max(sessionsContentHeight, 52), 520))
        }
    }

    // MARK: - Recents

    private func recentsSection(_ items: [RecentSessionItem]) -> some View {
        DisclosureGroup {
            VStack(spacing: 3) {
                ForEach(items.prefix(3)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(item.preview)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)

                        Spacer()

                        Text(Self.relativeDateFormatter.localizedString(for: item.timestamp, relativeTo: Date()))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 1)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Recent · \(items.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Footer

    private func footer(recentCount: Int) -> some View {
        HStack(spacing: 2) {
            Text(footerSummary(recentCount: recentCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()


            FooterButton(title: "Window", systemImage: "macwindow") {
                openSettings()
            }
            FooterButton(title: "Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    private func footerSummary(recentCount: Int) -> String {
        var parts = ["\(monitor.sessions.count) active"]
        if recentCount > 0 { parts.append("\(recentCount) recent") }
        if monitor.totalQueuedItems > 0 { parts.append("\(monitor.totalQueuedItems) queued") }
        return parts.joined(separator: " · ")
    }

    private func openSettings() {
        AppDelegate.shared?.openSettings()
    }
}

// MARK: - Session Card (Trackie-style: monochrome, roomy, message-forward)

private struct MenuSessionCard: View {
    let session: VoiceSession
    let title: String
    let lastMessage: String?
    let isExpanded: Bool
    let relativeFormatter: RelativeDateTimeFormatter
    let isRecordingThis: Bool
    let onToggle: () -> Void
    let onJump: () -> Void
    let onSend: (String) -> Void
    let onMicPress: () -> Void
    let onMicRelease: () -> Void

    @State private var isHovering = false
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card face: content (click to expand) + always-visible actions
            HStack(alignment: .center, spacing: 8) {
                Button(action: onToggle) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let message = lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                            Text(message.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? 6 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        } else if let detail = session.statusDetail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        HStack(spacing: 5) {
                            TagPill(text: session.sourceApp)
                            TagPill(text: session.activity.label.lowercased())
                            if session.queuedCount > 0 {
                                TagPill(text: "\(session.queuedCount) queued")
                            }

                            Spacer()

                            if let lastAt = session.lastSpokenAt {
                                Text(relativeFormatter.localizedString(for: lastAt, relativeTo: Date()))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Always-visible actions — outside the expand button
                if session.pid != nil {
                    HStack(spacing: 5) {
                        Button(action: onJump) {
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
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)

            // Expanded: meta + reply bar
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if let pid = session.pid {
                            Text("PID \(pid)")
                                .monospacedDigit()
                        }
                        if let cwd = session.cwd {
                            Text(URL(fileURLWithPath: cwd).lastPathComponent)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                    if session.pid != nil {
                        HStack(spacing: 6) {
                            TextField("Message \(session.sourceApp)…", text: $draft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .focused($inputFocused)
                                .onSubmit(sendDraft)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
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
                                    .font(.system(size: 17))
                                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? Color.secondary.opacity(0.4)
                                        : Color.accentColor)
                            }
                            .buttonStyle(PressableIconStyle())
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Send to session (Return)")
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 10)
                .onAppear { inputFocused = true }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isExpanded || isHovering ? 0.08 : 0.035))
        )
        .onHover { isHovering = $0 }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
        draft = ""
    }
}

private struct SessionsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Tag Pill (monochrome, Trackie-style)

private struct TagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Window Top Pin

/// The MenuBarExtra panel resizes from its bottom-left origin, so growing
/// content pushes the window up behind the menu bar. This accessor pins the
/// window's top edge: whenever the panel resizes, the origin is shifted so the
/// top stays where the system placed it.
private struct MenuWindowTopPin: NSViewRepresentable {
    final class Coordinator {
        weak var window: NSWindow?
        var topY: CGFloat?
        var isAdjusting = false
        var resizeObserver: NSObjectProtocol?
        var moveObserver: NSObjectProtocol?

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { attach(view, context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { attach(nsView, context.coordinator) }
    }

    private func attach(_ view: NSView, _ coordinator: Coordinator) {
        guard coordinator.resizeObserver == nil, let window = view.window else { return }
        coordinator.window = window
        coordinator.topY = window.frame.maxY

        // System-driven moves (opening the panel, screen changes) re-anchor the top.
        coordinator.moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { _ in
            guard !coordinator.isAdjusting, let window = coordinator.window else { return }
            coordinator.topY = window.frame.maxY
        }

        // Content-driven resizes keep the top edge fixed.
        coordinator.resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { _ in
            guard let window = coordinator.window, let topY = coordinator.topY else { return }
            var frame = window.frame
            guard abs(frame.maxY - topY) > 0.5 else { return }
            frame.origin.y = topY - frame.height
            coordinator.isAdjusting = true
            window.setFrame(frame, display: true)
            coordinator.isAdjusting = false
        }
    }
}

// MARK: - Status Bar Icon (template — adapts to menubar, no status tinting)

struct StatusBarIcon: View {
    let summary: VoiceSummary
    let serverOnline: Bool
    let serverEnabled: Bool

    var body: some View {
        Image(nsImage: menuBarImage)
            .help(!serverEnabled ? "Paused" : (serverOnline ? summary.label : "Offline"))
    }

    private var menuBarImage: NSImage {
        let imageName = (serverOnline && serverEnabled) ? "menubar_on" : "menubar_off"

        guard let url = Bundle.module.url(forResource: imageName, withExtension: "png", subdirectory: "Resources"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "bell", accessibilityDescription: nil) ?? NSImage()
        }

        // Template rendering: macOS adapts the glyph to menubar appearance.
        image.isTemplate = true
        let pointHeight: CGFloat = 20
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        image.size = NSSize(width: (pointHeight * aspect).rounded(), height: pointHeight)
        return image
    }
}

// MARK: - Button Styles

/// Small monochrome pill button with press feedback.
struct QuietPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .foregroundStyle(.primary)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Bare icon button with press feedback.
struct PressableIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Footer text button: quiet until hovered.
struct FooterButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9))
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(isHovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableIconStyle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - Push-to-Talk Mic Button (monochrome)

struct MicButton: View {
    let isRecording: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        Image(systemName: isRecording ? "mic.fill" : "mic")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isRecording ? Color.primary : Color.secondary)
            .frame(width: 26, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isRecording ? 0.18 : 0.07))
            )
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease()
                    }
            )
    }
}
