import Foundation

/// Behind this interface so the V1 Unix-socket transport can be swapped for
/// an HTTP collector later (spec §9) without touching callers.
public protocol EventTransportSending {
    /// Sends one already-serialized JSON line (no trailing newline) to the collector.
    func send(line: String) throws
}

public enum EventTransportError: Error, Equatable {
    case invalidAddress(String)
    case connectFailed(Int32)
    case writeFailed(Int32)
    case pathTooLong
}
