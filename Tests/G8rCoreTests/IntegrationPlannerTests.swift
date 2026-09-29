import XCTest
@testable import G8rCore

final class IntegrationPlannerTests: XCTestCase {
    private func decide(ready: [String], merged: [String] = [], deps: [String: [String]]) -> IntegrationPlanner.Decision {
        IntegrationPlanner.decide(ready: Set(ready), merged: Set(merged),
                                  dependencies: deps.mapValues(Set.init))
    }

    func testIndependentWorkMergesInAnyOrder() {
        let d = decide(ready: ["auth", "dash"], deps: [:])
        XCTAssertEqual(Set(d.merge.map { $0 }), [["auth"], ["dash"]])
        XCTAssertTrue(d.held.isEmpty)
    }

    /// The dashboard uses something auth provides.
    func testUserWaitsForWhatItDependsOn() {
        var d = decide(ready: ["dash"], deps: ["dash": ["auth"]])
        XCTAssertEqual(d.merge, [])
        XCTAssertEqual(d.held, ["dash": ["auth"]], "map shows: waiting on auth")

        d = decide(ready: ["auth", "dash"], deps: ["dash": ["auth"]])
        XCTAssertEqual(d.merge, [["auth"], ["dash"]], "dependency first, same decision")

        d = decide(ready: ["dash"], merged: ["auth"], deps: ["dash": ["auth"]])
        XCTAssertEqual(d.merge, [["dash"]])
    }

    func testChainsMergeInDependencyOrder() {
        let d = decide(ready: ["a", "b", "c"], deps: ["c": ["b"], "b": ["a"]])
        XCTAssertEqual(d.merge, [["a"], ["b"], ["c"]])
    }

    func testCyclesMergeTogether() {
        let d = decide(ready: ["auth", "dash"], deps: ["auth": ["dash"], "dash": ["auth"]])
        XCTAssertEqual(d.merge, [["auth", "dash"]], "one unit")
    }

    func testCycleWaitsIfOneMemberIsntReady() {
        let d = decide(ready: ["auth"], deps: ["auth": ["dash"], "dash": ["auth"]])
        XCTAssertEqual(d.held, ["auth": ["dash"]])
    }
}
