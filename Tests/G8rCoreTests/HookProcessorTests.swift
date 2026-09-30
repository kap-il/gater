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

    // MARK: - Codex

    /// Codex's notify payload, as codex-rs/hooks/src/legacy_notify.rs
    /// writes it.
    static let codexTurn = """
        {"type":"agent-turn-complete","thread-id":"b5f6c1c2-1111-2222-3333-444455556666","turn-id":"12345",\
        "cwd":"/w/app-cart","client":"codex-tui","input-messages":["Rename `foo` to `bar`."],\
        "last-assistant-message":"Rename complete."}
        """

    func testACodexTurnCompleteIsAStop() throws {
        let build = HookProcessor.Environment(paneId: "build-cart", component: "cart")
        let payload = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(Self.codexTurn.utf8)).objectValue)
        let events = HookProcessor.process(codexNotify: payload, env: build)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.kind, "stop")
        XCTAssertEqual(event.pane, "build-cart")
        XCTAssertEqual(event["component"]?.stringValue, "cart")
        XCTAssertEqual(event["session"]?.stringValue, "b5f6c1c2-1111-2222-3333-444455556666")
        XCTAssertEqual(event["turn"]?.stringValue, "12345")
        XCTAssertEqual(event["agent"]?.stringValue, "codex")
        XCTAssertNil(event["last-assistant-message"], "what the agent said stays out of the log")
    }

    func testAnyOtherCodexNotificationIsKeptRaw() throws {
        let event = try XCTUnwrap(HookProcessor.process(codexNotify: ["type": .string("approval-requested")],
                                                        env: delegate).first)
        XCTAssertEqual(event.kind, "raw")
        XCTAssertEqual(event["hook"]?.stringValue, "approval-requested")
    }

    func testTheArgumentsSayWhereThePayloadIs() {
        var readStdin = false
        let codex = HookProcessor.process(arguments: ["codex-notify", Self.codexTurn],
                                          stdin: { readStdin = true; return Data() }, env: delegate)
        XCTAssertEqual(codex?.map(\.kind), ["stop"])
        XCTAssertFalse(readStdin, "Codex gives notify no standard input")

        let claude = HookProcessor.process(arguments: [], stdin: { Data(#"{"hook_event_name":"Stop"}"#.utf8) },
                                           env: delegate)
        XCTAssertEqual(claude?.map(\.kind), ["stop"])

        XCTAssertNil(HookProcessor.process(arguments: ["codex-notify"], stdin: { Data() }, env: delegate))
        XCTAssertNil(HookProcessor.process(arguments: ["codex-notify", "not json"], stdin: { Data() }, env: delegate))
        XCTAssertNil(HookProcessor.process(arguments: [], stdin: { Data("[]".utf8) }, env: delegate))
    }
}
