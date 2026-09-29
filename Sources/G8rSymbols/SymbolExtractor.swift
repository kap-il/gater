import Foundation
import SwiftTreeSitter

public enum SymbolExtractorError: Error, Equatable {
    case unsupportedLanguage(String)
    case parseFailed(String)
}

/// A symbol with the text of its declaration.
struct SymbolDescription: Equatable {
    var symbol: CodeSymbol
    /// The declaration without its body, on one line.
    var signature: String
    /// The declaration as written, body and all.
    var code: String
}

/// Extracts symbols from source code with tree-sitter.
///
/// This is the part that is the same for every language. What differs, the
/// grammar, the query that says what a symbol is, and the rules for
/// qualifying, exporting and splitting one, is the language table in
/// `Languages/`.
public enum SymbolExtractor {
    public static func supports(path: String) -> Bool {
        SymbolLanguage.reading(path) != nil
    }

    /// Symbols in `source`, ids prefixed with `path` (repo-relative).
    public static func symbols(source: String, path: String) throws -> [CodeSymbol] {
        try describeAll(source: source, path: path).map(\.symbol)
    }

    /// A symbol's signature (whitespace-collapsed) and full source text,
    /// for review questions and wake messages.
    public static func describe(symbolId: String, source: String, path: String) -> (signature: String, code: String)? {
        guard let found = try? describeAll(source: source, path: path).last(where: { $0.symbol.id == symbolId }) else { return nil }
        return (found.signature, found.code)
    }

    /// Every symbol in `source` with its signature and code, from one
    /// parse. `describe` parses the file to answer for one symbol, so
    /// whoever wants them all asks here.
    static func describeAll(source: String, path: String) throws -> [SymbolDescription] {
        guard let language = SymbolLanguage.reading(path), let query = language.query else {
            throw SymbolExtractorError.unsupportedLanguage(path)
        }
        guard let tree = try language.parse(source) else { throw SymbolExtractorError.parseFailed(path) }

        let text = source as NSString
        var found: [CodeSymbol] = []
        var texts: [String: (signature: String, code: String)] = [:]
        for match in query.execute(in: tree) {
            guard let definition = match.captures.first(where: { $0.name?.hasPrefix("definition.") == true }),
                  let nameNode = match.captures(named: "name").first?.node,
                  let captureName = definition.name,
                  var kind = SymbolKind(rawValue: String(captureName.dropFirst("definition.".count))) else { continue }
            let node = definition.node
            guard !isLocal(node, in: language) else { continue }
            let parts = language.split(node, nameNode, &kind, text)
            let name = text.substring(with: nameNode.range)
            let qualified = (qualifiers(of: node, in: language, text: text) + [name]).joined(separator: ".")
            let exported = language.isExported(node, text)

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
            let signature = text.signature.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return SymbolDescription(
                symbol: symbol,
                signature: signature.trimmingCharacters(in: CharacterSet(charactersIn: " {=")),
                code: text.code
            )
        }
    }

    // MARK: - Structure

    /// Declarations inside a function body are locals, not symbols.
    private static func isLocal(_ node: Node, in language: SymbolLanguage) -> Bool {
        var current = node.parent
        while let n = current {
            if language.scopes.contains(n.nodeType ?? "") { return true }
            current = n.parent
        }
        return false
    }

    /// Names of the enclosing types and namespaces, outermost first.
    private static func qualifiers(of node: Node, in language: SymbolLanguage, text: NSString) -> [String] {
        var names: [String] = []
        var current = node.parent
        while let n = current {
            if let name = language.qualifier(n, text) { names.insert(name, at: 0) }
            current = n.parent
        }
        return names
    }

    /// Overloads declare one name several times; treat them as one symbol
    /// whose signature is all of them.
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
