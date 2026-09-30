import Foundation

/// The skills every agent g8r wires up is given, for that session only:
/// today one, `g8r-plan`, which teaches the plan doc format so plans an
/// agent writes land on the map as written.
///
/// Nothing is written to the user's repo, `~/.claude` or `~/.codex`. The
/// skills are copied next to the shims, and:
/// - Claude Code loads them as a plugin, with `--plugin-dir`.
/// - Codex has no per-session skills directory (its skills come from its
///   own folders and installed plugins), so it is told, with
///   `-c developer_instructions=…`, to read the skill's file before writing
///   a plan doc. That key replaces any `developer_instructions` in the
///   user's own config for the session.
public struct AgentSkills: Equatable, Sendable {
    /// The directory `claude --plugin-dir` loads.
    public var claudePlugin: String
    /// The plan skill's `SKILL.md`, which Codex is told to read.
    public var planSkill: String

    public init(claudePlugin: String, planSkill: String) {
        self.claudePlugin = claudePlugin
        self.planSkill = planSkill
    }

    public static let pluginName = "g8r"
    public static let planSkillName = "g8r-plan"

    /// The plan skill's text, from G8rCore's resources.
    public static func planSkillText() throws -> String {
        guard let url = Bundle.module.url(forResource: "SKILL", withExtension: "md",
                                          subdirectory: "Skills/\(planSkillName)") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Writes the Claude Code plugin (`.claude-plugin/plugin.json` and
    /// `skills/<name>/SKILL.md`) under `directory`.
    @discardableResult
    public static func install(into directory: String) throws -> AgentSkills {
        let plugin = (directory as NSString).appendingPathComponent("claude-plugin")
        let skillDir = (plugin as NSString).appendingPathComponent("skills/\(planSkillName)")
        let manifestDir = (plugin as NSString).appendingPathComponent(".claude-plugin")
        let files = FileManager.default
        try files.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        try files.createDirectory(atPath: manifestDir, withIntermediateDirectories: true)

        let manifest: JSONValue = .object([
            "name": .string(pluginName),
            "description": .string("What an agent needs to know in a repo opened in g8r: how to write a plan doc."),
            "version": .string("1.0.0"),
            "author": .object(["name": .string("g8r")]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(String(decoding: try encoder.encode(manifest), as: UTF8.self) + "\n",
                  to: (manifestDir as NSString).appendingPathComponent("plugin.json"))
        let skill = (skillDir as NSString).appendingPathComponent("SKILL.md")
        try write(try planSkillText(), to: skill)
        return AgentSkills(claudePlugin: plugin, planSkill: skill)
    }

    /// What Codex is told, as a developer message, so it reads the skill
    /// when the work calls for it, as a skill's description would.
    public var codexInstructions: String {
        "This session runs in g8r. Before you write or edit a g8r plan doc (PLAN.md, plans/*.md or "
            + "docs/plans/*.md), read \(planSkill) and follow it, so every component lands on g8r's map."
    }

    private static func write(_ text: String, to path: String) throws {
        if (try? String(contentsOfFile: path, encoding: .utf8)) != text {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
