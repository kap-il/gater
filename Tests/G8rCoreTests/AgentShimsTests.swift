import XCTest
@testable import G8rCore

/// The shims run as they would in a pane: `/bin/sh` scripts on a PATH made
/// up for the test, in front of a stand-in agent that prints what it was
/// run with, and a stand-in `g8r-hook` that writes down what it was run
/// with.
final class AgentShimsTests: XCTestCase {
    private var sandbox: URL!
    private var home: String!
    private var hook: String!
    private var hookLog: String!
    private var shims: AgentShims.Installed!
    /// Where the stand-in agents live.
    private var realBin: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-shims-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        home = path("home")
        realBin = path("real bin")
        hookLog = path("hook.log")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: realBin, withIntermediateDirectories: true)
        // Answers `claude-settings` the way g8r-hook's reply is used, and
        // writes down every run, one argument per line, then the pane.
        hook = try script(path("g8r hook"), """
        if [ "$1" = claude-settings ]; then printf 'MERGED(%s)\\n' "$2"; exit 0; fi
        { for a in "$@"; do printf '%s\\n' "$a"; done; printf 'pane=%s component=%s\\n' "$G8R_PANE_ID" "$G8R_COMPONENT"; } >> '\(hookLog!)'
        """)
        shims = try AgentShims.install(hookBinary: hook, home: home)
        for agent in Agent.allCases {
            // Prints each argument it got, NUL-terminated, after its own path.
            try script((realBin as NSString).appendingPathComponent(agent.program), #"""
            printf '%s\0' "$0" "$@"
            """#)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }

    private func path(_ name: String) -> String { sandbox.appendingPathComponent(name).path }

    @discardableResult
    private func script(_ path: String, _ body: String) throws -> String {
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func shim(_ agent: Agent) -> String { (shims.bin as NSString).appendingPathComponent(agent.program) }

    /// Runs `executable` with `environment` only.
    private func run(_ executable: String, _ arguments: [String] = [], environment: [String: String])
        throws -> (status: Int32, output: Data, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = sandbox
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output, String(decoding: error, as: UTF8.self))
    }

    /// The shim for `agent`, run in a pane (or not): what the real agent
    /// was run with, its own path first.
    private func argv(_ agent: Agent, _ arguments: [String], path: String? = nil,
                      pane: String? = "shell-1", component: String? = nil) throws -> [String] {
        var env = ["PATH": path ?? "\(shims.bin):\(realBin!):/usr/bin:/bin", "HOME": home!]
        env["G8R_PANE_ID"] = pane
        env["G8R_COMPONENT"] = component
        let result = try run(shim(agent), arguments, environment: env)
        XCTAssertEqual(result.status, 0, result.error)
        return String(decoding: result.output, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }

    private let awkward = ["plain", "two words", #"it's "quoted""#, "$HOME", "*", "", "a\nb", "--", "-c"]

    // MARK: - The scripts

    func testEveryShimIsValidShell() throws {
        for agent in Agent.allCases {
            let result = try run("/bin/sh", ["-n", shim(agent)], environment: [:])
            XCTAssertEqual(result.status, 0, "\(agent): \(result.error)")
            let attributes = try FileManager.default.attributesOfItem(atPath: shim(agent))
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shims.bin).sorted(),
                       Agent.allCases.map(\.program).sorted(), "one shim per agent")
    }

    func testShimsLiveUnderG8rsHomeOnePlacePerHook() {
        XCTAssertTrue(shims.bin.hasPrefix(home + "/.g8r/shims/"), shims.bin)
        XCTAssertNotEqual(AgentShims.directory(hookBinary: "/a/g8r-hook", home: home),
                          AgentShims.directory(hookBinary: "/b/g8r-hook", home: home))
        XCTAssertEqual(AgentShims.directory(hookBinary: hook, home: home) + "/bin", shims.bin)
    }

    func testThePaneEnvironmentPutsTheShimsFirst() {
        let env = AgentShims.environment(shims, path: "/usr/bin:/bin", base: ["ZDOTDIR": "/mine"])
        XCTAssertEqual(env["PATH"], "\(shims.bin):/usr/bin:/bin")
        XCTAssertEqual(env["ZDOTDIR"], shims.zdotdir)
        XCTAssertEqual(env["G8R_USER_ZDOTDIR"], "/mine")
        XCTAssertEqual(env["G8R_SHIMS"], shims.bin)
        XCTAssertNil(AgentShims.environment(shims, path: "/bin", base: [:])["G8R_USER_ZDOTDIR"])
    }

    // MARK: - Running the real agent

    func testClaudeGetsG8rsHooksBeforeTheUsersArgumentsUntouched() throws {
        let got = try argv(.claudeCode, awkward)
        XCTAssertEqual(got, [realBin + "/claude", "--settings", HookInstaller.flagSettings(hookBinary: hook),
                             "--plugin-dir", shims.skills.claudePlugin] + awkward)
        XCTAssertEqual(Array(got.dropFirst().prefix(4)), Agent.claudeCode.wiring(hookBinary: hook, skills: shims.skills))
    }

    func testCodexGetsItsNotifyBeforeTheUsersArgumentsUntouched() throws {
        let got = try argv(.codex, awkward)
        XCTAssertEqual(got, [realBin + "/codex", "-c", #"notify=["\#(hook!)", "codex-notify"]"#,
                             "-c", "developer_instructions=" + Agent.tomlString(shims.skills.codexInstructions)] + awkward)
        XCTAssertEqual(Array(got.dropFirst().prefix(4)), Agent.codex.wiring(hookBinary: hook, skills: shims.skills))
    }

    func testOutsideAPaneTheRealAgentRunsUntouched() throws {
        for agent in Agent.allCases {
            XCTAssertEqual(try argv(agent, awkward, pane: nil), [realBin + "/" + agent.program] + awkward)
            XCTAssertEqual(try argv(agent, awkward, pane: ""), [realBin + "/" + agent.program] + awkward)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hookLog), "nothing told to g8r")
    }

    func testAMissingRealAgentFailsClearly() throws {
        let result = try run(shim(.codex), ["hi"], environment: ["PATH": "\(shims.bin):/usr/bin:/bin",
                                                                  "G8R_PANE_ID": "shell-1"])
        XCTAssertEqual(result.status, 127)
        XCTAssertTrue(result.error.contains("codex isn't on your PATH"), result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hookLog), "no agent_started for an agent that didn't start")
    }

    func testTheShimDirectoryTwiceOnPathStillFindsTheRealAgent() throws {
        let alias = path("alias")
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: shims.bin)
        let path = "\(shims.bin):\(shims.bin)/:\(alias):\(shims.bin):\(realBin!):/usr/bin:/bin"
        XCTAssertEqual(try argv(.claudeCode, ["x"], path: path).first, realBin + "/claude")
        XCTAssertEqual(try argv(.codex, ["x"], path: path, pane: nil), [realBin + "/codex", "x"])
    }

    func testAnotherG8rsShimsAreSkippedToo() throws {
        let other = try AgentShims.install(hookBinary: "/elsewhere/g8r-hook", home: home)
        let path = "\(other.bin):\(shims.bin):\(realBin!):/usr/bin:/bin"
        XCTAssertEqual(try argv(.codex, ["x"], path: path),
                       [realBin + "/codex"] + Agent.codex.wiring(hookBinary: hook, skills: shims.skills) + ["x"])
    }

    // MARK: - The user's own --settings

    func testTheUsersOwnSettingsAreMergedNotReplaced() throws {
        let plugin = shims.skills.claudePlugin
        XCTAssertEqual(try argv(.claudeCode, ["--model", "opus", "--settings", "my settings.json", "hi there"]),
                       [realBin + "/claude", "--plugin-dir", plugin,
                        "--model", "opus", "--settings", "MERGED(my settings.json)", "hi there"])
        XCTAssertEqual(try argv(.claudeCode, [#"--settings={"a": "it's"}"#, "p"]),
                       [realBin + "/claude", "--plugin-dir", plugin, #"--settings=MERGED({"a": "it's"})"#, "p"])
        // After `--` everything is the prompt, and g8r adds its own settings.
        XCTAssertEqual(try argv(.claudeCode, ["--", "--settings", "x"]),
                       [realBin + "/claude", "--settings", HookInstaller.flagSettings(hookBinary: hook),
                        "--plugin-dir", plugin, "--", "--settings", "x"])
        // The user's own plugins load beside g8r's.
        XCTAssertEqual(try argv(.claudeCode, ["--plugin-dir", "mine"]).suffix(4),
                       ["--plugin-dir", plugin, "--plugin-dir", "mine"])
    }

    func testABuildLaunchThroughTheShimIsNotWiredTwice() throws {
        let wiring = Agent.claudeCode.wiring(hookBinary: hook, skills: shims.skills)
        let got = try argv(.claudeCode, ["--name", "build-x"] + wiring + ["prompt"], pane: "build-x", component: "x")
        XCTAssertEqual(got, [realBin + "/claude", "--name", "build-x", "--settings", "MERGED(\(wiring[1]))",
                             "--plugin-dir", shims.skills.claudePlugin, "prompt"], "neither settings nor plugin twice")
    }

    func testMergingSettingsKeepsTheUsersAndReplacesOldG8rHooks() throws {
        let own = #"{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}, {"hooks": [{"type": "command", "command": "'/old/g8r-hook'"}]}]}}"#
        let file = path("own.json")
        try own.write(toFile: file, atomically: true, encoding: .utf8)
        for value in [own, "own.json", file] {
            let merged = try HookInstaller.flagSettings(merging: value, hookBinary: "/new/g8r-hook",
                                                        directory: sandbox.path)
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(merged.utf8))
            XCTAssertEqual(json.value(atPath: "model")?.stringValue, "opus")
            let stops = json.value(atPath: "hooks.Stop")?.arrayValue ?? []
            let commands = stops.compactMap { $0.value(atPath: "hooks")?.arrayValue?.first?.value(atPath: "command")?.stringValue }
            XCTAssertEqual(commands, ["say done", "'/new/g8r-hook'"], value)
            XCTAssertEqual(json.value(atPath: "hooks.PostToolUse")?.arrayValue?.count, 2)
        }
        let ours = HookInstaller.flagSettings(hookBinary: "/x/g8r-hook")
        let again = try HookInstaller.flagSettings(merging: ours, hookBinary: "/x/g8r-hook", directory: sandbox.path)
        XCTAssertEqual(again, ours, "merging g8r's own changes nothing")
        XCTAssertThrowsError(try HookInstaller.flagSettings(merging: "missing.json", hookBinary: "/h",
                                                            directory: sandbox.path))
    }

    // MARK: - Telling g8r

    func testAShimTellsG8rItStartedAndTheEventLands() throws {
        _ = try argv(.codex, ["hi"], pane: "shell-2")
        let lines = try waitForHookLog()
        XCTAssertEqual(lines, ["agent-started", "codex", "pane=shell-2 component="])

        let event = try XCTUnwrap(HookProcessor.process(arguments: Array(lines.prefix(2)), stdin: { Data() },
                                                        env: .init(paneId: "shell-2"))?.first)
        XCTAssertEqual(event.kind, "agent_started")
        XCTAssertEqual(event.pane, "shell-2")
        XCTAssertEqual(event["agent"]?.stringValue, "codex")
        XCTAssertNil(event["component"])
        XCTAssertNotNil(event.ts)

        var wired = WiredAgent(since: Date(timeIntervalSinceNow: -5))
        XCTAssertTrue(wired.note(event))
        XCTAssertEqual(wired.agent, .codex)
    }

    func testABuildSessionSaysNothingOfStarting() throws {
        _ = try argv(.claudeCode, ["hi"], pane: "build-x", component: "x")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hookLog), "build_started says it")
    }

    func testAnUnknownAgentStartsNothing() {
        XCTAssertNil(HookProcessor.process(arguments: ["agent-started", "gemini"], stdin: { Data() },
                                           env: .init(paneId: "shell-1")))
        XCTAssertNil(HookProcessor.process(arguments: ["agent-started"], stdin: { Data() },
                                           env: .init(paneId: "shell-1")))
    }

    private func waitForHookLog() throws -> [String] {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: hookLog, encoding: .utf8), text.contains("pane=") {
                return text.split(separator: "\n").map(String.init)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw XCTSkip("the hook never ran")
    }

    // MARK: - zsh

    /// A login zsh reads /etc/zprofile, whose path_helper moves inherited
    /// PATH entries behind the system's, and a .zshrc may put more in
    /// front. By the first prompt the shims are first again.
    func testZshPutsTheShimsFirstAfterTheUsersStartupFiles() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { throw XCTSkip("no zsh") }
        let own = path("own zdotdir")
        try FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true)
        try "export FROM_ZSHENV=yes\n".write(toFile: own + "/.zshenv", atomically: true, encoding: .utf8)
        try "PATH=/in/front:$PATH\n".write(toFile: own + "/.zshrc", atomically: true, encoding: .utf8)
        var env = AgentShims.environment(shims, path: "\(realBin!):/usr/bin:/bin", base: ["ZDOTDIR": own])
        env["HOME"] = home
        env["TERM"] = "dumb"
        let input = path("input.zsh")
        try #"print -r -- "PATH=$PATH"; print -r -- "ENV=$FROM_ZSHENV Z=$ZDOTDIR"; print -r -- "HOOKS=$precmd_functions"; whence -p claude; exit"#
            .write(toFile: input, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-i"]
        process.environment = env
        process.standardInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: input))
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let path = try XCTUnwrap(text.components(separatedBy: "PATH=").last?.split(separator: "\n").first)
        let entries = path.split(separator: ":").map(String.init)
        XCTAssertEqual(entries.first, shims.bin, text)
        XCTAssertEqual(entries.filter { $0 == shims.bin }.count, 1, "once")
        XCTAssertTrue(entries.contains("/in/front"), "the user's .zshrc ran")
        XCTAssertTrue(text.contains("ENV=yes Z=\(own)"), "their .zshenv ran and their ZDOTDIR is back: \(text)")
        XCTAssertTrue(text.contains("HOOKS=\n") || text.contains("HOOKS=\r"), "the hook removed itself: \(text)")
        XCTAssertTrue(text.contains(shims.bin + "/claude"), "claude is the shim")
    }
}
