import XCTest
@testable import Managerie

// MARK: - Fixture builders

private func proc(_ pid: Int32, _ ppid: Int32, _ comm: String, tty: String = "??", args: String = "") -> JumpHandler.ProcessInfo {
    JumpHandler.ProcessInfo(pid: pid, ppid: ppid, comm: comm, tty: tty, args: args.isEmpty ? comm : args)
}

private func byPid(_ processes: [JumpHandler.ProcessInfo]) -> [Int: JumpHandler.ProcessInfo] {
    Dictionary(uniqueKeysWithValues: processes.map { (Int($0.pid), $0) })
}

// MARK: - ps output parsing

final class ProcessListParsingTests: XCTestCase {

    func testParsesTypicalPsOutput() {
        let output = """
            1     0 /sbin/launchd      ??   /sbin/launchd
          501     1 /bin/zsh           ttys001 -zsh
          742   501 node               ttys001 node /usr/local/bin/pi
        """
        let procs = JumpHandler.parseProcessList(output)
        XCTAssertEqual(procs.count, 3)
        XCTAssertEqual(procs[0].pid, 1)
        XCTAssertEqual(procs[0].tty, "??")
        XCTAssertEqual(procs[2].pid, 742)
        XCTAssertEqual(procs[2].ppid, 501)
        XCTAssertEqual(procs[2].comm, "node")
        XCTAssertEqual(procs[2].tty, "ttys001")
        XCTAssertEqual(procs[2].args, "node /usr/local/bin/pi")
    }

    func testArgsWithManySpacesArePreserved() {
        let output = "  900  800 node  ttys004 node /Users/x/bin/claude --dangerously-skip-permissions --model opus"
        let procs = JumpHandler.parseProcessList(output)
        XCTAssertEqual(procs.count, 1)
        XCTAssertTrue(procs[0].args.contains("--dangerously-skip-permissions --model opus"))
    }

    func testSkipsEmptyAndMalformedLines() {
        let output = """

          not a pid line at all

          100
          200 100
          300 200 zsh
        """
        // "300 200 zsh" has only 3 fields (missing tty) — must be skipped too
        XCTAssertTrue(JumpHandler.parseProcessList(output).isEmpty)
    }

    func testNonNumericPidSkipped() {
        let output = "  abc  1 zsh ttys000 -zsh"
        XCTAssertTrue(JumpHandler.parseProcessList(output).isEmpty)
    }

    func testMissingArgsDefaultsToEmpty() {
        let output = "  55  1 mdworker ??"
        let procs = JumpHandler.parseProcessList(output)
        XCTAssertEqual(procs.count, 1)
        XCTAssertEqual(procs[0].args, "")
    }
}

// MARK: - Mux detection (tmux / zellij / none)

final class MuxDetectionTests: XCTestCase {

    func testAgentInsideTmuxPaneDetectsTmuxViaServerAncestor() {
        // pi (agent) → zsh (pane shell) → tmux server (detached, tty ??)
        let processes = [
            proc(300, 200, "node", tty: "ttys005", args: "node /usr/local/bin/pi"),
            proc(200, 100, "/bin/zsh", tty: "ttys005", args: "-zsh"),
            proc(100, 1, "tmux", tty: "??", args: "tmux"),
            proc(1, 0, "/sbin/launchd"),
        ]
        let mux = JumpHandler.detectMux(pid: 300, byPid: byPid(processes))
        XCTAssertEqual(mux?.type, "tmux")
        XCTAssertNil(mux?.session)
    }

    func testTmuxClientWithNamedSessionExtractsSession() {
        // claude → zsh → tmux client "attach -t work"
        let processes = [
            proc(300, 200, "claude", tty: "ttys002", args: "claude"),
            proc(200, 100, "/bin/zsh", tty: "ttys002", args: "-zsh"),
            proc(100, 1, "tmux", tty: "ttys001", args: "tmux attach -t work"),
        ]
        let mux = JumpHandler.detectMux(pid: 300, byPid: byPid(processes))
        XCTAssertEqual(mux?.type, "tmux")
        XCTAssertEqual(mux?.session, "work")
    }

