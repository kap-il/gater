import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

enum UnixSocketAddress {
    /// `sun_path` is a fixed-size C array; this builds the sockaddr_un
    /// bytes for a given filesystem path, erroring if it doesn't fit.
    static func build(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLength else {
            throw EventTransportError.pathTooLong
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buffer = rawPtr.bindMemory(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                buffer[i] = CChar(bitPattern: byte)
            }
            buffer[pathBytes.count] = 0
        }
        return addr
    }

    static func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        try withUnsafePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                try body(sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
