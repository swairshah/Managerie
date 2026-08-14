import Foundation
import SwiftUI

private let integrationsDebugEnabled = ProcessInfo.processInfo.environment["MANAGERIE_DEBUG"] == "1"
private func debugLog(_ message: String) {
    if integrationsDebugEnabled { NSLog("%@", message) }
}

/// Installs/removes Managerie integrations for supported coding agents:
/// - pi:          extension dropped into ~/.pi/agent/extensions/managerie.ts
/// - claude-code: Stop + Notification hooks in ~/.claude/settings.json
/// - codex:       lifecycle hooks in ~/.codex/hooks.json
///
/// All integrations funnel agent events to Managerie's file spool
/// (~/.pi/agent/managerie/events/).
///
/// Design notes — these exist so a fresh `brew install` works with no manual
/// setup, which is what previously failed:
/// - Nothing shells out to a CLI. A GUI app launched from Finder/brew has a
///   minimal PATH and no nvm init, so `pi install` could not resolve `pi`.
///   Writing the extension file directly removes the node/nvm dependency.
/// - Codex uses hooks.json (a list per event) rather than the `notify` key in
///   config.toml (a single value), so Managerie no longer conflicts with any
///   notify program the user already configured.
/// - Every install is idempotent, and runs automatically at launch for agents
///   the user actually has — unless they explicitly removed that integration.
final class IntegrationsManager {
    static let shared = IntegrationsManager()

    enum Agent: String, CaseIterable, Identifiable {
        case pi
        case claudeCode = "claude-code"
        case codex

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .pi: return "Pi"
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        var detail: String {
            switch self {
            case .pi:
                return "Extension: messages, live status, and inbox replies (~/.pi/agent/extensions/managerie.ts)"
            case .claudeCode:
                return "Hooks: turn-end + attention notifications (~/.claude/settings.json)"
            case .codex:
                return "Hooks: turn-end notifications (~/.codex/hooks.json)"
            }
        }
    }

