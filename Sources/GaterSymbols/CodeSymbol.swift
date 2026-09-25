import Foundation

public enum SymbolKind: String, Codable, Equatable {
    case function, method, `class`, interface, type, `enum`, variable, property, module
}

/// One top-level or class-level declaration in a file (spec §4.6).
///
/// Identity is `path#qualifiedName` — ownership attaches to that, never to
/// line numbers, so it survives agents editing around it. Lines are only a
/// snapshot, recomputed on each parse.
public struct CodeSymbol: Codable, Equatable {
    /// `src/users.ts#UserService.getUser`
    public var id: String
    public var name: String
    /// Name qualified by enclosing namespaces/classes: `UserService.getUser`.
    public var qualifiedName: String
    public var kind: SymbolKind
    /// 1-based, inclusive.
    public var startLine: Int
    public var endLine: Int
    /// Where the symbol's name is: 1-based line, 0-based UTF-16 column —
    /// the position LSP queries (references, rename) need.
    public var nameLine: Int
    public var nameColumn: Int
    public var isExported: Bool
    /// Hash of the declaration minus its body: parameters, return type,
    /// type annotation, heritage, modifiers, and export status.
    public var signatureHash: String
    /// Hash of the implementation (function body, initializer, class body).
    public var bodyHash: String
}

public enum SymbolChangeKind: String, Codable, Equatable {
    case added, removed
    /// Params, return type, or export changed: public surface.
    case signature
    /// Internals only: not public surface.
    case body
}

public struct SymbolChange: Codable, Equatable {
    public var id: String
    public var symbol: String
    public var kind: SymbolKind
    public var change: SymbolChangeKind
    public var isExported: Bool

    /// Spec §4.9 trigger 2: added/removed/signature changes to exported
    /// symbols can break other agents' code; body edits can't.
    public var isPublicSurface: Bool {
        change != .body && isExported
    }
}
