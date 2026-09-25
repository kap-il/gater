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
}
