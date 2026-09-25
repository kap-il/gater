import Foundation

/// Everything the map UI draws (spec §4.11), derived from the event log
/// plus the plan — one data model behind the tree, web, and file views.
/// Pure and replayable: rebuilding from events.jsonl gives the same map.
public struct MapModel {
    public struct OwnedSymbol: Equatable {
        public var id: String
        public var name: String
        public var confidence: Double
        /// Below Jev's threshold: drawn dashed.
        public var uncertain: Bool
    }

    public struct Flag: Equatable {
        public var key: String
        public var kind: String
        public var panes: [String]
        public var symbol: String?
        public var sites: [String]
        /// "conflict" / "compatible", once Jev reviewed it.
        public var verdict: String?
        public var confidence: Double?
        public var woke: Bool

        public var summary: String {
            let name = symbol.flatMap { $0.split(separator: "#").last.map(String.init) } ?? "shared code"
            if kind == "public_surface" {
                return "\(name) changed by \(panes.first ?? "?"), used by \(panes.dropFirst().joined(separator: ", ")) at \(sites.joined(separator: ", "))"
            }
            return "\(panes.joined(separator: " and ")) both editing this feature"
        }
    }

    public struct DishCard: Equatable {
        public var id: String
        public var directive: String
        public var state: DishState
        public var pane: String?
        public var scope: [String]
        public var instructions: [String]
        /// GATER-DONE `did` / `assumed`, once posted.
        public var did: String?
        public var assumed: String?
    }

    public struct Activity: Equatable {
        public var text: String
        public var ts: String
    }

    public struct FeatureNode: Equatable {
        public var name: String
        /// The furthest-behind live dish: cooking before pass before
        /// finished before served.
        public var status: DishState
        public var dishes: [DishCard]
        public var agents: [String]
        /// file → symbols this feature owns in it
        public var files: [String: [OwnedSymbol]]
        public var flags: [Flag]
    }

    /// Feature `user` uses code owned by feature `owner` (spec §4.8 usage
    /// edges; drawn in the web view).
    public struct UsageEdge: Equatable, Hashable {
        public var user: String
        public var owner: String
        public var symbols: [String]
        public var overlapping: Bool
    }

    // MARK: - State folded from events

    private var owners: [String: (feature: String, confidence: Double, status: String)] = [:]
    private var overlaps: [Flag] = []
    private var overlapNode: [String: String] = [:]
    private var references: [String: (symbol: String, fromPane: String?, inPane: String, sites: [String])] = [:]
    private var doneNotes: [String: (did: String, assumed: String)] = [:]
    public private(set) var activity: [String: Activity] = [:]

    public init() {}

    public mutating func apply(_ event: GaterEvent) {
        let ts = event.ts ?? ""
        switch event.kind {
        case "ownership":
            guard let symbol = event["symbol"]?.stringValue, let feature = event["feature"]?.stringValue else { return }
            var confidence = 0.0
            if case let .number(c)? = event["confidence"] { confidence = c }
            owners[symbol] = (feature, confidence, event["status"]?.stringValue ?? "assigned")

        case "overlap":
            guard let key = event["overlap"]?.stringValue else { return }
            overlapNode[key] = event["node"]?.stringValue
            overlaps.append(Flag(key: key, kind: event["type"]?.stringValue ?? "",
                                 panes: (event.fields["panes"]?.arrayValue ?? []).compactMap(\.stringValue),
                                 symbol: event["symbol"]?.stringValue,
                                 sites: (event.fields["sites"]?.arrayValue ?? []).compactMap(\.stringValue),
                                 verdict: nil, confidence: nil, woke: false))

        case "review":
            guard let key = event["overlap_id"]?.stringValue,
                  let index = overlaps.lastIndex(where: { $0.key == key }) else { return }
            overlaps[index].verdict = event["verdict"]?.stringValue
            if case let .number(c)? = event["confidence"] { overlaps[index].confidence = c }

        case "wake":
            guard let key = event["overlap"]?.stringValue,
                  let index = overlaps.lastIndex(where: { $0.key == key }) else { return }
            overlaps[index].woke = true

        case "references":
            guard let symbol = event["symbol"]?.stringValue, let inPane = event["in_pane"]?.stringValue else { return }
            references["\(symbol)|\(inPane)"] = (symbol, event["from_pane"]?.stringValue, inPane,
                                                 (event.fields["sites"]?.arrayValue ?? []).compactMap(\.stringValue))

        case "done_note":
            if let dish = event["dish"]?.stringValue {
                doneNotes[dish] = (event["did"]?.stringValue ?? "", event["assumed"]?.stringValue ?? "")
            }
            if let pane = event.pane { activity[pane] = Activity(text: "posted GATER-DONE", ts: ts) }

        case "edit":
            if let pane = event.pane, let path = event["path"]?.stringValue {
                activity[pane] = Activity(text: "edited \((path as NSString).lastPathComponent)", ts: ts)
            }
        case "command":
            if let pane = event.pane {
                let text = event["description"]?.stringValue
                    ?? event["command"]?.stringValue.map { "ran " + (($0.split(separator: "\n").first.map(String.init)) ?? $0) }
                    ?? "ran a command"
                activity[pane] = Activity(text: String(text.prefix(90)), ts: ts)
            }
        case "message":
            if let pane = event.pane {
                let to = event["to_pane"]?.stringValue ?? event["to"]?.stringValue
                // An unresolved reply address (uds:…/<pid>.sock) is noise.
                let text = to.map { $0.hasPrefix("uds:") ? "replied" : "messaged \($0)" } ?? "sent a message"
                activity[pane] = Activity(text: text, ts: ts)
            }
        case "delegation":
            if let pane = event.pane {
                let g = event.fields["gater"]
                activity[pane] = Activity(text: "sent \(g?.value(atPath: "type")?.stringValue ?? "?") \(g?.value(atPath: "id")?.stringValue ?? "")", ts: ts)
            }
        case "stop":
            if let pane = event.pane { activity[pane] = Activity(text: "idle", ts: ts) }
        default:
            break
        }
    }

