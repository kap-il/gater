import Foundation

/// Decides what merges into `g8r/integration` next: incremental
/// integration on one branch, gated by dependencies.
///
/// - Ready work that uses something unmerged work provides is **held**
///   until that merges.
/// - Otherwise it merges now; arrival order is fine.
/// - A cycle (work that uses each other) merges together as one unit —
///   the only time two are stitched at once.
///
/// Pure: ids and dependencies come in as data.
public enum IntegrationPlanner {
    public struct Decision: Equatable {
        /// Units to merge now, in order; a unit is one id, or a cycle.
        public var merge: [[String]]
        /// Id → the unmerged ids it's waiting on.
        public var held: [String: [String]]
    }

    /// - ready: built and waiting to merge
    /// - merged: already on the integration branch
    /// - dependencies: id → the ids it uses
    public static func decide(ready: Set<String>, merged alreadyMerged: Set<String>,
                              dependencies: [String: Set<String>]) -> Decision {
        let candidates = ready.subtracting(alreadyMerged)
        let components = stronglyConnectedComponents(of: candidates, dependencies: dependencies)

        var merged = alreadyMerged
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
            for id in unit {
                let waiting = (dependencies[id] ?? []).filter { !members.contains($0) && !merged.contains($0) }
                held[id] = waiting.sorted()
            }
        }
        return Decision(merge: merge, held: held)
    }

    /// Tarjan's SCC over the candidates (edges only between candidates
    /// matter for cycles).
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
}
