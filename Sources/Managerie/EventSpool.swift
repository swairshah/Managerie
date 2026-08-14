import Foundation

/// Port-free agent ingestion.
///
/// Agents drop NDJSON files into `~/.pi/agent/managerie/events/` instead of
/// connecting to a TCP port. The app watches the directory, ingests each file
/// through the same request pipeline as the (legacy) TCP broker, and deletes
/// it. Writers create `<name>.json.tmp` and rename to `<name>.json` so the
/// watcher never reads half-written files.
///
/// Benefits over ports: no conflicts, no firewall prompts, no "is the server
/// up" races — and events written while the app is closed are delivered on
/// the next launch.
///
/// The app maintains a heartbeat file (`app.alive`, touched every 10s) so
/// agents that want presence info (e.g. the pi extension's status glyph) can
/// check its mtime instead of polling an HTTP health endpoint.
enum EventSpool {
    static var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/managerie", isDirectory: true)
    }

    static var eventsDir: URL {
        baseDir.appendingPathComponent("events", isDirectory: true)
    }

    static var heartbeatURL: URL {
        baseDir.appendingPathComponent("app.alive")
    }

    /// Only fully-renamed event files are eligible for ingestion.
    static func isEventFile(_ name: String) -> Bool {
        name.hasSuffix(".json") && !name.hasPrefix(".")
    }

    /// Chronological processing order. Writers zero-pad the millisecond
    /// timestamp prefix so lexicographic order == arrival order.
    static func sortedEventNames(_ names: [String]) -> [String] {
        names.filter(isEventFile).sorted()
    }

    /// Canonical event file name: sortable timestamp prefix + writer pid +
    /// entropy suffix to avoid same-millisecond collisions.
    static func makeEventFileName(timestampMs: Int64, pid: Int32, entropy: String) -> String {
        // %lld, not %d — millisecond timestamps overflow 32-bit format args.
        String(format: "%013lld-%d-%@.json", timestampMs, pid, entropy)
    }
}

/// Watches the spool directory and feeds each NDJSON line to the handler.
final class EventSpoolWatcher {
    private let handler: (Data) -> Void
    private let queue = DispatchQueue(label: "managerie.eventspool")
    private var source: DispatchSourceFileSystemObject?
    private var heartbeatTimer: DispatchSourceTimer?

    init(handler: @escaping (Data) -> Void) {
        self.handler = handler
    }

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: EventSpool.eventsDir, withIntermediateDirectories: true)

        queue.async { [weak self] in
            self?.touchHeartbeat()
            self?.drain()
        }

        // Watch for new files (renames into the directory count as .write).
        let fd = open(EventSpool.eventsDir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: .write, queue: queue
            )
            src.setEventHandler { [weak self] in self?.drain() }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }

        // Heartbeat keeps `app.alive` fresh so agents can detect presence.
        // Doubles as a safety-net drain in case a directory event is missed.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.touchHeartbeat()
            self?.drain()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    func stop() {
        source?.cancel()
        source = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        try? FileManager.default.removeItem(at: EventSpool.heartbeatURL)
    }

    private func drain() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: EventSpool.eventsDir.path) else { return }

        for name in EventSpool.sortedEventNames(names) {
            let url = EventSpool.eventsDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            try? fm.removeItem(at: url)
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                handler(Data(line))
            }
        }
    }

    private func touchHeartbeat() {
        let payload = String(Int(Date().timeIntervalSince1970))
        try? payload.data(using: .utf8)?.write(to: EventSpool.heartbeatURL, options: .atomic)
    }
}