    func testZellijAttachClientDetected() {
        let processes = [
            proc(300, 200, "node", tty: "ttys003", args: "node codex"),
            proc(200, 100, "/bin/zsh", tty: "ttys003"),
            proc(100, 1, "zellij", tty: "ttys001", args: "zellij attach mysession"),
        ]
        let mux = JumpHandler.detectMux(pid: 300, byPid: byPid(processes))
        XCTAssertEqual(mux?.type, "zellij")
        XCTAssertEqual(mux?.session, "mysession")
    }

    func testZellijServerPathExtractsSessionName() {
        XCTAssertEqual(
            JumpHandler.extractZellijSession(args: "zellij --server /tmp/zellij-501/0.43.1/deep-work"),
            "deep-work"
        )
    }

    func testNoMuxInPlainGhosttySession() {
        // pi → zsh → login → ghostty (GUI, no mux anywhere)
        let processes = [
            proc(400, 300, "node", tty: "ttys001", args: "node /usr/local/bin/pi"),
            proc(300, 200, "/bin/zsh", tty: "ttys001"),
            proc(200, 100, "login", tty: "ttys001", args: "login -fp swair"),
            proc(100, 1, "ghostty", args: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        ]
        XCTAssertNil(JumpHandler.detectMux(pid: 400, byPid: byPid(processes)))
    }

    func testAncestryCycleDoesNotHang() {
        // Corrupt tree: 100 ↔ 200 parent cycle
        let processes = [
            proc(100, 200, "zsh", tty: "ttys000"),
            proc(200, 100, "zsh", tty: "ttys000"),
        ]
        XCTAssertNil(JumpHandler.detectMux(pid: 100, byPid: byPid(processes)))
    }

    func testUnknownPidReturnsNil() {
        XCTAssertNil(JumpHandler.detectMux(pid: 9999, byPid: [:]))
    }

    func testTmuxSessionExtractionVariants() {
        XCTAssertEqual(JumpHandler.extractTmuxSession(args: "tmux attach -t piscan"), "piscan")
        XCTAssertEqual(JumpHandler.extractTmuxSession(args: "tmux new-session -t dev-loop"), "dev-loop")
        XCTAssertNil(JumpHandler.extractTmuxSession(args: "tmux"))
        XCTAssertNil(JumpHandler.extractTmuxSession(args: ""))
    }
}

// MARK: - Terminal app detection (Ghostty / iTerm2 / Terminal)

final class TerminalAppDetectionTests: XCTestCase {

    private func chainTo(terminal comm: String, args: String = "") -> [Int: JumpHandler.ProcessInfo] {
        byPid([
            proc(400, 300, "node", tty: "ttys001", args: "node /usr/local/bin/pi"),
            proc(300, 200, "/bin/zsh", tty: "ttys001"),
            proc(200, 100, "login", tty: "ttys001"),
            proc(100, 1, comm, args: args.isEmpty ? comm : args),
        ])
    }

    func testDetectsGhosttyByComm() {
        let (app, pid) = JumpHandler.detectTerminalApp(pid: 400, byPid: chainTo(terminal: "ghostty"))
        XCTAssertEqual(app, "Ghostty")
        XCTAssertEqual(pid, 100)
    }

    func testDetectsGhosttyByArgsPath() {
        let (app, _) = JumpHandler.detectTerminalApp(
            pid: 400,
            byPid: chainTo(terminal: "MacOS", args: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        )
        XCTAssertEqual(app, "Ghostty")
    }

    func testDetectsITerm2() {
        let (app, _) = JumpHandler.detectTerminalApp(pid: 400, byPid: chainTo(terminal: "iTerm2"))
        XCTAssertEqual(app, "iTerm2")
    }

    func testDetectsITermByAppBundlePath() {
        let (app, _) = JumpHandler.detectTerminalApp(
            pid: 400,
            byPid: chainTo(terminal: "Main", args: "/Applications/iTerm.app/Contents/MacOS/iTerm2")
        )
        XCTAssertEqual(app, "iTerm2")
    }

    func testDetectsAppleTerminal() {
        let (app, _) = JumpHandler.detectTerminalApp(pid: 400, byPid: chainTo(terminal: "Terminal"))
        XCTAssertEqual(app, "Terminal")
    }

    func testTmuxPaneShellHasNoTerminalAncestor() {
        // Inside tmux, the pane shell's parent is the detached tmux server → no
        // terminal in ancestry. This is exactly why findMuxClientPid exists.
        let processes = [
            proc(300, 200, "node", tty: "ttys005", args: "node pi"),
            proc(200, 100, "/bin/zsh", tty: "ttys005"),
            proc(100, 1, "tmux", tty: "??"),
            proc(1, 0, "/sbin/launchd"),
        ]
        let (app, pid) = JumpHandler.detectTerminalApp(pid: 300, byPid: byPid(processes))
        XCTAssertNil(app)
        XCTAssertNil(pid)
    }

    func testCycleSafe() {
        let processes = [proc(100, 100, "zsh", tty: "ttys000")]
        let (app, _) = JumpHandler.detectTerminalApp(pid: 100, byPid: byPid(processes))
        XCTAssertNil(app)
    }
}

// MARK: - Mux client discovery (the attached tmux client to focus)

final class MuxClientPidTests: XCTestCase {

