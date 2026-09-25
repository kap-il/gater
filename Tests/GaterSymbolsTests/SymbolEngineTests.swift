import XCTest
import GaterCore
@testable import GaterSymbols

final class SymbolEngineTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gater-symbols-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        repo = sandbox.appendingPathComponent("app").path
        try FileManager.default.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
        try write("src/users.ts", "export function getUser(id: string): User { return db.get(id) }\n", in: repo)
        for args in [["init", "-q", "-b", "main"], ["add", "."],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"]] {
            XCTAssertEqual(try GitWorktree.git(args, in: repo).status, 0)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    @discardableResult
    private func write(_ rel: String, _ text: String, in root: String) throws -> String {
        let path = (root as NSString).appendingPathComponent(rel)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func engine() -> SymbolEngine {
        SymbolEngine(snapshotDirectory: SymbolEngine.defaultSnapshotDirectory(repoRoot: repo))
    }

    /// The golden scenario's first half, end to end in a delegate worktree.
    func testFirstEditIsDiffedAgainstHEADThenAgainstSnapshot() throws {
        let worktree = try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
        let engine = engine()

        let path = try write("src/users.ts",
            "export function getUser(id: string, opts: Opts): User { return db.get(id) }\n", in: worktree)
        let first = try XCTUnwrap(engine.fileEdited(absolutePath: path))
        XCTAssertEqual(first.path, "src/users.ts")
        XCTAssertEqual(first.changes.map(\.change), [.signature], "HEAD baseline catches the very first edit")

        try write("src/users.ts",
            "export function getUser(id: string, opts: Opts): User { log(id); return db.get(id) }\n", in: worktree)
        XCTAssertEqual(engine.fileEdited(absolutePath: path)?.changes.map(\.change), [.body])

        XCTAssertEqual(engine.fileEdited(absolutePath: path)?.changes, [], "no-op edit")

        let event = try XCTUnwrap(first.event(pane: "delegate-auth"))
        XCTAssertEqual(event.kind, "symbols_changed")
        XCTAssertEqual(event["public_surface"], .bool(true))
        XCTAssertEqual(event.fields["changes"]?.arrayValue?.first?.value(atPath: "symbol")?.stringValue, "getUser")
    }

    func testNewFileSymbolsAreAdded() throws {
        let path = try write("src/new.ts", "export const a = 1\nfunction b() {}\n", in: repo)
        let changes = try XCTUnwrap(engine().fileEdited(absolutePath: path)).changes
        XCTAssertEqual(Set(changes.map(\.change)), [.added])
        XCTAssertEqual(changes.count, 2)
    }

    func testSnapshotsPersistAcrossEngines() throws {
        let path = try write("src/users.ts",
            "export function getUser(id: string): User { return db.fetch(id) }\n", in: repo)
        XCTAssertEqual(engine().fileEdited(absolutePath: path)?.changes.map(\.change), [.body])
        // A fresh engine (Gater restarted) diffs against the saved snapshot,
        // not HEAD, so it sees no change.
        XCTAssertEqual(engine().fileEdited(absolutePath: path)?.changes, [])
    }

    func testSnapshotsAreKeptPerWorktree() throws {
        let auth = try GitWorktree.ensure(delegate: "auth", repoRoot: repo)
        let dash = try GitWorktree.ensure(delegate: "dash", repoRoot: repo)
        let engine = engine()
        let changed = "export function getUser(id: string, opts: Opts): User { return db.get(id) }\n"
        XCTAssertEqual(engine.fileEdited(absolutePath: try write("src/users.ts", changed, in: auth))?.changes.count, 1)
        XCTAssertEqual(engine.fileEdited(absolutePath: try write("src/users.ts", changed, in: dash))?.changes.count, 1,
                       "dash's copy has its own baseline")
    }

    func testIgnoresUnsupportedFiles() throws {
        XCTAssertNil(engine().fileEdited(absolutePath: try write("README.md", "# hi", in: repo)))
    }
}
