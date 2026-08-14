import Foundation

/// Sends text to a pi session via file-based inbox (pi-messenger style)
final class SendHandler {
    
    struct SendResult {
        let success: Bool
        let message: String?
    }
    
    private static let inboxBaseDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/managerie-inbox")

    /// Legacy inbox watched by the older pi-talk extension. We dual-write so
    /// sessions still running that extension receive messages too.
    private static let legacyInboxBaseDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/pitalk-inbox")
    
    static func send(pid: Int?, tty: String?, mux: String?, text: String, completion: @escaping (SendResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performSend(pid: pid, text: text)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    private static func performSend(pid: Int?, text: String) -> SendResult {
        guard let pid = pid else {
            return SendResult(success: false, message: "No PID")
        }
        
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
}
