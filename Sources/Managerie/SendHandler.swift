import Foundation

/// Sends text into agent sessions.
/// - pi: file-based inbox picked up by the Managerie pi extension
/// - claude-code / codex: tmux send-keys into the pane owning the agent's TTY
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
        // deliver via tmux send-keys instead.
        if !usesInboxRoute(sourceApp: sourceApp) {
            return sendViaTmux(pid: pid, tty: tty, text: text, sourceApp: (sourceApp ?? "?").lowercased())
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

    // MARK: - tmux route (claude-code / codex)

    private static func sendViaTmux(pid: Int, tty: String?, text: String, sourceApp: String) -> SendResult {
        let resolvedTty = normalizedTty(tty) ?? ttyForPid(pid)
        guard let ttyName = resolvedTty else {
            return SendResult(success: false, message: "No TTY for PID \(pid) — can't reach \(sourceApp)")
        }

        guard let tmux = tmuxBinary() else {
            return SendResult(success: false, message: "tmux not found — replies to \(sourceApp) require the session to run inside tmux")
        }

        guard let target = tmuxTarget(forTty: ttyName, tmux: tmux) else {
            return SendResult(success: false, message: "No tmux pane for \(sourceApp) (PID \(pid)) — run the session inside tmux to enable replies")
        }

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
