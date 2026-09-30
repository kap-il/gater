import XCTest
@testable import G8rCore

final class DriftTests: XCTestCase {
    private func node(_ id: String, _ status: NodeStatus = .built) -> MapNode {
        MapNode(id: id, name: id.uppercased(), summary: "", status: status)
    }

    /// Runs drift over nodes and edges, and returns the edges by `from>to`.
    private func drift(_ nodes: [MapNode], _ edges: [MapEdge]) throws -> [String: MapEdge] {
        var map = LivingMap(repo: "r", head: nil, generated: "", docs: [], nodes: nodes, edges: edges,
                            retired: [], problems: [])
        let context = MapContext(planRoot: "/", codeRoot: "/", config: G8rConfig(),
                                 graph: PlanGraph(docs: [], components: [], retired: [], problems: []),
                                 files: [], scans: [:])
        try Drift().apply(to: &map, context: context)
        XCTAssertEqual(map.edges.map { "\($0.from)>\($0.to)" }, edges.map { "\($0.from)>\($0.to)" },
                       "drift keeps the edges and their order")
        return Dictionary(uniqueKeysWithValues: map.edges.map { ("\($0.from)>\($0.to)", $0) })
    }

    // MARK: - The kind table

    func testPlannedWhenOneEndIsNotBuiltWhateverTheRestSays() throws {
        let edges = try drift([node("a"), node("b", .planned), node("c", .building), node("d", .proven)], [
            MapEdge(from: "a", to: "b", declared: true, measured: false),
            MapEdge(from: "b", to: "a", declared: true, measured: true),
            MapEdge(from: "a", to: "c", declared: false, measured: true),
            MapEdge(from: "c", to: "d", declared: true, measured: false),
            MapEdge(from: "d", to: "ghost", declared: false, measured: true),
        ])

        for key in ["a>b", "b>a", "a>c", "c>d", "d>ghost"] {
            XCTAssertEqual(edges[key]?.kind, .planned, key)
        }
    }

    func testConfirmedWhenDeclaredAndMeasured() throws {
        let edges = try drift([node("a"), node("b", .unplanned)], [
            MapEdge(from: "a", to: "b", declared: true, measured: true, symbols: ["Beta"], refs: 2),
        ])

        XCTAssertEqual(edges["a>b"]?.kind, .confirmed)
        XCTAssertEqual(edges["a>b"]?.symbols, ["Beta"], "drift leaves codemap's fields alone")
        XCTAssertEqual(edges["a>b"]?.refs, 2)
    }

    func testUnrealizedWhenDeclaredAndNotMeasured() throws {
        let edges = try drift([node("a"), node("b", .failing)], [
            MapEdge(from: "a", to: "b", declared: true, measured: false),
        ])

        XCTAssertEqual(edges["a>b"]?.kind, .unrealized)
    }

    func testIndirectWhenThePlanReachesItThroughOtherComponents() throws {
        let edges = try drift([node("a"), node("b"), node("c")], [
            MapEdge(from: "a", to: "b", declared: true, measured: true),
            MapEdge(from: "a", to: "c", declared: false, measured: true),
            MapEdge(from: "b", to: "c", declared: true, measured: false),
        ])

        XCTAssertEqual(edges["a>c"]?.kind, .indirect)
        XCTAssertEqual(edges["a>c"]?.implied, false, "only a declared edge is implied")
        XCTAssertEqual(edges["a>b"]?.kind, .confirmed)
        XCTAssertEqual(edges["b>c"]?.kind, .unrealized)
    }

    func testIndirectThroughAPlanStepThatIsNotBuiltYet() throws {
        let edges = try drift([node("a"), node("b", .planned), node("c")], [
            MapEdge(from: "a", to: "b", declared: true, measured: false),
            MapEdge(from: "a", to: "c", declared: false, measured: true),
            MapEdge(from: "b", to: "c", declared: true, measured: false),
        ])

        XCTAssertEqual(edges["a>c"]?.kind, .indirect)
    }

