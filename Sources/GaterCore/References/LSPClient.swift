import Foundation

public enum LSPError: Error, Equatable, CustomStringConvertible {
    case launchFailed(String)
    case timedOut(method: String)
    case serverExited
    case responseError(code: Int, message: String)

    public var description: String {
        switch self {
        case let .launchFailed(why): return "language server failed to launch: \(why)"
        case let .timedOut(method): return "language server timed out on \(method)"
        case .serverExited: return "language server exited"
        case let .responseError(code, message): return "language server error \(code): \(message)"
        }
    }
}

/// A JSON-RPC connection to a language server over stdio with LSP's
/// Content-Length framing (spec §4.8).
///
/// Synchronous by design: callers are Gater's background queues, and a
/// server answers one query at a time anyway. A reader thread parses
/// frames, hands responses to waiting requests, and answers the server's
/// own requests (configuration, capability registration, progress) with
/// empty results so it never stalls waiting on us.
public final class LSPClient {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: (DispatchSemaphore, Box)] = [:]
    private var exited = false

    private final class Box: @unchecked Sendable {
        var result: Result<JSONValue, LSPError>?
    }

    public init(executable: String, arguments: [String], workingDirectory: String) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.failAll() }
        do {
            try process.run()
        } catch {
            throw LSPError.launchFailed("\(executable): \(error)")
        }
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "gater.lsp.reader"
        thread.start()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    public var isRunning: Bool { process.isRunning }

    // MARK: - Sending

    public func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = 20) throws -> JSONValue {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        lock.lock()
        guard !exited else { lock.unlock(); throw LSPError.serverExited }
        let id = nextId
        nextId += 1
        pending[id] = (semaphore, box)
        lock.unlock()

        try send(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]))
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            lock.lock(); pending[id] = nil; lock.unlock()
            throw LSPError.timedOut(method: method)
        }
        return try box.result!.get()
    }

    public func notify(_ method: String, _ params: JSONValue) throws {
        try send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    /// Polite shutdown; kills the process if it doesn't comply.
    public func shutdown() {
        _ = try? request("shutdown", .null, timeout: 3)
        try? notify("exit", .null)
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
    }

    private func send(_ message: JSONValue) throws {
        let body = try JSONEncoder().encode(message)
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        lock.lock(); defer { lock.unlock() }
        guard !exited else { throw LSPError.serverExited }
        stdin.fileHandleForWriting.write(frame)
    }

    // MARK: - Reading

    private func readLoop() {
        let handle = stdout.fileHandleForReading
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break } // EOF
            buffer.append(chunk)
            while let headerEnd = buffer.range(of: separator) {
                let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                guard let length = header.split(separator: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap({ Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }) else {
                    buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                    continue
                }
                let bodyStart = headerEnd.upperBound
                guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
                let bodyEnd = buffer.index(bodyStart, offsetBy: length)
                let body = buffer[bodyStart..<bodyEnd]
                buffer.removeSubrange(buffer.startIndex..<bodyEnd)
                if let message = try? JSONDecoder().decode(JSONValue.self, from: Data(body)) {
                    dispatch(message)
                }
            }
        }
        failAll()
    }

    private func dispatch(_ message: JSONValue) {
        let method = message.value(atPath: "method")?.stringValue
        let idValue = message.value(atPath: "id")

        if let method, let idValue {
            // A request from the server. Configuration requests want one
            // entry per requested item; everything else gets null.
            var result = JSONValue.null
            if method == "workspace/configuration" {
                let count = message.value(atPath: "params.items")?.arrayValue?.count ?? 0
                result = .array(Array(repeating: .null, count: count))
            }
            try? send(.object(["jsonrpc": .string("2.0"), "id": idValue, "result": result]))
            return
        }
        guard method == nil, case let .number(n)? = idValue else { return } // notification
        lock.lock()
        let waiter = pending.removeValue(forKey: Int(n))
        lock.unlock()
        guard let (semaphore, box) = waiter else { return }
        if let error = message.value(atPath: "error") {
            var code = 0
            if case let .number(c)? = error.value(atPath: "code") { code = Int(c) }
            box.result = .failure(.responseError(code: code, message: error.value(atPath: "message")?.stringValue ?? ""))
        } else {
            box.result = .success(message.value(atPath: "result") ?? .null)
        }
        semaphore.signal()
    }

    private func failAll() {
        lock.lock()
        exited = true
        let waiters = pending
        pending = [:]
        lock.unlock()
        for (_, (semaphore, box)) in waiters {
            box.result = .failure(.serverExited)
            semaphore.signal()
        }
    }
}
