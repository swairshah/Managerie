import Foundation
import ManagerieClient

/// mnote - Managerie command line interface
///
/// Usage:
///   mnote "Hello world"                    # Enqueue speech in Managerie broker
///   mnote --voice alba "Hello"             # Use specific voice
///   echo "Hello" | mnote                   # Read from stdin
///   mnote --list-voices                     # List available voices
///   mnote --stop                            # Stop current/queued speech

struct CLI {
    var text: String = ""
    var voice: String? = nil  // nil = let Managerie auto-assign
    var port: Int = 18090
    var brokerPort: Int = 18091
    var host: String = "127.0.0.1"
    var sessionId: String?
    var listVoices: Bool = false
    var stopSpeech: Bool = false
    var showHelp: Bool = false
    var quiet: Bool = false
}

struct BrokerRequest: Encodable {
    let type: String
    let text: String?
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int32?
}

struct BrokerResponse: Decodable {
    let ok: Bool?
    let error: String?
    let queued: Int?
    let pending: Int?
    let playing: Bool?
}

func printUsage() {
    let usage = """
    mnote - Managerie command line text-to-speech

    USAGE:
        mnote [OPTIONS] <TEXT>
        echo "text" | mnote [OPTIONS]

    ARGUMENTS:
        <TEXT>    Text to speak (can also be piped via stdin)

    OPTIONS:
        -v, --voice <VOICE>   Voice to use (default: auto-assigned by Managerie)
        -p, --port <PORT>     TTS server port (default: 18090)
        -b, --broker-port <PORT>
                              Broker queue port (default: 18091)
        -H, --host <HOST>     Server host (default: 127.0.0.1)
        -S, --session-id <ID> Session identifier attached to broker requests
        -q, --quiet           Suppress status messages
        -l, --list-voices     List available voices
        -s, --stop            Stop current/queued speech
        -h, --help            Show this help message

    EXAMPLES:
        mnote "Hello, world!"
        mnote -v alba "Good morning"
        echo "Long text from file" | mnote
        mnote --session-id pi-session-abc123 "Hello from a specific session"

    VOICES:
        ally, dorothy, lily, alice, dave, joseph
        george, emma, oliver, sophia, charlotte, william, jack, olivia, isla, liam
        draco, pandora, hyperion, theia, angus
        alba, vera, paul, charles, michael, anna, fantine, eponine, cosette, eve
        mary, marius, javert, azelma, caro_davy, peter_yearsley, stuart_bell

    NOTE:
        Requires Managerie.app to be running.
        Default mode enqueues speech in Managerie's local broker queue for centralized playback.
    """
    FileHandle.standardError.write(usage.data(using: .utf8)!)
}

func parseArgs() -> CLI {
    var cli = CLI()
    let args = Array(CommandLine.arguments.dropFirst())
    var positionalArgs: [String] = []

    var i = 0
    while i < args.count {
        let arg = args[i]

        switch arg {
        case "-h", "--help":
            cli.showHelp = true
            return cli
        case "-l", "--list-voices":
            cli.listVoices = true
            return cli
        case "-s", "--stop":
            cli.stopSpeech = true
            return cli
        case "-v", "--voice":
            i += 1
            if i < args.count {
                cli.voice = args[i]
            }
        case "-p", "--port":
            i += 1
            if i < args.count, let port = Int(args[i]) {
                cli.port = port
            }
        case "-b", "--broker-port":
            i += 1
            if i < args.count, let brokerPort = Int(args[i]) {
                cli.brokerPort = brokerPort
            }
        case "-H", "--host":
            i += 1
            if i < args.count {
                cli.host = args[i]
            }
        case "-S", "--session-id":
            i += 1
            if i < args.count {
                cli.sessionId = args[i]
            }
        case "-q", "--quiet":
            cli.quiet = true
        default:
            if arg.hasPrefix("-") {
                FileHandle.standardError.write("Unknown option: \(arg)\n".data(using: .utf8)!)
            } else {
                positionalArgs.append(arg)
            }
        }
        i += 1
    }

    cli.text = positionalArgs.joined(separator: " ")
    return cli
}

