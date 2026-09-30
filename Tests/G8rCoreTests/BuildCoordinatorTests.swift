import XCTest
@testable import G8rCore

final class BuildCoordinatorTests: XCTestCase {
    private var shop: BuildFixture!
    private var host: FakeBuildHost!
    private var events: [G8rEvent] = []

    override func setUpWithError() throws {
        shop = try BuildFixture()
        host = FakeBuildHost()
        events = []
    }

    override func tearDownWithError() throws { shop.remove() }

    private func coordinator(agent: String, runner: ((String) -> CommandRunner)? = nil) -> BuildCoordinator {
        let coordinator = BuildCoordinator(planRoot: shop.repo, agent: .claudeCode, agentCommand: agent, host: host,
                                           record: { [unowned self] in events.append($0) },
                                           scanner: BuildStubScanner(),
                                           runner: runner ?? { ProcessRunner.runner(in: $0) })
        host.coordinator = coordinator
        return coordinator
    }

    private func codexCoordinator(agent command: String, hookBinary: String) -> BuildCoordinator {
        let coordinator = BuildCoordinator(planRoot: shop.repo, agent: .codex, agentCommand: command,
                                           hookBinary: hookBinary, host: host,
                                           record: { [unowned self] in events.append($0) },
                                           scanner: BuildStubScanner())
        host.coordinator = coordinator
        return coordinator
    }

    private func kinds() -> [String] { events.compactMap(\.kind) }

    // MARK: - Refusals

