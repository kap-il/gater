import XCTest
@testable import G8rCore

final class AgentSkillsTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }

    /// The skill's example plan is what the parser reads, so the two can't
    /// drift apart: it names two components, and the map has no problem
    /// with them.
    func testTheSkillsExamplePlanParses() throws {
        let text = try AgentSkills.planSkillText()
        let fence = try XCTUnwrap(text.components(separatedBy: "```markdown\n").dropFirst().first)
        let example = try XCTUnwrap(fence.components(separatedBy: "\n```\n").first)

        let parsed = PlanDocParser.parse(text: example, doc: "PLAN.md")
        XCTAssertEqual(parsed.components.map(\.id), ["auth", "db"])
        let auth = try XCTUnwrap(parsed.components.first)
        XCTAssertEqual(auth.name, "Sign-in")
        XCTAssertEqual(auth.needs, ["db"])
        XCTAssertEqual(auth.paths, ["src/auth/", "src/middleware.ts"])
        XCTAssertTrue(auth.summary.hasPrefix("Email and password sign-in"), auth.summary)
        XCTAssertNotNil(auth.doneWhen)
        XCTAssertTrue(parsed.components.allSatisfy { !$0.paths.isEmpty && $0.doneWhen != nil })
        XCTAssertEqual(PlanLoader.check(parsed.components).problems, [])
    }

    func testTheSkillIsAClaudeCodePlugin() throws {
        let skills = try AgentSkills.install(into: sandbox.path)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath:
            skills.claudePlugin + "/.claude-plugin/plugin.json")))
        XCTAssertEqual(manifest.value(atPath: "name")?.stringValue, "g8r")
        XCTAssertEqual(skills.planSkill, skills.claudePlugin + "/skills/g8r-plan/SKILL.md")
        let skill = try String(contentsOfFile: skills.planSkill, encoding: .utf8)
        XCTAssertEqual(skill, try AgentSkills.planSkillText())
        XCTAssertTrue(skill.hasPrefix("---\nname: g8r-plan\ndescription: "), "frontmatter Claude Code reads")
        XCTAssertNoThrow(try AgentSkills.install(into: sandbox.path), "installing again is fine")
    }

    func testBothAgentsAreGivenTheSkill() throws {
        let skills = AgentSkills(claudePlugin: "/g/claude-plugin", planSkill: "/g/claude-plugin/skills/g8r-plan/SKILL.md")
        XCTAssertEqual(Array(Agent.claudeCode.wiring(hookBinary: "/h", skills: skills).suffix(2)),
                       ["--plugin-dir", "/g/claude-plugin"])
        let claude = Agent.claudeCode.launch(command: "claude", name: "build-x", prompt: "p", hookBinary: "/h",
                                             skills: skills)
        XCTAssertTrue(claude.command.hasSuffix(" --plugin-dir /g/claude-plugin 'p'"), claude.command)

        let codex = Agent.codex.wiring(hookBinary: "/h", skills: skills)
        XCTAssertEqual(codex.count, 4)
        XCTAssertEqual(codex[2], "-c")
        XCTAssertTrue(codex[3].hasPrefix(#"developer_instructions="This session runs in g8r."#), codex[3])
        XCTAssertTrue(codex[3].contains(skills.planSkill))
        XCTAssertTrue(codex[3].hasSuffix(#"map.""#))
        XCTAssertEqual(Agent.codex.wiring(hookBinary: "/h").count, 2, "no skills, no instructions")
    }
}
