import Foundation
import SwiftUI

/// Installs/removes Managerie integrations for supported coding agents:
/// - pi:          extension file registered via `pi install <path>`
/// - claude-code: Stop + Notification hooks in ~/.claude/settings.json
/// - codex:       `notify` program in ~/.codex/config.toml
///
/// All integrations funnel agent events to the broker on 127.0.0.1:18091.
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
                return "Extension: messages, live status, and inbox replies (~/.pi/agent/settings.json)"
            case .claudeCode:
                return "Hooks: turn-end + attention notifications (~/.claude/settings.json)"
            case .codex:
                return "Notify program: turn-end notifications (~/.codex/config.toml)"
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

    // MARK: - Paths

    private var appSupportDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Managerie")
    }

    var hookScriptPath: String {
        (appSupportDir as NSString).appendingPathComponent("managerie-hook.py")
    }

    var piExtensionPath: String {
        (appSupportDir as NSString).appendingPathComponent("managerie-pi-extension/index.ts")
    }

    private var claudeSettingsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    }

    private var codexConfigPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/config.toml")
    }

    private var piSettingsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/settings.json")
    }

    private let markerToken = "managerie-hook"

    // MARK: - Helpers on disk

    /// Copy bundled helper files (hook script + pi extension) into App Support.
    func ensureHelpersInstalled() throws {
        try fm.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)

        guard let hookURL = Bundle.module.url(forResource: "managerie-hook", withExtension: "py", subdirectory: "Resources"),
              let extURL = Bundle.module.url(forResource: "managerie-extension", withExtension: "ts", subdirectory: "Resources")
        else {
            throw IntegrationError.helperMissing
        }

        // Hook script (always refresh so upgrades propagate)
        if fm.fileExists(atPath: hookScriptPath) { try? fm.removeItem(atPath: hookScriptPath) }
        try fm.copyItem(at: hookURL, to: URL(fileURLWithPath: hookScriptPath))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptPath)

        // Pi extension
        let extDir = (piExtensionPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: extDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: piExtensionPath) { try? fm.removeItem(atPath: piExtensionPath) }
        try fm.copyItem(at: extURL, to: URL(fileURLWithPath: piExtensionPath))
    }

    // MARK: - Status

    func isInstalled(_ agent: Agent) -> Bool {
        switch agent {
        case .pi:
            guard let data = fm.contents(atPath: piSettingsPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            let extensions = json["extensions"] as? [String] ?? []
            return extensions.contains { $0.contains("managerie") }
        case .claudeCode:
            guard let data = fm.contents(atPath: claudeSettingsPath),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(markerToken)
        case .codex:
            guard let data = fm.contents(atPath: codexConfigPath),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(markerToken)
        }
    }

    // MARK: - Install / Uninstall

    func install(_ agent: Agent) throws {
        try ensureHelpersInstalled()
        switch agent {
        case .pi: try installPi()
        case .claudeCode: try installClaude()
        case .codex: try installCodex()
        }
    }

    func uninstall(_ agent: Agent) throws {
        switch agent {
        case .pi: try uninstallPi()
        case .claudeCode: try uninstallClaude()
        case .codex: try uninstallCodex()
        }
    }

    // MARK: - Pi

    private func runPiCLI(_ arguments: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "pi \(arguments)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw IntegrationError.commandFailed("pi \(arguments) failed: \(output.suffix(300))")
        }
    }

    private func installPi() throws {
        try runPiCLI("install '\(piExtensionPath)'")
    }

    private func uninstallPi() throws {
        try runPiCLI("remove '\(piExtensionPath)'")
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

    private var codexNotifyLine: String {
        "notify = [\"/usr/bin/python3\", \"\(hookScriptPath)\", \"codex\"]"
    }

    private func installCodex() throws {
        var lines: [String] = []
        if let data = fm.contents(atPath: codexConfigPath),
           let text = String(data: data, encoding: .utf8) {
            lines = text.components(separatedBy: "\n")
        }

        if lines.contains(where: { $0.contains(markerToken) }) { return }
        if let existing = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }) {
            throw IntegrationError.conflict("Codex already has a notify program configured: \(existing.trimmingCharacters(in: .whitespaces))")
        }

        // Top-level keys must precede any [table] in TOML — insert at the top.
        lines.insert(codexNotifyLine, at: 0)

        let dir = (codexConfigPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(toFile: codexConfigPath, atomically: true, encoding: .utf8)
    }

    private func uninstallCodex() throws {
        guard let data = fm.contents(atPath: codexConfigPath),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.contains(markerToken) }
        try lines.joined(separator: "\n").write(toFile: codexConfigPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Integrations Tab

struct IntegrationsTabView: View {
    @State private var installed: [IntegrationsManager.Agent: Bool] = [:]
    @State private var busy: IntegrationsManager.Agent? = nil
    @State private var message: String?
    @State private var messageColor: Color = .secondary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Agent Integrations")

                Text("Connect your coding agents to Managerie. Each integration forwards agent messages to the broker (127.0.0.1:18091) so they appear as notifications and sessions. Restart agent sessions after installing.")
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

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(.system(size: 13, weight: .medium))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isInstalled ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(isInstalled ? "Connected" : "Not installed")
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
                        : "\(agent.displayName) integration removed."
                    messageColor = install ? .green : .secondary
                }
                refresh()
            }
        }
    }
}
