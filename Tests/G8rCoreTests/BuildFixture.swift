import XCTest
@testable import G8rCore

/// Reads the Swift-ish fixtures well enough for the build tests: a line
/// that starts with `public struct`, `public func` and so on declares an
/// exported name; without `public` it isn't exported.
struct BuildStubScanner: SymbolScanning {
    func scan(source: String, path: String) -> FileScan? {
        guard path.hasSuffix(".swift") else { return nil }
        var declarations: [Declaration] = []
        var uses: [String: Int] = [:]
        let word = try! NSRegularExpression(pattern: #"[A-Za-z_]\w*"#)
        for line in source.split(separator: "\n").map(String.init) {
            var words = word.matches(in: line, range: NSRange(line.startIndex..., in: line))
                .map { String(line[Range($0.range, in: line)!]) }[...]
            let exported = words.first == "public"
            if exported { words = words.dropFirst() }
            if let first = words.first, ["struct", "class", "enum", "func"].contains(first), words.count > 1 {
                let name = words[words.startIndex + 1]
                declarations.append(Declaration(name: name, kind: first, exported: exported, topLevel: true,
                                                signature: line.trimmingCharacters(in: .whitespaces)))
                words = words.dropFirst(2)
            }
            for name in words { uses[name, default: 0] += 1 }
        }
        return FileScan(declarations: declarations, uses: uses)
    }
}

/// A shop in a scratch folder: `store` is built, `cart` is planned and
/// needs it, `pay` is planned and needs `cart`, so it is blocked.
final class BuildFixture {
    let sandbox: URL
    let repo: String

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        repo = sandbox.appendingPathComponent("shop").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)

        try write("PLAN.md", """
        # Shop

        ## store: Store

        Keeps things.

        - Code: `src/store/`

        ## cart: Cart

        Holds what someone is buying.

        - Needs: store
        - Changes: store
        - Code: `src/cart/`
        - Done when: a cart can be saved to the store.

        ## pay: Pay

        Takes the money.

        - Needs: cart
        - Code: `src/pay/`
        """)
        try write("src/store/Store.swift", """
        public struct Store {
            public func save(_ key: String, value: String) -> Bool
            func secret() -> Int
        }
        """)
        try write("src/checkout/Checkout.swift", "struct Checkout { let store: Store }\n")
        try write(".gitignore", ".g8r/\n.setup-ran\n")
        try git("init", "-q", "-b", "main")
        try git("add", ".")
        try git("commit", "-qm", "init")
    }

    func remove() { try? FileManager.default.removeItem(at: sandbox) }

    func write(_ path: String, _ text: String, in root: String? = nil) throws {
        let file = URL(fileURLWithPath: root ?? repo).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ arguments: String..., in root: String? = nil) throws -> String {
        let result = try GitWorktree.git(["-c", "user.name=t", "-c", "user.email=t@t"] + arguments, in: root ?? repo)
        XCTAssertEqual(result.status, 0, result.output)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func map(codeRoot: String? = nil, stages: [MapStage] = [BuildNotes()]) throws -> LivingMap {
        try LivingMapBuilder.build(planRoot: repo, codeRoot: codeRoot ?? repo, scanner: BuildStubScanner(),
                                   stages: stages, extractor: nil)
    }

    func worktree(_ name: String) -> String {
        GitWorktree.path(forDelegate: name, repoRoot: repo)
    }

    /// An executable script in the sandbox.
    func script(_ name: String, _ body: String) throws -> String {
        let path = sandbox.appendingPathComponent(name).path
        try ("#!/bin/sh\nset -e\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}

/// Stands in for the app's panes. A build pane's agent runs when the test
/// says so, as a pane's shell would run it, and its exit is reported the
/// way the app reports a pane whose agent isn't Claude Code.
final class FakeBuildHost: BuildHost {
    var opened: [BuildLaunch] = []
    var told: [(pane: String, text: String)] = []
    var closed: [String] = []
    weak var coordinator: BuildCoordinator?

    func open(_ launch: BuildLaunch) throws { opened.append(launch) }
    func tell(_ text: String, pane: String) { told.append((pane, text)) }
    func close(pane: String) { closed.append(pane) }

    /// Runs the last launch's command in its worktree with its environment,
    /// and says the session went idle when it exits.
    @discardableResult
    func runAgent() throws -> Int32 {
        let launch = try XCTUnwrap(opened.last)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", launch.command]
        process.currentDirectoryURL = URL(fileURLWithPath: launch.worktree)
        process.environment = ProcessInfo.processInfo.environment.merging(launch.environment) { $1 }
        try process.run()
        process.waitUntilExit()
        if launch.idleOnExit { coordinator?.handle(Self.stop(launch)) }
        return process.terminationStatus
    }

    /// What g8r-hook sends when a build session stops.
    static func stop(_ launch: BuildLaunch) -> G8rEvent {
        G8rEvent(kind: "stop", extra: ["pane": .string(launch.pane), "component": .string(launch.component)])
    }
}
