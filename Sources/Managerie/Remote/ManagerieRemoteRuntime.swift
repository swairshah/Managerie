import Combine
import Foundation

@MainActor
final class ManagerieRemoteRuntime {
    private weak var appDelegate: AppDelegate?
    private var server: ManagerieRemoteServer?
    private let monitor = VoiceMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var lastSnapshotFingerprint: String?
    private var lastHistoryTopId: String?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func startIfEnabled() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "remoteServerEnabled") as? Bool ?? true
        guard enabled else {
            monitor.stop()
            print("Managerie Remote: disabled via remoteServerEnabled=false")
            return
        }

        guard server == nil else { return }

        let config = ManagerieRemoteServerConfig.fromEnvironmentAndDefaults()

        let server = ManagerieRemoteServer(
            config: config,
            snapshotProvider: { [weak self] in
                guard let self else { return .empty }
                return self.buildSnapshot(limitHistory: 80)
            },
            commandHandler: { [weak self] command, completion in
                Task { @MainActor in
                    guard let self else {
                        completion(.failure(code: "INTERNAL_ERROR", message: "runtime unavailable"))
                        return
                    }
                    let result = await self.handle(command: command)
                    completion(result)
                }
            }
        )

        do {
            try server.start()
            monitor.start()
            self.server = server
            bindPublishers()
            publishSnapshotIfChanged(force: true)
        } catch {
            monitor.stop()
            print("Managerie Remote: failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        cancellables.removeAll()
        monitor.stop()
        server?.stop()
        server = nil
    }

    private func bindPublishers() {
        cancellables.removeAll()

        monitor.$sessions
            .combineLatest(monitor.$summary)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.publishSnapshotIfChanged()
            }
            .store(in: &cancellables)

        RequestHistoryStore.shared.$entries
            .sink { [weak self] entries in
                guard let self else { return }
                self.publishHistoryDelta(entries)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.publishSnapshotIfChanged()
                }
            }
            .store(in: &cancellables)
    }

    private func publishSnapshotIfChanged(force: Bool = false) {
        guard let server else { return }
        let snapshot = buildSnapshot(limitHistory: 80)
        let fingerprint = snapshotFingerprint(snapshot)
        if !force, fingerprint == lastSnapshotFingerprint {
            return
        }
        lastSnapshotFingerprint = fingerprint
        server.publishSessionsUpdated(snapshot)
    }

    private func publishHistoryDelta(_ entries: [RequestHistoryEntry]) {
        guard let server, let first = entries.first else {
            if entries.isEmpty {
                lastHistoryTopId = nil
            }
            return
        }

        let topId = first.id.uuidString
        guard topId != lastHistoryTopId else { return }
        lastHistoryTopId = topId
        server.publishHistoryAppended(historyEntry(first))
    }

    private func buildSnapshot(limitHistory: Int) -> ManagerieRemoteSnapshot {
        let historyEntries = RequestHistoryStore.shared.entries
        let history = Array(historyEntries.prefix(limitHistory)).map(historyEntry)

        return ManagerieRemoteSnapshot(
            generatedAtMs: managerieRemoteCurrentTimestampMs(),
            summary: ManagerieRemoteSummary(
                total: monitor.summary.total,
                queued: monitor.summary.queued,
                idle: monitor.summary.idle,
                color: monitor.summary.color,
                label: monitor.summary.label
            ),
            sessions: monitor.sessions.map(remoteSession),
            history: history
        )
    }

    private func snapshotFingerprint(_ snapshot: ManagerieRemoteSnapshot) -> String {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return UUID().uuidString
        }
        return String(data.count) + ":" + String(data.hashValue)
    }

    private func remoteSession(_ session: VoiceSession) -> ManagerieRemoteSession {
        ManagerieRemoteSession(
            id: session.id,
            sourceApp: session.sourceApp,
            sessionId: session.sessionId,
            pid: session.pid,
            activity: activityCode(session.activity),
            activityLabel: session.activity.label,
            statusDetail: session.statusDetail,
            project: session.project,
            currentText: session.currentText,
            queuedCount: session.queuedCount,
            lastSpokenAtMs: session.lastSpokenAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            lastSpokenText: session.lastSpokenText,
            cwd: session.cwd,
            tty: session.tty,
            mux: session.mux
        )
    }

    private func historyEntry(_ entry: RequestHistoryEntry) -> ManagerieRemoteHistoryEntry {
        ManagerieRemoteHistoryEntry(
            id: entry.id.uuidString,
            timestampMs: Int64(entry.timestamp.timeIntervalSince1970 * 1000),
            text: entry.text,
            sourceApp: entry.sourceApp,
            sessionId: entry.sessionId,
            pid: entry.pid,
            status: entry.status.rawValue
        )
    }

    private func activityCode(_ activity: VoiceActivity) -> String {
        switch activity {
        case .starting: return "starting"
        case .thinking: return "thinking"
        case .reading: return "reading"
        case .editing: return "editing"
        case .running: return "running"
        case .searching: return "searching"
        case .error: return "error"
        case .waiting: return "waiting"
        case .idle: return "idle"
        }
    }

    private func handle(command: ManagerieRemoteIncomingCommand) async -> ManagerieRemoteCommandResult {
        switch command {
        case .sendText(let sessionKey, let text, _):
            return await handleSendText(sessionKey: sessionKey, text: text)

        case .sendScreenshot(let sessionKey, let imageBase64, let mimeType, let note, _):
            return await handleSendScreenshot(sessionKey: sessionKey, imageBase64: imageBase64, mimeType: mimeType, note: note)

        case let .speak(text, sourceApp, sessionId, pid, _):
            return handleSpeak(text: text, sourceApp: sourceApp, sessionId: sessionId, pid: pid)

        case .stop:
            return handleStop()
        }
    }

    private func handleSpeak(
        text: String,
        sourceApp: String?,
        sessionId: String?,
        pid: Int?
    ) -> ManagerieRemoteCommandResult {
        let delivered = BrokerRequestProcessor.deliver(
            text: text,
            sourceApp: sourceApp ?? "managerie-ios",
            sessionId: sessionId,
            pid: pid
        )
        guard delivered else {
            return .failure(code: "INVALID_ARGUMENT", message: "Missing text")
        }
        return .success()
    }

    /// Retained as a no-op so existing clients don't error.
    private func handleStop() -> ManagerieRemoteCommandResult {
        .success()
    }

    private func handleSendText(sessionKey: String, text: String) async -> ManagerieRemoteCommandResult {
        guard let session = monitor.sessions.first(where: { $0.id == sessionKey }) else {
            return .failure(code: "SESSION_NOT_FOUND", message: "Unknown session key: \(sessionKey)")
        }

        guard let pid = session.pid else {
            return .failure(code: "SESSION_NOT_ROUTABLE", message: "Selected session has no pid")
        }

        let result: SendHandler.SendResult = await withCheckedContinuation { continuation in
            SendHandler.send(pid: pid, tty: session.tty, mux: session.mux, text: text) { sendResult in
                continuation.resume(returning: sendResult)
            }
        }

        if result.success {
            return .success(payload: [
                "delivered": true,
                "pid": pid,
                "sessionKey": sessionKey,
                "message": result.message as Any,
            ])
        }

        return .failure(code: "DELIVERY_FAILED", message: result.message ?? "Failed to deliver text")
    }

    private func handleSendScreenshot(
        sessionKey: String,
        imageBase64: String,
        mimeType: String,
        note: String?
    ) async -> ManagerieRemoteCommandResult {
        guard let session = monitor.sessions.first(where: { $0.id == sessionKey }) else {
            return .failure(code: "SESSION_NOT_FOUND", message: "Unknown session key: \(sessionKey)")
        }

        guard let pid = session.pid else {
            return .failure(code: "SESSION_NOT_ROUTABLE", message: "Selected session has no pid")
        }

        guard let imageData = Data(base64Encoded: imageBase64, options: [.ignoreUnknownCharacters]), !imageData.isEmpty else {
            return .failure(code: "BAD_REQUEST", message: "imageBase64 is invalid")
        }

        // Keep remote payload bounded so one request cannot flood disk/memory.
        if imageData.count > 8 * 1024 * 1024 {
            return .failure(code: "PAYLOAD_TOO_LARGE", message: "image exceeds 8MB limit")
        }

        guard let imagePath = persistScreenshotForSession(imageData: imageData, mimeType: mimeType, pid: pid) else {
            return .failure(code: "INTERNAL_ERROR", message: "Failed to persist screenshot")
        }

        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = "Managerie iOS screenshot attached. Please inspect this image file and help the user.\nImage path: \(imagePath)"
        if let trimmedNote, !trimmedNote.isEmpty {
            message += "\nUser note: \(trimmedNote)"
        }

        let result: SendHandler.SendResult = await withCheckedContinuation { continuation in
            SendHandler.send(pid: pid, tty: session.tty, mux: session.mux, text: message) { sendResult in
                continuation.resume(returning: sendResult)
            }
        }

        if result.success {
            return .success(payload: [
                "delivered": true,
                "pid": pid,
                "sessionKey": sessionKey,
                "imagePath": imagePath,
                "message": result.message as Any,
            ])
        }

        return .failure(code: "DELIVERY_FAILED", message: result.message ?? "Failed to deliver screenshot")
    }

    private func persistScreenshotForSession(imageData: Data, mimeType: String, pid: Int) -> String? {
        let ext: String
        if mimeType.lowercased().contains("png") {
            ext = "png"
        } else if mimeType.lowercased().contains("heic") {
            ext = "heic"
        } else {
            ext = "jpg"
        }

        let baseDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".pi/agent/managerie-inbox-media")
            .appendingPathComponent("\(pid)")

        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            let filename = "\(managerieRemoteCurrentTimestampMs())-\(UUID().uuidString).\(ext)"
            let fileURL = baseDir.appendingPathComponent(filename)
            try imageData.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            return nil
        }
    }
}
