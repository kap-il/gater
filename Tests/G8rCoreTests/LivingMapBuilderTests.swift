import XCTest
@testable import G8rCore

/// Reads the Swift-ish fixtures below well enough for the map: a line that
/// starts with `struct`, `class`, `enum` or `func` declares a top-level
/// name, and every other word is a use.
private struct StubScanner: SymbolScanning {
    func scan(source: String, path: String) -> FileScan? {
        guard path.hasSuffix(".swift") else { return nil }
        var declarations: [Declaration] = []
        var uses: [String: Int] = [:]
        let word = try! NSRegularExpression(pattern: #"[A-Za-z_]\w*"#)
        for line in source.split(separator: "\n").map(String.init) {
            let words = word.matches(in: line, range: NSRange(line.startIndex..., in: line))
                .map { String(line[Range($0.range, in: line)!]) }
            var rest = words[...]
            if let first = words.first, ["struct", "class", "enum", "func"].contains(first), words.count > 1 {
                declarations.append(Declaration(name: words[1], kind: first, exported: true, topLevel: true,
                                                signature: line))
                rest = words.dropFirst(2)
            }
            for name in rest { uses[name, default: 0] += 1 }
        }
        return FileScan(declarations: declarations, uses: uses)
    }
}

final class LivingMapBuilderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-map-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func git(_ arguments: String...) throws {
        let result = try GitWorktree.git(["-c", "user.name=t", "-c", "user.email=t@t"] + arguments, in: root.path)
        XCTAssertEqual(result.status, 0, result.output)
    }

    private func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func build(stages: [MapStage] = []) throws -> LivingMap {
        try LivingMapBuilder.build(planRoot: root.path, codeRoot: root.path, scanner: StubScanner(),
                                   stages: stages, extractor: nil)
    }