    func testUndeclaredWhenThePlanDoesNotReachItAtAll() throws {
        let edges = try drift([node("a"), node("b"), node("c")], [
            MapEdge(from: "a", to: "b", declared: true, measured: true),
            MapEdge(from: "a", to: "c", declared: false, measured: true),
            // The plan reaches c from b, but only the other way from a.
            MapEdge(from: "c", to: "b", declared: true, measured: true),
            MapEdge(from: "b", to: "a", declared: false, measured: true),
        ])

        XCTAssertEqual(edges["a>c"]?.kind, .undeclared)
        XCTAssertEqual(edges["b>a"]?.kind, .undeclared)
        XCTAssertEqual(edges["a>c"]?.implied, false)
    }

    // MARK: - Implied

    func testADeclaredEdgeIsImpliedWhenThePlanGetsThereByALongerRoute() throws {
        let edges = try drift([node("a"), node("b"), node("c"), node("d")], [
            MapEdge(from: "a", to: "b", declared: true, measured: true),
            MapEdge(from: "a", to: "c", declared: true, measured: true),
            MapEdge(from: "a", to: "d", declared: true, measured: false),
            MapEdge(from: "b", to: "c", declared: true, measured: true),
            MapEdge(from: "c", to: "d", declared: true, measured: true),
        ])

        XCTAssertEqual(edges["a>c"]?.implied, true)
        XCTAssertEqual(edges["a>d"]?.implied, true, "three steps is a longer route too")
        XCTAssertEqual(edges["a>c"]?.kind, .confirmed, "implied says nothing about the kind")
        XCTAssertEqual(edges["a>d"]?.kind, .unrealized)
        for key in ["a>b", "b>c", "c>d"] {
            XCTAssertEqual(edges[key]?.implied, false, key)
        }
    }

    func testAMeasuredEdgeDoesNotMakeARoute() throws {
        let edges = try drift([node("a"), node("b"), node("c")], [
            MapEdge(from: "a", to: "b", declared: false, measured: true),
            MapEdge(from: "a", to: "c", declared: true, measured: true),
            MapEdge(from: "b", to: "c", declared: true, measured: true),
        ])

        XCTAssertEqual(edges["a>c"]?.implied, false)
        XCTAssertEqual(edges["a>b"]?.kind, .undeclared)
    }

    func testImpliedOnPlannedEdges() throws {
        let edges = try drift([node("a", .planned), node("b", .planned), node("c")], [
            MapEdge(from: "a", to: "b", declared: true, measured: false),
            MapEdge(from: "a", to: "c", declared: true, measured: false),
            MapEdge(from: "b", to: "c", declared: true, measured: false),
        ])

        XCTAssertEqual(edges["a>c"]?.kind, .planned)
        XCTAssertEqual(edges["a>c"]?.implied, true)
    }

    func testACycleInThePlanEndsTheSearch() throws {
        let edges = try drift([node("a"), node("b"), node("c")], [
            MapEdge(from: "a", to: "b", declared: true, measured: true),
            MapEdge(from: "b", to: "a", declared: true, measured: true),
            MapEdge(from: "b", to: "c", declared: true, measured: true),
            MapEdge(from: "c", to: "b", declared: true, measured: true),
            MapEdge(from: "c", to: "a", declared: false, measured: true),
        ])

        // A route back through where it started isn't a longer route.
        XCTAssertEqual(edges["a>b"]?.implied, false)
        XCTAssertEqual(edges["b>a"]?.implied, false)
        XCTAssertEqual(edges["c>a"]?.kind, .indirect)
    }

    // MARK: - JSON

    func testKindAndImpliedAreWrittenToTheMap() throws {
        let edges = try drift([node("a"), node("b")], [MapEdge(from: "a", to: "b", declared: true, measured: true)])
        let data = try JSONEncoder().encode(try XCTUnwrap(edges["a>b"]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["kind"] as? String, "confirmed")
        XCTAssertEqual(json["implied"] as? Bool, false)
    }
}
