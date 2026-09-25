import XCTest
@testable import GaterCore

final class EventLogTests: XCTestCase {

    private func tempLogPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gater-tests-\(UUID().uuidString)")
            .appendingPathComponent("events.jsonl")
    }

    func testAppendAndReplayRoundTrips() throws {
        let path = tempLogPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let log = try EventLog(path: path)
        try log.append(GaterEvent(kind: "delegation", extra: [
            "pane": .string("orch"),
            "to": .string("pane-A"),
            "gater_id": .string("d-007")
        ]))
        try log.append(GaterEvent(kind: "edit", extra: [
            "pane": .string("pane-A"),
            "path": .string("src/auth/session.ts")
        ]))
        log.close()

        let replayed = try EventLog.replay(path: path)
        XCTAssertEqual(replayed.count, 2)
        XCTAssertEqual(replayed[0].kind, "delegation")
        XCTAssertEqual(replayed[0]["gater_id"]?.stringValue, "d-007")
        XCTAssertEqual(replayed[1].kind, "edit")
        XCTAssertEqual(replayed[1]["path"]?.stringValue, "src/auth/session.ts")
    }

    func testReplayOfMissingFileReturnsEmpty() throws {
        let path = tempLogPath()
        XCTAssertEqual(try EventLog.replay(path: path), [])
    }

    func testReplaySkipsMalformedTrailingLine() throws {
        let path = tempLogPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let log = try EventLog(path: path)
        try log.append(GaterEvent(kind: "edit", extra: ["pane": .string("pane-A")]))
        log.close()

        let handle = try FileHandle(forWritingTo: path)
        handle.seekToEndOfFile()
        handle.write("{not valid json\n".data(using: .utf8)!)
        try handle.close()

        let replayed = try EventLog.replay(path: path)
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(replayed[0].kind, "edit")
    }

    func testAppendCreatesParentDirectory() throws {
        let path = tempLogPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
        _ = try EventLog(path: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    }
}
