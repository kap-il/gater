import Foundation

/// A place code refers to a symbol. Path is relative to the worktree.
public struct ReferenceSite: Codable, Equatable, Hashable {
    public var path: String
    /// 1-based.
    public var line: Int
    /// 1-based, UTF-16 units (what LSP counts).
    public var column: Int

    public init(path: String, line: Int, column: Int) {
        self.path = path
        self.line = line
        self.column = column
    }

    public var description: String { "\(path):\(line)" }
}

/// One TypeScript language server for one worktree (spec §4.8: one server
/// per active worktree).
///
/// Runs TypeScript 7's native compiler in LSP mode (`tsc --lsp --stdio`):
/// a single binary, no node or bun runtime and no typescript-language-
/// server wrapper. Idle servers block on stdin and use no CPU.
public final class TypeScriptServer {
    public let worktree: String
    private let client: LSPClient
    /// Paths already reported to the server. The first report of a path
    /// says "created": the server ignores "changed" for files it doesn't
    /// know, so an agent's brand-new file would stay invisible (seen live).
    private var reportedPaths: Set<String> = []

    public init(worktree: String, tsc: String) throws {
        self.worktree = worktree
        client = try LSPClient(executable: tsc, arguments: ["--lsp", "--stdio"], workingDirectory: worktree)
        let root = JSONValue.string(Self.uri(for: worktree))
        _ = try client.request("initialize", .object([
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": root,
            "workspaceFolders": .array([.object(["uri": root, "name": .string((worktree as NSString).lastPathComponent)])]),
            "capabilities": .object([
                "workspace": .object(["didChangeWatchedFiles": .object(["dynamicRegistration": .bool(false)])]),
            ]),
        ]), timeout: 30)
        try client.notify("initialized", .object([:]))
    }

    deinit { client.shutdown() }

    public var isRunning: Bool { client.isRunning }

    public func stop() { client.shutdown() }

    /// The TypeScript 7 native binary to use for `worktree`: GATER_TSC if
    /// set, else the project's own TypeScript 7, else Gater's copy in
    /// ~/.gater/tools (installed with bun, kept out of the home folder).
    public static func locateCompiler(worktree: String,
                                      environment: [String: String] = ProcessInfo.processInfo.environment,
                                      home: String = NSHomeDirectory()) -> String? {
        if let explicit = environment["GATER_TSC"], FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        #if os(macOS)
        let platform = "darwin-\(arch)"
        #else
        let platform = "linux-\(arch)"
        #endif
        let relative = "node_modules/@typescript/typescript-\(platform)/lib/tsc"
        for base in [worktree, (home as NSString).appendingPathComponent(".gater/tools")] {
            let candidate = (base as NSString).appendingPathComponent(relative)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Tells the server files changed on disk (agents edit files directly),
    /// so its program doesn't answer from stale contents.
    public func filesChanged(_ relativePaths: [String]) {
        guard !relativePaths.isEmpty else { return }
        var changes: [JSONValue] = []
        for path in relativePaths {
            let absolute = (worktree as NSString).appendingPathComponent(path)
            let uri = JSONValue.string(Self.uri(for: absolute))
            func change(_ type: Int) -> JSONValue { .object(["uri": uri, "type": .number(Double(type))]) }
            if !FileManager.default.fileExists(atPath: absolute) {
                reportedPaths.remove(path)
                changes.append(change(3)) // deleted
            } else if reportedPaths.insert(path).inserted {
                // First report: we can't tell a brand-new file (needs
                // "created") from one the server loaded at startup (needs
                // "changed" to refresh), so send both — changed first, as
                // "created" after it for a known file is a no-op, while the
                // reverse order loses the refresh (verified by tests).
                changes.append(change(2))
                changes.append(change(1))
            } else {
                changes.append(change(2))
            }
        }
        try? client.notify("workspace/didChangeWatchedFiles", .object(["changes": .array(changes)]))
    }

    /// References to whatever is at `path`:`line`:`column` (1-based line,
    /// 0-based UTF-16 column), excluding the declaration itself.
    public func references(path: String, line: Int, column: Int) throws -> [ReferenceSite] {
        let absolute = (worktree as NSString).appendingPathComponent(path)
        let uri = Self.uri(for: absolute)
        let text = (try? String(contentsOfFile: absolute, encoding: .utf8)) ?? ""
        let languageId = path.hasSuffix(".tsx") || path.hasSuffix(".jsx") ? "typescriptreact" : "typescript"

        // Open from disk for the query and close after: the server's view
        // of this file is always the current one.
        try client.notify("textDocument/didOpen", .object(["textDocument": .object([
            "uri": .string(uri), "languageId": .string(languageId), "version": .number(1), "text": .string(text),
        ])]))
        defer { try? client.notify("textDocument/didClose", .object(["textDocument": .object(["uri": .string(uri)])])) }

        let result = try client.request("textDocument/references", .object([
            "textDocument": .object(["uri": .string(uri)]),
            "position": .object(["line": .number(Double(line - 1)), "character": .number(Double(column))]),
            "context": .object(["includeDeclaration": .bool(false)]),
        ]))

        let rootPrefix = Self.canonical(worktree) + "/"
        var sites: [ReferenceSite] = []
        for location in result.arrayValue ?? [] {
            guard let target = location.value(atPath: "uri")?.stringValue.flatMap(Self.path(fromURI:)),
                  case let .number(l)? = location.value(atPath: "range.start.line"),
                  case let .number(c)? = location.value(atPath: "range.start.character") else { continue }
            let canonicalTarget = Self.canonical(target)
            // References into node_modules or outside the worktree aren't
            // anyone's code in this repo.
            guard canonicalTarget.hasPrefix(rootPrefix), !canonicalTarget.contains("/node_modules/") else { continue }
            sites.append(ReferenceSite(path: String(canonicalTarget.dropFirst(rootPrefix.count)),
                                       line: Int(l) + 1, column: Int(c) + 1))
        }
        return sites.sorted { ($0.path, $0.line, $0.column) < ($1.path, $1.line, $1.column) }
    }

    static func uri(for path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    static func path(fromURI uri: String) -> String? {
        URL(string: uri)?.path
    }

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
