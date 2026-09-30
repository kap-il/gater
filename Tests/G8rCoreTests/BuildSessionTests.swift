import XCTest
@testable import G8rCore

final class BuildSessionTests: XCTestCase {
    private func checking(round: Int) -> BuildSession {
        var session = BuildSession(component: "auth")
        for _ in 1..<round {
            _ = session.handle(.wentIdle)
            _ = session.handle(.checked(passed: false, tail: "no"))
        }
        _ = session.handle(.wentIdle)
        return session
    }

    func testStartsWorking() {
        let session = BuildSession(component: "auth")
        XCTAssertEqual(session.component, "auth")
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.failedRounds, 0)
    }

    func testGoingIdleRunsTheFirstRoundOfChecks() {
        var session = BuildSession(component: "auth")
        XCTAssertEqual(session.handle(.wentIdle), .runChecks(round: 1))
        XCTAssertEqual(session.state, .checking(round: 1))
    }

    func testPassingChecksMerge() {
        var session = checking(round: 1)
        XCTAssertEqual(session.handle(.checked(passed: true, tail: "ok")), .merge)
        XCTAssertEqual(session.state, .checking(round: 1), "stays checking until the merge answers")
    }

    func testAMergeClosesTheSession() {
        var session = checking(round: 1)
        _ = session.handle(.checked(passed: true, tail: "ok"))
        XCTAssertEqual(session.handle(.merged(commit: "abc")), .close)
        XCTAssertEqual(session.state, .merged(commit: "abc"))
    }

    func testAFailedMergeNeedsAPerson() {
        var session = checking(round: 1)
        _ = session.handle(.checked(passed: true, tail: "ok"))
        XCTAssertEqual(session.handle(.mergeFailed(reason: "conflicts in a.swift")), .none)
        guard case let .needsHuman(reason) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertTrue(reason.contains("conflicts in a.swift"))
    }

    func testAFailedRoundTellsTheSessionAndWaits() {
        var session = checking(round: 1)
        guard case let .tell(text) = session.handle(.checked(passed: false, tail: "test_command failed")) else {
            return XCTFail("expected tell")
        }
        XCTAssertTrue(text.contains("test_command failed"))
        XCTAssertTrue(text.contains("round 1 of 3"))
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.failedRounds, 1)
    }

    func testTheNextIdleRunsTheNextRound() {
        var session = checking(round: 1)
        _ = session.handle(.checked(passed: false, tail: "no"))
        XCTAssertEqual(session.handle(.wentIdle), .runChecks(round: 2))
        XCTAssertEqual(session.state, .checking(round: 2))
    }

    func testTheSecondFailedRoundStillTells() {
        var session = checking(round: 2)
        guard case let .tell(text) = session.handle(.checked(passed: false, tail: "no")) else {
            return XCTFail("expected tell")
        }
        XCTAssertTrue(text.contains("round 2 of 3"))
        XCTAssertEqual(session.state, .working)
    }

    func testTheThirdFailedRoundStopsTypingAndNeedsAPerson() {
        var session = checking(round: 3)
        XCTAssertEqual(session.state, .checking(round: 3))
        XCTAssertEqual(session.handle(.checked(passed: false, tail: "still red")), .none)
        guard case let .needsHuman(reason) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertTrue(reason.contains("3 times"))
        XCTAssertTrue(reason.contains("still red"))
        XCTAssertEqual(session.failedRounds, BuildSession.maxRounds)
        XCTAssertEqual(session.handle(.wentIdle), .none, "no fourth round")
    }

    func testTheThirdRoundCanStillPass() {
        var session = checking(round: 3)
        XCTAssertEqual(session.handle(.checked(passed: true, tail: "ok")), .merge)
    }

    func testIdleWhileCheckingChangesNothing() {
        var session = checking(round: 1)
        XCTAssertEqual(session.handle(.wentIdle), .none)
        XCTAssertEqual(session.state, .checking(round: 1))
    }

    func testInputsNobodyWaitsForChangeNothing() {
        var working = BuildSession(component: "auth")
        XCTAssertEqual(working.handle(.checked(passed: true, tail: "")), .none)
        XCTAssertEqual(working.handle(.merged(commit: "abc")), .none)
        XCTAssertEqual(working.handle(.mergeFailed(reason: "x")), .none)
        XCTAssertEqual(working.state, .working)

        var merged = checking(round: 1)
        _ = merged.handle(.checked(passed: true, tail: "ok"))
        _ = merged.handle(.merged(commit: "abc"))
        XCTAssertEqual(merged.handle(.wentIdle), .none)
        XCTAssertEqual(merged.handle(.checked(passed: false, tail: "")), .none)
        XCTAssertEqual(merged.state, .merged(commit: "abc"))
    }
}
