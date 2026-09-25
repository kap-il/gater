import Foundation

/// A place where two agents' work meets (spec §4.9).
public struct Overlap: Equatable {
    public enum Kind: String, Equatable {
        /// Two or more agents occupy the same feature node.
        case sharedFeature = "shared_feature"
        /// An agent changed the public surface of a symbol that another
        /// agent's code (written/changed by it, or in its scope) uses.
        case publicSurface = "public_surface"
    }

    /// Stable key: the same overlap is only reported once.
    public var key: String
    public var kind: Kind
    /// The feature node the overlap is on.
    public var feature: String
    public var panes: [String]
    // publicSurface
    public var symbol: String?
    public var change: String?
    public var fromPane: String?
    public var inPane: String?
    public var sites: [String]
    /// Symbols whose ownership is uncertain, with confidence (spec §4.7:
    /// uncertain + overlap → part of the orchestrator review).
    public var uncertain: [String: Double]

    public var event: GaterEvent {
        var extra: [String: JSONValue] = [
            "overlap": .string(key),
            "type": .string(kind.rawValue),
            "node": .string(feature),
            "panes": .array(panes.map { .string($0) }),
            "sites": .array(sites.map { .string($0) }),
            "uncertain": .object(uncertain.mapValues { .number($0) }),
        ]
        if let symbol { extra["symbol"] = .string(symbol) }
        if let change { extra["change"] = .string(change) }
        if let fromPane { extra["from_pane"] = .string(fromPane) }
        if let inPane { extra["in_pane"] = .string(inPane) }
        return GaterEvent(kind: "overlap", extra: extra)
    }
}

/// Derives overlaps from the event stream (spec §4.9). Occupancy is
/// computed from edits + symbols + ownership, never self-reported; the
/// plan supplies each pane's dish scope.
///
/// Triggers: a `references` event (a public-surface change was found used
/// in another worktree) is a targeted check; `ownership` / `symbols_changed`
/// re-evaluate shared occupancy. Body-only edits inside an agent's own
/// feature never produce anything.
public struct OverlapDetector {
    public struct Owner: Equatable {
        public var feature: String
        public var status: String
        public var confidence: Double
    }

    public private(set) var owners: [String: Owner] = [:]
    /// pane → symbol ids it changed
    private var changedSymbols: [String: Set<String>] = [:]
    /// pane → worktree-relative files it changed
    private var changedFiles: [String: Set<String>] = [:]
    private var reported: Set<String> = []

    public init() {}

    /// Folds one event in; returns overlaps that are new.
    public mutating func apply(_ event: GaterEvent, plan: Plan) -> [Overlap] {
        switch event.kind {
        case "ownership":
            guard let symbol = event["symbol"]?.stringValue, let feature = event["feature"]?.stringValue else { return [] }
            var confidence = 0.0
            if case let .number(c)? = event["confidence"] { confidence = c }
            owners[symbol] = Owner(feature: feature, status: event["status"]?.stringValue ?? "assigned", confidence: confidence)
            return sharedFeatureOverlaps()

        case "symbols_changed":
            guard let pane = event.pane else { return [] }
            if let path = event["path"]?.stringValue { changedFiles[pane, default: []].insert(path) }
            for change in event.fields["changes"]?.arrayValue ?? [] {
                if let id = change.value(atPath: "id")?.stringValue { changedSymbols[pane, default: []].insert(id) }
            }
            return sharedFeatureOverlaps()

        case "references":
            return surfaceOverlap(event, plan: plan).map { [$0] } ?? []

        default:
            return []
        }
    }

    /// Symbols `pane` changed that are owned by `feature` (review context).
    public func symbols(changedBy pane: String, in feature: String) -> [String] {
        (changedSymbols[pane] ?? []).filter { owners[$0]?.feature == feature }.sorted()
    }

    /// Replays a log (at launch) without re-reporting what it contains.
    public mutating func replay(_ events: [GaterEvent], plan: Plan) {
        for event in events {
            if event.kind == "overlap", let key = event["overlap"]?.stringValue {
                reported.insert(key)
            } else {
                _ = apply(event, plan: plan)
            }
        }
    }

    // MARK: - Conditions

    /// Two or more agents changed symbols confidently owned by the same
    /// feature. `unassigned` isn't a node, so it never counts.
    private mutating func sharedFeatureOverlaps() -> [Overlap] {
        var occupants: [String: Set<String>] = [:]
        for (pane, symbols) in changedSymbols {
            for symbol in symbols {
                guard let owner = owners[symbol], owner.status == "assigned",
                      owner.feature != "unassigned" else { continue }
                occupants[owner.feature, default: []].insert(pane)
            }
        }
        var found: [Overlap] = []
        for (feature, panes) in occupants.sorted(by: { $0.key < $1.key }) where panes.count > 1 {
            let sortedPanes = panes.sorted()
            let key = "feature|\(feature)|\(sortedPanes.joined(separator: ","))"
            guard reported.insert(key).inserted else { continue }
            found.append(Overlap(key: key, kind: .sharedFeature, feature: feature, panes: sortedPanes,
                                 symbol: nil, change: nil, fromPane: nil, inPane: nil, sites: [], uncertain: [:]))
        }
        return found
    }

    /// A's public-surface change is used in B's worktree *in code B wrote
    /// or changed, or inside B's dish scope*. Uses of untouched code outside
    /// B's scope aren't B's problem (yet).
    private mutating func surfaceOverlap(_ event: GaterEvent, plan: Plan) -> Overlap? {
        guard let symbol = event["symbol"]?.stringValue, let inPane = event["in_pane"]?.stringValue,
              let fromPane = event["from_pane"]?.stringValue, fromPane != inPane else { return nil }
        let allSites = (event.fields["sites"]?.arrayValue ?? []).compactMap(\.stringValue)
        let scope = plan.dishes
            .filter { $0.pane == inPane && [.cooking, .pass, .finished].contains($0.state) }
            .flatMap(\.scope)
            .filter(Glob.isPathLike)
        let files = changedFiles[inPane] ?? []
        let relevant = allSites.filter { site in
            let path = site.split(separator: ":").dropLast().joined(separator: ":")
            return files.contains(path) || scope.contains { Glob.matches($0, path) }
        }
        guard !relevant.isEmpty else { return nil }

        let key = "surface|\(symbol)|\(fromPane)|\(inPane)|\(relevant.joined(separator: ","))"
        guard reported.insert(key).inserted else { return nil }
        let owner = owners[symbol]
        var uncertain: [String: Double] = [:]
        if let owner, owner.status == "uncertain" { uncertain[symbol] = owner.confidence }
        // The node is the symbol's owner when Jev placed it confidently;
        // otherwise it's the feature of the work that changed it (an
        // uncertain 0.07 guess must not name the node — seen live).
        let confidentOwner = owner.flatMap { $0.status == "assigned" && $0.feature != "unassigned" ? $0.feature : nil }
        let feature = confidentOwner ?? plan.currentDish(forPane: fromPane)?.feature ?? "unassigned"
        return Overlap(key: key, kind: .publicSurface, feature: feature,
                       panes: [fromPane, inPane], symbol: symbol, change: event["change"]?.stringValue,
                       fromPane: fromPane, inPane: inPane, sites: relevant, uncertain: uncertain)
    }
}
