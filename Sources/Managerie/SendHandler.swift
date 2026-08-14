import Foundation
import AppKit

/// Sends text into agent sessions.
/// - pi: file-based inbox picked up by the Managerie pi extension
/// - claude-code / codex: herdr `agent prompt` if the agent lives in a herdr
///   pane, else tmux send-keys into the pane owning the agent's TTY, falling
///   back to iTerm2 / Terminal.app AppleScript targeting the same TTY (no
///   tmux required). Ghostty (outside herdr/tmux) has no scripting API — see
///   TODO.md.
final class SendHandler {
    
    struct SendResult {
        let success: Bool
        let message: String?
    }
    
    private static let inboxBaseDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/managerie-inbox")

    /// Legacy inbox watched by the older pi-talk extension. We dual-write so
    /// sessions still running that extension receive messages too.
    private static let legacyInboxBaseDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/pitalk-inbox")
    
    static func send(pid: Int?, tty: String?, mux: String?, text: String, sourceApp: String? = nil, completion: @escaping (SendResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performSend(pid: pid, tty: tty, sourceApp: sourceApp, text: text)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func performSend(pid: Int?, tty: String?, sourceApp: String?, text: String) -> SendResult {
        guard let pid = pid else {
            return SendResult(success: false, message: "No PID")
        }

        // Non-pi agents (claude-code, codex, …) have no inbox watcher —
        // deliver by typing into their terminal (tmux, then iTerm2/Terminal).
        if !usesInboxRoute(sourceApp: sourceApp) {
            return sendViaTerminal(pid: pid, tty: tty, text: text, sourceApp: (sourceApp ?? "?").lowercased())
        }

        return sendViaInbox(pid: pid, text: text)
    }

    /// pi sessions have an extension-side inbox watcher; everything else needs tmux.
    static func usesInboxRoute(sourceApp: String?) -> Bool {
        (sourceApp ?? "pi").trimmingCharacters(in: .whitespaces).lowercased() == "pi"
    }

    // MARK: - Pi inbox route

    private static func sendViaInbox(pid: Int, text: String) -> SendResult {
        print("SendHandler: sending to PID \(pid) via inbox")

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let random = String(format: "%06x", Int.random(in: 0..<0xFFFFFF))
        let filename = "\(timestamp)-\(random).json"

        let message: [String: Any] = [
            "text": text,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "from": "Managerie"
        ]

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message, options: .prettyPrinted)
        } catch {
            return SendResult(success: false, message: "Failed to encode message: \(error.localizedDescription)")
        }

        // Write to the Managerie inbox and, if present, the legacy pi-talk inbox
        // (sessions running the old extension watch the legacy path).
        var wroteAny = false
        var lastError: String?

        for base in [inboxBaseDir, legacyInboxBaseDir] {
            // Only create the legacy tree if the old extension has ever used it.
            if base == legacyInboxBaseDir && !FileManager.default.fileExists(atPath: base) { continue }

            let inboxDir = (base as NSString).appendingPathComponent("\(pid)")
            let filePath = (inboxDir as NSString).appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(atPath: inboxDir, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: filePath))
                print("SendHandler: wrote message to \(filePath)")
                wroteAny = true
            } catch {
                lastError = error.localizedDescription
            }
        }

        if wroteAny {
            return SendResult(success: true, message: "Sent via inbox")
        }
        return SendResult(success: false, message: "Failed to write message: \(lastError ?? "unknown error")")
    }

    // MARK: - Terminal route (claude-code / codex)

    /// Fallback chain: herdr pane → tmux pane → iTerm2 AppleScript → Terminal.app AppleScript.
    private static func sendViaTerminal(pid: Int, tty: String?, text: String, sourceApp: String) -> SendResult {
        // 0. herdr — agents in herdr panes run on herdr's own ptys, so the
        //    TTY-based routes below can never reach them. herdr has a
        //    first-class API for this: `herdr agent prompt <pane> <text>`.
        if let paneId = herdrPaneId(forPid: pid) {
            if runHerdr(["agent", "prompt", paneId, text]) != nil {
                print("SendHandler: sent to \(sourceApp) via herdr pane \(paneId)")
                return SendResult(success: true, message: "Sent via herdr")
            }
            return SendResult(success: false, message: "herdr agent prompt failed for pane \(paneId)")
        }

        let resolvedTty = normalizedTty(tty) ?? ttyForPid(pid)
        guard let ttyName = resolvedTty else {
            return SendResult(success: false, message: "No TTY for PID \(pid) — can't reach \(sourceApp)")
        }

        // 1. tmux — most precise, works in any terminal, never steals focus.
        if let tmux = tmuxBinary(), let target = tmuxTarget(forTty: ttyName, tmux: tmux) {
            // Literal text and Enter must be separate send-keys invocations.
            guard runProcess(tmux, ["send-keys", "-t", target, "-l", text]) != nil else {
                return SendResult(success: false, message: "tmux send-keys failed")
            }
            usleep(80_000) // let the TUI ingest the text before Enter
            guard runProcess(tmux, ["send-keys", "-t", target, "Enter"]) != nil else {
                return SendResult(success: false, message: "tmux send-keys (Enter) failed")
            }
            print("SendHandler: sent to \(sourceApp) via tmux pane \(target)")
            return SendResult(success: true, message: "Sent via tmux")
        }

        // 2. iTerm2 — `write text` targets the session owning the TTY directly,
        //    no tmux and no focus stealing.
        if isAppRunning("iTerm2") {
            let script = """
            try
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with tb in tabs of w
                            repeat with s in sessions of tb
                                try
                                    if (tty of s as text) ends with "\(escapeForAppleScript(ttyName))" then
                                        tell s to write text "\(escapeForAppleScript(text))"
                                        return "ok"
                                    end if
                                end try
                            end repeat
                        end repeat
                    end repeat
                end tell
            end try
            return "no"
            """
            if runAppleScript(script) == "ok" {
                print("SendHandler: sent to \(sourceApp) via iTerm2 (tty \(ttyName))")
                return SendResult(success: true, message: "Sent via iTerm2")
            }
        }

        // 3. Terminal.app — `do script … in tab` types into the tab owning the
        //    TTY (works while a TUI is running; appends a newline).
        if isAppRunning("Terminal") {
            let script = """
            try
                tell application "Terminal"
                    repeat with w in windows
                        repeat with tb in tabs of w
                            try
                                if (tty of tb as text) ends with "\(escapeForAppleScript(ttyName))" then
                                    do script "\(escapeForAppleScript(text))" in tb
                                    return "ok"
                                end if
                            end try
                        end repeat
                    end repeat
                end tell
            end try
            return "no"
            """
            if runAppleScript(script) == "ok" {
                print("SendHandler: sent to \(sourceApp) via Terminal.app (tty \(ttyName))")
                return SendResult(success: true, message: "Sent via Terminal")
            }
        }

        return SendResult(success: false, message: "Can't reach \(sourceApp) (PID \(pid)) — no herdr/tmux pane or iTerm2/Terminal tab owns \(ttyName). Ghostty replies need herdr or tmux for now.")
    }

    // MARK: - herdr route

    private struct HerdrAgentListResponse: Decodable {
        struct Result: Decodable { let agents: [Agent] }
        struct Agent: Decodable { let paneId: String }
        let result: Result
    }

    private struct HerdrProcessInfoResponse: Decodable {
        struct Result: Decodable { let processInfo: ProcessInfo }
        struct ProcessInfo: Decodable {
            struct ForegroundProcess: Decodable { let pid: Int }
            let shellPid: Int?
            let foregroundProcesses: [ForegroundProcess]?
        }
        let result: Result
    }

    /// Find the herdr pane whose shell or foreground process is `pid`.
    /// Same matching approach as JumpHandler.jumpViaHerdr.
    private static func herdrPaneId(forPid pid: Int) -> String? {
        guard let listData = runHerdr(["agent", "list"]),
              let list = decodeHerdr(HerdrAgentListResponse.self, from: listData) else {
            return nil
        }
        for agent in list.result.agents {
            guard let infoData = runHerdr(["pane", "process-info", "--pane", agent.paneId]),
                  let info = decodeHerdr(HerdrProcessInfoResponse.self, from: infoData) else {
                continue
            }
            let p = info.result.processInfo
            if p.shellPid == pid || p.foregroundProcesses?.contains(where: { $0.pid == pid }) == true {
                return agent.paneId
            }
        }
        return nil
    }

    private static func decodeHerdr<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
    }

    private static func herdrExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            "\(home)/.local/bin/herdr",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private static func runHerdr(_ arguments: [String]) -> Data? {
        guard let executableURL = herdrExecutableURL() else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    // MARK: - AppleScript helpers

    private static func isAppRunning(_ appName: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == appName || $0.bundleIdentifier?.hasSuffix(appName.lowercased()) == true
        }
    }

    static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ script: String, timeout: TimeInterval = 5.0) -> String {
        var result = "timeout"
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                let output = appleScript.executeAndReturnError(&error)
                result = error == nil ? (output.stringValue ?? "") : "error"
            } else {
                result = "error"
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    /// "ttys012", "/dev/ttys012" → "/dev/ttys012"; "??" → nil
    static func normalizedTty(_ tty: String?) -> String? {
        guard var tty = tty?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tty.isEmpty, tty != "??" else { return nil }
        if !tty.hasPrefix("/dev/") { tty = "/dev/" + tty }
        return tty
    }

    private static func ttyForPid(_ pid: Int) -> String? {
        guard let out = runProcess("/bin/ps", ["-o", "tty=", "-p", "\(pid)"]) else { return nil }
        return normalizedTty(out)
    }

    private static func tmuxBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Fall back to PATH resolution
        if let out = runProcess("/usr/bin/env", ["sh", "-c", "command -v tmux"]),
           !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func tmuxTarget(forTty ttyPath: String, tmux: String) -> String? {
        guard let out = runProcess(tmux, ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index}\t#{pane_tty}"]) else {
            return nil
        }
        return parseTmuxPaneTarget(out, ttyPath: ttyPath)
    }

    /// Parse tab-separated `list-panes -F "#{target}\t#{pane_tty}"` output.
    /// Tab-delimited so session names containing spaces survive.
    static func parseTmuxPaneTarget(_ output: String, ttyPath: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[1] == ttyPath {
                return parts[0]
            }
        }
        return nil
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