    func testFindsAttachedTmuxClientOnDifferentTty() {
        let agentTty = "ttys005"  // pane tty
        let processes = [
            proc(300, 200, "node", tty: agentTty),
            proc(100, 1, "tmux", tty: "??", args: "tmux"),                    // server — no tty
            proc(150, 140, "tmux", tty: "ttys001", args: "tmux attach -t x"), // client in real terminal
        ]
        let mux = JumpHandler.MuxInfo(type: "tmux", session: "x")
        XCTAssertEqual(JumpHandler.findMuxClientPid(mux: mux, tty: agentTty, processes: processes), 150)
    }

    func testServerWithoutTtyIsNeverTheClient() {
        let processes = [proc(100, 1, "tmux", tty: "??", args: "tmux")]
        let mux = JumpHandler.MuxInfo(type: "tmux", session: nil)
        XCTAssertNil(JumpHandler.findMuxClientPid(mux: mux, tty: "ttys005", processes: processes))
    }

    func testClientOnAgentTtyIsExcluded() {
        // A tmux process on the same tty as the agent is not the attached client
        let processes = [proc(150, 140, "tmux", tty: "ttys005", args: "tmux attach")]
        let mux = JumpHandler.MuxInfo(type: "tmux", session: nil)
        XCTAssertNil(JumpHandler.findMuxClientPid(mux: mux, tty: "ttys005", processes: processes))
    }

    func testNilMuxReturnsNil() {
        XCTAssertNil(JumpHandler.findMuxClientPid(mux: nil, tty: "ttys005", processes: []))
    }

    func testZellijHasNoClientLookup() {
        let mux = JumpHandler.MuxInfo(type: "zellij", session: "s")
        let processes = [proc(150, 140, "zellij", tty: "ttys001", args: "zellij attach s")]
        XCTAssertNil(JumpHandler.findMuxClientPid(mux: mux, tty: "ttys005", processes: processes))
    }
}

// MARK: - tmux pane parsing (Jump info + Send target)

final class TmuxPaneParsingTests: XCTestCase {

    func testJumpInfoMatchesTty() {
        let output = """
        /dev/ttys001\tmain\teditor
        /dev/ttys005\tpiscan\tagent window
        /dev/ttys009\tother\tlogs
        """
        let info = JumpHandler.parseTmuxInfo(output: output, ttyPath: "/dev/ttys005")
        XCTAssertEqual(info?.session, "piscan")
        XCTAssertEqual(info?.windowName, "agent window")
    }

    func testJumpInfoSessionWithSpacesSurvives() {
        let output = "/dev/ttys002\tmy project\twindow one"
        let info = JumpHandler.parseTmuxInfo(output: output, ttyPath: "/dev/ttys002")
        XCTAssertEqual(info?.session, "my project")
        XCTAssertEqual(info?.windowName, "window one")
    }

    func testJumpInfoNoMatchReturnsNil() {
        XCTAssertNil(JumpHandler.parseTmuxInfo(output: "/dev/ttys001\ta\tb", ttyPath: "/dev/ttys099"))
    }

    func testSendTargetMatchesCorrectPane() {
        let output = """
        main:0.0\t/dev/ttys001
        piscan:2.1\t/dev/ttys005
        piscan:2.2\t/dev/ttys006
        """
        XCTAssertEqual(SendHandler.parseTmuxPaneTarget(output, ttyPath: "/dev/ttys005"), "piscan:2.1")
        XCTAssertEqual(SendHandler.parseTmuxPaneTarget(output, ttyPath: "/dev/ttys006"), "piscan:2.2")
    }