// MARK: - File spool transport (port-free)
//
// mnote drops NDJSON event files into ~/.pi/agent/managerie/events/ where the
// Managerie app picks them up. No ports, no server races — events written
// while the app is closed are delivered on its next launch.

let spoolBaseDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".pi/agent/managerie", isDirectory: true)
let spoolEventsDir = spoolBaseDir.appendingPathComponent("events", isDirectory: true)
let heartbeatFile = spoolBaseDir.appendingPathComponent("app.alive")

/// The app touches its heartbeat file every 10s while running.
func managerieAppAlive(maxAge: TimeInterval = 30) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: heartbeatFile.path),
          let modified = attrs[.modificationDate] as? Date else {
        return false
    }
    return Date().timeIntervalSince(modified) < maxAge
}

/// Atomic spool write: tmp file + rename so the app never reads partial JSON.
func sendViaSpool(request: BrokerRequest) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: spoolEventsDir, withIntermediateDirectories: true)

    var payload = try JSONEncoder().encode(request)
    payload.append(0x0A)

    let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
    let entropy = String(UUID().uuidString.prefix(6)).lowercased()
    // %lld, not %d — millisecond timestamps overflow 32-bit format args.
    let name = String(format: "%013lld-%d-%@.json", timestampMs, getpid(), entropy)

    let tmpURL = spoolEventsDir.appendingPathComponent(".\(name).tmp")
    try payload.write(to: tmpURL)
    _ = try fm.replaceItemAt(spoolEventsDir.appendingPathComponent(name), withItemAt: tmpURL)
}

func stopViaSpool() throws {
    try sendViaSpool(request: BrokerRequest(type: "stop", text: nil, voice: nil, sourceApp: "mnote", sessionId: nil, pid: getpid()))
}

func enqueueViaSpool(text: String, voice: String?, sessionId: String?) throws {
    try sendViaSpool(request: BrokerRequest(type: "speak", text: text, voice: voice, sourceApp: "mnote", sessionId: sessionId, pid: getpid()))
}

func main() async {
    let cli = parseArgs()

    if cli.showHelp {
        printUsage()
        exit(0)
    }

    if cli.listVoices {
        print("Available voices:")
        for voice in TTSClient.availableVoices {
            print("  \(voice)")
        }
        exit(0)
    }

    if cli.stopSpeech {
        do {
            try stopViaSpool()
            if !cli.quiet {
                FileHandle.standardError.write("Stop request sent.\n".data(using: .utf8)!)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write("Error stopping speech: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // Get text from args or stdin
    var text = cli.text

    if text.isEmpty {
        // Check if stdin has data (isatty returns 0 when NOT a tty, i.e., piped input)
        if isatty(STDIN_FILENO) == 0 {
            if let stdinData = try? FileHandle.standardInput.readToEnd(),
               let stdinText = String(data: stdinData, encoding: .utf8) {
                text = stdinText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    if text.isEmpty {
        FileHandle.standardError.write("Error: No text provided. Use mnote --help for usage.\n".data(using: .utf8)!)
        exit(1)
    }

    // Validate voice if explicitly specified
    if let voice = cli.voice, !TTSClient.availableVoices.contains(voice) {
        FileHandle.standardError.write("Warning: Unknown voice '\(voice)'\n".data(using: .utf8)!)
    }

    // Send via spool. Works even when the app is closed — warn in that case
    // so the user knows delivery happens on next launch.
    do {
        try enqueueViaSpool(text: text, voice: cli.voice, sessionId: cli.sessionId)
        if !cli.quiet {
            if managerieAppAlive() {
                FileHandle.standardError.write("Sent to Managerie.\n".data(using: .utf8)!)
            } else {
                FileHandle.standardError.write("Queued — Managerie isn't running; delivered on next launch.\n".data(using: .utf8)!)
            }
        }
    } catch {
        FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Run async main
let semaphore = DispatchSemaphore(value: 0)
Task {
    await main()
    semaphore.signal()
}
semaphore.wait()
