import Foundation

struct ManagerieRemoteServerConfig {
    var host: String
    var port: Int
    var token: String
    var replayLimit: Int
    var allowInsecureNoAuth: Bool

    static func fromEnvironmentAndDefaults() -> ManagerieRemoteServerConfig {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard

        let host: String = {
            // 1. Explicit env var
            if let envHost = env["MANAGERIE_REMOTE_BIND"], !envHost.isEmpty {
                return envHost
            }
            // 2. UserDefaults
            if let stored = defaults.string(forKey: "remoteBindHost"), !stored.isEmpty {
                return stored
            }
            // 3. Auto-detect Tailscale — bind to it so iOS can reach us
            if let tailscaleIP = TailscaleDetector.detectTailscaleIP() {
                return tailscaleIP
            }
            // 4. Loopback fallback
            return "127.0.0.1"
        }()

        let port: Int = {
            if let envPort = env["MANAGERIE_REMOTE_PORT"], let parsed = Int(envPort), parsed > 0 {
                return parsed
            }
            let stored = defaults.integer(forKey: "remotePort")
            return stored > 0 ? stored : 18092
        }()

        let token = env["MANAGERIE_REMOTE_TOKEN"]
            ?? defaults.string(forKey: "remoteToken")
            ?? ""

        let allowInsecureNoAuth: Bool = {
            // Explicit env var takes priority.
            if let raw = env["MANAGERIE_REMOTE_ALLOW_INSECURE_NO_AUTH"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                return raw == "1" || raw == "true" || raw == "yes"
            }
            // Explicit UserDefaults.
            if defaults.object(forKey: "remoteAllowInsecureNoAuth") != nil {
                return defaults.bool(forKey: "remoteAllowInsecureNoAuth")
            }
            // Auto-allow on Tailscale: the network itself is authenticated
            // and encrypted (WireGuard), so token auth is optional.
            if TailscaleDetector.isTailscaleIP(host) {
                return true
            }
            return false
        }()

        return ManagerieRemoteServerConfig(
            host: host,
            port: port,
            token: token,
            replayLimit: 500,
            allowInsecureNoAuth: allowInsecureNoAuth
        )
    }

    var requiresAuth: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isLoopback: Bool {
        let normalized = host.lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }
}

struct ManagerieRemoteSummary: Codable, Equatable {
    let total: Int
    let queued: Int
    let idle: Int
    let color: String
    let label: String
}

struct ManagerieRemoteSession: Codable, Equatable, Identifiable {
    let id: String
    let sourceApp: String
    let sessionId: String?
    let pid: Int?
    let activity: String
    let activityLabel: String
    let statusDetail: String?
    let project: String?
    let currentText: String?
    let queuedCount: Int
    let lastSpokenAtMs: Int64?
    let lastSpokenText: String?
    let cwd: String?
    let tty: String?
    let mux: String?
}

struct ManagerieRemoteHistoryEntry: Codable, Equatable, Identifiable {
    let id: String
    let timestampMs: Int64
    let text: String
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    let status: String
}

struct ManagerieRemoteSnapshot: Codable, Equatable {
    let generatedAtMs: Int64
    let summary: ManagerieRemoteSummary
    let sessions: [ManagerieRemoteSession]
    let history: [ManagerieRemoteHistoryEntry]

    static let empty = ManagerieRemoteSnapshot(
        generatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
        summary: ManagerieRemoteSummary(total: 0, queued: 0, idle: 0, color: "gray", label: "No sessions"),
        sessions: [],
        history: []
    )
}

enum ManagerieRemoteIncomingCommand {
    case sendText(sessionKey: String, text: String, idempotencyKey: String)
    case sendScreenshot(sessionKey: String, imageBase64: String, mimeType: String, note: String?, idempotencyKey: String)
    /// `speak` is the legacy wire name for "deliver this message"; kept for
    /// compatibility with existing clients.
    case speak(text: String, sourceApp: String?, sessionId: String?, pid: Int?, idempotencyKey: String)
    case stop(scope: String?, idempotencyKey: String)
}

struct ManagerieRemoteCommandResult {
    let ok: Bool
    let code: String?
    let message: String?
    let payload: [String: Any]

    static func success(payload: [String: Any] = [:]) -> ManagerieRemoteCommandResult {
        ManagerieRemoteCommandResult(ok: true, code: nil, message: nil, payload: payload)
    }

    static func failure(code: String, message: String) -> ManagerieRemoteCommandResult {
        ManagerieRemoteCommandResult(ok: false, code: code, message: message, payload: [:])
    }
}

typealias ManagerieRemoteSnapshotProvider = () -> ManagerieRemoteSnapshot
typealias ManagerieRemoteCommandHandler = (_ command: ManagerieRemoteIncomingCommand, _ completion: @escaping (ManagerieRemoteCommandResult) -> Void) -> Void

func managerieRemoteCurrentTimestampMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

func managerieRemoteJsonObject<T: Encodable>(_ value: T) -> Any? {
    do {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        return nil
    }
}
