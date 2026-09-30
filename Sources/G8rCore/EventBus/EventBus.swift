import Foundation

/// Glues the Unix socket transport to the event log: every line a
/// `g8r-hook` invocation sends becomes one JSONL entry, plus a callback
/// for live consumers (overlap detector, map UI) once those exist.
public final class EventBus {
    public typealias EventHandler = (G8rEvent) -> Void

    private let server: UnixSocketServer
    private var eventLog: EventLog?
    /// Guards `eventLog`: lines arrive on the socket's threads, and the app
    /// swaps the log when the project root moves.
    private let logLock = NSLock()
    private let onEvent: EventHandler?
    private let decoder = JSONDecoder()

    /// Answers a request from g8r-hook (JSON in, JSON out). Runs on the
    /// requesting client's thread and may block.
    public typealias RequestHandler = (JSONValue) -> JSONValue

    public init(socketPath: String, eventLog: EventLog? = nil, onEvent: EventHandler? = nil,
                onRequest: RequestHandler? = nil) {
        self.eventLog = eventLog
        self.onEvent = onEvent
        var handler: ((String) -> Void)!
        self.server = UnixSocketServer(path: socketPath, onLine: { line in handler(line) }, onRequest: { line in
            guard let onRequest,
                  let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  let reply = try? JSONEncoder().encode(onRequest(request)) else {
                return #"{"ok":false,"reason":"bad request"}"#
            }
            return String(decoding: reply, as: UTF8.self)
        })
        handler = { [weak self] line in self?.handle(line: line) }
    }

    public func start() throws {
        try server.start()
    }

    /// Appends from now on go to `log`. Returns the log they went to
    /// before, for the caller to close.
    @discardableResult
    public func setEventLog(_ log: EventLog?) -> EventLog? {
        logLock.lock()
        defer { logLock.unlock() }
        let old = eventLog
        eventLog = log
        return old
    }

    public func stop() {
        server.stop()
    }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? decoder.decode(G8rEvent.self, from: data) else {
            return
        }
        logLock.lock()
        if let eventLog { _ = try? eventLog.append(event) }
        logLock.unlock()
        onEvent?(event)
    }

    public static func defaultSocketPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".g8r/g8r.sock")
    }
}
