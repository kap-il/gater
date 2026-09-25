import XCTest
@testable import GaterCore

final class HookProcessorTests: XCTestCase {
    private let orch = HookProcessor.Environment(paneId: "orch", role: "orchestrator")
    private let delegate = HookProcessor.Environment(paneId: "delegate-auth", role: "delegate")

    private let validDelegation = """
    GATER/1
    type: delegate
    id: d-007
    feature: Auth
    directive: add session expiry
    scope: src/auth/**
    ---
    Add expiry to sessions. End with a GATER-DONE note.
    """

    private func send(_ hook: String, message: String, to: String = "delegate-auth") -> [String: JSONValue] {
        [
            "hook_event_name": .string(hook),
            "tool_name": .string("SendMessage"),
            "session_id": .string("s-1"),
            "tool_input": .object(["to": .string(to), "message": .string(message), "summary": .string("auth expiry")]),
        ]
    }

    // MARK: - SendMessage

    func testOrchestratorMalformedSendIsBlockedWithFormatHelp() {
        let outcome = HookProcessor.process(payload: send("PreToolUse", message: "hey, go do auth"), env: orch)
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertTrue(outcome.stderr?.contains("GATER/1") ?? false)
        XCTAssertTrue(outcome.events.isEmpty)
    }

    func testOrchestratorValidSendPassesPreToolUseSilently() {
        let outcome = HookProcessor.process(payload: send("PreToolUse", message: validDelegation), env: orch)
        XCTAssertEqual(outcome, HookOutcome(events: [], exitCode: 0, stderr: nil))
    }

    func testDelegateSendsAreNeverBlocked() {
        let outcome = HookProcessor.process(payload: send("PreToolUse", message: "done, see note", to: "orch"), env: delegate)
        XCTAssertEqual(outcome.exitCode, 0)
    }

    func testPostToolUseLogsDelegationWithRecipientAndParsedBlock() throws {
        let outcome = HookProcessor.process(payload: send("PostToolUse", message: validDelegation), env: orch)
        let event = try XCTUnwrap(outcome.events.first)
        XCTAssertEqual(event.kind, "delegation")
        XCTAssertEqual(event.pane, "orch")
        XCTAssertEqual(event["to"]?.stringValue, "delegate-auth")
        XCTAssertEqual(event["session"]?.stringValue, "s-1")
        XCTAssertEqual(event.fields["gater"]?.value(atPath: "type")?.stringValue, "delegate")
        XCTAssertEqual(event.fields["gater"]?.value(atPath: "id")?.stringValue, "d-007")
        XCTAssertEqual(event.fields["gater"]?.value(atPath: "feature")?.stringValue, "Auth")
        XCTAssertEqual(event.fields["gater"]?.value(atPath: "scope")?.arrayValue?.first?.stringValue, "src/auth/**")
        XCTAssertEqual(event["raw"]?.stringValue, validDelegation)
    }

    func testDelegateReplyIsLoggedAsPlainMessage() throws {
        let outcome = HookProcessor.process(payload: send("PostToolUse", message: "all done", to: "orch"), env: delegate)
        let event = try XCTUnwrap(outcome.events.first)
        XCTAssertEqual(event.kind, "message")
        XCTAssertEqual(event["to"]?.stringValue, "orch")
        XCTAssertNil(event.fields["gater"])
    }

    func testReplyAddressIsResolvedToPane() throws {
        let payload = send("PostToolUse", message: "sunny", to: "uds:/tmp/cc-socks/76756.sock")
        let outcome = HookProcessor.process(payload: payload, env: delegate,
                                            resolvePane: { $0.hasSuffix("76756.sock") ? "orch" : nil })
        XCTAssertEqual(outcome.events.first?["to_pane"]?.stringValue, "orch")
        XCTAssertEqual(outcome.events.first?["to"]?.stringValue, "uds:/tmp/cc-socks/76756.sock")
    }

    // MARK: - Plan-aware id checks

    private func orch(with events: [GaterEvent]) -> HookProcessor.Environment {
        HookProcessor.Environment(paneId: "orch", role: "orchestrator", plan: PlanReducer.replay(events))
    }

    private func block(_ type: String, id: String, extra: String = "") -> String {
        "GATER/1\ntype: \(type)\nid: \(id)\nfeature: Auth\ndirective: do it\n\(extra)---\nbody"
    }

    func testInstructForUnknownDishIsBlockedWithNextId() {
        // Exactly the live-test slip: new work sent as `instruct d-001`.
        let outcome = HookProcessor.process(payload: send("PreToolUse", message: block("instruct", id: "d-001")),
                                            env: orch(with: []))
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertTrue(outcome.stderr?.contains("type: delegate with id: d-001") ?? false, outcome.stderr ?? "")
    }

    func testDelegateReusingIdIsBlocked() {
        let existing = HookProcessor.process(payload: send("PostToolUse", message: validDelegation), env: self.orch)
        let outcome = HookProcessor.process(payload: send("PreToolUse", message: validDelegation),
                                            env: orch(with: existing.events))
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertTrue(outcome.stderr?.contains("next free is d-008") ?? false, outcome.stderr ?? "")
    }

    func testValidFollowUpPasses() {
        let existing = HookProcessor.process(payload: send("PostToolUse", message: validDelegation), env: self.orch)
        let outcome = HookProcessor.process(payload: send("PreToolUse", message: block("instruct", id: "d-007")),
                                            env: orch(with: existing.events))
        XCTAssertEqual(outcome.exitCode, 0, outcome.stderr ?? "")
    }

