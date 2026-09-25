import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Resolves a SendMessage address to the Gater pane behind it.
///
/// Claude Code addresses a peer's reply channel as `uds:<dir>/<pid>.sock`,
/// where pid is that session's `claude` process. Every pane's claude
/// inherits GATER_PANE_ID from Gater, so reading that variable from the
/// process's environment names the pane — no bookkeeping needed.
public enum PaneAddressResolver {
    public static func pane(forAddress address: String) -> String? {
        guard let pid = pid(fromAddress: address) else { return nil }
        return environmentVariable("GATER_PANE_ID", ofProcess: pid)
    }

    static func pid(fromAddress address: String) -> Int32? {
        guard address.hasPrefix("uds:") else { return nil }
        let file = (String(address.dropFirst(4)) as NSString).lastPathComponent
        guard file.hasSuffix(".sock") else { return nil }
        return Int32(file.dropLast(".sock".count))
    }

    /// One environment variable of another (same-user) process.
    public static func environmentVariable(_ name: String, ofProcess pid: Int32) -> String? {
        #if canImport(Darwin)
        // KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding,
        // argv[0..argc), then the environment, all NUL-terminated.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func skipString() { while index < size && buffer[index] != 0 { index += 1 } }
        func skipNULs() { while index < size && buffer[index] == 0 { index += 1 } }

        skipString(); skipNULs() // exec path + padding
        for _ in 0..<argc { skipString(); skipNULs() }

        let prefix = Array("\(name)=".utf8)
        while index < size && buffer[index] != 0 {
            let start = index
            skipString()
            let entry = buffer[start..<index]
            if entry.starts(with: prefix) {
                return String(decoding: entry.dropFirst(prefix.count), as: UTF8.self)
            }
            index += 1
        }
        return nil
        #else
        return nil
        #endif
    }
}
