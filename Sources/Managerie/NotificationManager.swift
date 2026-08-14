import Foundation
import AppKit
import UserNotifications

private let notifDebugEnabled = ProcessInfo.processInfo.environment["MANAGERIE_DEBUG"] == "1"
private func debugLog(_ message: String) {
    if notifDebugEnabled { NSLog("%@", message) }
}

/// Managerie is notification-first: agent messages arrive here and are surfaced
/// as macOS user notifications. Clicking a notification jumps to the agent's
/// terminal session via JumpHandler. Voice playback (TTS) is optional on top.
final class AgentNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotificationManager()

    private static let enabledKey = "notificationsEnabled"
    private let jumpActionId = "MANAGERIE_JUMP"
    private let categoryId = "MANAGERIE_AGENT_MESSAGE"

    /// Defaults to true — notifications are the primary channel.
    static var notificationsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// UNUserNotificationCenter requires a real app bundle; guard so a bare
    /// debug binary (swift run) doesn't crash.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setup() {
        guard available else {
            debugLog("Managerie Notifications: no bundle identifier, notifications unavailable")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let jump = UNNotificationAction(
            identifier: jumpActionId,
            title: "Jump to Session",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [jump],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                debugLog("Managerie Notifications: authorization error: \(error.localizedDescription)")
            } else {
                debugLog("Managerie Notifications: authorization granted=\(granted)")
            }
        }
    }

    /// Post an agent message as a user notification.
    func postAgentMessage(text: String, sourceApp: String?, sessionId: String?, pid: Int?) {
        guard available, Self.notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        if let sourceApp, !sourceApp.isEmpty {
            content.title = sourceApp
        } else {
            content.title = "Agent"
        }
        if let sessionId, !sessionId.isEmpty {
            content.subtitle = String(sessionId.prefix(32))
        }
        content.body = text
        content.categoryIdentifier = categoryId
        if let pid {
            content.userInfo["pid"] = pid
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                debugLog("Managerie Notifications: failed to post: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Default tap or explicit "Jump to Session" both focus the agent's terminal.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let pid = userInfo["pid"] as? Int {
            debugLog("Managerie Notifications: jump requested for pid=\(pid)")
            DispatchQueue.global(qos: .userInitiated).async {
                let result = JumpHandler.jump(to: pid)
                debugLog("Managerie Notifications: jump ok=\(result.ok) message=\(result.message ?? "")")
            }
        }
        completionHandler()
    }
}
