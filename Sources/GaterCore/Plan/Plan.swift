import Foundation

/// A dish's place in the kitchen (spec §4.10), plus the two ways a dish
/// can leave the plan early.
public enum DishState: String, Codable, Equatable {
    case cooking   // a delegate is working on it
    case pass      // the delegate posted GATER-DONE; waiting on the orchestrator
    case finished  // the orchestrator finished/patched it (type: finish)
    case served    // merged into gater/integration
    case cancelled // type: cancel
    case merged    // folded into another dish (type: merge)

    /// Still part of the live plan.
    public var isActive: Bool { self != .cancelled && self != .merged }
}

public struct Dish: Codable, Equatable {
    public var id: String
    public var feature: String
    public var directive: String
    public var scope: [String]
    /// Pane the dish was delegated to (SendMessage `to`).
    public var pane: String?
    public var state: DishState
    /// Directives of later `instruct` messages, oldest first.
    public var instructions: [String]
    public var mergedInto: String?
    public var createdAt: String
    public var updatedAt: String
    /// From the latest GATER-DONE note.
    public var did: String?
    public var assumed: String?

    enum CodingKeys: String, CodingKey {
        case id, feature, directive, scope, pane, state, instructions, did, assumed
        case mergedInto = "merged_into"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// One step in the plan's history: what changed, and why (the directive).
public struct PlanChange: Codable, Equatable {
    public var version: Int
    public var ts: String
    /// GATER/1 type, or "done" / "lifecycle".
    public var type: String
    public var dish: String
    public var summary: String
    public var reason: String?
}

/// The amorphous plan (spec §4.5): derived only from the event log, written
/// only by Gater, versioned by change.
public struct Plan: Codable, Equatable {
    public var version: Int = 0
    /// Feature names in the order they first appeared.
    public var features: [String] = []
    public var dishes: [Dish] = []
    public var changes: [PlanChange] = []
    /// Events that couldn't be applied (e.g. instruct for an unknown dish).
    public var warnings: [String] = []

    public init() {}

    public func dish(_ id: String) -> Dish? { dishes.first { $0.id == id } }

    /// Jev's option set (spec §4.5/§4.7): live features, plus `unassigned`.
    public var jevOptions: [String] {
        let live = Set(dishes.filter { $0.state.isActive }.map(\.feature))
        return features.filter(live.contains) + ["unassigned"]
    }

    /// Next unused `d-NNN` id, for error messages that suggest one.
    public var nextDishId: String {
        let highest = dishes.compactMap { Int($0.id.drop(while: { !$0.isNumber })) }.max() ?? 0
        return String(format: "d-%03d", highest + 1)
    }

    /// The dish a pane is currently working on: its most recently updated
    /// live, unserved dish. Used for commit trailers.
    public func currentDish(forPane pane: String) -> Dish? {
        dishes
            .filter { $0.pane == pane && [.cooking, .pass, .finished].contains($0.state) }
            .max { $0.updatedAt < $1.updatedAt }
    }

    enum CodingKeys: String, CodingKey {
        case version, features, dishes, changes, warnings
        case jevOptions = "jev_options"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        features = try c.decodeIfPresent([String].self, forKey: .features) ?? []
        dishes = try c.decodeIfPresent([Dish].self, forKey: .dishes) ?? []
        changes = try c.decodeIfPresent([PlanChange].self, forKey: .changes) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(features, forKey: .features)
        try c.encode(jevOptions, forKey: .jevOptions)
        try c.encode(dishes, forKey: .dishes)
        try c.encode(changes, forKey: .changes)
        try c.encode(warnings, forKey: .warnings)
    }
}
