import Foundation
import SwiftUI
import Combine
import Darwin

// MARK: - Voice Session Model

enum VoiceActivity: Equatable {
    case speaking
    case queued
    case starting
    case thinking
    case reading
    case editing
    case running
    case searching
    case error
    case waiting
    case idle

    var label: String {
        switch self {
        case .speaking: return "Speaking"
        case .queued: return "Queued"
        case .starting: return "Starting"
        case .thinking: return "Thinking"
        case .reading: return "Reading"
        case .editing: return "Editing"
        case .running: return "Running"
        case .searching: return "Searching"
        case .error: return "Error"
        case .waiting: return "Waiting"
        case .idle: return "Idle"
        }
    }

    var color: Color {
        switch self {
        case .speaking: return .red
        case .queued: return .orange
        case .starting: return .green
        case .thinking: return .orange
        case .reading: return .blue
        case .editing: return .yellow
        case .running: return .orange
        case .searching: return Color(red: 0.78, green: 0.33, blue: 0.08)  // burnt orange
        case .error: return .red
        case .waiting: return .green
        case .idle: return .secondary
        }
    }

    var isWorkStatus: Bool {
        switch self {
        case .starting, .thinking, .reading, .editing, .running, .searching, .error:
            return true
        default:
            return false
        }
    }
}

struct VoiceSession: Identifiable, Equatable {
    let id: String
    let sourceApp: String
    let sessionId: String?
    let pid: Int?

    var activity: VoiceActivity
    var statusDetail: String?   // e.g. "reading App.swift", "running ls"
    var project: String?        // project/directory name from extension
    var currentText: String?
    var queuedCount: Int
    var voice: String?
    var lastSpokenAt: Date?
    var lastSpokenText: String?
    var cwd: String?
    var tty: String?
    var mux: String?
}

struct VoiceSummary: Equatable {
    let total: Int
    let speaking: Int
    let queued: Int
    let idle: Int
    let color: String
    let label: String

    var uiColor: Color {
        switch color {
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "orange": return .orange
        case "blue": return .blue
        case "purple": return .purple
        default: return .gray
        }
    }

    static let empty = VoiceSummary(
        total: 0, speaking: 0, queued: 0, idle: 0,
        color: "gray", label: "No voice activity"
    )
}

// MARK: - Voice Monitor (push-based)

@MainActor
final class VoiceMonitor: ObservableObject {
    @Published private(set) var sessions: [VoiceSession] = []
    @Published private(set) var summary: VoiceSummary = .empty
    @Published private(set) var serverOnline: Bool = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var recentHistory: [RequestHistoryEntry] = []

    private var cancellables = Set<AnyCancellable>()
    private var statusObserver: NSObjectProtocol?
    private var micObserver: NSObjectProtocol?
    private var isStarted = false
    private let historyStore = RequestHistoryStore.shared
    private let activeSessionWindow: TimeInterval = 5 * 60

    var speakingCount: Int { sessions.filter { $0.activity == .speaking }.count }
    var queuedCount: Int { sessions.filter { $0.activity == .queued }.count }
    var totalQueuedItems: Int { recentHistory.filter { $0.status == .queued }.count }

    var isMicActive: Bool = false

    @Published var serverEnabled: Bool = !UserDefaults.standard.bool(forKey: "serverDisabled")

    @Published var speechSpeed: Double = min(2.0, max(0.7, UserDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1.0)) {
        didSet {
            let clamped = min(2.0, max(0.7, speechSpeed))
            if clamped != speechSpeed { speechSpeed = clamped }
            else { UserDefaults.standard.set(speechSpeed, forKey: "speechSpeed") }
        }
    }

