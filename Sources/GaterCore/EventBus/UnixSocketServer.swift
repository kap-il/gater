import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public enum UnixSocketServerError: Error, Equatable {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// Long-lived Unix domain socket server backing the Gater event bus.
/// One accept loop thread, one reader thread per connected `gater-hook`
/// client (each of which sends exactly one line and disconnects).
public final class UnixSocketServer {
    public typealias LineHandler = (String) -> Void

    private let path: String
    private let onLine: LineHandler
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let stateLock = NSLock()
    private var isRunning = false

    public init(path: String, onLine: @escaping LineHandler) {
        self.path = path
        self.onLine = onLine
    }

    public func start() throws {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketServerError.socketCreationFailed(errno) }

        var addr = try UnixSocketAddress.build(path: path)
        let bindResult = UnixSocketAddress.withSockaddr(&addr) { sockPtr, len in
            bind(fd, sockPtr, len)
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw UnixSocketServerError.bindFailed(err)
        }
        guard listen(fd, 32) == 0 else {
            let err = errno
            close(fd)
            throw UnixSocketServerError.listenFailed(err)
        }

        listenFD = fd
        stateLock.lock(); isRunning = true; stateLock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "gater.eventbus.accept"
        thread.start()
        acceptThread = thread
    }

    private func acceptLoop() {
        while true {
            stateLock.lock(); let running = isRunning; stateLock.unlock()
            guard running else { break }

            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                stateLock.lock(); let stillRunning = isRunning; stateLock.unlock()
                if stillRunning { continue } else { break }
            }
            let clientThread = Thread { [weak self] in self?.handle(clientFD: clientFD) }
            clientThread.start()
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = chunk.withUnsafeMutableBytes { buf -> Int in
                read(clientFD, buf.baseAddress, buf.count)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineBytes = Array(buffer[0..<newlineIndex])
                buffer.removeFirst(newlineIndex + 1)
                if let line = String(bytes: lineBytes, encoding: .utf8), !line.isEmpty {
                    onLine(line)
                }
            }
        }
    }

    public func stop() {
        stateLock.lock(); isRunning = false; stateLock.unlock()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    deinit {
        stop()
    }
}