    func testABlockedNodeRefusesToBuild() throws {
        let map = try shop.map()
        XCTAssertEqual(map.node("pay")?.blockedBy, ["cart"])
        let builds = coordinator(agent: "claude")
        XCTAssertThrowsError(try builds.build("pay", in: map)) { error in
            XCTAssertEqual(error as? BuildCoordinator.BuildError, .blocked("pay", by: ["cart"]))
        }
        XCTAssertTrue(host.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shop.worktree("pay")), "no worktree for a refusal")
        XCTAssertTrue(events.isEmpty)
    }

    func testWithNoWiredAgentBuildIsRefused() throws {
        let builds = BuildCoordinator(planRoot: shop.repo, host: host, record: { [unowned self] in events.append($0) })
        XCTAssertThrowsError(try builds.build("cart", in: try shop.map())) { error in
            XCTAssertEqual(error as? BuildCoordinator.BuildError, .noAgent)
            XCTAssertEqual("\(error)", "Start claude or codex in a shell to build.")
        }
        XCTAssertTrue(host.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shop.worktree("cart")), "no worktree for a refusal")
        XCTAssertTrue(events.isEmpty)

        builds.agent = .claudeCode
        builds.agentCommand = "claude"
        XCTAssertEqual(try builds.build("cart", in: try shop.map()).agent, .claudeCode, "once wired, it builds")
    }

    func testOnlyPlannedNodesBuild() throws {
        let map = try shop.map()
        XCTAssertEqual(BuildCoordinator.refusal(for: "store", in: map), .notPlanned("store", status: .built))
        XCTAssertEqual(BuildCoordinator.refusal(for: "nope", in: map), .unknown("nope"))
        XCTAssertNil(BuildCoordinator.refusal(for: "cart", in: map))
    }

    func testASecondBuildOfAnOpenSessionIsRefused() throws {
        let map = try shop.map()
        let builds = coordinator(agent: "claude")
        try builds.build("cart", in: map)
        XCTAssertThrowsError(try builds.build("cart", in: map)) { error in
            XCTAssertEqual(error as? BuildCoordinator.BuildError, .alreadyBuilding("cart"))
        }
    }

    // MARK: - Start

    func testStartOpensAClaudePaneWithThePromptInItsOwnWorktree() throws {
        try shop.write("g8r.json", #"{"worktree_setup": "echo \"$G8R_PLAN_ROOT\" > .setup-ran"}"#)
        let map = try shop.map()
        let launch = try coordinator(agent: "claude").build("cart", in: map)

        XCTAssertEqual(launch.pane, "build-cart")
        XCTAssertEqual(launch.worktree, shop.worktree("cart"))
        XCTAssertEqual(launch.branch, "g8r/cart")
        XCTAssertEqual(launch.base, GitWorktree.head(of: shop.repo))
        XCTAssertEqual(launch.environment, ["G8R_PANE_ID": "build-cart", "G8R_COMPONENT": "cart"])
        XCTAssertFalse(launch.idleOnExit)
        XCTAssertTrue(launch.command.hasPrefix("claude --name 'build-cart' 'You are building"), launch.command)
        XCTAssertTrue(launch.prompt.contains("public func save(_ key: String, value: String) -> Bool"))
        XCTAssertEqual(host.opened, [launch])
        XCTAssertEqual(GitWorktree.head(of: launch.worktree), launch.base)
        let setup = try String(contentsOfFile: launch.worktree + "/.setup-ran", encoding: .utf8)
        XCTAssertEqual(setup.trimmingCharacters(in: .whitespacesAndNewlines), shop.repo)

        let started = try XCTUnwrap(events.first)
        XCTAssertEqual(started.kind, "build_started")
        XCTAssertEqual(started["component"]?.stringValue, "cart")
        XCTAssertEqual(started.pane, "build-cart")
        XCTAssertEqual(started["worktree"]?.stringValue, launch.worktree)
        XCTAssertEqual(started["branch"]?.stringValue, "g8r/cart")
        XCTAssertEqual(started["base"]?.stringValue, launch.base)
    }

    func testBranchesFromIntegrationOnceItExists() throws {
        let integration = try Integrator(repoRoot: shop.repo).ensureWorktree()
        try shop.write("NOTES.md", "landed\n", in: integration)
        try shop.git("add", ".", in: integration)
        try shop.git("commit", "-qm", "landed", in: integration)
        let landed = try XCTUnwrap(GitWorktree.head(of: integration))
        XCTAssertNotEqual(landed, GitWorktree.head(of: shop.repo))

        let launch = try coordinator(agent: "claude").build("cart", in: try shop.map())
        XCTAssertEqual(launch.base, landed)
        XCTAssertEqual(GitWorktree.head(of: launch.worktree), landed)
    }

    func testAFailingSetupStopsTheBuild() throws {
        try shop.write("g8r.json", #"{"worktree_setup": "echo broken; exit 3"}"#)
        XCTAssertThrowsError(try coordinator(agent: "claude").build("cart", in: try shop.map())) { error in
            guard case let .setupFailed(id, output)? = error as? BuildCoordinator.BuildError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(id, "cart")
            XCTAssertTrue(output.contains("broken"))
        }
        XCTAssertTrue(host.opened.isEmpty)
    }

    // MARK: - End to end

    /// The done-when: an agent that writes a file, commits it with the
    /// trailer and exits ends with the commit on `g8r/integration`, the
    /// pane closed and the worktree gone.
    func testAScriptAgentEndsMergedWithThePaneClosedAndTheWorktreeGone() throws {
        try shop.write("g8r.json", """
        {"build_command": "true", "test_command": "test -f src/cart/Cart.swift",
         "worktree_setup": "touch .setup-ran"}
        """)
        let agent = try shop.script("agent.sh", """
        test "$G8R_PANE_ID" = build-cart
        test "$G8R_COMPONENT" = cart
        case "$1" in *"You are building the \\`cart\\` component"*) ;; *) exit 9 ;; esac
        mkdir -p src/cart
        echo 'public struct Cart { let store: Store }' > src/cart/Cart.swift
        git add src/cart/Cart.swift
        git -c user.name=agent -c user.email=agent@localhost commit -q \\
          -m 'Add the cart' -m 'Assumed: a cart holds one store.' -m 'G8r-Component: cart'
        """)
        let builds = coordinator(agent: agent)
        let launch = try builds.build("cart", in: try shop.map())
        XCTAssertTrue(launch.idleOnExit)
        XCTAssertEqual(builds.state(of: "cart"), .working)
        XCTAssertEqual(BuildNotes.openSessions(planRoot: shop.repo), [:], "events go through record")

        XCTAssertEqual(try host.runAgent(), 0)

        XCTAssertNil(builds.state(of: "cart"), "the session is over")
        XCTAssertEqual(kinds(), ["build_started", "build_checked", "build_merged"])
        XCTAssertEqual(events[1]["passed"], .bool(true))
        XCTAssertEqual(events[1]["round"], .number(1))
        XCTAssertEqual(host.closed, ["build-cart"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.worktree), "worktree removed")

        let log = try shop.git("log", "--format=%B", Integrator.branch)
        XCTAssertTrue(log.contains("G8r-Component: cart"), log)
        XCTAssertTrue(log.contains("Merge cart: Cart"), log)
        let merged = try shop.git("rev-parse", Integrator.branch)
        XCTAssertEqual(events[2]["commit"]?.stringValue, merged)
        XCTAssertEqual(try shop.git("rev-parse", "--verify", "--quiet", "refs/heads/g8r/cart").isEmpty, false,
                       "the branch is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shop.repo + "/src/cart/Cart.swift"),
                       "the user's checkout is never merged into")

        // Measured on the integration worktree, cart is built and carries its note.
        let after = try shop.map(codeRoot: Integrator(repoRoot: shop.repo).worktree)
        XCTAssertEqual(after.node("cart")?.status, .built)
        XCTAssertEqual(after.node("cart")?.notes, ["Assumed: a cart holds one store."])
        XCTAssertNil(after.node("cart")?.building)
    }

    func testAScriptAgentThatLeavesWorkUncommittedNeedsAPerson() throws {
        let agent = try shop.script("agent.sh", "mkdir -p src/cart && echo x > src/cart/Cart.swift\n")
        let builds = coordinator(agent: agent)
        let launch = try builds.build("cart", in: try shop.map())
        try host.runAgent()

        XCTAssertEqual(kinds(), ["build_started", "build_checked", "build_needs_human"])
        XCTAssertEqual(events[1]["passed"], .bool(false))
        XCTAssertTrue(events[1]["tail"]?.stringValue?.contains("Uncommitted") == true)
        XCTAssertTrue(host.told.isEmpty, "nothing is typed into a shell")
        XCTAssertTrue(host.closed.isEmpty, "left open for a person")
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.worktree))
    }

    // MARK: - Failed rounds

    /// A runner whose build always fails, and whose git status is clean.
    private func failingBuild(_ calls: @escaping (String) -> Void) -> (String) -> CommandRunner {
        { _ in
            { executable, arguments, _ in
                calls(([executable] + arguments).joined(separator: " "))
                return executable == "git" ? (0, "") : (1, "error: Cart.swift:3: expected '}'")
            }
        }
    }

    func testFailedChecksAreTypedIntoTheSessionUntilTheThirdRound() throws {
        try shop.write("g8r.json", #"{"build_command": "make"}"#)
        var calls: [String] = []
        let builds = coordinator(agent: "claude", runner: failingBuild { calls.append($0) })
        let launch = try builds.build("cart", in: try shop.map())
        let stop = FakeBuildHost.stop(launch)

        builds.handle(stop)
        XCTAssertEqual(host.told.count, 1)
        XCTAssertEqual(host.told.first?.pane, "build-cart")
        XCTAssertTrue(host.told.first?.text.contains("expected '}'") == true)
        XCTAssertEqual(builds.state(of: "cart"), .working)
        XCTAssertTrue(calls.contains("/bin/sh -c make"), "\(calls)")

        builds.handle(stop)
        XCTAssertEqual(host.told.count, 2)
        builds.handle(stop)
        XCTAssertEqual(host.told.count, 2, "the third failure isn't typed")
        guard case .needsHuman? = builds.state(of: "cart") else { return XCTFail("\(String(describing: builds.state(of: "cart")))") }
        XCTAssertEqual(kinds().filter { $0 == "build_checked" }.count, 3)
        XCTAssertEqual(events.last?.kind, "build_needs_human")
        XCTAssertEqual(events.filter { $0.kind == "build_checked" }.map { $0["round"] },
                       [.number(1), .number(2), .number(3)])

        builds.handle(stop)
        XCTAssertEqual(kinds().filter { $0 == "build_checked" }.count, 3, "no fourth round")
        XCTAssertTrue(host.closed.isEmpty)
    }

    func testStopsFromOtherPanesAreIgnored() throws {
        let builds = coordinator(agent: "claude", runner: failingBuild { _ in XCTFail("no checks") })
        try builds.build("cart", in: try shop.map())
        builds.handle(G8rEvent(kind: "stop", extra: ["pane": .string("delegate-cart")]))
        builds.handle(G8rEvent(kind: "edit", extra: ["pane": .string("build-cart")]))
        XCTAssertEqual(builds.state(of: "cart"), .working)
    }

    func testClosingThePaneEndsTheSession() throws {
        let builds = coordinator(agent: "claude")
        try builds.build("cart", in: try shop.map())
        XCTAssertEqual(builds.openPanes, ["build-cart"])
        builds.handle(G8rEvent(kind: "pane_closed", extra: ["pane": .string("build-cart")]))
        XCTAssertNil(builds.state(of: "cart"))
        XCTAssertNoThrow(try builds.build("cart", in: try shop.map()), "a closed session can be built again")
    }

    func testAMergeConflictNeedsAPerson() throws {
        try shop.write("g8r.json", #"{}"#)
        let builds = coordinator(agent: "claude")
        let launch = try builds.build("cart", in: try shop.map())
        // The session and integration both change the same line.
        try shop.write("src/store/Store.swift", "public struct Store {}\n", in: launch.worktree)
        try shop.git("commit", "-qam", "cart's store", in: launch.worktree)
        let integration = try Integrator(repoRoot: shop.repo).ensureWorktree()
        try shop.write("src/store/Store.swift", "public struct Store { let x: Int }\n", in: integration)
        try shop.git("commit", "-qam", "someone else's store", in: integration)

        builds.handle(FakeBuildHost.stop(launch))
        guard case let .needsHuman(reason)? = builds.state(of: "cart") else { return XCTFail() }
        XCTAssertTrue(reason.contains("src/store/Store.swift"), reason)
        XCTAssertEqual(kinds(), ["build_started", "build_checked", "build_needs_human"])
        XCTAssertTrue(host.closed.isEmpty)
    }

    // MARK: - Commands

    func testCommandsForClaudeAndForAnythingElse() {
        let claude = BuildLaunch.command(agent: "claude", pane: "build-x", prompt: "It's here")
        XCTAssertEqual(claude.command, #"claude --name 'build-x' 'It'\''s here'"#)
        XCTAssertFalse(claude.idleOnExit)
        let path = BuildLaunch.command(agent: "/usr/local/bin/claude --model opus", pane: "build-x", prompt: "p")
        XCTAssertEqual(path.command, "/usr/local/bin/claude --model opus --name 'build-x' 'p'")
        let script = BuildLaunch.command(agent: "./agent.sh", pane: "build-x", prompt: "p")
        XCTAssertEqual(script.command, "./agent.sh 'p'; exit")
        XCTAssertTrue(script.idleOnExit)
    }

    // MARK: - Codex

    /// The same loop with Codex: a stand-in `codex` writes the file,
    /// commits it with the trailer, runs the notify command it was given
    /// with a turn-complete payload, and exits. The stand-in `g8r-hook`
    /// writes down what it was run with; that goes through HookProcessor
    /// as g8r-hook would send it, and the stop it makes merges the build.
    func testAStandInCodexEndsMergedThroughItsNotify() throws {
        try shop.write("g8r.json", """
        {"agent": "codex", "build_command": "true", "test_command": "test -f src/cart/Cart.swift"}
        """)
        let notified = shop.sandbox.appendingPathComponent("notified").path
        let hook = try shop.script("g8r-hook", """
        printf '%s\\t%s\\t%s\\t%s\\n' "$G8R_PANE_ID" "$G8R_COMPONENT" "$1" "$2" >> '\(notified)'
        """)
        try FileManager.default.createDirectory(at: shop.sandbox.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        let codex = try shop.script("bin/codex", """
        test "$1" = -c
        case "$3" in *"You are building the \\`cart\\` component"*) ;; *) exit 9 ;; esac
        notify=$(printf '%s' "$2" | sed -E 's/^notify=\\["([^"]*)", "([^"]*)"\\]$/\\1 \\2/')
        mkdir -p src/cart
        echo 'public struct Cart { let store: Store }' > src/cart/Cart.swift
        git add src/cart/Cart.swift
        git -c user.name=agent -c user.email=agent@localhost commit -q \\
          -m 'Add the cart' -m 'Assumed: a cart holds one store.' -m 'G8r-Component: cart'
        $notify '{"type":"agent-turn-complete","thread-id":"t-1","turn-id":"1","cwd":"'"$PWD"'","input-messages":["build"],"last-assistant-message":"Done."}'
        """)
        XCTAssertEqual(G8rConfig.load(repoRoot: shop.repo).agent, .codex)

        let builds = codexCoordinator(agent: codex, hookBinary: hook)
        let launch = try builds.build("cart", in: try shop.map())
        XCTAssertFalse(launch.idleOnExit, "Codex says it went idle through notify")
        XCTAssertTrue(launch.command.hasPrefix("\(codex) -c 'notify=[\"\(hook)\", \"codex-notify\"]' 'You are building"),
                      launch.command)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.worktree + "/.claude"),
                       "nothing of Claude Code's in a Codex worktree")

        XCTAssertEqual(try host.runAgent(), 0)
        XCTAssertEqual(builds.state(of: "cart"), .working, "exiting alone isn't idle for Codex")

        // What g8r-hook does with what it was run with.
        let lines = try String(contentsOfFile: notified, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(Array(fields.prefix(3)), ["build-cart", "cart", "codex-notify"])
            let env = HookProcessor.Environment(paneId: fields[0], component: fields[1])
            let stops = try XCTUnwrap(HookProcessor.process(arguments: [fields[2], fields[3]],
                                                            stdin: { Data() }, env: env))
            XCTAssertEqual(stops.map(\.kind), ["stop"])
            stops.forEach(builds.handle)
        }

        XCTAssertNil(builds.state(of: "cart"), "the session is over")
        XCTAssertEqual(kinds(), ["build_started", "build_checked", "build_merged"])
        XCTAssertEqual(host.closed, ["build-cart"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.worktree), "worktree removed")
        let log = try shop.git("log", "--format=%B", Integrator.branch)
        XCTAssertTrue(log.contains("G8r-Component: cart"), log)
    }
}