    /// A shop whose plan names three components, with code for each, code
    /// no plan mentions, tests, and files the map must leave out.
    private func writeShop(commit: Bool = true) throws {
        try write("PLAN.md", """
        # Shop

        ## core: Core

        Runs the shop.

        - Code: `src/`, `Tests/Named/`

        ## auth: Auth

        Checks people.

        - Code: `src/auth/`

        ## tokens: Tokens

        Makes tokens.

        - Code: `src/auth/Tok*.swift`
        """)
        try write("g8r.json", #"{"ignore": ["Vendor/**"]}"#)
        try write(".gitignore", "build/\n")

        try write("src/App.swift", """
        struct Ledger {}
        struct Id {}
        func run() {
            Session()
            Session()
            Password()
            Password()
            Password()
            Ledger()
        }
        """)
        try write("src/auth/Login.swift", """
        struct Ledger {}
        struct Session {}
        struct Password {}
        func check() {
            Session()
            Ledger()
            Id()
            Token()
        }
        """)
        try write("src/auth/Token.swift", """
        struct Token {}
        func mint() {
            Session()
        }
        """)
        try write("src/auth/README.md", "Notes on auth.\n")
        try write("tools/gen.swift", "func gen() {\n    Token()\n}\n")
        try write("tools/fmt.swift", "func fmt() {}\n")
        try write("root.swift", "func top() {}\n")
        try write("notes.txt", "Not code, and no plan names it.\n")
        try write("Vendor/lib/Lib.swift", "struct Vendored {}\n")
        try write("build/Out.swift", "struct Built {}\n")

        // Rule 1 beats rule 3: core's `Code:` names it, though it uses auth.
        try write("Tests/Named/ShopTests.swift", """
        func testOne() {
            Session()
            Session()
            Password()
        }
        """)
        // Rule 1 beats rule 2: auth's `src/auth/` names it, though it is
        // named after tokens' `Token.swift`.
        try write("src/auth/Token.spec.ts", """
        it("mints", () => {})
        test("expires", () => {})
        """)
        // Rule 2 by a file's stem beats rule 3.
        try write("Tests/LoginTests.swift", """
        func testLogin() {
            Token()
            Token()
        }
        func testLogout() {}
        func helper() {}
        """)
        // Rule 2 by a top-level name beats rule 3.
        try write("Tests/PasswordTests.swift", "func testPassword() {\n    Token()\n    Token()\n}\n")
        // Two components declare `Ledger`, so rule 3 decides.
        try write("Tests/LedgerTests.swift", "func testLedger() {\n    Token()\n    Ledger()\n}\n")
        // Nothing to go on: left off the map.
        try write("Tests/OrphanTests.swift", "func testNothing() {}\n")

        if commit {
            try git("add", "-A")
            try git("commit", "-qm", "shop")
        }
        // Untracked but not ignored: git would track it, so the map has it.
        try write("src/auth/Pending.swift", "struct Pending {}\n")
    }

    // MARK: - Files

    func testLongestCodeMatchWinsAndGlobsMatch() throws {
        try writeShop()
        let map = try build()

        XCTAssertEqual(map.node("core")?.files.map(\.path), ["src/App.swift"])
        XCTAssertEqual(map.node("auth")?.files.map(\.path),
                       ["src/auth/Login.swift", "src/auth/Pending.swift", "src/auth/README.md"])
        XCTAssertEqual(map.node("tokens")?.files.map(\.path), ["src/auth/Token.swift"])

        XCTAssertEqual(map.node("auth")?.files.first?.loc, 9)
        XCTAssertEqual(map.node("auth")?.files.last?.loc, 0, "a file that isn't code has no lines")
        XCTAssertEqual(map.node("auth")?.loc, 10)
        XCTAssertEqual(map.node("tokens")?.files.first?.symbols,
                       [MapSymbol(kind: "struct", name: "Token"), MapSymbol(kind: "func", name: "mint")])
        XCTAssertEqual(map.node("auth")?.status, .built)
        XCTAssertEqual(map.head?.count, 7)
        XCTAssertEqual(map.repo, root.lastPathComponent)
    }

    func testIgnoredPathsAreAbsentAndLeftoverCodeIsGroupedByDirectory() throws {
        try writeShop()
        let map = try build()
        let everywhere = map.nodes.flatMap { $0.files.map(\.path) + ($0.tests?.files ?? []) }

        for absent in ["Vendor/lib/Lib.swift", "build/Out.swift", "notes.txt", "Tests/OrphanTests.swift"] {
            XCTAssertFalse(everywhere.contains(absent), absent)
        }
        XCTAssertEqual(everywhere.count, Set(everywhere).count, "a file is in one node at most")

        XCTAssertEqual(map.nodes.map(\.id), ["core", "auth", "tokens", "unplanned:.", "unplanned:tools"])
        let tools = try XCTUnwrap(map.node("unplanned:tools"))
        XCTAssertEqual(tools.status, .unplanned)
        XCTAssertEqual(tools.name, "fmt, gen")
        XCTAssertEqual(tools.files.map(\.path), ["tools/fmt.swift", "tools/gen.swift"])
        XCTAssertNil(tools.doc)
        XCTAssertEqual(map.node("unplanned:.")?.files.map(\.path), ["root.swift"])
    }

    // MARK: - Edges

    func testEdgesCountNamesOnlyOneComponentDeclares() throws {
        try writeShop()
        let edges = try build().edges

        // `Ledger` is declared by core and auth, `Id` is too short, and auth's
        // own uses of `Session` make no edge.
        XCTAssertEqual(edges, [
            MapEdge(from: "auth", to: "tokens", declared: false, measured: true, symbols: ["Token"], refs: 1),
            MapEdge(from: "core", to: "auth", declared: false, measured: true,
                    symbols: ["Password", "Session"], refs: 5),
            MapEdge(from: "tokens", to: "auth", declared: false, measured: true, symbols: ["Session"], refs: 1),
            MapEdge(from: "unplanned:tools", to: "tokens", declared: false, measured: true,
                    symbols: ["Token"], refs: 1),
        ])
    }

    func testDeclaredEdgesComeFromNeedsThatNameAComponent() throws {
        try write("PLAN.md", """
        ## a: A

        Uses b.

        - Needs: b, ghost, a
        - Code: `a/`

        ## b: B

        Is used.

        - Code: `b/`
        """)
        try write("a/A.swift", "func alpha() {\n    Beta()\n}\n")
        try write("b/B.swift", "struct Beta {}\n")
        let map = try build()

        XCTAssertEqual(map.edges, [
            MapEdge(from: "a", to: "b", declared: true, measured: true, symbols: ["Beta"], refs: 1),
        ])
        XCTAssertEqual(map.problems, ["a needs an unknown component: ghost", "a needs itself"])
    }

    // MARK: - Tests

    func testTestAttributionFollowsTheThreeRulesInOrder() throws {
        try writeShop()
        let map = try build()

        XCTAssertEqual(map.node("core")?.tests, NodeTests(files: ["Tests/Named/ShopTests.swift"], count: 1))
        XCTAssertEqual(map.node("auth")?.tests,
                       NodeTests(files: ["Tests/LoginTests.swift", "Tests/PasswordTests.swift",
                                         "src/auth/Token.spec.ts"], count: 5))
        XCTAssertEqual(map.node("tokens")?.tests, NodeTests(files: ["Tests/LedgerTests.swift"], count: 1))
        XCTAssertNil(map.node("unplanned:tools")?.tests)
        XCTAssertFalse(map.nodes.contains { $0.id.hasPrefix("unplanned:Tests") }, "test files are never code of their own")
    }

    func testRecognisesTestFilesAndCountsTheirFunctions() {
        for path in ["Tests/X/A.swift", "tests/a.py", "web/__tests__/a.js", "Sources/ATests.swift",
                     "a.test.ts", "a.spec.tsx", "a_test.go", "test_a.py"] {
            XCTAssertTrue(CodeFiles.isTest(path), path)
        }
        for path in ["Sources/Test.swift", "latest.ts", "contest_a.py", "Tests/README.md", "a_test.txt"] {
            XCTAssertFalse(CodeFiles.isTest(path), path)
        }
        XCTAssertEqual(["GlobTests.swift", "glob.test.ts", "glob.spec.js", "glob_test.go", "test_glob.py"]
            .map(CodeFiles.testSubject), ["Glob", "glob", "glob", "glob", "glob"])

        XCTAssertEqual(CodeFiles.testCount(source: """
        func testA() {}
        func test_b() throws {}
        @Test func works() {}
        @Test("named") func testNamed() {}
        func helper() {}
        """, path: "T.swift"), 4)
        XCTAssertEqual(CodeFiles.testCount(source: "def test_a():\n  pass\ndef helper():\n  pass\n", path: "test_a.py"), 1)
        XCTAssertEqual(CodeFiles.testCount(source: "describe('x', () => { it('a'); it.skip('b'); x.test('c') })",
                                           path: "a.test.js"), 2)
    }

    // MARK: - Build order

    func testWavesBlockedByAndBlastForAPlanThreeLevelsDeep() throws {
        try write("PLAN.md", """
        ## Built

        ### base: Base

        The ground.

        - Code: `base/`

        ### user: User

        Uses the ground.

        - Needs: base
        - Code: `user/`

        ## To build

        ### one: One

        Changes the ground.

        - Needs: base
        - Changes: base, ghost

        ### two: Two

        Builds on one.

        - Needs: one

        ### three: Three

        Builds on two.

        - Needs: two, base, ghost

        ### four: Four

        Builds on one and three.

        - Needs: one, three
        """)
        try write("base/Base.swift", "struct Ground {}\n")
        try write("user/User.swift", "func stand() {\n    Ground()\n}\n")
        let map = try build()

        let planned = ["one", "two", "three", "four"]
        XCTAssertEqual(planned.map { map.node($0)?.status }, Array(repeating: .planned, count: 4))
        XCTAssertEqual(planned.map { map.node($0)?.wave }, [1, 2, 3, 4])
        XCTAssertEqual(planned.map { map.node($0)?.blockedBy }, [[], ["one"], ["two"], ["one", "three"]])
        XCTAssertEqual(planned.map { map.node($0)?.blast }, [["user"], [], [], []])

        for built in ["base", "user"] {
            let node = try XCTUnwrap(map.node(built))
            XCTAssertEqual(node.status, .built)
            XCTAssertNil(node.wave)
            XCTAssertNil(node.blockedBy)
            XCTAssertNil(node.blast)
        }
    }

    func testACycleEndsWithNoWaveForItsMembers() throws {
        try write("PLAN.md", """
        ## x: X

        Needs y.

        - Needs: y

        ## y: Y

        Needs x.

        - Needs: x

        ## z: Z

        Needs the cycle.

        - Needs: x

        ## free: Free

        Needs nothing.
        """)
        let map = try build()

        XCTAssertNil(map.node("x")?.wave)
        XCTAssertNil(map.node("y")?.wave)
        XCTAssertNil(map.node("z")?.wave)
        XCTAssertEqual(map.node("x")?.blockedBy, ["y"])
        XCTAssertEqual(map.node("free")?.wave, 1)
        XCTAssertTrue(map.problems.contains { $0.contains("need each other") })
    }

    // MARK: - The map as a whole

    func testStagesRunInOrderOnWhatCodemapMeasured() throws {
        struct Note: MapStage {
            var text: String
            func apply(to map: inout LivingMap, context: MapContext) throws {
                map.problems.append("\(text): \(context.files.joined(separator: ", ")) \(context.scans.keys.sorted())")
            }
        }
        try write("PLAN.md", "## a: A\n\nIs here.\n\n- Code: `a/`\n")
        try write("a/A.swift", "struct Alpha {}\n")
        try write("a/notes.md", "About a.\n")
        let map = try build(stages: [Note(text: "first"), Note(text: "second")])

        XCTAssertEqual(map.problems, ["first: a/A.swift, a/notes.md [\"a/A.swift\"]",
                                      "second: a/A.swift, a/notes.md [\"a/A.swift\"]"])
    }

    func testJSONLeavesOutWhatIsAbsent() throws {
        try write("PLAN.md", "## a: A\n\nIs here.\n\n- Code: `a/`\n\n## b: B\n\nIsn't yet.\n\n- Needs: a\n")
        try write("a/A.swift", "struct Alpha {}\n")
        let map = try build()
        let data = try JSONEncoder().encode(map)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(json.keys), ["repo", "generated", "docs", "nodes", "edges", "retired", "timeline", "problems"])
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        XCTAssertEqual(Set(nodes[0].keys), ["id", "name", "summary", "status", "doc", "needs", "changes",
                                            "paths", "loc", "files", "section"])
        XCTAssertEqual(nodes[1]["wave"] as? Int, 1)
        XCTAssertEqual(nodes[1]["blockedBy"] as? [String], [])
        let edge = try XCTUnwrap((json["edges"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(edge.keys), ["from", "to", "declared", "measured", "symbols", "refs"])
        XCTAssertEqual(try JSONDecoder().decode(LivingMap.self, from: data), map)
    }

    // MARK: - A folder that isn't a repository

    func testAFolderThatIsNotARepositoryIsWalked() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        try write("PLAN.md", "# Plan\n\n## core: Core\n\nRuns.\n\n- Code: `src/`\n")
        try write("g8r.json", #"{"ignore": ["gen/**", "*.log"]}"#)
        for path in ["src/A.swift", "src/nested/B.swift", "src/notes.txt", "Tests/ATests.swift",
                     "vendors/C.swift", "web/app.ts",
                     // Hidden entries, skipped folders at any depth, and ignored globs.
                     ".hidden.swift", ".tools/D.swift", "src/.cache/E.swift", ".git/HEAD",
                     ".build/debug/F.swift", "web/node_modules/pkg/index.js", "dist/out.js",
                     "src/build/G.swift", ".next/page.js", "target/debug/H.rs", "vendor/I.go",
                     "gen/J.swift", "run.log"] {
            try write(path, "struct X {}\n")
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked.swift").path,
                                                   withDestinationPath: root.appendingPathComponent("src/A.swift").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("src-link").path,
                                                   withDestinationPath: root.appendingPathComponent("src").path)

        XCTAssertEqual(try LivingMapBuilder.trackedFiles(in: root.path, ignoring: ["gen/**", "*.log"]), [
            "PLAN.md", "Tests/ATests.swift", "g8r.json", "linked.swift", "src/A.swift", "src/nested/B.swift",
            "src/notes.txt", "vendors/C.swift", "web/app.ts",
        ])
    }

    func testAMapIsBuiltOnAFolderThatIsNotARepository() throws {
        try writeShop()
        let tracked = try build(stages: [Drift(), Timeline(), BuildNotes(), Evidence()])
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeShop(commit: false)
        XCTAssertFalse(GitWorktree.isRepository(root.path))

        let map = try build(stages: [Drift(), Timeline(), BuildNotes(), Evidence()])
        XCTAssertNil(map.head)
        XCTAssertEqual(map.timeline, [], "no history to replay")
        XCTAssertEqual(map.nodes.map { $0.git?.commits }, Array(repeating: 0, count: map.nodes.count))
        // The same files, owners and test attribution as the repository.
        XCTAssertEqual(map.nodes.map(\.id), tracked.nodes.map(\.id))
        XCTAssertEqual(map.nodes.map(\.files), tracked.nodes.map(\.files))
        XCTAssertEqual(map.nodes.map(\.tests), tracked.nodes.map(\.tests))
        XCTAssertEqual(map.node("tokens")?.tests, NodeTests(files: ["Tests/LedgerTests.swift"], count: 1))
        XCTAssertEqual(map.edges, tracked.edges)
        XCTAssertEqual(map.docs, tracked.docs)
        XCTAssertEqual(map.nodes.map(\.status), tracked.nodes.map(\.status))
    }

    func testTheIdleNoteSaysWhenThereIsNoRepository() throws {
        XCTAssertNil(MapViewer.idleNote(planRoot: root.path))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        XCTAssertEqual(MapViewer.idleNote(planRoot: root.path),
                       "Not a git repository: history and builds are off until `git init`.")
    }
}
