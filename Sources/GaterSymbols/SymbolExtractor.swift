import Foundation
import SwiftTreeSitter
import TreeSitterTypeScript
import TreeSitterTSX

public enum SymbolExtractorError: Error, Equatable {
    case unsupportedLanguage(String)
    case parseFailed(String)
}

/// Extracts symbols from TypeScript / TSX / JavaScript with tree-sitter.
///
/// "What is a symbol" is a declarative query (symbols.scm below), modelled
/// on the tags.scm files tree-sitter-typescript/-javascript ship and editors
/// like Neovim and Helix reuse, but covering what ownership needs that
/// navigation tags skip: type aliases, enums, plain consts, class fields.
/// Other languages slot in with their own grammar + query.
public enum SymbolExtractor {
    static let query = """
    (function_declaration name: (identifier) @name) @definition.function
    (generator_function_declaration name: (identifier) @name) @definition.function
    (function_signature name: (identifier) @name) @definition.function
    (class_declaration name: (type_identifier) @name) @definition.class
    (abstract_class_declaration name: (type_identifier) @name) @definition.class
    (method_definition name: (_) @name) @definition.method
    (abstract_method_signature name: (_) @name) @definition.method
    (public_field_definition name: (_) @name) @definition.property
    (interface_declaration name: (type_identifier) @name) @definition.interface
    (type_alias_declaration name: (type_identifier) @name) @definition.type
    (enum_declaration name: (identifier) @name) @definition.enum
    (internal_module name: (_) @name) @definition.module
    (variable_declarator name: (identifier) @name) @definition.variable
    """

    public static func supports(path: String) -> Bool {
        grammar(for: path) != nil
    }

    private enum Grammar { case typescript, tsx }

    private static func grammar(for path: String) -> Grammar? {
        switch (path as NSString).pathExtension.lowercased() {
        case "ts", "mts", "cts": return .typescript
        // TSX's grammar is a superset that also parses JS/JSX.
        case "tsx", "js", "jsx", "mjs", "cjs": return .tsx
        default: return nil
        }
    }

    private static let languages: (typescript: Language, tsx: Language) = (
        Language(language: tree_sitter_typescript()),
        Language(language: tree_sitter_tsx())
    )

    private static let queries: (typescript: Query, tsx: Query)? = {
        let data = Data(query.utf8)
        guard let ts = try? Query(language: languages.typescript, data: data),
              let tsx = try? Query(language: languages.tsx, data: data) else { return nil }
        return (ts, tsx)
    }()

    /// Symbols in `source`, ids prefixed with `path` (repo-relative).
    public static func symbols(source: String, path: String) throws -> [CodeSymbol] {
        try extract(source: source, path: path).map(\.symbol)
    }

    /// A symbol's signature (whitespace-collapsed) and full source text,
    /// for review questions and wake messages.
    public static func describe(symbolId: String, source: String, path: String) -> (signature: String, code: String)? {
        guard let found = try? extract(source: source, path: path).last(where: { $0.symbol.id == symbolId }) else { return nil }
        let signature = found.signature.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return (signature.trimmingCharacters(in: CharacterSet(charactersIn: " {=")), found.code)
    }

    private struct Extracted {
        var symbol: CodeSymbol
        var signature: String
        var code: String
    }

    private static func extract(source: String, path: String) throws -> [Extracted] {
        guard let grammar = grammar(for: path), let queries else {
            throw SymbolExtractorError.unsupportedLanguage(path)
        }
        let (language, query) = grammar == .typescript
            ? (languages.typescript, queries.typescript)
            : (languages.tsx, queries.tsx)

        let parser = Parser()
        try parser.setLanguage(language)
        guard let tree = parser.parse(source) else { throw SymbolExtractorError.parseFailed(path) }

        let text = source as NSString
        var found: [CodeSymbol] = []
        var texts: [String: (signature: String, code: String)] = [:]
        for match in query.execute(in: tree) {
            guard let definition = match.captures.first(where: { $0.name?.hasPrefix("definition.") == true }),
                  let nameNode = match.captures(named: "name").first?.node,
                  let captureName = definition.name,
                  var kind = SymbolKind(rawValue: String(captureName.dropFirst("definition.".count))) else { continue }
            let node = definition.node
            guard !isLocal(node) else { continue }
            let parts = split(node: node, kind: &kind, text: text)
            let name = text.substring(with: nameNode.range)
            let qualified = (qualifiers(of: node, text: text) + [name]).joined(separator: ".")
            let exported = isExported(node, kind: kind, text: text)

            texts["\(path)#\(qualified)", default: (parts.signature, text.substring(with: node.range))] =
                (parts.signature, text.substring(with: node.range))
            found.append(CodeSymbol(
                id: "\(path)#\(qualified)",
                name: name,
                qualifiedName: qualified,
                kind: kind,
                startLine: Int(node.pointRange.lowerBound.row) + 1,
                endLine: Int(node.pointRange.upperBound.row) + 1,
                nameLine: Int(nameNode.pointRange.lowerBound.row) + 1,
                nameColumn: nameNode.range.location - text.lineRange(for: NSRange(location: nameNode.range.location, length: 0)).location,
                isExported: exported,
                signatureHash: hash(normalize(parts.signature) + (exported ? "|export" : "")),
                bodyHash: hash(normalize(parts.body))
            ))
        }
        return mergeOverloads(found).map { symbol in
            let text = texts[symbol.id] ?? ("", "")
            return Extracted(symbol: symbol, signature: text.signature, code: text.code)
        }
    }

    // MARK: - Signature / body split

