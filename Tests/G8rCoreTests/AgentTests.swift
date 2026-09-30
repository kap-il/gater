import XCTest
@testable import G8rCore

final class AgentTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        repo = sandbox.appendingPathComponent("app").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"]] {
            XCTAssertEqual(try GitWorktree.git(args, in: repo).status, 0)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }

    // MARK: - Choosing

    func testNamesAndPrograms() {
        XCTAssertEqual(Agent(name: "claude"), .claudeCode)
        XCTAssertEqual(Agent(name: " Codex "), .codex)
        XCTAssertNil(Agent(name: "gemini"))
        XCTAssertEqual(Agent.default, .claudeCode)
        XCTAssertEqual(Agent.claudeCode.program, "claude")
        XCTAssertEqual(Agent.codex.program, "codex")
        XCTAssertEqual(Agent.codex.command(environment: [:]), "codex")
        XCTAssertEqual(Agent.codex.command(environment: ["G8R_AGENT_COMMAND": "./stand-in.sh"]), "./stand-in.sh")
        XCTAssertEqual(Agent.claudeCode.command(environment: ["G8R_AGENT_COMMAND": ""]), "claude")
    }

    // MARK: - Launch

    func testClaudeCodeLaunchesAreTodays() {
        let build = Agent.claudeCode.launch(command: "claude", name: "build-x", prompt: "It's here", hookBinary: "/h")
        XCTAssertEqual(build.command, #"claude --name 'build-x' 'It'\''s here'"#)
        XCTAssertEqual(build.idle, .stopEvent)
        let delegate = Agent.claudeCode.launch(command: "/usr/local/bin/claude --model opus", name: "delegate-a",
                                               prompt: nil, hookBinary: nil)
        XCTAssertEqual(delegate.command, "/usr/local/bin/claude --model opus --name 'delegate-a'")
        let script = Agent.claudeCode.launch(command: "./agent.sh", name: "build-x", prompt: "p", hookBinary: "/h")
        XCTAssertEqual(script.command, "./agent.sh 'p'; exit")
        XCTAssertTrue(script.idleOnExit)
        XCTAssertEqual(Agent.claudeCode.launch(command: "./agent.sh", name: "d", prompt: nil, hookBinary: nil).command,
                       "./agent.sh")
    }

    func testCodexIsToldToNotifyG8rOnTheCommandLine() {
        let build = Agent.codex.launch(command: "codex", name: "build-x", prompt: "It's here",
                                       hookBinary: "/opt/g8r bin/g8r-hook")
        XCTAssertEqual(build.command,
                       #"codex -c 'notify=["/opt/g8r bin/g8r-hook", "codex-notify"]' 'It'\''s here'"#)
        XCTAssertEqual(build.idle, .stopEvent)

        let delegate = Agent.codex.launch(command: "/usr/local/bin/codex -m gpt-5", name: "delegate-a", prompt: nil,
                                          hookBinary: "/h/g8r-hook")
        XCTAssertEqual(delegate.command, #"/usr/local/bin/codex -m gpt-5 -c 'notify=["/h/g8r-hook", "codex-notify"]'"#)
    }

    func testCodexWithoutTheHookIsIdleOnExit() {
        let launch = Agent.codex.launch(command: "codex", name: "build-x", prompt: "p", hookBinary: nil)
        XCTAssertEqual(launch.command, "codex 'p'; exit")
        XCTAssertEqual(launch.idle, .paneExit)
        let script = Agent.codex.launch(command: "./agent.sh", name: "build-x", prompt: "p", hookBinary: "/h")
        XCTAssertEqual(script.command, "./agent.sh 'p'; exit")
        XCTAssertTrue(script.idleOnExit)
    }

    func testTheNotifyPathIsQuotedForTomlAndTheShell() {
        XCTAssertEqual(Agent.tomlArray([#"/a "b"\c"#, "d'e"]), #"["/a \"b\"\\c", "d'e"]"#)
        let launch = Agent.codex.launch(command: "codex", name: "n", prompt: nil, hookBinary: "/it's/g8r-hook")
        XCTAssertEqual(launch.command, #"codex -c 'notify=["/it'\''s/g8r-hook", "codex-notify"]'"#)
    }

    // MARK: - Installing into a worktree

    private func worktree() throws -> String {
        try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
    }

    private func status(_ dir: String) throws -> String {
        try GitWorktree.git(["status", "--porcelain", "--untracked-files=all"], in: dir).output
    }

    func testClaudeCodeInstallsItsHooksAndUninstallsThemAlone() throws {
        let tree = try worktree()
        let settings = URL(fileURLWithPath: tree).appendingPathComponent(".claude/settings.local.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)

        try Agent.claudeCode.install(into: tree, hookBinary: "/x/g8r-hook")
        var json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settings))
        XCTAssertNotNil(json.value(atPath: "hooks.PostToolUse"))
        XCTAssertEqual(json.value(atPath: "hooks.Stop")?.arrayValue?.count, 2)
        XCTAssertEqual(try status(tree), "", "the settings file is kept out of git")

        try Agent.claudeCode.uninstall(from: tree)
        json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settings))
        XCTAssertEqual(json, .object([
            "model": .string("opus"),
            "hooks": .object(["Stop": .array([.object(["hooks": .array([.object([
                "type": .string("command"), "command": .string("say done")])])])])]),
        ]))
    }

    func testUninstallingWhatWasOnlyG8rsRemovesTheFile() throws {
        let tree = try worktree()
        try Agent.claudeCode.install(into: tree, hookBinary: "/x/g8r-hook")
        try Agent.claudeCode.uninstall(from: tree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree + "/.claude/settings.local.json"))
        XCTAssertNoThrow(try Agent.claudeCode.uninstall(from: tree), "nothing to take out")
    }

    func testCodexInstallsNothing() throws {
        let tree = try worktree()
        let before = try FileManager.default.contentsOfDirectory(atPath: tree).sorted()
        try Agent.codex.install(into: tree, hookBinary: "/x/g8r-hook")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tree).sorted(), before)
        try Agent.codex.uninstall(from: tree)
        XCTAssertEqual(try status(tree), "")
    }

    // MARK: - Trust

    func testClaudeCodeTrustIsWrittenAndCodexNeedsNone() throws {
        let home = sandbox.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let config = ClaudeTrust.defaultConfigPath(home: home)
        try #"{"projects": {"\#(repo!)": {"hasTrustDialogAccepted": true}}}"#
            .write(to: config, atomically: true, encoding: .utf8)
        let tree = try worktree()

        try Agent.codex.trustWorktree(tree, createdFrom: repo, home: home)
        XCTAssertFalse(ClaudeTrust.isTrusted(tree, config: config))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.codex"), "nothing written for Codex")

        try Agent.claudeCode.trustWorktree(tree, createdFrom: repo, home: home)
        XCTAssertTrue(ClaudeTrust.isTrusted(tree, config: config))
    }

    // MARK: - One-shot questions

    func testOneShotCommands() {
        let claude = Agent.claudeCode.oneShot(prompt: "Q", schema: "{}", schemaFile: "/tmp/s.json")
        XCTAssertEqual(claude, .init(executable: "claude",
                                     arguments: ["-p", "Q", "--output-format", "json", "--json-schema", "{}"]))
        let codex = Agent.codex.oneShot(prompt: "Q", schema: "{}", schemaFile: "/tmp/s.json")
        XCTAssertEqual(codex, .init(executable: "codex",
                                    arguments: ["exec", "--json", "--ephemeral", "--sandbox", "read-only",
                                                "--output-schema", "/tmp/s.json", "Q"]))
        XCTAssertFalse(Agent.claudeCode.needsSchemaFile)
        XCTAssertTrue(Agent.codex.needsSchemaFile)
        XCTAssertTrue(Agent.codex.needsStrictSchema)
    }

    /// What `codex exec --json` prints, in the event shapes of
    /// codex-rs/exec/src/exec_events.rs.
    static let codexEvents = """
        {"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"Reading the plan."}}
        {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"{\\"components\\":[]}"}}
        {"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}
        """

    func testCodexAnswersWithItsLastAgentMessage() throws {
        let answer = try Agent.codex.oneShotAnswer(from: (0, "note: reading from stdin\n" + Self.codexEvents))
        XCTAssertEqual(answer, .object(["components": .array([])]))
        // Without --json, the final message is all Codex prints.
        XCTAssertEqual(try Agent.codex.oneShotAnswer(from: (0, #"{"components":[]}"#)),
                       .object(["components": .array([])]))
    }

    func testCodexFailuresSayWhy() {
        let failed = """
            {"type":"thread.started","thread_id":"t"}
            {"type":"turn.started"}
            {"type":"error","message":"stream disconnected"}
            {"type":"turn.failed","error":{"message":"401 Unauthorized"}}
            """
        XCTAssertThrowsError(try Agent.codex.oneShotAnswer(from: (1, failed))) {
            XCTAssertEqual($0 as? Agent.OneShotError, .failed("401 Unauthorized"))
        }
        XCTAssertThrowsError(try Agent.codex.oneShotAnswer(from: (0, failed))) {
            XCTAssertEqual($0 as? Agent.OneShotError, .failed("401 Unauthorized"), "whatever the exit status")
        }
        XCTAssertThrowsError(try Agent.codex.oneShotAnswer(from: (127, "sh: codex: command not found"))) {
            XCTAssertEqual($0 as? Agent.OneShotError, .failed("sh: codex: command not found"))
        }
        let chatty = #"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"Sure! Here they are."}}"#
        XCTAssertThrowsError(try Agent.codex.oneShotAnswer(from: (0, chatty))) {
            XCTAssertEqual($0 as? Agent.OneShotError, .noAnswer)
        }
    }

    func testClaudeCodeAnswersUnderStructuredOutput() throws {
        let answer = try Agent.claudeCode.oneShotAnswer(from: (0, StubClaude.output(components: "")))
        XCTAssertEqual(answer, .object(["components": .array([])]))
        XCTAssertThrowsError(try Agent.claudeCode.oneShotAnswer(from: (0, Self.codexEvents))) {
            XCTAssertEqual($0 as? Agent.OneShotError, .noAnswer)
        }
    }
}
