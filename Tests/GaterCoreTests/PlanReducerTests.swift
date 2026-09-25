import XCTest
@testable import GaterCore

final class PlanReducerTests: XCTestCase {
    private var clock = 0

    private func ts() -> String {
        clock += 1
        return String(format: "2026-09-25T20:%02d:00Z", clock)
    }

    private func delegation(_ type: String, _ id: String, feature: String? = nil, directive: String? = nil,
                            scope: [String] = [], mergeInto: String? = nil, to: String? = nil) -> GaterEvent {
        var gater: [String: JSONValue] = ["type": .string(type), "id": .string(id),
                                          "scope": .array(scope.map { .string($0) })]
        if let feature { gater["feature"] = .string(feature) }
        if let directive { gater["directive"] = .string(directive) }
        if let mergeInto { gater["merge_into"] = .string(mergeInto) }
        var fields: [String: JSONValue] = ["kind": .string("delegation"), "pane": .string("orch"),
                                           "ts": .string(ts()), "gater": .object(gater)]
        if let to { fields["to"] = .string(to) }
        return GaterEvent(fields: fields)
    }

    private func done(_ id: String) -> GaterEvent {
        GaterEvent(fields: ["kind": .string("done_note"), "dish": .string(id), "did": .string("did it"),
                            "ts": .string(ts())])
    }

    func testDelegateCreatesDishAndFeature() throws {
        let plan = PlanReducer.replay([
            delegation("delegate", "d-001", feature: "Auth", directive: "add session expiry",
                       scope: ["src/auth/**"], to: "delegate-auth"),
        ])
        XCTAssertEqual(plan.version, 1)
        XCTAssertEqual(plan.features, ["Auth"])
        let dish = try XCTUnwrap(plan.dish("d-001"))
        XCTAssertEqual(dish.state, .cooking)
        XCTAssertEqual(dish.pane, "delegate-auth")
        XCTAssertEqual(dish.scope, ["src/auth/**"])
        XCTAssertEqual(plan.changes.first?.reason, "add session expiry", "history keeps the why")
        XCTAssertEqual(plan.jevOptions, ["Auth", "unassigned"])
    }

    func testKitchenLifecycle() {
        var plan = PlanReducer.replay([
            delegation("delegate", "d-001", feature: "Auth", directive: "expiry", to: "delegate-auth"),
            done("d-001"),
        ])
        XCTAssertEqual(plan.dish("d-001")?.state, .pass)

        PlanReducer.apply(delegation("instruct", "d-001", directive: "also handle refresh"), to: &plan)
        XCTAssertEqual(plan.dish("d-001")?.state, .cooking, "instruct sends plated work back")
        XCTAssertEqual(plan.dish("d-001")?.instructions, ["also handle refresh"])

        PlanReducer.apply(done("d-001"), to: &plan)
        PlanReducer.apply(delegation("finish", "d-001"), to: &plan)
        XCTAssertEqual(plan.dish("d-001")?.state, .finished)

        PlanReducer.apply(GaterEvent(fields: ["kind": .string("lifecycle"), "dish": .string("d-001"),
                                              "state": .string("served"), "ts": .string(ts())]), to: &plan)
        XCTAssertEqual(plan.dish("d-001")?.state, .served)
        XCTAssertEqual(plan.version, 6)
        XCTAssertEqual(plan.changes.map(\.version), Array(1...6))
    }

    func testRescopeCancelAndMerge() {
        let plan = PlanReducer.replay([
            delegation("delegate", "d-001", feature: "Auth", directive: "a", scope: ["src/auth/**"]),
            delegation("delegate", "d-002", feature: "Auth", directive: "b", scope: ["src/session.ts"]),
            delegation("delegate", "d-003", feature: "Dashboard", directive: "c"),
            delegation("rescope", "d-001", directive: "a, narrower", scope: ["src/auth/login.ts"]),
            delegation("merge", "d-002", mergeInto: "d-001"),
            delegation("cancel", "d-003"),
        ])
        XCTAssertEqual(plan.dish("d-001")?.directive, "a, narrower")
        XCTAssertEqual(plan.dish("d-001")?.scope, ["src/auth/login.ts", "src/session.ts"])
        XCTAssertEqual(plan.dish("d-002")?.state, .merged)
        XCTAssertEqual(plan.dish("d-002")?.mergedInto, "d-001")
        XCTAssertEqual(plan.dish("d-003")?.state, .cancelled)
        XCTAssertEqual(plan.jevOptions, ["Auth", "unassigned"], "a feature with no live dishes drops out")
    }

    func testBadReferencesBecomeWarningsNotChanges() {
        let plan = PlanReducer.replay([
            delegation("instruct", "d-001", directive: "weather"), // the live-test mistake
            delegation("delegate", "d-002", feature: "Auth", directive: "x"),
            delegation("delegate", "d-002", feature: "Auth", directive: "dupe"),
            done("d-009"),
        ])
        XCTAssertEqual(plan.version, 1, "only the valid delegate changed the plan")
        XCTAssertEqual(plan.warnings.count, 3)
        XCTAssertEqual(plan.dish("d-002")?.directive, "x")
    }

    func testDoneNoteOnlyMovesCookingDishes() {
        let plan = PlanReducer.replay([
            delegation("delegate", "d-001", feature: "Auth", directive: "x"),
            delegation("cancel", "d-001"),
            done("d-001"),
        ])
        XCTAssertEqual(plan.dish("d-001")?.state, .cancelled)
    }

    func testCurrentDishForPaneAndNextId() {
        let plan = PlanReducer.replay([
            delegation("delegate", "d-001", feature: "Auth", directive: "x", to: "delegate-auth"),
            delegation("delegate", "d-007", feature: "Auth", directive: "y", to: "delegate-auth"),
            delegation("delegate", "d-003", feature: "Dash", directive: "z", to: "delegate-dash"),
            delegation("cancel", "d-007"),
        ])
        XCTAssertEqual(plan.currentDish(forPane: "delegate-auth")?.id, "d-001")
        XCTAssertNil(plan.currentDish(forPane: "orch"))
        XCTAssertEqual(plan.nextDishId, "d-008")
    }

    func testReplayIsDeterministicAndRoundTripsThroughJSON() throws {
        let events = [
            delegation("delegate", "d-001", feature: "Auth", directive: "x", scope: ["a"], to: "delegate-auth"),
            done("d-001"),
        ]
        let plan = PlanReducer.replay(events)
        XCTAssertEqual(PlanReducer.replay(events), plan)
        let decoded = try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
        let json = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        XCTAssertTrue(json.contains("\"jev_options\""))
    }

    func testPlanStoreRebuildsAndWritesFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gater-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlanStore(path: dir.appendingPathComponent("plan.json"))
        try store.rebuild(from: [delegation("delegate", "d-001", feature: "Auth", directive: "x")])
        XCTAssertEqual(PlanStore.load(from: store.path)?.dish("d-001")?.state, .cooking)

        let changed = expectation(description: "onChange")
        store.onChange = { _ in changed.fulfill() }
        store.apply(done("d-001"))
        wait(for: [changed], timeout: 2)
        XCTAssertEqual(PlanStore.load(from: store.path)?.dish("d-001")?.state, .pass)
        XCTAssertEqual(PlanStore.load(from: dir.appendingPathComponent("missing.json")), Plan())
    }
}
