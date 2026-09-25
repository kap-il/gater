import Foundation

public enum EventLogError: Error, Equatable {
    case cannotOpenFile(String)
}

/// Append-only JSONL log at `<repo>/.gater/events.jsonl`. This is the single
/// source of truth for a Gater session — the plan, the map UI, and overlap
/// detection are all derived by replaying it, never mutated in place.
public final class EventLog {
    private let fileURL: URL
    private let fileHandle: FileHandle
    private let encoder: JSONEncoder
    private let queue = DispatchQueue(label: "gater.eventlog")

    public init(path: URL) throws {
        self.fileURL = path
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path.path) {
            guard FileManager.default.createFile(atPath: path.path, contents: nil) else {
                throw EventLogError.cannotOpenFile(path.path)
            }
        }
        guard let handle = FileHandle(forWritingAtPath: path.path) else {
            throw EventLogError.cannotOpenFile(path.path)
        }
        self.fileHandle = handle
        self.fileHandle.seekToEndOfFile()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    @discardableResult
    public func append(_ event: GaterEvent) throws -> GaterEvent {
        var data = try encoder.encode(event)
        data.append(0x0A)
        queue.sync {
            fileHandle.write(data)
        }
        return event
    }

    /// Replays the full log from disk. Malformed lines are skipped rather
    /// than aborting the replay, since a partially-written last line (e.g.
    /// from a crash mid-append) shouldn't take down the whole plan derivation.
    public static func replay(path: URL) throws -> [GaterEvent] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let content = try String(contentsOf: path, encoding: .utf8)
        let decoder = JSONDecoder()
        var events: [GaterEvent] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let event = try? decoder.decode(GaterEvent.self, from: data) else {
                continue
            }
            events.append(event)
        }
        return events
    }

    public func close() {
        try? fileHandle.close()
    }

    deinit {
        try? fileHandle.close()
    }
}
