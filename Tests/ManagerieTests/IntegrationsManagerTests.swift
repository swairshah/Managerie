import XCTest
@testable import Managerie

/// Exercises the real install/uninstall paths against a temporary HOME so the
/// developer's own ~/.codex and ~/.pi are never touched.
///
/// These cover the two failures that made a fresh `brew install` unusable:
/// an existing Codex `notify` program blocking install, and `pi install`
/// failing when the GUI app can't resolve `pi` through nvm.
final class IntegrationsManagerTests: XCTestCase {

    private var tempHome: String!
    private var manager: IntegrationsManager!

    override func setUpWithError() throws {
        tempHome = NSTemporaryDirectory() + "managerie-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempHome, withIntermediateDirectories: true)
        manager = IntegrationsManager(home: tempHome)

        for agent in IntegrationsManager.Agent.allCases {
            UserDefaults.standard.removeObject(forKey: "integrationOptOut.\(agent.rawValue)")
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempHome)
        for agent in IntegrationsManager.Agent.allCases {
            UserDefaults.standard.removeObject(forKey: "integrationOptOut.\(agent.rawValue)")
        }
    }

    // MARK: - Helpers

    private var codexHooksPath: String { tempHome + "/.codex/hooks.json" }
    private var piExtensionPath: String { tempHome + "/.pi/agent/extensions/managerie.ts" }

    private func makeCodexDir(withForeignHook: Bool = true, notify: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempHome + "/.codex", withIntermediateDirectories: true)

        if withForeignHook {
            let existing: [String: Any] = [
                "hooks": [
                    "Stop": [["matcher": ".*", "hooks": [["type": "command", "command": "python3 /some/other/tool.py"]]]]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: existing)
            try data.write(to: URL(fileURLWithPath: codexHooksPath))
        }
        if notify {
            // The exact situation from issue #1: a notify program already set.
            let toml = "notify = [ \"/Applications/SomeOtherTool.app/Contents/MacOS/tool\", \"turn-ended\" ]\n\nmodel = \"gpt-5\"\n"
            try toml.write(toFile: tempHome + "/.codex/config.toml", atomically: true, encoding: .utf8)
        }
    }

    private func codexCommands() throws -> [String] {
        guard let data = FileManager.default.contents(atPath: codexHooksPath),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { value -> [String] in
            (value as? [[String: Any]] ?? []).flatMap { group in
                (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
        }
    }

    // MARK: - Codex

    /// Issue #1: an existing notify program must not block installation.
    func testCodexInstallsAlongsideExistingNotifyProgram() throws {
        try makeCodexDir(withForeignHook: false, notify: true)

        XCTAssertNoThrow(try manager.install(.codex))
        XCTAssertTrue(manager.isInstalled(.codex))

        // The user's notify program is left exactly as it was.
        let toml = try String(contentsOfFile: tempHome + "/.codex/config.toml", encoding: .utf8)
        XCTAssertTrue(toml.contains("SomeOtherTool"))
    }

    func testCodexInstallPreservesOtherToolsHooks() throws {
        try makeCodexDir()
        try manager.install(.codex)

        let commands = try codexCommands()
        XCTAssertTrue(commands.contains { $0.contains("/some/other/tool.py") }, "foreign hook was dropped")
        XCTAssertTrue(commands.contains { $0.contains("managerie-hook") }, "managerie hook missing")
    }

    func testCodexInstallIsIdempotent() throws {
        try makeCodexDir()
        try manager.install(.codex)
        let afterFirst = try codexCommands()
        try manager.install(.codex)
        let afterSecond = try codexCommands()

        XCTAssertEqual(afterFirst.count, afterSecond.count, "reinstall duplicated hooks")
        XCTAssertEqual(afterSecond.filter { $0.contains("managerie-hook") }.count, 2, "expected Stop + StopFailure only")
    }

    func testCodexUninstallLeavesOtherToolsIntact() throws {
        try makeCodexDir()
        try manager.install(.codex)
        try manager.uninstall(.codex)

        let commands = try codexCommands()
        XCTAssertFalse(commands.contains { $0.contains("managerie-hook") }, "managerie hook survived uninstall")
        XCTAssertTrue(commands.contains { $0.contains("/some/other/tool.py") }, "uninstall removed another tool's hook")
        XCTAssertFalse(manager.isInstalled(.codex))
    }

    // MARK: - Pi

    /// Issue #2: installing must not depend on resolving the `pi` CLI.
    func testPiInstallWritesExtensionFileDirectly() throws {
        try FileManager.default.createDirectory(atPath: tempHome + "/.pi/agent", withIntermediateDirectories: true)

        try manager.install(.pi)

        XCTAssertTrue(FileManager.default.fileExists(atPath: piExtensionPath))
        XCTAssertTrue(manager.isInstalled(.pi))

        let source = try String(contentsOfFile: piExtensionPath, encoding: .utf8)
        XCTAssertTrue(source.contains("managerie"), "extension source looks wrong")
    }

    func testPiUninstallRemovesExtensionFile() throws {
        try FileManager.default.createDirectory(atPath: tempHome + "/.pi/agent", withIntermediateDirectories: true)
        try manager.install(.pi)
        try manager.uninstall(.pi)

        XCTAssertFalse(FileManager.default.fileExists(atPath: piExtensionPath))
        XCTAssertFalse(manager.isInstalled(.pi))
    }

    // MARK: - Auto-install & opt-out

    func testAutoInstallConnectsAgentsThatArePresent() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempHome + "/.pi/agent", withIntermediateDirectories: true)
        try makeCodexDir()
        // No ~/.claude — that agent isn't installed on this machine.

        manager.autoInstallIfNeeded()

        XCTAssertTrue(manager.isInstalled(.pi))
        XCTAssertTrue(manager.isInstalled(.codex))
        XCTAssertFalse(manager.isInstalled(.claudeCode), "installed for an agent the user doesn't have")
    }

    /// Removing from the app must survive the next launch.
    func testAutoInstallRespectsExplicitRemoval() throws {
        try FileManager.default.createDirectory(atPath: tempHome + "/.pi/agent", withIntermediateDirectories: true)

        try manager.install(.pi)
        try manager.uninstall(.pi)
        XCTAssertTrue(manager.isOptedOut(.pi))

        manager.autoInstallIfNeeded()

        XCTAssertFalse(manager.isInstalled(.pi), "auto-install resurrected a removed integration")
    }

    /// Reinstalling by hand clears the opt-out again.
    func testManualInstallClearsOptOut() throws {
        try FileManager.default.createDirectory(atPath: tempHome + "/.pi/agent", withIntermediateDirectories: true)

        try manager.install(.pi)
        try manager.uninstall(.pi)
        try manager.install(.pi)

        XCTAssertFalse(manager.isOptedOut(.pi))
        manager.autoInstallIfNeeded()
        XCTAssertTrue(manager.isInstalled(.pi))
    }
}
