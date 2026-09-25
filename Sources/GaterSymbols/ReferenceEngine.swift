import Foundation
import GaterCore

/// Cross-worktree reference queries (spec §4.8): "if A changed symbol X,
/// where does B's code use it?" Keeps one TypeScript server per worktree,
/// started on first use and stopped with the worktree's pane or dish.
///
/// Not thread-safe: call from one serial queue (the app's symbol queue).
public final class ReferenceEngine {
    private var servers: [String: TypeScriptServer] = [:]
    private let locateCompiler: (String) -> String?

    public init(locateCompiler: @escaping (String) -> String? = { TypeScriptServer.locateCompiler(worktree: $0) }) {
        self.locateCompiler = locateCompiler
    }

    public var runningWorktrees: [String] { servers.filter { $0.value.isRunning }.map(\.key).sorted() }

    public func server(for worktree: String) throws -> TypeScriptServer? {
        if let existing = servers[worktree], existing.isRunning { return existing }
        guard let tsc = locateCompiler(worktree) else { return nil }
        let server = try TypeScriptServer(worktree: worktree, tsc: tsc)
        servers[worktree] = server
        return server
    }

    /// Keeps a running server's view of the worktree fresh after edits.
    public func filesChanged(in worktree: String, relativePaths: [String]) {
        servers[worktree]?.filesChanged(relativePaths)
    }

    public func stop(worktree: String) {
        servers.removeValue(forKey: worktree)?.stop()
    }

    public func stopAll() {
        for worktree in Array(servers.keys) { stop(worktree: worktree) }
    }

    /// References to `symbolId` (`path#Qualified.name`) in `worktree`'s own
    /// copy of the code, excluding the declaration. nil when that copy has
    /// no such symbol or no TypeScript 7 compiler is available.
    public func references(to symbolId: String, in worktree: String) throws -> [ReferenceSite]? {
        guard let hash = symbolId.lastIndex(of: "#") else { return nil }
        let path = String(symbolId[..<hash])
        let absolute = (worktree as NSString).appendingPathComponent(path)
        guard let source = try? String(contentsOfFile: absolute, encoding: .utf8),
              let symbol = try SymbolExtractor.symbols(source: source, path: path).first(where: { $0.id == symbolId }),
              let server = try server(for: worktree) else { return nil }
        return try server.references(path: path, line: symbol.nameLine, column: symbol.nameColumn)
    }
}
