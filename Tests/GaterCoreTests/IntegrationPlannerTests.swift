import XCTest
@testable import GaterCore

final class IntegrationPlannerTests: XCTestCase {
    private func decide(finished: [String], served: [String] = [], deps: [String: [String]]) -> IntegrationPlanner.Decision {
        IntegrationPlanner.decide(finished: Set(finished), served: Set(served),
                                  dependencies: deps.mapValues(Set.init))
    }

    func testIndependentDishesMergeInAnyOrder() {
        let d = decide(finished: ["d-001", "d-002"], deps: [:])
        XCTAssertEqual(Set(d.merge.map { $0 }), [["d-001"], ["d-002"]])
        XCTAssertTrue(d.held.isEmpty)
    }

    /// Golden scenario: Dashboard (d-002) uses Auth's (d-001) getUser.
    func testUserWaitsForTheDishItDependsOn() {
        var d = decide(finished: ["d-002"], deps: ["d-002": ["d-001"]])
        XCTAssertEqual(d.merge, [])
        XCTAssertEqual(d.held, ["d-002": ["d-001"]], "map shows: waiting on d-001")

        d = decide(finished: ["d-001", "d-002"], deps: ["d-002": ["d-001"]])
        XCTAssertEqual(d.merge, [["d-001"], ["d-002"]], "dependency first, same decision")

        d = decide(finished: ["d-002"], served: ["d-001"], deps: ["d-002": ["d-001"]])
        XCTAssertEqual(d.merge, [["d-002"]])
    }

    func testChainsMergeInDependencyOrder() {
        let d = decide(finished: ["a", "b", "c"], deps: ["c": ["b"], "b": ["a"]])
        XCTAssertEqual(d.merge, [["a"], ["b"], ["c"]])
    }

    func testCyclesMergeTogether() {
        let d = decide(finished: ["d-001", "d-002"], deps: ["d-001": ["d-002"], "d-002": ["d-001"]])
        XCTAssertEqual(d.merge, [["d-001", "d-002"]], "one unit")
    }

    func testCycleWaitsIfOneMemberIsntFinished() {
        let d = decide(finished: ["d-001"], deps: ["d-001": ["d-002"], "d-002": ["d-001"]])
        XCTAssertEqual(d.held, ["d-001": ["d-002"]])
    }

    func testDependenciesFromReferenceEvents() {
        func delegate(_ id: String, to pane: String) -> GaterEvent {
            GaterEvent(fields: ["kind": .string("delegation"), "ts": .string(id), "to": .string(pane),
                                "gater": .object(["type": .string("delegate"), "id": .string(id),
                                                  "feature": .string("F\(id)"), "directive": .string("x"), "scope": .array([])])])
        }
        let events = [
            delegate("d-001", to: "delegate-auth"), delegate("d-002", to: "delegate-dash"),
            GaterEvent(fields: ["kind": .string("references"), "from_pane": .string("delegate-auth"),
                                "in_pane": .string("delegate-dash"), "symbol": .string("src/users.ts#getUser")]),
        ]
        XCTAssertEqual(IntegrationPlanner.dependencies(from: events, plan: PlanReducer.replay(events)),
                       ["d-002": ["d-001"]])
    }
}
