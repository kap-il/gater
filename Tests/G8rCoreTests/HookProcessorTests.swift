import XCTest
@testable import G8rCore

final class HookProcessorTests: XCTestCase {
    private let delegate = HookProcessor.Environment(paneId: "delegate-auth")

    func testEditLogsPathAndTool() throws {
        let payload: [String: JSONValue] = [
            "hook_event_name": .string("PostToolUse"), "tool_name": .string("Write"), "session_id": .string("s-1"),
            "tool_input": .object(["file_path": .string("/w/src/auth/session.ts"), "content": .string("x")]),
        ]
        let event = try XCTUnwrap(HookProcessor.process(payload: payload, env: delegate).first)
        XCTAssertEqual(event.kind, "edit")
        XCTAssertEqual(event.pane, "delegate-auth")
        XCTAssertEqual(event["session"]?.stringValue, "s-1")
        XCTAssertEqual(event["path"]?.stringValue, "/w/src/auth/session.ts")
        XCTAssertEqual(event["tool"]?.stringValue, "Write")
        XCTAssertNil(event["content"], "file contents stay out of the log")
    }

    func testBashLogsCommand() throws {
        let payload: [String: JSONValue] = [
            "hook_event_name": .string("PostToolUse"), "tool_name": .string("Bash"),
            "tool_input": .object(["command": .string("npm test"), "description": .string("Run tests")]),
        ]
        let event = try XCTUnwrap(HookProcessor.process(payload: payload, env: delegate).first)
        XCTAssertEqual(event.kind, "command")
        XCTAssertEqual(event["command"]?.stringValue, "npm test")
        XCTAssertEqual(event["description"]?.stringValue, "Run tests")
    }

    func testStopLogsThatTheSessionWentIdle() {
        let payload: [String: JSONValue] = ["hook_event_name": .string("Stop"), "last_assistant_message": .string("done")]
        XCTAssertEqual(HookProcessor.process(payload: payload, env: delegate).map(\.kind), ["stop"])
    }

    func testAnythingElseIsKeptRaw() throws {
        let payload: [String: JSONValue] = ["hook_event_name": .string("Notification"), "message": .string("hi")]
        let event = try XCTUnwrap(HookProcessor.process(payload: payload, env: delegate).first)
        XCTAssertEqual(event.kind, "raw")
        XCTAssertEqual(event["hook"]?.stringValue, "Notification")
        XCTAssertEqual(event["message"]?.stringValue, "hi")
    }

    func testBuildSessionEventsCarryTheirComponent() {
        let build = HookProcessor.Environment(paneId: "build-cart", component: "cart")
        let payload: [String: JSONValue] = ["hook_event_name": .string("Stop")]
        let event = HookProcessor.process(payload: payload, env: build).first
        XCTAssertEqual(event?.pane, "build-cart")
        XCTAssertEqual(event?["component"]?.stringValue, "cart")
        XCTAssertNil(HookProcessor.process(payload: payload, env: delegate).first?["component"],
                     "other panes don't say")
    }
}
