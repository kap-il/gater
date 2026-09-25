import Foundation

/// Owns `<repo>/.gater/plan.json`: rebuilt from the event log at startup,
/// updated as events arrive, rewritten atomically on every change.
public final class PlanStore {
    public let path: URL
    private let queue = DispatchQueue(label: "gater.plan")
    private var plan = Plan()

    /// Called (on the store's queue) after each change is written.
    public var onChange: ((Plan) -> Void)?

    public init(path: URL) {
        self.path = path
    }

    public static func defaultPath(repoRoot: String) -> URL {
        URL(fileURLWithPath: repoRoot).appendingPathComponent(".gater/plan.json")
    }

    public var current: Plan { queue.sync { plan } }

    /// Replays the whole log (the plan is derived state, never trusted
    /// from disk) and writes the result.
    public func rebuild(from events: [GaterEvent]) throws {
        try queue.sync {
            plan = PlanReducer.replay(events)
            try write(plan)
        }
    }

    public func apply(_ event: GaterEvent) {
        queue.async { [self] in
            guard PlanReducer.apply(event, to: &plan) else { return }
            try? write(plan)
            onChange?(plan)
        }
    }

    private func write(_ plan: Plan) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(plan).write(to: path, options: .atomic)
    }

    /// Reads plan.json (for gater-hook). Missing file = empty plan.
    public static func load(from path: URL) -> Plan? {
        guard FileManager.default.fileExists(atPath: path.path) else { return Plan() }
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Plan.self, from: data)
    }
}
