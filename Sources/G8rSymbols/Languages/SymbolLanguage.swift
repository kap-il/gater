import Foundation
import SwiftTreeSitter

/// One language the symbol engine reads: everything the engine has to be
/// told that differs from one language to the next. The engine itself has
/// no language in it, so teaching it another is writing an entry and adding
/// it to `all`.
struct SymbolLanguage {
    /// File extensions this entry reads, lowercased, without the dot.
    let extensions: Set<String>
    let grammar: Language
    /// `symbols` compiled for `grammar`; nil when it doesn't compile, which
    /// leaves the language unreadable rather than half-read.
    let query: Query?
    /// Node types that are names. These are what `uses` counts.
    let identifiers: Set<String>
    /// Node types that are comments and string literals. `uses` never looks
    /// inside them, so a name mentioned in prose isn't taken for a use.
    let prose: Set<String>
    /// Node types whose contents are locals, not symbols.
    let scopes: Set<String>
    /// The name a node lends to the declarations inside it, for the nodes
    /// that qualify what they hold (types, namespaces). Nil for the rest.
    let qualifier: (_ node: Node, _ text: NSString) -> String?
    /// The rule for what counts as exported.
    let isExported: (_ node: Node, _ text: NSString) -> Bool
    /// Splits a declaration into signature text and body text, and settles
    /// its kind where that depends on more than the query can see.
    let split: (_ node: Node, _ name: Node, _ kind: inout SymbolKind, _ text: NSString) -> (signature: String, body: String)

    /// - Parameter symbols: what a symbol is, as a tree-sitter query. Each
    ///   pattern captures the declaration as `@definition.<kind>`, where
    ///   the kind is a `SymbolKind`, and its name as `@name`.
    init(extensions: Set<String>,
         grammar: Language,
         symbols: String,
         identifiers: Set<String>,
         prose: Set<String>,
         scopes: Set<String>,
         qualifier: @escaping (Node, NSString) -> String?,
         isExported: @escaping (Node, NSString) -> Bool,
         split: @escaping (Node, Node, inout SymbolKind, NSString) -> (signature: String, body: String)) {
        self.extensions = extensions
        self.grammar = grammar
        self.query = try? Query(language: grammar, data: Data(symbols.utf8))
        self.identifiers = identifiers
        self.prose = prose
        self.scopes = scopes
        self.qualifier = qualifier
        self.isExported = isExported
        self.split = split
    }

    /// The table.
    static let all: [SymbolLanguage] = [.typescript, .tsx, .javascript, .swift]

    /// The language that reads `path`, going by its extension.
    static func reading(_ path: String) -> SymbolLanguage? {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        return all.first { $0.extensions.contains(pathExtension) }
    }

    /// Parses `source`. The parser reads the string as UTF-16, so every
    /// range the tree gives lines up with the same string as an `NSString`.
    func parse(_ source: String) throws -> MutableTree? {
        let parser = Parser()
        try parser.setLanguage(grammar)
        return parser.parse(source)
    }
}

extension Node {
    func text(in text: NSString) -> String {
        text.substring(with: range)
    }

    /// The text from the start of this node up to `child`.
    func text(before child: Node, in text: NSString) -> String {
        text.substring(with: NSRange(location: range.location, length: child.range.location - range.location))
    }

    var children: [Node] {
        (0..<childCount).compactMap { child(at: $0) }
    }
}