    func handleServerToggle(enabled: Bool) {
        UserDefaults.standard.set(!enabled, forKey: "serverDisabled")
        guard let appDelegate = AppDelegate.shared else { return }
        if enabled {
            appDelegate.speechCoordinator?.isMuted = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                appDelegate.startLocalBroker()
            }
        } else {
            appDelegate.speechCoordinator?.stopAll()
            appDelegate.speechCoordinator?.isMuted = true
            appDelegate.stopLocalBroker()
        }
    }

    init() {
        // React to mic activity changes
        micObserver = NotificationCenter.default.addObserver(
            forName: .micActivityChanged, object: nil, queue: .main
        ) { [weak self] notification in
            if let isActive = notification.userInfo?["isActive"] as? Bool {
                Task { @MainActor in self?.isMicActive = isActive }
            }
        }

        // Start listening immediately
        start()
    }

    deinit {
        if let observer = micObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = statusObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Subscribe to agent status events (from pi extension via broker)
        if statusObserver == nil {
            statusObserver = NotificationCenter.default.addObserver(
                forName: .agentStatusChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.rebuild() }
            }
        }

        // Subscribe to history changes (speech queue state)
        historyStore.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        // Initial build
        rebuild()
    }

    func stop() {
        isStarted = false
        cancellables.removeAll()
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
            statusObserver = nil
        }
    }

    // MARK: - Rebuild (replaces the old polling refresh)

    // Stable dropdown ordering state — session id → fixed rank.
    private var stableRanks: [String: Int] = [:]
    private var nextStableRank = 0

    /// Assign ranks to unseen sessions in their incoming (preference) order,
    /// then sort everything by rank. Known sessions never move.
    nonisolated static func stableOrder(_ sessions: [VoiceSession], ranks: inout [String: Int], nextRank: inout Int) -> [VoiceSession] {
        for session in sessions where ranks[session.id] == nil {
            ranks[session.id] = nextRank
            nextRank += 1
        }
        return sessions.sorted { (ranks[$0.id] ?? .max) < (ranks[$1.id] ?? .max) }
    }

    private func rebuild() {
        let entries = historyStore.entries
        let agents = AgentStatusStore.shared.allAgents()
        let isMicActive = self.isMicActive
        let currentSessions = self.sessions

        let agentInstances = agents.map { agent in
            AgentInstance(
                pid: agent.pid,
                sourceApp: agent.sourceApp,
                sessionId: agent.sessionId,
                cwd: agent.cwd,
                activity: Self.mapStatus(agent.status),
                detail: agent.detail,
                project: agent.project
            )
        }

        let inboxPids = Self.activeInboxPids()

        let newSessions = Self.buildSessions(
            from: entries,
            agents: agentInstances,
            inboxPids: inboxPids,
            activeSessionWindow: activeSessionWindow
        )

        // Stable ordering: a session keeps its slot for its lifetime.
        // buildSessions' preference sort only decides where a session enters
        // the list the first time it's seen — after that, activity flips and
        // recency updates never move it. (Replaces the old mic-active freeze,
        // which is subsumed: the order simply never churns.)
        sessions = Self.stableOrder(newSessions, ranks: &stableRanks, nextRank: &nextStableRank)

        // Keep the rank map from growing without bound across very long runs.
        if stableRanks.count > 300 {
            let liveIds = Set(sessions.map(\.id))
            stableRanks = stableRanks.filter { liveIds.contains($0.key) }
        }

        summary = Self.buildSummary(from: sessions)
        recentHistory = Array(entries.filter { !$0.status.isInQueue }
            .sorted { $0.timestamp > $1.timestamp }.prefix(10))
        checkServerHealth()
    }

    // MARK: - Agent Instance

    private struct AgentInstance {
        let pid: Int
        let sourceApp: String?
        let sessionId: String?
        let cwd: String?
        let activity: VoiceActivity
        let detail: String?
        let project: String?
    }

    private static func mapStatus(_ status: String) -> VoiceActivity {
        switch status {
        case "starting": return .starting
        case "thinking": return .thinking
        case "reading": return .reading
        case "editing": return .editing
        case "running": return .running
        case "searching": return .searching
        case "error": return .error
        case "done": return .waiting
        default: return .idle
        }
    }

    // MARK: - Actions

    func stopAll() {
        AppDelegate.shared?.stopCurrentSpeech()
        RequestHistoryStore.shared.cancelAllPending()
        lastMessage = "Stopped all speech"
    }

    func jump(to session: VoiceSession) {
        guard let pid = session.pid else {
            lastMessage = "No PID available for jump"
            return
        }
        lastMessage = "Jumping to PID \(pid)..."
        JumpHandler.jumpAsync(to: pid) { [weak self] result in
            self?.lastMessage = result.focused
                ? "Focused \(result.focusedApp ?? "terminal") for PID \(pid)"
                : (result.message ?? "Could not focus terminal")
        }
    }

    func sendText(to session: VoiceSession, text: String) {
        guard let pid = session.pid else {
            lastMessage = "No PID available"
            return
        }
        lastMessage = "Sending..."
        SendHandler.send(pid: pid, tty: session.tty, mux: session.mux, text: text, sourceApp: session.sourceApp) { [weak self] result in
            self?.lastMessage = result.message ?? (result.success ? "Sent" : "Failed")
            self?.rebuild()
        }
    }

    func reportVoiceInputStatus(_ message: String) {
        lastMessage = message
    }

    // MARK: - Build Sessions

    private static func buildSessions(
        from entries: [RequestHistoryEntry],
        agents: [AgentInstance],
        inboxPids: [Int],
        activeSessionWindow: TimeInterval
    ) -> [VoiceSession] {
        var sessions: [VoiceSession] = []
        var seenPids = Set<Int>()

        // Sessions from live agent status events
        for agent in agents {
            guard Self.isPidAlive(agent.pid) else { continue }
            seenPids.insert(agent.pid)
            let cwdName = agent.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }

            var session = VoiceSession(
                id: "pid-\(agent.pid)",
                sourceApp: normalizedAppName(agent.sourceApp),
                sessionId: normalizedSessionId(agent.sessionId) ?? cwdName,
                pid: agent.pid,
                activity: agent.activity,
                statusDetail: agent.detail,
                project: agent.project ?? cwdName,
                currentText: nil,
                queuedCount: 0,
                voice: nil,
                lastSpokenAt: nil,
                lastSpokenText: nil,
                cwd: agent.cwd,
                tty: nil,
                mux: nil
            )

            // Overlay voice history
            let pidEntries = entries.filter { $0.pid == agent.pid }
            if !pidEntries.isEmpty {
                let recentCutoff = Date().addingTimeInterval(-120)
                let playingEntry = pidEntries.first { $0.status == .playing && $0.timestamp > recentCutoff }
                let queuedEntries = pidEntries.filter { $0.status == .queued && $0.timestamp > recentCutoff }
                let playedEntries = pidEntries.filter { $0.status == .played }

                // Keep live agent status as the primary activity signal.
                // Only fall back to speech-based activity when agent reports idle/waiting.
                if let playing = playingEntry {
                    if session.activity == .idle || session.activity == .waiting {
                        session.activity = .speaking
                    }
                    session.currentText = playing.text
                    session.queuedCount = queuedEntries.count
                } else if !queuedEntries.isEmpty {
                    if session.activity == .idle || session.activity == .waiting {
                        session.activity = .queued
                    }
                    session.currentText = queuedEntries.first?.text
                    session.queuedCount = queuedEntries.count
                }

                if let lastPlayed = playedEntries.max(by: { $0.timestamp < $1.timestamp }) {
                    session.lastSpokenAt = lastPlayed.timestamp
                    session.lastSpokenText = lastPlayed.text
                }
                session.voice = pidEntries.compactMap { $0.voice }.first
            }

            sessions.append(session)
        }

        // Also show sessions with recent speech activity (even without live status events)
        let recentCutoff = Date().addingTimeInterval(-activeSessionWindow)
        var voiceBuckets: [Int: [RequestHistoryEntry]] = [:]  // keyed by pid
        for entry in entries {
            guard let pid = entry.pid, !seenPids.contains(pid) else { continue }
            guard entry.timestamp > recentCutoff else { continue }

            // Keep active queue activity visible even if the originating pid has already exited.
            // This can happen when external clients enqueue speech from short-lived processes.
            if !Self.isPidAlive(pid) && !entry.status.isInQueue { continue }
            voiceBuckets[pid, default: []].append(entry)
        }

        for (pid, pidEntries) in voiceBuckets {
            let key = "pid-\(pid)"
            guard !sessions.contains(where: { $0.id == key }) else { continue }

            let pidAlive = Self.isPidAlive(pid)
            let playingEntry = pidEntries.first { $0.status == .playing }
            let queuedEntries = pidEntries.filter { $0.status == .queued }
            let playedEntries = pidEntries.filter { $0.status == .played }

            var activity: VoiceActivity = .waiting
            var currentText: String? = nil

            if playingEntry != nil {
                activity = .speaking
                currentText = playingEntry?.text
            } else if !queuedEntries.isEmpty {
                activity = .queued
                currentText = queuedEntries.first?.text
            } else if !pidAlive {
                continue
            }

            // Get project name from process cwd only when pid is still alive.
            let cwd = pidAlive ? Self.cwdForPid(pid) : nil
            let projectName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }

            sessions.append(VoiceSession(
                id: key,
                sourceApp: normalizedAppName(pidEntries.first?.sourceApp),
                sessionId: pidEntries.first?.sessionId,
                pid: pidAlive ? pid : nil,
                activity: activity,
                statusDetail: nil,
                project: projectName,
                currentText: currentText,
                queuedCount: queuedEntries.count,
                voice: pidEntries.compactMap { $0.voice }.first,
                lastSpokenAt: playedEntries.max(by: { $0.timestamp < $1.timestamp })?.timestamp,
                lastSpokenText: playedEntries.max(by: { $0.timestamp < $1.timestamp })?.text,
                cwd: cwd,
                tty: nil,
                mux: nil
            ))
            seenPids.insert(pid)
        }

        // Fallback for speech history that has no usable pid.
        // Group by sourceApp+sessionId so these sessions still appear in UI while queued/playing.
        var historyBuckets: [String: [RequestHistoryEntry]] = [:]
        for entry in entries {
            guard entry.timestamp > recentCutoff else { continue }

            if let pid = entry.pid {
                if seenPids.contains(pid) { continue }
                if Self.isPidAlive(pid) { continue }
            }

            let appSessionKey = Self.appSessionKey(sourceApp: entry.sourceApp, sessionId: entry.sessionId)
            historyBuckets[appSessionKey, default: []].append(entry)
        }

        for (bucketKey, bucketEntries) in historyBuckets {
            guard !sessions.contains(where: {
                Self.appSessionKey(sourceApp: $0.sourceApp, sessionId: $0.sessionId) == bucketKey
            }) else { continue }

            let playingEntry = bucketEntries.first { $0.status == .playing }
            let queuedEntries = bucketEntries.filter { $0.status == .queued }
            let playedEntries = bucketEntries.filter { $0.status == .played }

            var activity: VoiceActivity = .waiting
            var currentText: String? = nil

            if playingEntry != nil {
                activity = .speaking
                currentText = playingEntry?.text
            } else if !queuedEntries.isEmpty {
                activity = .queued
                currentText = queuedEntries.first?.text
            } else if playedEntries.isEmpty {
                continue
            }

            sessions.append(VoiceSession(
                id: "history-\(bucketKey)",
                sourceApp: normalizedAppName(bucketEntries.first?.sourceApp),
                sessionId: normalizedSessionId(bucketEntries.first?.sessionId),
                pid: nil,
                activity: activity,
                statusDetail: nil,
                project: nil,
                currentText: currentText,
                queuedCount: queuedEntries.count,
                voice: bucketEntries.compactMap { $0.voice }.first,
                lastSpokenAt: playedEntries.max(by: { $0.timestamp < $1.timestamp })?.timestamp,
                lastSpokenText: playedEntries.max(by: { $0.timestamp < $1.timestamp })?.text,
                cwd: nil,
                tty: nil,
                mux: nil
            ))
        }

        // Final fallback: extension-owned inbox pids that are active but haven't emitted status/speech yet.
        for pid in inboxPids where !seenPids.contains(pid) {
            let cwd = Self.cwdForPid(pid)
            let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            sessions.append(VoiceSession(
                id: "pid-\(pid)",
                sourceApp: Self.sourceAppForPid(pid),
                sessionId: nil,
                pid: pid,
                activity: .waiting,
                statusDetail: nil,
                project: project,
                currentText: nil,
                queuedCount: 0,
                voice: nil,
                lastSpokenAt: nil,
                lastSpokenText: nil,
                cwd: cwd,
                tty: nil,
                mux: nil
            ))
            seenPids.insert(pid)
        }

        // Sort: speaking > active work states > queued > waiting > idle, then by recency
        let order: [VoiceActivity] = [.speaking, .starting, .thinking, .reading, .editing, .running, .searching, .error, .queued, .waiting, .idle]
        return sessions.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs.activity) ?? 99
            let ri = order.firstIndex(of: rhs.activity) ?? 99
            if li != ri { return li < ri }
            let lt = lhs.lastSpokenAt ?? .distantPast
            let rt = rhs.lastSpokenAt ?? .distantPast
            if lt != rt { return lt > rt }
            return (lhs.pid ?? 0) < (rhs.pid ?? 0)
        }
    }

    private static func buildSummary(from sessions: [VoiceSession]) -> VoiceSummary {
        let total = sessions.count
        let speaking = sessions.filter { $0.activity == .speaking }.count
        let workingSessions = sessions.filter { $0.activity.isWorkStatus }
        let working = workingSessions.count
        let queued = sessions.filter { $0.activity == .queued }.count
        let waiting = sessions.filter { $0.activity == .waiting }.count
        let idle = total - speaking - working - queued - waiting

        let color: String
        let label: String

        if total == 0 {
            color = "default"
            label = "No agents"
        } else if speaking > 0 {
            color = "red"
            label = speaking == 1 ? "Speaking" : "\(speaking) speaking"
        } else if working > 0 {
            let precedence: [VoiceActivity] = [.starting, .thinking, .reading, .editing, .running, .searching, .error]
            let primary = precedence.first { activity in sessions.contains(where: { $0.activity == activity }) } ?? .running
            let primaryCount = sessions.filter { $0.activity == primary }.count
            switch primary {
            case .starting: color = "green"
            case .thinking: color = "orange"
            case .reading: color = "blue"
            case .editing: color = "yellow"
            case .running: color = "orange"
            case .searching: color = "orange"
            case .error: color = "red"
            default: color = "default"
            }
            label = working == 1
                ? primary.label
                : (primaryCount == working ? "\(primaryCount) \(primary.label.lowercased())" : "\(working) active")
        } else if queued > 0 {
            color = "orange"
            label = queued == 1 ? "Queued" : "\(queued) queued"
        } else if waiting > 0 {
            color = "green"
            label = waiting == 1 ? "Waiting" : "\(waiting) waiting"
        } else {
            color = "default"
            label = "Idle"
        }

        return VoiceSummary(total: total, speaking: speaking, queued: queued, idle: idle, color: color, label: label)
    }

    private func checkServerHealth() {
        switch SpeechPlaybackCoordinator.currentProvider {
        case .elevenlabs:
            serverOnline = ElevenLabsApiKeyManager.resolvedKey() != nil
        case .google:
            serverOnline = GoogleApiKeyManager.resolvedKey() != nil
        case .deepgram:
            serverOnline = DeepgramApiKeyManager.resolvedKey() != nil
        case .local:
            serverOnline = LocalTTSRuntime.shared.isRuntimeAvailable() && LocalTTSRuntime.shared.isModelInstalled()
        }
    }

    /// Discover active pi sessions from extension-owned inbox directories.
    /// This avoids telemetry polling and gives us a stable fallback session list.
    private static func activeInboxPids() -> [Int] {
        // Scan both the Managerie inbox and the legacy pi-talk inbox so sessions
        // still running the old extension show up too.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inboxRoots = [
            home.appendingPathComponent(".pi/agent/managerie-inbox", isDirectory: true),
            home.appendingPathComponent(".pi/agent/pitalk-inbox", isDirectory: true),
        ]

        let items = inboxRoots.flatMap { root in
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        let now = Date()
        let maxAge: TimeInterval = 60 * 60 * 6  // ignore very stale crash leftovers
        var seen = Set<Int>()

        return items.compactMap { url in
            guard let pid = Int(url.lastPathComponent), !seen.contains(pid) else { return nil }
            seen.insert(pid)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate,
               now.timeIntervalSince(modified) > maxAge {
                return nil
            }
            guard Self.isPidAlive(pid) else { return nil }
            return pid
        }
    }

    private static let pidLivenessLock = NSLock()
    private static var pidLivenessCache: [Int: (alive: Bool, updatedAt: Date)] = [:]
    private static let pidLivenessTTL: TimeInterval = 5

    private static func isPidAlive(_ pid: Int) -> Bool {
        let now = Date()

        pidLivenessLock.lock()
        if let cached = pidLivenessCache[pid], now.timeIntervalSince(cached.updatedAt) < pidLivenessTTL {
            pidLivenessLock.unlock()
            return cached.alive
        }
        pidLivenessLock.unlock()

        errno = 0
        let result = kill(pid_t(pid), 0)
        let alive = (result == 0) || (errno == EPERM)

        pidLivenessLock.lock()
        pidLivenessCache[pid] = (alive: alive, updatedAt: now)
        pidLivenessLock.unlock()

        return alive
    }

    private static let commandCacheLock = NSLock()
    private static var commandCache: [Int: (command: String, updatedAt: Date)] = [:]
    private static let commandCacheTTL: TimeInterval = 10

    private static func commandForPid(_ pid: Int) -> String? {
        let now = Date()

        commandCacheLock.lock()
        if let cached = commandCache[pid], now.timeIntervalSince(cached.updatedAt) < commandCacheTTL {
            commandCacheLock.unlock()
            return cached.command
        }
        commandCacheLock.unlock()

        // Syscall, not `ps` + waitUntilExit: rebuild runs on the main thread,
        // and NSTask.waitUntilExit pumps the run loop — a display-link tick
        // re-enters SwiftUI mid-update and AttributeGraph aborts (SIGABRT).
        if let command = Self.commandLineViaSysctl(pid), !command.isEmpty {
            commandCacheLock.lock()
            commandCache[pid] = (command: command, updatedAt: now)
            commandCacheLock.unlock()
            return command
        }

        commandCacheLock.lock()
        commandCache.removeValue(forKey: pid)
        commandCacheLock.unlock()
        return nil
    }

    /// Full command line via sysctl KERN_PROCARGS2 (what `ps` itself reads).
    /// Works for same-uid processes; returns nil otherwise.
    nonisolated static func commandLineViaSysctl(_ pid: Int) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs2(buffer: buffer, size: size)
    }

    /// KERN_PROCARGS2 layout: argc (Int32) | exec_path\0 | \0 padding | argv[0]\0 argv[1]\0 …
    nonisolated static func parseProcArgs2(buffer: [UInt8], size: Int) -> String? {
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0 else { return nil }
        var idx = MemoryLayout<Int32>.size
        // Skip exec path
        while idx < size, buffer[idx] != 0 { idx += 1 }
        // Skip NUL padding
        while idx < size, buffer[idx] == 0 { idx += 1 }

        var args: [String] = []
        var current: [UInt8] = []
        var idxArg = idx
        while idxArg < size, args.count < argc {
            if buffer[idxArg] == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(buffer[idxArg])
            }
            idxArg += 1
        }
        let joined = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    private static func sourceAppForPid(_ pid: Int) -> String {
        guard let command = commandForPid(pid)?.lowercased() else { return "pi" }
        if command.contains("claude") { return "claude-code" }
        if command.contains("codex") { return "codex" }
        if command.contains("gemini") { return "gemini" }
        if command.contains("aider") { return "aider" }
        if command.contains("cursor") { return "cursor" }
        if command.hasPrefix("pi") || command.contains("/pi ") || command.contains(" pi ") { return "pi" }
        return "pi"
    }

    private static let cwdCacheLock = NSLock()
    private static var cwdCache: [Int: (path: String, updatedAt: Date)] = [:]
    private static let cwdCacheTTL: TimeInterval = 10

    /// Current working directory via proc_pidinfo(PROC_PIDVNODEPATHINFO).
    nonisolated static func cwdViaProcPidInfo(_ pid: Int) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result > 0 else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return path.isEmpty ? nil : path
    }

    /// Best-effort cwd lookup for pid (used when extension status events are unavailable).
    private static func cwdForPid(_ pid: Int) -> String? {
        let now = Date()
        cwdCacheLock.lock()
        if let cached = cwdCache[pid], now.timeIntervalSince(cached.updatedAt) < cwdCacheTTL {
            cwdCacheLock.unlock()
            return cached.path
        }
        cwdCacheLock.unlock()

        // Syscall, not `lsof` + waitUntilExit — same main-thread run-loop
        // re-entrancy hazard as commandForPid, and ~1000x faster.
        if let path = Self.cwdViaProcPidInfo(pid) {
            cwdCacheLock.lock()
            cwdCache[pid] = (path: path, updatedAt: now)
            cwdCacheLock.unlock()
            return path
        }

        cwdCacheLock.lock()
        cwdCache.removeValue(forKey: pid)
        cwdCacheLock.unlock()
        return nil
    }

    private static func normalizedAppName(_ sourceApp: String?) -> String {
        let trimmed = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "Unknown"
    }

    private static func normalizedSessionId(_ sessionId: String?) -> String? {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : nil
    }

    private static func appSessionKey(sourceApp: String?, sessionId: String?) -> String {
        let app = normalizedAppName(sourceApp)
        let sid = normalizedSessionId(sessionId) ?? "__none__"
        return "\(app)::\(sid)"
    }

}
