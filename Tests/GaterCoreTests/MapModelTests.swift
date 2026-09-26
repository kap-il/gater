import XCTest
@testable import GaterCore

final class MapModelTests: XCTestCase {
    private func e(_ kind: String, _ fields: [String: JSONValue]) -> GaterEvent {
        var f = fields
        f["kind"] = .string(kind)
        if f["ts"] == nil { f["ts"] = .string("2026-09-25T23:35:59Z") }
        return GaterEvent(fields: f)
    }

    private func delegate(_ id: String, _ feature: String, _ directive: String, to pane: String) -> GaterEvent {
        e("delegation", ["pane": .string("orch"), "to": .string(pane),
                         "gater": .object(["type": .string("delegate"), "id": .string(id), "feature": .string(feature),
                                           "directive": .string(directive), "scope": .array([.string("src/**")])])])
    }

    /// The golden run's log, condensed.
    private var golden: [GaterEvent] {
        [
            delegate("d-001", "Auth", "add session expiry", to: "delegate-auth"),
            delegate("d-002", "Dashboard", "user card", to: "delegate-dash"),
            e("ownership", ["symbol": .string("src/dashboard/UserCard.tsx#UserCard"), "feature": .string("Dashboard"),
                            "status": .string("assigned"), "confidence": .number(1)]),
            e("ownership", ["symbol": .string("src/users.ts#getUser"), "feature": .string("Auth"),
                            "status": .string("assigned"), "confidence": .number(0.96)]),
            e("ownership", ["symbol": .string("src/users.ts#User"), "feature": .string("Auth"),
                            "status": .string("uncertain"), "confidence": .number(0.63)]),
            e("command", ["pane": .string("delegate-auth"), "command": .string("git commit -qm auth\nmore")]),
            e("references", ["symbol": .string("src/users.ts#getUser"), "from_pane": .string("delegate-auth"),
                             "in_pane": .string("delegate-dash"), "sites": .array([.string("src/dashboard/UserCard.tsx:4")])]),
            e("overlap", ["overlap": .string("k1"), "type": .string("public_surface"), "node": .string("Auth"),
                          "panes": .array([.string("delegate-auth"), .string("delegate-dash")]),
                          "symbol": .string("src/users.ts#getUser"), "sites": .array([.string("src/dashboard/UserCard.tsx:4")])]),
            e("review", ["overlap_id": .string("k1"), "verdict": .string("conflict"), "confidence": .number(0.97)]),
            e("wake", ["overlap": .string("k1"), "pane": .string("orch")]),
            e("done_note", ["pane": .string("delegate-auth"), "dish": .string("d-001"), "did": .string("added expiry"),
                            "assumed": .string("ms timestamps")]),
        ]
    }

    func testFeatureNodesFromTheGoldenRun() throws {
        let plan = PlanReducer.replay(golden)
        var map = MapModel()
        map.replay(golden)
        let nodes = map.features(plan: plan)
        XCTAssertEqual(nodes.map(\.name), ["Auth", "Dashboard"])

        let auth = nodes[0]
        XCTAssertEqual(auth.status, .pass, "d-001 posted GATER-DONE")
        XCTAssertEqual(auth.agents, ["delegate-auth"])
        XCTAssertEqual(auth.dishes.first?.did, "added expiry")
        XCTAssertEqual(auth.files["src/users.ts"]?.map(\.name), ["User", "getUser"])
        XCTAssertEqual(auth.files["src/users.ts"]?.first?.uncertain, true, "dashed")
        XCTAssertEqual(auth.flags.count, 1)
        XCTAssertEqual(auth.flags[0].verdict, "conflict")
        XCTAssertEqual(auth.flags[0].woke, true)
        XCTAssertTrue(auth.flags[0].summary.contains("getUser changed by delegate-auth"))

        XCTAssertEqual(nodes[1].status, .cooking)
        XCTAssertTrue(nodes[1].flags.isEmpty)
    }

    func testUsageEdges() {
        let plan = PlanReducer.replay(golden)
        var map = MapModel()
        map.replay(golden)
        XCTAssertEqual(map.usageEdges(plan: plan),
                       [MapModel.UsageEdge(user: "Dashboard", owner: "Auth", symbols: ["src/users.ts#getUser"], overlapping: true)])
    }

    func testActivityIsTheLastThingEachAgentDid() {
        var map = MapModel()
        map.replay(golden)
        XCTAssertEqual(map.activity["delegate-auth"]?.text, "posted GATER-DONE")
        map.apply(e("edit", ["pane": .string("delegate-dash"), "path": .string("/w/src/dashboard/UserCard.tsx")]))
        XCTAssertEqual(map.activity["delegate-dash"]?.text, "edited UserCard.tsx")
        map.apply(e("command", ["pane": .string("delegate-dash"), "command": .string("npm test\n--watch")]))
        XCTAssertEqual(map.activity["delegate-dash"]?.text, "ran npm test")
    }

    func testCancelledFeaturesDropOut() {
        let events = golden + [e("delegation", ["pane": .string("orch"),
                                                "gater": .object(["type": .string("cancel"), "id": .string("d-002")])])]
        var map = MapModel()
        map.replay(events)
        XCTAssertEqual(map.features(plan: PlanReducer.replay(events)).map(\.name), ["Auth"])
    }

    func testStatusIsTheFurthestBehindDish() {
        XCTAssertEqual(MapModel.status(of: [.served, .pass, .cooking]), .cooking)
        XCTAssertEqual(MapModel.status(of: [.served, .finished]), .finished)
    }

    func testUnresolvedReplyAddressReadsAsReplied() {
        var map = MapModel()
        map.apply(e("message", ["pane": .string("delegate-dash"), "to": .string("uds:/tmp/cc-socks/1.sock")]))
        XCTAssertEqual(map.activity["delegate-dash"]?.text, "replied")
        map.apply(e("message", ["pane": .string("delegate-dash"), "to": .string("uds:/x.sock"), "to_pane": .string("orch")]))
        XCTAssertEqual(map.activity["delegate-dash"]?.text, "messaged orch")
    }

    func testUseSitesForTheFileView() {
        var map = MapModel()
        map.replay(golden)
        let sites = map.useSites(inPane: "delegate-dash")
        XCTAssertEqual(sites.map(\.site), ["src/dashboard/UserCard.tsx:4"])
        XCTAssertEqual(sites.first?.overlapping, true)
        XCTAssertEqual(sites.first?.path, "src/dashboard/UserCard.tsx")
        XCTAssertEqual(sites.first?.line, 4)
        XCTAssertTrue(map.useSites(inPane: "delegate-auth").isEmpty)
    }

    func testHeldDishShowsWhatItsWaitingOnUntilServed() {
        let finish = e("delegation", ["pane": .string("orch"), "gater": .object(["type": .string("finish"), "id": .string("d-002")])])
        let hold = e("lifecycle_hold", ["dish": .string("d-002"), "waiting_on": .array([.string("d-001")])])
        var events = golden + [finish, hold]
        var map = MapModel()
        map.replay(events)
        let dash = map.features(plan: PlanReducer.replay(events)).first { $0.name == "Dashboard" }
        XCTAssertEqual(dash?.dishes.first?.waitingOn, ["d-001"])

        events.append(e("lifecycle", ["dish": .string("d-002"), "state": .string("served")]))
        map.apply(events.last!)
        let served = map.features(plan: PlanReducer.replay(events)).first { $0.name == "Dashboard" }
        XCTAssertEqual(served?.status, .served)
        XCTAssertEqual(served?.dishes.first?.waitingOn, [])
    }
}
