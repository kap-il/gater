import XCTest
@testable import G8rCore

final class WiredAgentTests: XCTestCase {
    private let launch = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!

    private func started(_ agent: String, pane: String = "shell-1", at offset: TimeInterval) -> G8rEvent {
        G8rEvent(kind: "agent_started", ts: launch.addingTimeInterval(offset),
                 extra: ["agent": .string(agent), "pane": .string(pane)])
    }

    func testThereIsNoneUntilAnAgentStarts() {
        var wired = WiredAgent(since: launch)
        XCTAssertNil(wired.agent)
        XCTAssertFalse(wired.note(G8rEvent(kind: "stop", ts: launch.addingTimeInterval(5), extra: ["pane": .string("shell-1")])))
        XCTAssertNil(wired.agent)
        XCTAssertEqual(WiredAgent.missing, "Start claude or codex in a shell to build.")
    }

    func testTheLastStartedAgentWins() {
        var wired = WiredAgent(since: launch)
        XCTAssertTrue(wired.note(started("claude", at: 1)))
        XCTAssertEqual(wired.agent, .claudeCode)
        XCTAssertTrue(wired.note(started("codex", pane: "shell-2", at: 2)))
        XCTAssertEqual(wired.agent, .codex)
        XCTAssertEqual(wired.pane, "shell-2")
        XCTAssertFalse(wired.note(started("codex", at: 3)), "the same agent again changes nothing")
        XCTAssertTrue(wired.note(started("claude", at: 4)))
        XCTAssertEqual(wired.agent, .claudeCode)
    }

    func testAnAgentFromAnEarlierRunDoesntCount() {
        var wired = WiredAgent(since: launch.addingTimeInterval(0.7))
        XCTAssertFalse(wired.note(started("codex", at: -60)), "replayed from the log")
        XCTAssertNil(wired.agent)
        XCTAssertTrue(wired.note(started("codex", at: 0)), "the second the app started counts")
        XCTAssertFalse(wired.note(started("claude", at: -1)))
        XCTAssertEqual(wired.agent, .codex)
    }

    func testAnUnknownOrUndatedAgentDoesntCount() {
        var wired = WiredAgent(since: launch)
        XCTAssertFalse(wired.note(started("gemini", at: 1)))
        XCTAssertFalse(wired.note(G8rEvent(fields: ["kind": .string("agent_started"), "agent": .string("claude")])))
        XCTAssertNil(wired.agent)
    }

    func testBusyUntilItsPaneStops() {
        var wired = WiredAgent(since: launch)
        func event(_ kind: String, pane: String = "shell-1") -> G8rEvent {
            G8rEvent(kind: kind, ts: launch.addingTimeInterval(5), extra: ["pane": .string(pane)])
        }
        wired.note(event("edit"))
        XCTAssertFalse(wired.busy, "no agent yet")
        wired.note(started("claude", at: 1))
        XCTAssertFalse(wired.busy, "a new agent waits at its prompt")
        wired.note(event(ChangeRequest.eventKind))
        XCTAssertTrue(wired.busy)
        wired.note(event("stop", pane: "shell-2"))
        XCTAssertTrue(wired.busy, "another pane's stop")
        wired.note(event("stop"))
        XCTAssertFalse(wired.busy)
        wired.note(event("command"))
        XCTAssertTrue(wired.busy)
        wired.note(started("codex", pane: "shell-2", at: 2))
        XCTAssertFalse(wired.busy)
    }
}