    enum IntegrationError: LocalizedError {
        case helperMissing
        case conflict(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing: return "Bundled helper files not found"
            case .conflict(let message): return message
            case .commandFailed(let message): return message
            }
        }
    }

    private let fm = FileManager.default

    /// Root for all integration paths. Injectable so tests can run against a
    /// scratch directory instead of the real home.
    private let home: String

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    // MARK: - Paths

    private var appSupportDir: String {
        (home as NSString).appendingPathComponent("Library/Application Support/Managerie")
    }

    var hookScriptPath: String {
        (appSupportDir as NSString).appendingPathComponent("managerie-hook.py")
    }

    /// Pi auto-loads every .ts file in this directory — no CLI registration.
    private var piExtensionsDir: String {
        (home as NSString).appendingPathComponent(".pi/agent/extensions")
    }

    var piExtensionPath: String {
        (piExtensionsDir as NSString).appendingPathComponent("managerie.ts")
    }

    /// Where older builds staged the extension before `pi install`.
    private var legacyPiExtensionPath: String {
        (appSupportDir as NSString).appendingPathComponent("managerie-pi-extension/index.ts")
    }

    private var codexHooksPath: String {
        (home as NSString).appendingPathComponent(".codex/hooks.json")
    }

    private var piAgentDir: String {
        (home as NSString).appendingPathComponent(".pi/agent")
    }

    private var claudeDir: String {
        (home as NSString).appendingPathComponent(".claude")
    }

    private var codexDir: String {
        (home as NSString).appendingPathComponent(".codex")
    }

    private var claudeSettingsPath: String {
        (home as NSString).appendingPathComponent(".claude/settings.json")
    }

    private var codexConfigPath: String {
        (home as NSString).appendingPathComponent(".codex/config.toml")
    }

    private var piSettingsPath: String {
        (home as NSString).appendingPathComponent(".pi/agent/settings.json")
    }

    private let markerToken = "managerie-hook"

    // MARK: - Helpers on disk

    /// Copy the bundled hook script into App Support (always refreshed so app
    /// upgrades propagate to already-installed integrations).
    func ensureHelpersInstalled() throws {
        try fm.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)

        guard let hookURL = Bundle.module.url(forResource: "managerie-hook", withExtension: "py", subdirectory: "Resources")
        else {
            throw IntegrationError.helperMissing
        }

        if fm.fileExists(atPath: hookScriptPath) { try? fm.removeItem(atPath: hookScriptPath) }
        try fm.copyItem(at: hookURL, to: URL(fileURLWithPath: hookScriptPath))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptPath)
    }

    // MARK: - Auto-install

    /// True when the user explicitly removed this integration from the app.
    /// Auto-install honours it so a launch never resurrects what was removed.
    private func optOutKey(_ agent: Agent) -> String { "integrationOptOut.\(agent.rawValue)" }

    func isOptedOut(_ agent: Agent) -> Bool {
        UserDefaults.standard.bool(forKey: optOutKey(agent))
    }

    private func setOptedOut(_ agent: Agent, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: optOutKey(agent))
    }

    /// Whether the user actually has this agent installed.
    private func agentPresent(_ agent: Agent) -> Bool {
        switch agent {
        case .pi: return fm.fileExists(atPath: piAgentDir)
        case .claudeCode: return fm.fileExists(atPath: claudeDir)
        case .codex: return fm.fileExists(atPath: codexDir)
        }
    }

    /// Called at launch: connect every agent the user has, unless they removed
    /// it. Idempotent and silent — a failure here must never block startup.
    func autoInstallIfNeeded() {
        for agent in Agent.allCases {
            guard agentPresent(agent), !isOptedOut(agent) else { continue }
            do {
                try install(agent, userInitiated: false)
            } catch {
                debugLog("Managerie Integrations: auto-install \(agent.rawValue) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Status

    func isInstalled(_ agent: Agent) -> Bool {
        switch agent {
        case .pi:
            return fm.fileExists(atPath: piExtensionPath)
        case .claudeCode:
            guard let data = fm.contents(atPath: claudeSettingsPath),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(markerToken)
        case .codex:
            if let data = fm.contents(atPath: codexHooksPath),
               let text = String(data: data, encoding: .utf8),
               text.contains(markerToken) {
                return true
            }
            // Legacy: notify program in config.toml
            guard let data = fm.contents(atPath: codexConfigPath),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(markerToken)
        }
    }

    // MARK: - Install / Uninstall

    func install(_ agent: Agent) throws {
        try install(agent, userInitiated: true)
    }

    /// - Parameter userInitiated: when true, clears the opt-out so the choice
    ///   sticks across launches.
    func install(_ agent: Agent, userInitiated: Bool) throws {
        try ensureHelpersInstalled()
        switch agent {
        case .pi: try installPi()
        case .claudeCode: try installClaude()
        case .codex: try installCodex()
        }
        if userInitiated { setOptedOut(agent, false) }
    }

    /// Removing from the app is sticky — the opt-out stops the next launch
    /// from auto-installing it again.
    func uninstall(_ agent: Agent) throws {
        switch agent {
        case .pi: try uninstallPi()
        case .claudeCode: try uninstallClaude()
        case .codex: try uninstallCodex()
        }
        setOptedOut(agent, true)
    }

    // MARK: - Pi

    /// Pi loads every .ts in ~/.pi/agent/extensions, so installing is just
    /// writing the file — no `pi` CLI, no node/nvm PATH dependency.
    private func installPi() throws {
        guard let extURL = Bundle.module.url(forResource: "managerie-extension", withExtension: "ts", subdirectory: "Resources") else {
            throw IntegrationError.helperMissing
        }
        try fm.createDirectory(atPath: piExtensionsDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: piExtensionPath) { try? fm.removeItem(atPath: piExtensionPath) }
        try fm.copyItem(at: extURL, to: URL(fileURLWithPath: piExtensionPath))

        // Older builds registered a staged copy in settings.json via `pi
        // install`; drop that entry so the extension doesn't load twice.
        removeLegacyPiRegistration()
    }

    private func uninstallPi() throws {
        if fm.fileExists(atPath: piExtensionPath) {
            try fm.removeItem(atPath: piExtensionPath)
        }
        removeLegacyPiRegistration()
        try? fm.removeItem(atPath: (legacyPiExtensionPath as NSString).deletingLastPathComponent)
    }

    /// Strip any "managerie" entry from settings.json's extensions array.
    private func removeLegacyPiRegistration() {
        guard let data = fm.contents(atPath: piSettingsPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extensions = root["extensions"] as? [String]
        else { return }

        let filtered = extensions.filter { !$0.contains("managerie") }
        guard filtered.count != extensions.count else { return }

        root["extensions"] = filtered
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: URL(fileURLWithPath: piSettingsPath))
    }

    // MARK: - Claude Code

    private var claudeHookCommand: (stop: String, notification: String) {
        let base = "/usr/bin/python3 '\(hookScriptPath)'"
        return ("\(base) claude-stop", "\(base) claude-notification")
    }

    private func installClaude() throws {
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: claudeSettingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        func addHook(event: String, command: String) {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let alreadyInstalled = groups.contains { group in
                let inner = group["hooks"] as? [[String: Any]] ?? []
                return inner.contains { ($0["command"] as? String)?.contains(markerToken) == true }
            }
            guard !alreadyInstalled else { return }
            groups.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = groups
        }

        addHook(event: "Stop", command: claudeHookCommand.stop)
        addHook(event: "Notification", command: claudeHookCommand.notification)
        root["hooks"] = hooks

        let dir = (claudeSettingsPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: claudeSettingsPath))
    }

    private func uninstallClaude() throws {
        guard let data = fm.contents(atPath: claudeSettingsPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any]
        else { return }

        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                var group = group
                var inner = group["hooks"] as? [[String: Any]] ?? []
                inner.removeAll { ($0["command"] as? String)?.contains(markerToken) == true }
                if inner.isEmpty { return nil }
                group["hooks"] = inner
                return group
            }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
        root["hooks"] = hooks

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: claudeSettingsPath))
    }

    // MARK: - Codex

    /// Turn-end events. Codex >= 0.14x supports Claude-style lifecycle hooks;
    /// StopFailure covers turns that die on an API error.
    private let codexHookEvents = ["Stop", "StopFailure"]

    private var codexHookCommand: String {
        "/usr/bin/python3 '\(hookScriptPath)' codex-hook"
    }

    /// Hooks are a list per event, so this appends alongside whatever the user
    /// already has — no conflict with an existing `notify` program.
    private func installCodex() throws {
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: codexHooksPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let entry: [String: Any] = [
            "matcher": ".*",
            "hooks": [["type": "command", "command": codexHookCommand]]
        ]

        for event in codexHookEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Idempotent: drop our previous entry before re-adding, so an app
            // upgrade refreshes the command instead of duplicating it.
            groups = groups.compactMap { stripManagerieHooks(from: $0) }
            groups.append(entry)
            hooks[event] = groups
        }
        root["hooks"] = hooks

        try fm.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: codexHooksPath))
    }

    private func uninstallCodex() throws {
        // hooks.json
        if let data = fm.contents(atPath: codexHooksPath),
           var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard var groups = value as? [[String: Any]] else { continue }
                groups = groups.compactMap { stripManagerieHooks(from: $0) }
                if groups.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = groups
                }
            }
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: codexHooksPath))
        }

        // Legacy: notify program written into config.toml by older builds.
        if let data = fm.contents(atPath: codexConfigPath),
           let text = String(data: data, encoding: .utf8),
           text.contains(markerToken) {
            let lines = text.components(separatedBy: "\n").filter { !$0.contains(markerToken) }
            try lines.joined(separator: "\n").write(toFile: codexConfigPath, atomically: true, encoding: .utf8)
        }
    }

    /// Remove Managerie's command from a hook group, returning nil when the
    /// group is left empty. Other tools' hooks are preserved untouched.
    private func stripManagerieHooks(from group: [String: Any]) -> [String: Any]? {
        guard var inner = group["hooks"] as? [[String: Any]] else { return group }
        inner.removeAll { ($0["command"] as? String)?.contains(markerToken) == true }
        guard !inner.isEmpty else { return nil }
        var updated = group
        updated["hooks"] = inner
        return updated
    }
}

