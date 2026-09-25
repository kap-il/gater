import XCTest
import GaterCore
@testable import GaterSymbols

/// Spec Phase 6 acceptance: references for a changed symbol are queried in
/// another worktree and return correct sites. Needs TypeScript 7's native
/// compiler (~/.gater/tools, or GATER_TSC); skipped without it.
final class ReferenceEngineTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUpWithError() throws {
        try XCTSkipIf(TypeScriptServer.locateCompiler(worktree: "/nonexistent") == nil,
                      "TypeScript 7 not installed (cd ~/.gater/tools && bun add typescript@^7)")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gater-refs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        repo = sandbox.appendingPathComponent("app").path
        try FileManager.default.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
        try write("tsconfig.json", #"{ "compilerOptions": { "strict": true, "jsx": "react-jsx" }, "include": ["src"] }"#, in: repo)
        try write("src/users.ts", """
        export interface User { id: string; name: string }

        export function getUser(id: string): User {
          return { id, name: "Ada" }
        }
        """, in: repo)
        for args in [["init", "-q", "-b", "main"], ["add", "."],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"]] {
            XCTAssertEqual(try GitWorktree.git(args, in: repo).status, 0)
        }
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func write(_ rel: String, _ text: String, in root: String) throws {
        let path = (root as NSString).appendingPathComponent(rel)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The golden scenario: A changes getUser's signature in its worktree;
    /// B's worktree calls getUser. Querying B's server finds B's call site.
    func testFindsCallersInTheOtherDelegatesWorktree() throws {
        let auth = try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
        let dash = try GitWorktree.ensure(delegate: "dash", repoRoot: repo)
        try write("src/users.ts", """
        export interface User { id: string; name: string }

        export function getUser(id: string, opts: { includeSession?: boolean }): User {
          return { id, name: "Ada" }
        }
        """, in: auth)
        try write("src/dashboard/UserCard.tsx", """
        import { getUser } from "../users"

        export function UserCard({ id }: { id: string }) {
          const user = getUser(id)
          return <div>{user.name}</div>
        }
        """, in: dash)

        let engine = ReferenceEngine()
        defer { engine.stopAll() }

        let inDash = try XCTUnwrap(engine.references(to: "src/users.ts#getUser", in: dash))
        // TypeScript 7 reports uses, not the import binding (a separate
        // alias) — the call is what a signature change breaks.
        XCTAssertEqual(inDash.map(\.description), ["src/dashboard/UserCard.tsx:4"])
        XCTAssertEqual(try engine.references(to: "src/users.ts#getUser", in: auth), [], "auth has no callers")
        XCTAssertEqual(engine.runningWorktrees.count, 2, "one server per worktree")

        // B keeps editing: after a change notification the server sees it.
        try write("src/dashboard/UserCard.tsx", """
        import { getUser } from "../users"

        export function UserCard({ id }: { id: string }) {
          const user = getUser(id)
          const again = getUser(id)
          return <div>{user.name}{again.id}</div>
        }
        """, in: dash)
        engine.filesChanged(in: dash, relativePaths: ["src/dashboard/UserCard.tsx"])
        XCTAssertEqual(try engine.references(to: "src/users.ts#getUser", in: dash)?.map(\.line), [4, 5])
    }

    func testMissingSymbolOrFile() throws {
        let engine = ReferenceEngine()
        defer { engine.stopAll() }
        XCTAssertNil(try engine.references(to: "src/users.ts#nope", in: repo))
        XCTAssertNil(try engine.references(to: "src/missing.ts#x", in: repo))
    }

    func testStopEndsTheServer() throws {
        let engine = ReferenceEngine()
        _ = try engine.references(to: "src/users.ts#getUser", in: repo)
        XCTAssertEqual(engine.runningWorktrees, [repo])
        engine.stop(worktree: repo)
        XCTAssertEqual(engine.runningWorktrees, [])
    }

    func testNoCompilerMeansNoAnswer() throws {
        let engine = ReferenceEngine(locateCompiler: { _ in nil })
        XCTAssertNil(try engine.references(to: "src/users.ts#getUser", in: repo))
    }
}
