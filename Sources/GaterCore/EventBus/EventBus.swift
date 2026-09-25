import Foundation

/// Glues the Unix socket transport to the event log: every line a
/// `gater-hook` invocation sends becomes one JSONL entry, plus a callback
/// for live consumers (overlap detector, map UI) once those exist.
public final class EventBus {
    public typealias EventHandler = (GaterEvent) -> Void

    private let server: UnixSocketServer
    private let eventLog: EventLog?
    private let onEvent: EventHandler?
    private let decoder = JSONDecoder()

    public init(socketPath: String, eventLog: EventLog? = nil, onEvent: EventHandler? = nil) {
        self.eventLog = eventLog
        self.onEvent = onEvent
        var handler: ((String) -> Void)!
        self.server = UnixSocketServer(path: socketPath, onLine: { line in handler(line) })
        handler = { [weak self] line in self?.handle(line: line) }
    }

    public func start() throws {
        try server.start()
    }

    public func stop() {
        server.stop()
    }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? decoder.decode(GaterEvent.self, from: data) else {
            return
        }
        if let eventLog { _ = try? eventLog.append(event) }
        onEvent?(event)
    }

    public static func defaultSocketPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".gater/gater.sock")
    }
}
