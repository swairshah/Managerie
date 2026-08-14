import Foundation
import Darwin

/// Notification posted when agent status changes.
/// Observers should refresh their session state.
extension Notification.Name {
    static let agentStatusChanged = Notification.Name("agentStatusChanged")
}

/// Stores real-time agent status events received from the managerie extension via the broker.
/// Posts a notification on every update so VoiceMonitor can react instantly (no polling).
final class AgentStatusStore {
    static let shared = AgentStatusStore()

    struct AgentStatus {
        let pid: Int
        let sourceApp: String?
        let sessionId: String?
        let project: String?
        let cwd: String?
        let status: String       // "starting", "thinking", "reading", "editing", "running", "searching", "done", "error"
        let detail: String?
        let contextPercent: Int?
        let updatedAt: Date
    }

    private let lock = NSLock()
    private var agents: [Int: AgentStatus] = [:]  // keyed by pid
    private let staleInterval: TimeInterval = 5 * 60  // 5 minutes

    private static let livenessLock = NSLock()
    private static var livenessCache: [Int: (alive: Bool, updatedAt: Date)] = [:]
    private static let livenessTTL: TimeInterval = 5

    private init() {}

    /// Statuses that mean "the agent is finished and waiting for the user".
    /// Note: "error" is NOT idle — tool errors fire mid-turn and the agent
    /// keeps going.
    static let idleStatuses: Set<String> = ["done", "waiting", "idle"]

    /// Pure transition check: chime-worthy only when moving from an active
    /// state into an idle one. Unknown previous state (app launched mid-turn)
    /// is not a transition.
    static func isIdleTransition(from previous: String?, to next: String) -> Bool {
        guard idleStatuses.contains(next) else { return false }
        guard let previous else { return false }
        return !idleStatuses.contains(previous)
    }

    func update(pid: Int, sourceApp: String?, sessionId: String?, project: String?, cwd: String?, status: String, detail: String?, contextPercent: Int?) {
        lock.lock()
        let previousStatus = agents[pid]?.status
        agents[pid] = AgentStatus(
            pid: pid, sourceApp: sourceApp, sessionId: sessionId,
            project: project, cwd: cwd,
            status: status, detail: detail,
            contextPercent: contextPercent, updatedAt: Date()
        )
        lock.unlock()
        NotificationCenter.default.post(name: .agentStatusChanged, object: nil)

        // Sessions with live status tracking chime here — on the moment they
        // go idle — not on message arrival.
        if Self.isIdleTransition(from: previousStatus, to: status) {
            AgentNotificationManager.shared.chimeForIdle(pid: pid)
        }
    }

    /// Whether this pid reports live status events (pi extension sessions do;
    /// hook-based sessions like claude-code/codex don't).
    func hasAgent(pid: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return agents[pid] != nil
    }

    func remove(pid: Int) {
        lock.lock()
        agents.removeValue(forKey: pid)
        lock.unlock()
        NotificationCenter.default.post(name: .agentStatusChanged, object: nil)
    }

    func allAgents() -> [AgentStatus] {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        var deadKeys: [Int] = []
        var waitingKeys: [Int] = []

        for (pid, status) in agents {
            guard now.timeIntervalSince(status.updatedAt) > staleInterval else { continue }

            if Self.isPidAlive(pid) {
                // If an agent stays quiet for a while but process is still alive,
                // treat it as waiting rather than dropping/removing immediately.
                if status.status != "done" {
                    waitingKeys.append(pid)
                }
            } else {
                deadKeys.append(pid)
            }
        }

        for key in deadKeys {
            agents.removeValue(forKey: key)
        }

        for key in waitingKeys {
            guard let existing = agents[key] else { continue }
            agents[key] = AgentStatus(
                pid: existing.pid,
                sourceApp: existing.sourceApp,
                sessionId: existing.sessionId,
                project: existing.project,
                cwd: existing.cwd,
                status: "done",
                detail: nil,
                contextPercent: existing.contextPercent,
                updatedAt: existing.updatedAt
            )
        }

        return Array(agents.values)
    }

    private static func isPidAlive(_ pid: Int) -> Bool {
        let now = Date()

        livenessLock.lock()
        if let cached = livenessCache[pid], now.timeIntervalSince(cached.updatedAt) < livenessTTL {
            livenessLock.unlock()
            return cached.alive
        }
        livenessLock.unlock()

        errno = 0
        let result = kill(pid_t(pid), 0)
        let alive = (result == 0) || (errno == EPERM)

        livenessLock.lock()
        livenessCache[pid] = (alive: alive, updatedAt: now)
        livenessLock.unlock()

        return alive
    }
}