// MARK: - Integrations Tab

struct IntegrationsTabView: View {
    @State private var installed: [IntegrationsManager.Agent: Bool] = [:]
    @State private var optedOut: [IntegrationsManager.Agent: Bool] = [:]
    @State private var busy: IntegrationsManager.Agent? = nil
    @State private var message: String?
    @State private var messageColor: Color = .secondary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Agent Integrations")

                Text("Connect your coding agents to Managerie. Agents you already have are connected automatically on launch; remove one here and it stays removed. Restart agent sessions after changing this.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)

                VStack(spacing: 10) {
                    ForEach(IntegrationsManager.Agent.allCases) { agent in
                        agentRow(agent)
                    }
                }
                .padding(.vertical, 8)

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(messageColor)
                        .padding(.top, 4)
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func agentRow(_ agent: IntegrationsManager.Agent) -> some View {
        let isInstalled = installed[agent] ?? false
        let isOptedOut = optedOut[agent] ?? false

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(.system(size: 13, weight: .medium))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isInstalled ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(isInstalled ? "Connected" : (isOptedOut ? "Removed" : "Not installed"))
                            .font(.caption2)
                            .foregroundStyle(isInstalled ? Color.green : Color.secondary)
                    }
                }
                Text(agent.detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if busy == agent {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(isInstalled ? "Remove" : "Install") {
                    toggle(agent, install: !isInstalled)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isInstalled ? .red : .accentColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func refresh() {
        for agent in IntegrationsManager.Agent.allCases {
            installed[agent] = IntegrationsManager.shared.isInstalled(agent)
            optedOut[agent] = IntegrationsManager.shared.isOptedOut(agent)
        }
    }

    private func toggle(_ agent: IntegrationsManager.Agent, install: Bool) {
        busy = agent
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var errorText: String?
            do {
                if install {
                    try IntegrationsManager.shared.install(agent)
                } else {
                    try IntegrationsManager.shared.uninstall(agent)
                }
            } catch {
                errorText = error.localizedDescription
            }
            DispatchQueue.main.async {
                busy = nil
                if let errorText {
                    message = errorText
                    messageColor = .red
                } else {
                    message = install
                        ? "\(agent.displayName) connected — restart its sessions to activate."
                        : "\(agent.displayName) integration removed — it won't be reinstalled on launch."
                    messageColor = install ? .green : .secondary
                }
                refresh()
            }
        }
    }
}
