import Foundation
import SwiftTreeSitter
import TreeSitterTypeScript
import TreeSitterTSX

/// How many arguments a function-like symbol accepts.
public struct Arity: Equatable {
    /// Parameters without `?`, a default value, or `...rest`.
    public var required: Int
    public var total: Int
    public var hasRest: Bool

    public func accepts(_ arguments: Int) -> Bool {
        arguments >= required && (hasRest || arguments <= total)
    }

    public var description: String {
        let optional = total - required
        var text = "requires \(required)"
        if optional > 0 { text += " (+\(optional) optional)" }
        if hasRest { text += " (+rest)" }
        return text
    }
}

/// Deterministic call-site checks for the conflict review: does a call in
/// B's code still satisfy A's new signature's arity? Parser facts, not
/// judgment — they keep Jev from having to infer types from raw text.
public enum CallCompatibility {
    /// Arity of `symbolId` as declared in `source`; nil if it isn't a
    /// function, method, or function-valued const.
    public static func arity(symbolId: String, source: String, path: String) -> Arity? {
        guard let symbol = (try? SymbolExtractor.symbols(source: source, path: path))?.last(where: { $0.id == symbolId }),
              let tree = parse(source, path: path),
              let root = tree.rootNode else { return nil }
        let text = source as NSString
        // Find the name node, then its declaration's parameter list.
        let lineStart = lineOffset(text, line: symbol.nameLine)
        let offset = lineStart + symbol.nameColumn
        guard let name = root.descendant(in: utf16ByteRange(offset, offset + symbol.name.utf16.count)) else { return nil }
        var node: Node? = name.parent
        while let n = node {
            if let parameters = parameters(of: n) { return arity(of: parameters, text: text) }
            if ["program", "class_body", "statement_block"].contains(n.nodeType ?? "") { break }
            node = n.parent
        }
        return nil
    }

    /// Argument counts of calls to `name` on `line` (1-based).
    public static func argumentCounts(calling name: String, source: String, path: String, line: Int) -> [Int] {
        guard let tree = parse(source, path: path), let root = tree.rootNode else { return [] }
        let text = source as NSString
        var counts: [Int] = []
        walk(root) { node in
            guard node.nodeType == "call_expression",
                  Int(node.pointRange.lowerBound.row) + 1 <= line, Int(node.pointRange.upperBound.row) + 1 >= line,
                  let function = node.child(byFieldName: "function"),
                  let arguments = node.child(byFieldName: "arguments") else { return }
            let callee = function.nodeType == "member_expression"
                ? function.child(byFieldName: "property").map { text.substring(with: $0.range) }
                : text.substring(with: function.range)
            guard callee == name else { return }
            var count = 0
            for index in 0..<arguments.namedChildCount {
                if let arg = arguments.namedChild(at: index), arg.nodeType != "comment" { count += 1 }
            }
            counts.append(count)
        }
        return counts
    }

    // MARK: - Helpers

    private static func parameters(of node: Node) -> Node? {
        switch node.nodeType {
        case "function_declaration", "generator_function_declaration", "function_signature",
             "method_definition", "abstract_method_signature", "arrow_function", "function_expression":
            return node.child(byFieldName: "parameters")
        case "variable_declarator", "public_field_definition":
            guard let value = node.child(byFieldName: "value") else { return nil }
            return parameters(of: value)
        default:
            return nil
        }
    }

    private static func arity(of parameters: Node, text: NSString) -> Arity {
        var required = 0, total = 0, rest = false
        for index in 0..<parameters.namedChildCount {
            guard let p = parameters.namedChild(at: index) else { continue }
            switch p.nodeType {
            case "optional_parameter":
                total += 1
            case "required_parameter":
                if p.child(byFieldName: "pattern")?.nodeType == "rest_pattern" { rest = true; continue }
                if let pattern = p.child(byFieldName: "pattern"), text.substring(with: pattern.range) == "this" { continue }
                total += 1
                if p.child(byFieldName: "value") == nil { required += 1 }
            case "identifier": // `x => …`
                total += 1
                required += 1
            default:
                continue
            }
        }
        return Arity(required: required, total: total, hasRest: rest)
    }

    private static func parse(_ source: String, path: String) -> MutableTree? {
        let language: Language
        switch (path as NSString).pathExtension.lowercased() {
        case "ts", "mts", "cts": language = Language(language: tree_sitter_typescript())
        case "tsx", "js", "jsx", "mjs", "cjs": language = Language(language: tree_sitter_tsx())
        default: return nil
        }
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil else { return nil }
        return parser.parse(source)
    }

    private static func walk(_ node: Node, _ visit: (Node) -> Void) {
        visit(node)
        for index in 0..<node.childCount {
            if let child = node.child(at: index) { walk(child, visit) }
        }
    }

    private static func lineOffset(_ text: NSString, line: Int) -> Int {
        var offset = 0
        for _ in 1..<max(line, 1) {
            let range = text.lineRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(range)
        }
        return offset
    }

    /// Parser.parse(String) reads UTF-16, so tree byte offsets are 2× units.
    private static func utf16ByteRange(_ start: Int, _ end: Int) -> Range<UInt32> {
        UInt32(start * 2)..<UInt32(end * 2)
    }
}
