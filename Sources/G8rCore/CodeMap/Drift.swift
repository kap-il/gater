import Foundation

/// Compares the edges the plan declares with the edges the code has, and
/// says which is which.
///
/// | Kind         | Declared | Measured | Also                                   |
/// |--------------|----------|----------|----------------------------------------|
/// | `planned`    | either   | either   | one end isn't built                    |
/// | `confirmed`  | yes      | yes      |                                        |
/// | `unrealized` | yes      | no       |                                        |
/// | `indirect`   | no       | yes      | the plan reaches it through others     |
/// | `undeclared` | no       | yes      | the plan doesn't reach it at all       |
///
/// A declared edge is `implied` when the plan also gets there by a longer
/// route, so a chart can leave it out without losing the build order.
/// Every other edge is not implied.
public struct Drift: MapStage {
    public init() {}

    public func apply(to map: inout LivingMap, context: MapContext) throws {
        let unbuilt = Set(map.nodes.filter { !Self.isBuilt($0.status) }.map(\.id))
        let known = Set(map.nodes.map(\.id))

        var declared: [String: Set<String>] = [:]
        for edge in map.edges where edge.declared {
            declared[edge.from, default: []].insert(edge.to)
        }

        for index in map.edges.indices {
            let edge = map.edges[index]
            let longer = Self.reaches(from: edge.from, to: edge.to, in: declared)
            map.edges[index].implied = edge.declared && longer

            if [edge.from, edge.to].contains(where: { unbuilt.contains($0) || !known.contains($0) }) {
                map.edges[index].kind = .planned
            } else if edge.declared {
                map.edges[index].kind = edge.measured ? .confirmed : .unrealized
            } else {
                map.edges[index].kind = longer ? .indirect : .undeclared
            }
        }
    }

    /// A node with no code yet, or whose code a build session is still
    /// writing, isn't built.
    private static func isBuilt(_ status: NodeStatus) -> Bool {
        status != .planned && status != .building
    }

    /// Whether the plan gets from `from` to `to` through at least one other
    /// component. The direct edge doesn't count, and neither does a route
    /// back through `from`.
    static func reaches(from: String, to: String, in declared: [String: Set<String>]) -> Bool {
        var seen: Set<String> = [from]
        var queue = (declared[from] ?? []).filter { $0 != to }.sorted()
        seen.formUnion(queue)
        while let next = queue.popLast() {
            for step in declared[next] ?? [] {
                if step == to { return true }
                if seen.insert(step).inserted { queue.append(step) }
            }
        }
        return false
    }
}