    func testSendTargetSessionNameWithSpaces() {
        let output = "my cool session:1.0\t/dev/ttys004"
        XCTAssertEqual(SendHandler.parseTmuxPaneTarget(output, ttyPath: "/dev/ttys004"), "my cool session:1.0")
    }

    func testSendTargetNoMatchAndEmptyOutput() {
        XCTAssertNil(SendHandler.parseTmuxPaneTarget("a:0.0\t/dev/ttys001", ttyPath: "/dev/ttys002"))
        XCTAssertNil(SendHandler.parseTmuxPaneTarget("", ttyPath: "/dev/ttys002"))
    }
}

// MARK: - TTY normalization

final class TtyNormalizationTests: XCTestCase {

    func testBareNameGetsDevPrefix() {
        XCTAssertEqual(SendHandler.normalizedTty("ttys012"), "/dev/ttys012")
    }

    func testFullPathPassesThrough() {
        XCTAssertEqual(SendHandler.normalizedTty("/dev/ttys012"), "/dev/ttys012")
    }

    func testPsWhitespaceIsTrimmed() {
        XCTAssertEqual(SendHandler.normalizedTty("ttys003\n"), "/dev/ttys003")
        XCTAssertEqual(SendHandler.normalizedTty("  ttys003  "), "/dev/ttys003")
    }

    func testNoTtyMarkersReturnNil() {
        XCTAssertNil(SendHandler.normalizedTty("??"))
        XCTAssertNil(SendHandler.normalizedTty(""))
        XCTAssertNil(SendHandler.normalizedTty("   "))
        XCTAssertNil(SendHandler.normalizedTty(nil))
    }
}

// MARK: - Send routing (inbox vs tmux)

final class SendRoutingTests: XCTestCase {

    func testPiUsesInbox() {
        XCTAssertTrue(SendHandler.usesInboxRoute(sourceApp: "pi"))
        XCTAssertTrue(SendHandler.usesInboxRoute(sourceApp: "Pi"))
        XCTAssertTrue(SendHandler.usesInboxRoute(sourceApp: " pi "))
    }

    func testNilDefaultsToInbox() {
        XCTAssertTrue(SendHandler.usesInboxRoute(sourceApp: nil))
    }

    func testClaudeAndCodexUseTmux() {
        XCTAssertFalse(SendHandler.usesInboxRoute(sourceApp: "claude-code"))
        XCTAssertFalse(SendHandler.usesInboxRoute(sourceApp: "codex"))
        XCTAssertFalse(SendHandler.usesInboxRoute(sourceApp: "NotchCom"))
    }

    func testPiPrefixedAppsAreNotPi() {
        // "pi-scan" or "pilot" must not be mistaken for pi
        XCTAssertFalse(SendHandler.usesInboxRoute(sourceApp: "pi-scan"))
        XCTAssertFalse(SendHandler.usesInboxRoute(sourceApp: "pilot"))
    }
}

// MARK: - Herdr pane matching

final class HerdrMatchingTests: XCTestCase {

    private func decodeProcessInfo(_ json: String) throws -> JumpHandler.HerdrProcessInfoResponse {
        try JSONDecoder().decode(JumpHandler.HerdrProcessInfoResponse.self, from: Data(json.utf8))
    }

    func testMatchesShellPid() throws {
        let response = try decodeProcessInfo("""
        {"result":{"processInfo":{"shellPid":7100,"foregroundProcesses":[]}}}
        """)
        XCTAssertTrue(JumpHandler.herdrPaneMatches(response.result.processInfo, pid: 7100))
        XCTAssertFalse(JumpHandler.herdrPaneMatches(response.result.processInfo, pid: 7101))
    }

    func testMatchesForegroundProcess() throws {
        let response = try decodeProcessInfo("""
        {"result":{"processInfo":{"shellPid":7100,"foregroundProcesses":[{"pid":8200},{"pid":8300}]}}}
        """)
        XCTAssertTrue(JumpHandler.herdrPaneMatches(response.result.processInfo, pid: 8300))
        XCTAssertFalse(JumpHandler.herdrPaneMatches(response.result.processInfo, pid: 8400))
    }

