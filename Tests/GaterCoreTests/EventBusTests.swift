import XCTest
@testable import GaterCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class EventBusTests: XCTestCase {

    private func tempSocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gater-\(UUID().uuidString).sock")
            .path
    }

    func testClientServerRoundTrip() throws {
        let socketPath = tempSocketPath()
        defer { unlink(socketPath) }

        let expectation = expectation(description: "line received")
        var receivedLine: String?

        let server = UnixSocketServer(path: socketPath) { line in
            receivedLine = line
            expectation.fulfill()
        }
        try server.start()
        defer { server.stop() }

        // Give the accept loop a moment to actually be listening.
        Thread.sleep(forTimeInterval: 0.05)

        let client = UnixSocketClient(path: socketPath)
        try client.send(line: #"{"kind":"edit","pane":"pane-A"}"#)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedLine, #"{"kind":"edit","pane":"pane-A"}"#)
    }

    func testEventBusAppendsToLogAndNotifiesHandler() throws {
        let socketPath = tempSocketPath()
        defer { unlink(socketPath) }
        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gater-tests-\(UUID().uuidString)")
            .appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: logPath.deletingLastPathComponent()) }

        let log = try EventLog(path: logPath)
        let expectation = expectation(description: "event handled")
        var received: GaterEvent?

        let bus = EventBus(socketPath: socketPath, eventLog: log) { event in
            received = event
            expectation.fulfill()
        }
        try bus.start()
        defer { bus.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let event = GaterEvent(kind: "edit", extra: ["pane": .string("pane-A")])
        let line = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        try UnixSocketClient(path: socketPath).send(line: line)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(received?.kind, "edit")

        log.close()
        let replayed = try EventLog.replay(path: logPath)
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(replayed[0].kind, "edit")
    }
}