    /// Splits a declaration into signature text and body text by the
    /// grammar's fields: `body` for functions/classes/namespaces, `value`
    /// for variables and fields. Types, interfaces and enums are all
    /// signature — every part of them is public surface.
    private static func split(node: Node, kind: inout SymbolKind, text: NSString) -> (signature: String, body: String) {
        func before(_ child: Node) -> String {
            text.substring(with: NSRange(location: node.range.location,
                                         length: child.range.location - node.range.location))
        }

        switch kind {
        case .function, .method, .class, .module:
            if let body = node.child(byFieldName: "body") {
                return (before(body), text.substring(with: body.range))
            }
            return (text.substring(with: node.range), "")

        case .variable, .property:
            guard let value = node.child(byFieldName: "value") else {
                return (text.substring(with: node.range), "")
            }
            // `const f = (a: A): R => …` is a function: its parameters and
            // return type are signature, the arrow body is body.
            if ["arrow_function", "function_expression", "function", "generator_function"].contains(value.nodeType ?? ""),
               let body = value.child(byFieldName: "body") {
                if kind == .variable { kind = .function }
                return (before(body), text.substring(with: body.range))
            }
            // Plain values: name, type annotation and declaration keyword
            // are signature; the initializer is body.
            let keyword = node.parent?.child(at: 0).map { text.substring(with: $0.range) } ?? ""
            return (keyword + " " + before(value), text.substring(with: value.range))

        case .interface, .type, .enum:
            return (text.substring(with: node.range), "")
        }
    }

    // MARK: - Structure

    private static let functionScopes: Set<String> = [
        "function_declaration", "generator_function_declaration", "method_definition",
        "arrow_function", "function_expression", "function", "generator_function",
        "class_static_block",
    ]

    /// Declarations inside a function body are locals, not symbols.
    private static func isLocal(_ node: Node) -> Bool {
        var current = node.parent
        while let n = current {
            if functionScopes.contains(n.nodeType ?? "") { return true }
            current = n.parent
        }
        return false
    }

    /// Enclosing class and namespace names, outermost first.
    private static func qualifiers(of node: Node, text: NSString) -> [String] {
        var names: [String] = []
        var current = node.parent
        while let n = current {
            if ["class_declaration", "abstract_class_declaration", "class", "internal_module"].contains(n.nodeType ?? ""),
               let name = n.child(byFieldName: "name") {
                names.insert(text.substring(with: name.range), at: 0)
            }
            current = n.parent
        }
        return names
    }

    /// Exported: wrapped in an `export` statement (walking up through the
    /// declaration list for variables). Class members inherit their class's
    /// export unless private (`private` or `#name`).
    private static func isExported(_ node: Node, kind: SymbolKind, text: NSString) -> Bool {
        var current = node.parent
        while let n = current {
            switch n.nodeType {
            case "export_statement":
                return true
            case "class_body":
                if isPrivateMember(node, text: text) { return false }
                current = n.parent // the class; keep walking to its export
                continue
            case "lexical_declaration", "variable_declaration", "class_declaration",
                 "abstract_class_declaration", "internal_module", "expression_statement":
                current = n.parent
                continue
            default:
                // Namespace bodies are statement blocks; exported members of
                // an exported namespace are public too.
                if n.nodeType == "statement_block", n.parent?.nodeType == "internal_module" {
                    current = n.parent
                    continue
                }
                return false
            }
        }
        return false
    }

    private static func isPrivateMember(_ node: Node, text: NSString) -> Bool {
        if let name = node.child(byFieldName: "name"), name.nodeType == "private_property_identifier" { return true }
        for index in 0..<node.childCount {
            if let child = node.child(at: index), child.nodeType == "accessibility_modifier",
               text.substring(with: child.range) == "private" {
                return true
            }
        }
        return false
    }

    /// TypeScript overloads declare one function several times; treat them
    /// as one symbol whose signature is all of them.
    private static func mergeOverloads(_ symbols: [CodeSymbol]) -> [CodeSymbol] {
        var order: [String] = []
        var byId: [String: [CodeSymbol]] = [:]
        for symbol in symbols {
            if byId[symbol.id] == nil { order.append(symbol.id) }
            byId[symbol.id, default: []].append(symbol)
        }
        return order.map { id in
            let group = byId[id]!
            guard group.count > 1 else { return group[0] }
            var merged = group.last!
            merged.startLine = group.map(\.startLine).min()!
            merged.endLine = group.map(\.endLine).max()!
            merged.isExported = group.contains(where: \.isExported)
            merged.signatureHash = hash(group.map(\.signatureHash).joined(separator: "|"))
            merged.bodyHash = hash(group.map(\.bodyHash).joined(separator: "|"))
            return merged
        }
    }

    // MARK: - Hashing

    /// Formatting-insensitive, so a formatter reflowing a declaration isn't
    /// mistaken for a public-surface change: whitespace survives only where
    /// it separates two word characters (`async function`), and trailing
    /// commas before a closing bracket are dropped.
    static func normalize(_ s: String) -> String {
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }
        var out: [Character] = []
        var pendingSpace = false
        for c in s {
            if c.isWhitespace {
                pendingSpace = true
                continue
            }
            if [")", "]", "}", ">"].contains(c), out.last == "," { out.removeLast() }
            if pendingSpace, let last = out.last, isWord(last), isWord(c) { out.append(" ") }
            out.append(c)
            pendingSpace = false
        }
        return String(out)
    }

    /// FNV-1a 64: stable across runs and platforms (Hasher is seeded).
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }
}