    func testMissingForegroundListMatchesOnlyShell() throws {
        let response = try decodeProcessInfo("""
        {"result":{"processInfo":{"shellPid":7100}}}
        """)
        XCTAssertTrue(JumpHandler.herdrPaneMatches(response.result.processInfo, pid: 7100))
        XCTAssertFalse(JumpHandler.herdrPaneMatches(response.result.processInfo, pid: 8200))
    }

    func testAgentListDecodes() throws {
        let json = """
        {"result":{"agents":[{"paneId":"pane-1"},{"paneId":"pane-2"}]}}
        """
        let list = try JSONDecoder().decode(JumpHandler.HerdrAgentListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(list.result.agents.map(\.paneId), ["pane-1", "pane-2"])
    }
}

// MARK: - End-to-end identification scenarios (fixture process trees)

final class SessionIdentificationScenarioTests: XCTestCase {

    /// claude-code inside tmux inside iTerm2 — the full stack
    func testClaudeInTmuxInITerm() {
        let processes = [
            proc(900, 800, "claude", tty: "ttys007", args: "claude --model opus"),
            proc(800, 700, "/bin/zsh", tty: "ttys007"),
            proc(700, 1, "tmux", tty: "??", args: "tmux"),                       // server
            proc(650, 600, "tmux", tty: "ttys002", args: "tmux attach -t dev"),  // client
            proc(600, 500, "/bin/zsh", tty: "ttys002"),
            proc(500, 1, "iTerm2", args: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        ]
        let map = byPid(processes)

        // 1. Mux detection: agent ancestry hits the tmux server
        let mux = JumpHandler.detectMux(pid: 900, byPid: map)
        XCTAssertEqual(mux?.type, "tmux")

        // 2. Direct terminal detection fails (server is detached)…
        let (direct, _) = JumpHandler.detectTerminalApp(pid: 900, byPid: map)
        XCTAssertNil(direct)

        // 3. …so we find the attached client and detect its terminal
        let clientPid = JumpHandler.findMuxClientPid(mux: mux, tty: "ttys007", processes: processes)
        XCTAssertEqual(clientPid, 650)
        let (viaClient, _) = JumpHandler.detectTerminalApp(pid: clientPid!, byPid: map)
        XCTAssertEqual(viaClient, "iTerm2")

        // 4. Reply routing: claude needs the tmux route
        XCTAssertFalse(SendHandler.usesInboxRoute(sourceApp: "claude-code"))
    }

    /// pi directly in Ghostty (no mux) — extension inbox handles replies
    func testPiBareInGhostty() {
        let processes = [
            proc(400, 300, "node", tty: "ttys001", args: "node /Users/x/.nvm/versions/node/v24/bin/pi"),
            proc(300, 200, "/bin/zsh", tty: "ttys001"),
            proc(200, 100, "login", tty: "ttys001"),
            proc(100, 1, "ghostty", args: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        ]
        let map = byPid(processes)

        XCTAssertNil(JumpHandler.detectMux(pid: 400, byPid: map))
        let (app, _) = JumpHandler.detectTerminalApp(pid: 400, byPid: map)
        XCTAssertEqual(app, "Ghostty")
        XCTAssertTrue(SendHandler.usesInboxRoute(sourceApp: "pi"))
    }

    /// codex inside tmux — send target resolution from pane listing
    func testCodexTmuxSendTargetResolution() {
        let paneListing = """
        dev:0.0\t/dev/ttys002
        dev:1.0\t/dev/ttys007
        scratch:0.0\t/dev/ttys009
        """
        // codex pid's tty resolves to ttys007 (via ps) → normalized → matched
        let tty = SendHandler.normalizedTty("ttys007")
        XCTAssertEqual(tty, "/dev/ttys007")
        XCTAssertEqual(SendHandler.parseTmuxPaneTarget(paneListing, ttyPath: tty!), "dev:1.0")
    }
}

// MARK: - Stable dropdown ordering

final class StableOrderingTests: XCTestCase {

    private func session(_ id: String, activity: VoiceActivity = .waiting, lastSpokenAt: Date? = nil) -> VoiceSession {
        VoiceSession(
            id: id, sourceApp: "pi", sessionId: nil, pid: nil,
            activity: activity, statusDetail: nil, project: nil,
            currentText: nil, queuedCount: 0, voice: nil,
            lastSpokenAt: lastSpokenAt, lastSpokenText: nil,
            cwd: nil, tty: nil, mux: nil
        )
    }

    func testFirstAppearanceUsesIncomingOrder() {
        var ranks: [String: Int] = [:]
        var next = 0
        let result = VoiceMonitor.stableOrder([session("a"), session("b"), session("c")], ranks: &ranks, nextRank: &next)
        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    func testActivityChurnDoesNotReorder() {
        var ranks: [String: Int] = [:]
        var next = 0
        _ = VoiceMonitor.stableOrder([session("a"), session("b"), session("c")], ranks: &ranks, nextRank: &next)

        // Next rebuild: preference sort would put c first (it's "running" now)
        // and b last — stable order must ignore that completely.
        let churned = [
            session("c", activity: .running, lastSpokenAt: Date()),
            session("a", activity: .thinking),
            session("b", activity: .idle),
        ]
        let result = VoiceMonitor.stableOrder(churned, ranks: &ranks, nextRank: &next)
        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    func testNewSessionAppendsWithoutMovingOthers() {
        var ranks: [String: Int] = [:]
        var next = 0
        _ = VoiceMonitor.stableOrder([session("a"), session("b")], ranks: &ranks, nextRank: &next)

        // New session arrives at the front of the preference sort — it still
        // gets a fresh rank after the existing ones.
        let result = VoiceMonitor.stableOrder([session("new", activity: .running), session("b"), session("a")], ranks: &ranks, nextRank: &next)
        XCTAssertEqual(result.map(\.id), ["a", "b", "new"])
    }

    func testReturningSessionKeepsItsOldSlot() {
        var ranks: [String: Int] = [:]
        var next = 0
        _ = VoiceMonitor.stableOrder([session("a"), session("b"), session("c")], ranks: &ranks, nextRank: &next)
        // b disappears for a rebuild…
        _ = VoiceMonitor.stableOrder([session("a"), session("c")], ranks: &ranks, nextRank: &next)
        // …and returns: it's back in the middle, not at the end.
        let result = VoiceMonitor.stableOrder([session("c"), session("b"), session("a")], ranks: &ranks, nextRank: &next)
        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }
}

// MARK: - Syscall-based process inspection (replaced ps/lsof subprocesses,
// which pumped the main run loop via waitUntilExit → AttributeGraph crash)

final class ProcessSyscallTests: XCTestCase {

    func testParseProcArgs2Layout() {
        // argc=2 | exec_path\0 | padding | "pi\0" "--serve\0"
        var buf: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { buf.append(contentsOf: $0) }
        buf.append(contentsOf: Array("/usr/local/bin/pi".utf8)); buf.append(0)
        buf.append(contentsOf: [0, 0, 0])  // padding
        buf.append(contentsOf: Array("pi".utf8)); buf.append(0)
        buf.append(contentsOf: Array("--serve".utf8)); buf.append(0)
        XCTAssertEqual(VoiceMonitor.parseProcArgs2(buffer: buf, size: buf.count), "pi --serve")
    }

    func testParseProcArgs2EmptyIsNil() {
        var buf: [UInt8] = []
        withUnsafeBytes(of: Int32(0)) { buf.append(contentsOf: $0) }
        XCTAssertNil(VoiceMonitor.parseProcArgs2(buffer: buf, size: buf.count))
    }

    func testCommandLineForOwnProcess() {
        let cmd = VoiceMonitor.commandLineViaSysctl(Int(getpid()))
        XCTAssertNotNil(cmd)
        XCTAssertTrue(cmd?.lowercased().contains("xctest") == true || cmd?.contains("Managerie") == true,
                      "unexpected command: \(cmd ?? "nil")")
    }

    func testCwdForOwnProcess() {
        let cwd = VoiceMonitor.cwdViaProcPidInfo(Int(getpid()))
        XCTAssertNotNil(cwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cwd ?? "/nonexistent"))
    }

    func testNonexistentPidReturnsNil() {
        XCTAssertNil(VoiceMonitor.cwdViaProcPidInfo(999_999_99))
        XCTAssertNil(VoiceMonitor.commandLineViaSysctl(999_999_99))
    }
}
