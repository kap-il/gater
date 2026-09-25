import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// One-shot client used by `gater-hook`: connect, write a line, disconnect.
/// Hook invocations are short-lived processes, so there's no persistent
/// connection to manage.
public struct UnixSocketClient: EventTransportSending {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func send(line: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EventTransportError.connectFailed(errno) }
        defer { close(fd) }

        var addr = try UnixSocketAddress.build(path: path)
        let connectResult = UnixSocketAddress.withSockaddr(&addr) { sockPtr, len in
            connect(fd, sockPtr, len)
        }
        guard connectResult == 0 else { throw EventTransportError.connectFailed(errno) }

        var payload = Array(line.utf8)
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { buf -> Int in
            write(fd, buf.baseAddress, buf.count)
        }
        guard written == payload.count else { throw EventTransportError.writeFailed(errno) }
    }

    /// Sends a request line and waits for the one-line reply.
    public func request(line: String, timeout: TimeInterval) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EventTransportError.connectFailed(errno) }
        defer { close(fd) }

        var addr = try UnixSocketAddress.build(path: path)
        let connectResult = UnixSocketAddress.withSockaddr(&addr) { sockPtr, len in
            connect(fd, sockPtr, len)
        }
        guard connectResult == 0 else { throw EventTransportError.connectFailed(errno) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var payload = Array(("?" + line).utf8)
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw EventTransportError.writeFailed(errno) }

        var reply = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while !reply.contains(0x0A) {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw EventTransportError.writeFailed(errno) }
            reply.append(contentsOf: chunk[0..<n])
        }
        let end = reply.firstIndex(of: 0x0A)!
        return String(decoding: reply[..<end], as: UTF8.self)
    }
}
