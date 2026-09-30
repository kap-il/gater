import XCTest
@testable import G8rCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class EventBusTests: XCTestCase {

    private func tempSocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("g8r-\(UUID().uuidString).sock")
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
            .appendingPathComponent("g8r-tests-\(UUID().uuidString)")
            .appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: logPath.deletingLastPathComponent()) }

        let log = try EventLog(path: logPath)
        let expectation = expectation(description: "event handled")
        var received: G8rEvent?

        let bus = EventBus(socketPath: socketPath, eventLog: log) { event in
            received = event
            expectation.fulfill()
        }
        try bus.start()
        defer { bus.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let event = G8rEvent(kind: "edit", extra: ["pane": .string("pane-A")])
        let line = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        try UnixSocketClient(path: socketPath).send(line: line)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(received?.kind, "edit")

        log.close()
        let replayed = try EventLog.replay(path: logPath)
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(replayed[0].kind, "edit")
    }

    func testRequestGetsAReplyWhileEventsStillFlow() throws {
        let path = NSTemporaryDirectory() + "g8r-req-\(UUID().uuidString.prefix(8)).sock"
        let received = expectation(description: "event")
        let bus = EventBus(socketPath: path, onEvent: { _ in received.fulfill() }, onRequest: { request in
            .object(["ok": .bool(true), "echo": request.value(atPath: "pane") ?? .null])
        })
        try bus.start()
        defer { bus.stop() }

        let reply = try UnixSocketClient(path: path).request(line: #"{"request":"echo","pane":"delegate-x"}"#, timeout: 5)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        XCTAssertEqual(json.value(atPath: "echo")?.stringValue, "delegate-x")

        try UnixSocketClient(path: path).send(line: #"{"kind":"edit","ts":"t"}"#)
        wait(for: [received], timeout: 2)
    }

    /// When the project root moves, the bus writes to the new root's log;
    /// the old log keeps what came before.
    func testSwappingTheLogMovesLaterEvents() throws {
        let socketPath = tempSocketPath()
        defer { unlink(socketPath) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstPath = dir.appendingPathComponent("a/events.jsonl")
        let secondPath = dir.appendingPathComponent("b/events.jsonl")
        let first = try EventLog(path: firstPath)
        let second = try EventLog(path: secondPath)

        var arrived = expectation(description: "first event")
        let bus = EventBus(socketPath: socketPath, eventLog: first) { _ in arrived.fulfill() }
        try bus.start()
        defer { bus.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        try UnixSocketClient(path: socketPath).send(line: #"{"kind":"edit","ts":"t","pane":"one"}"#)
        wait(for: [arrived], timeout: 2)
        XCTAssertTrue(bus.setEventLog(second) === first)
        arrived = expectation(description: "second event")
        try UnixSocketClient(path: socketPath).send(line: #"{"kind":"edit","ts":"t","pane":"two"}"#)
        wait(for: [arrived], timeout: 2)
        first.close()
        second.close()

        XCTAssertEqual(try EventLog.replay(path: firstPath).map(\.pane), ["one"])
        XCTAssertEqual(try EventLog.replay(path: secondPath).map(\.pane), ["two"])
    }
}