    func testMergeIntoMissingDishIsBlocked() {
        let existing = HookProcessor.process(payload: send("PostToolUse", message: validDelegation), env: self.orch)
        let merge = "GATER/1\ntype: merge\nid: d-007\nmerge_into: d-099\n---\nfold"
        let outcome = HookProcessor.process(payload: send("PreToolUse", message: merge), env: orch(with: existing.events))
        XCTAssertEqual(outcome.exitCode, 2)
    }

    // MARK: - Edits and commands

    func testEditLogsPathAndTool() throws {
        let payload: [String: JSONValue] = [
            "hook_event_name": .string("PostToolUse"), "tool_name": .string("Write"),
            "tool_input": .object(["file_path": .string("/w/src/auth/session.ts"), "content": .string("x")]),
        ]
        let event = try XCTUnwrap(HookProcessor.process(payload: payload, env: delegate).events.first)
        XCTAssertEqual(event.kind, "edit")
        XCTAssertEqual(event["path"]?.stringValue, "/w/src/auth/session.ts")
        XCTAssertEqual(event["tool"]?.stringValue, "Write")
        XCTAssertNil(event["content"], "file contents stay out of the log")
    }

    func testBashLogsCommand() throws {
        let payload: [String: JSONValue] = [
            "hook_event_name": .string("PostToolUse"), "tool_name": .string("Bash"),
            "tool_input": .object(["command": .string("npm test"), "description": .string("Run tests")]),
        ]
        let event = try XCTUnwrap(HookProcessor.process(payload: payload, env: delegate).events.first)
        XCTAssertEqual(event.kind, "command")
        XCTAssertEqual(event["command"]?.stringValue, "npm test")
    }

    // MARK: - Stop / GATER-DONE

    private let doneText = """
    Implemented expiry.

    GATER-DONE d-007
    did: added expiresAt to sessions
    assumed: getUser(id) signature unchanged
    touched: src/auth/session.ts
    """

    func testStopWithLastAssistantMessageEmitsDoneNote() throws {
        let payload: [String: JSONValue] = ["hook_event_name": .string("Stop"), "last_assistant_message": .string(doneText)]
        let events = HookProcessor.process(payload: payload, env: delegate).events
        XCTAssertEqual(events.map(\.kind), ["stop", "done_note"])
        XCTAssertEqual(events[1]["dish"]?.stringValue, "d-007")
        XCTAssertEqual(events[1]["assumed"]?.stringValue, "getUser(id) signature unchanged")
    }

    func testStopFallsBackToTranscript() throws {
        let transcript = [
            #"{"type":"user","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit"},{"type":"text","text":"\#(doneText.replacingOccurrences(of: "\n", with: "\\n"))"}]}}"#,
        ].joined(separator: "\n")
        let payload: [String: JSONValue] = ["hook_event_name": .string("Stop"), "transcript_path": .string("/t.jsonl")]
        let events = HookProcessor.process(payload: payload, env: delegate, readTranscript: { _ in transcript }).events
        XCTAssertEqual(events.map(\.kind), ["stop", "done_note"])
    }

    func testStopWithoutNoteIsJustStop() {
        let payload: [String: JSONValue] = ["hook_event_name": .string("Stop"), "last_assistant_message": .string("hi")]
        XCTAssertEqual(HookProcessor.process(payload: payload, env: delegate).events.map(\.kind), ["stop"])
    }
}

final class PaneAddressResolverTests: XCTestCase {
    func testPidParsing() {
        XCTAssertEqual(PaneAddressResolver.pid(fromAddress: "uds:/tmp/cc-socks/76756.sock"), 76756)
        XCTAssertNil(PaneAddressResolver.pid(fromAddress: "delegate-auth"))
        XCTAssertNil(PaneAddressResolver.pid(fromAddress: "uds:/tmp/x.txt"))
    }

    #if os(macOS)
    func testReadsGaterPaneIdFromAnotherProcess() throws {
        // macOS withholds the environment of Apple platform binaries like
        // /bin/sleep, so use an ad-hoc-signed copy — an ordinary binary,
        // like claude.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gater-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sleeper = dir.appendingPathComponent("sleeper")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: sleeper.path)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", sleeper.path]
        try sign.run()
        sign.waitUntilExit()

        let child = Process()
        child.executableURL = sleeper
        child.arguments = ["5"]
        child.environment = ["GATER_PANE_ID": "delegate-auth", "OTHER": "1"]
        try child.run()
        defer { child.terminate() }
        // Right after run() the child may not have exec'd yet; wait for it.
        let deadline = Date().addingTimeInterval(2)
        while PaneAddressResolver.environmentVariable("OTHER", ofProcess: child.processIdentifier) == nil,
              Date() < deadline { usleep(10_000) }
        let address = "uds:/tmp/cc-socks/\(child.processIdentifier).sock"
        XCTAssertEqual(PaneAddressResolver.pane(forAddress: address), "delegate-auth")
        XCTAssertEqual(PaneAddressResolver.environmentVariable("OTHER", ofProcess: child.processIdentifier), "1")
        XCTAssertNil(PaneAddressResolver.environmentVariable("MISSING", ofProcess: child.processIdentifier))
    }
    #endif
}
