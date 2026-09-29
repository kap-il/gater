import Foundation

/// A repo's settings, from three places. `g8r.json` at the repo root is
/// tracked, so everyone who clones the repo gets it. `.g8r/config.json` is
/// local and overrides it key by key. The environment overrides both, so
/// one run can differ without a file changing.
public struct G8rConfig: Equatable {
    /// Where plan docs are looked for when nothing names them.
    public static let defaultPlans = ["PLAN.md", "plans/*.md", "docs/plans/*.md"]

    /// Plan docs, as paths or globs relative to the repo root.
    public var plans: [String]
    public var buildCommand: String?
    public var testCommand: String?
    /// Run in each new worktree, to put back what git doesn't carry.
    public var worktreeSetup: String?
    /// Globs of paths the map leaves out.
    public var ignore: [String]

    public init(plans: [String] = G8rConfig.defaultPlans, buildCommand: String? = nil,
                testCommand: String? = nil, worktreeSetup: String? = nil, ignore: [String] = []) {
        self.plans = plans
        self.buildCommand = buildCommand
        self.testCommand = testCommand
        self.worktreeSetup = worktreeSetup
        self.ignore = ignore
    }

    public static func load(repoRoot: String,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> G8rConfig {
        let root = URL(fileURLWithPath: repoRoot)
        let shared = keys(of: root.appendingPathComponent("g8r.json"))
        let local = keys(of: root.appendingPathComponent(".g8r/config.json"))
        // A key the local file has wins even when its value is null, which
        // is how one checkout turns off a command the repo sets.
        func value(_ key: String) -> JSONValue? { local[key] ?? shared[key] }
        func list(_ key: String) -> [String]? { value(key)?.arrayValue?.compactMap(\.stringValue) }

        return G8rConfig(
            plans: list("plans") ?? defaultPlans,
            buildCommand: environment["G8R_BUILD_COMMAND"] ?? value("build_command")?.stringValue,
            testCommand: environment["G8R_TEST_COMMAND"] ?? value("test_command")?.stringValue,
            worktreeSetup: value("worktree_setup")?.stringValue,
            ignore: list("ignore") ?? [])
    }

    /// The top-level keys of a settings file; none when the file is missing
    /// or isn't a JSON object.
    private static func keys(of file: URL) -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return json.objectValue ?? [:]
    }
}
