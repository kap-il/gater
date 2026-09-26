import Foundation

/// Decides what merges into `gater/integration` next (spec §4.10,
/// "incremental integration on one branch, gated by dependencies"):
///
/// - A finished dish that uses the changed public surface of a dish that
///   isn't merged yet is **held** ("waiting on d-00X").
/// - Otherwise it merges now; arrival order is fine.
/// - A cycle (dishes using each other's changes) merges together as one
///   unit — the only time two dishes are stitched at once.
///
/// Pure: dependencies come in as data, derived from `references` events.
public enum IntegrationPlanner {
    public struct Decision: Equatable {
        /// Units to merge now, in order; a unit is one dish, or a cycle.
        public var merge: [[String]]
        /// Dish → the unmerged dishes it's waiting on.
        public var held: [String: [String]]
    }

    /// - finished: dishes the orchestrator finished (ready to merge)
    /// - served: dishes already merged
    /// - dependencies: dish → dishes whose changes it uses
    public static func decide(finished: Set<String>, served: Set<String>,
                              dependencies: [String: Set<String>]) -> Decision {
        let candidates = finished.subtracting(served)
        let components = stronglyConnectedComponents(of: candidates, dependencies: dependencies)

        var merged = served
        var merge: [[String]] = []
        var held: [String: [String]] = [:]
        var progress = true
        var pending = components

        // Repeatedly take units whose outside dependencies are all merged,
        // so a chain A → B → C lands in dependency order in one decision.
        while progress {
            progress = false
            for unit in pending {
                let members = Set(unit)
                let outside = members.flatMap { dependencies[$0] ?? [] }.filter { !members.contains($0) }
                if outside.allSatisfy(merged.contains) {
                    merge.append(unit.sorted())
                    merged.formUnion(members)
                    pending.removeAll { $0 == unit }
                    progress = true
                }
            }
        }
        for unit in pending {
            let members = Set(unit)
            for dish in unit {
                let waiting = (dependencies[dish] ?? []).filter { !members.contains($0) && !merged.contains($0) }
                held[dish] = waiting.sorted()
            }
        }
        return Decision(merge: merge, held: held)
    }

    /// Tarjan's SCC over the candidate dishes (edges only between
    /// candidates matter for cycles).
    static func stronglyConnectedComponents(of nodes: Set<String>, dependencies: [String: Set<String>]) -> [[String]] {
        var index = 0
        var indices: [String: Int] = [:]
        var lowlink: [String: Int] = [:]
        var stack: [String] = []
        var onStack: Set<String> = []
        var result: [[String]] = []

        func visit(_ v: String) {
            indices[v] = index
            lowlink[v] = index
            index += 1
            stack.append(v)
            onStack.insert(v)
            for w in (dependencies[v] ?? []).sorted() where nodes.contains(w) {
                if indices[w] == nil {
                    visit(w)
                    lowlink[v] = min(lowlink[v]!, lowlink[w]!)
                } else if onStack.contains(w) {
                    lowlink[v] = min(lowlink[v]!, indices[w]!)
                }
            }
            if lowlink[v] == indices[v] {
                var component: [String] = []
                while let w = stack.popLast() {
                    onStack.remove(w)
                    component.append(w)
                    if w == v { break }
                }
                result.append(component.sorted())
            }
        }
        for node in nodes.sorted() where indices[node] == nil { visit(node) }
        return result
    }

    /// Dish dependencies from `references` events: the dish of the pane
    /// where a use was found depends on the dish of the pane that changed
    /// the symbol. Panes map to their current dish in the plan.
    public static func dependencies(from events: [GaterEvent], plan: Plan) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for event in events where event.kind == "references" {
            guard let inPane = event["in_pane"]?.stringValue, let fromPane = event["from_pane"]?.stringValue,
                  let user = dish(forPane: inPane, plan: plan), let owner = dish(forPane: fromPane, plan: plan),
                  user != owner else { continue }
            result[user, default: []].insert(owner)
        }
        return result
    }

    private static func dish(forPane pane: String, plan: Plan) -> String? {
        // Includes served/finished dishes: a dependency on already-merged
        // work is satisfied, not forgotten.
        plan.dishes.filter { $0.pane == pane && $0.state.isActive }.max { $0.updatedAt < $1.updatedAt }?.id
    }
}
