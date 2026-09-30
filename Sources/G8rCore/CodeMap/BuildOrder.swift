import Foundation

/// What can be built next, and what building it would touch. Only planned
/// nodes get these.
enum BuildOrder {
    static func apply(to map: inout LivingMap) {
        let planned = Set(map.nodes.filter { $0.status == .planned }.map(\.id))
        let waves = self.waves(of: map.nodes.filter { planned.contains($0.id) }, planned: planned)

        for index in map.nodes.indices where planned.contains(map.nodes[index].id) {
            let node = map.nodes[index]
            map.nodes[index].wave = waves[node.id]
            map.nodes[index].blockedBy = node.needs.filter(planned.contains)
            let users = map.edges.filter { $0.measured && node.changes.contains($0.to) && $0.from != node.id }
            map.nodes[index].blast = Set(users.map(\.from)).sorted()
        }
    }

    /// Wave 1 holds the nodes whose needs are all built; each wave after
    /// holds the nodes whose needs are built or in an earlier wave. A need
    /// that names no component holds nothing up. Nodes in a cycle, and
    /// nodes that need one, never become ready and get no wave.
    private static func waves(of nodes: [MapNode], planned: Set<String>) -> [String: Int] {
        var waves: [String: Int] = [:]
        var pending = nodes
        var wave = 1
        while true {
            let ready = pending.filter { node in
                node.needs.allSatisfy { !planned.contains($0) || (waves[$0] ?? wave) < wave }
            }
            if ready.isEmpty { return waves }
            for node in ready { waves[node.id] = wave }
            pending.removeAll { waves[$0.id] != nil }
            wave += 1
        }
    }
}