    public mutating func replay(_ events: [GaterEvent]) {
        events.forEach { apply($0) }
    }

    // MARK: - Views onto the model

    /// Feature nodes in plan order, each with its dishes, agents, owned
    /// symbols, and flags. Features whose dishes all left the plan
    /// (cancelled/merged) are omitted.
    public func features(plan: Plan) -> [FeatureNode] {
        var nodes: [FeatureNode] = []
        for name in plan.features {
            let dishes = plan.dishes.filter { $0.feature == name && $0.state.isActive }
            guard !dishes.isEmpty else { continue }

            var files: [String: [OwnedSymbol]] = [:]
            for (id, owner) in owners where owner.feature == name {
                let parts = id.split(separator: "#", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                files[parts[0], default: []].append(OwnedSymbol(id: id, name: parts[1], confidence: owner.confidence,
                                                              uncertain: owner.status != "assigned"))
            }
            for key in files.keys { files[key]?.sort { $0.name < $1.name } }

            nodes.append(FeatureNode(
                name: name,
                status: Self.status(of: dishes.map(\.state)),
                dishes: dishes.map { dish in
                    DishCard(id: dish.id, directive: dish.directive, state: dish.state, pane: dish.pane,
                             scope: dish.scope, instructions: dish.instructions,
                             did: doneNotes[dish.id]?.did, assumed: doneNotes[dish.id]?.assumed)
                },
                agents: Array(Set(dishes.compactMap(\.pane))).sorted(),
                files: files,
                flags: overlaps.filter { overlapNode[$0.key] == name }))
        }
        return nodes
    }

    /// "Uses" edges between features, from cross-worktree references: the
    /// using agent's feature uses the changed symbol's owner (or, when Jev
    /// hasn't placed it confidently, the changing agent's feature).
    public func usageEdges(plan: Plan) -> [UsageEdge] {
        var edges: [String: UsageEdge] = [:]
        let overlapping = Set(overlaps.compactMap(\.symbol))
        for ref in references.values {
            guard let user = plan.currentDish(forPane: ref.inPane)?.feature else { continue }
            let confident = owners[ref.symbol].flatMap { $0.status == "assigned" && $0.feature != "unassigned" ? $0.feature : nil }
            guard let owner = confident ?? ref.fromPane.flatMap({ plan.currentDish(forPane: $0)?.feature }),
                  owner != user else { continue }
            let key = "\(user)→\(owner)"
            var edge = edges[key] ?? UsageEdge(user: user, owner: owner, symbols: [], overlapping: false)
            if !edge.symbols.contains(ref.symbol) { edge.symbols.append(ref.symbol) }
            edge.overlapping = edge.overlapping || overlapping.contains(ref.symbol)
            edges[key] = edge
        }
        return edges.values.sorted { ($0.user, $0.owner) < ($1.user, $1.owner) }
    }

    /// Owner of a symbol, for the file view.
    public func owner(of symbolId: String) -> (feature: String, uncertain: Bool)? {
        owners[symbolId].map { ($0.feature, $0.status != "assigned") }
    }

    /// Sites involved in unresolved overlaps, for red highlighting.
    public var overlapSites: [String] { overlaps.flatMap(\.sites) }

    static func status(of states: [DishState]) -> DishState {
        for state in [DishState.cooking, .pass, .finished, .served] where states.contains(state) { return state }
        return .cooking
    }
}
