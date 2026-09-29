import Foundation
import SwiftTreeSitter
import TreeSitterTypeScript
import TreeSitterTSX

extension SymbolLanguage {
    static let typescript = ecmaScript(["ts", "mts", "cts"], grammar: tree_sitter_typescript())
    static let tsx = ecmaScript(["tsx"], grammar: tree_sitter_tsx())
    /// TSX's grammar is a superset that also parses JavaScript and JSX.
    static let javascript = ecmaScript(["js", "jsx", "mjs", "cjs"], grammar: tree_sitter_tsx())

    /// TypeScript, TSX and JavaScript differ in grammar and nothing else.
    ///
    /// The query is modelled on the tags.scm files
    /// tree-sitter-typescript/-javascript ship and editors like Neovim and
    /// Helix reuse, but covering what ownership needs that navigation tags
    /// skip: type aliases, enums, plain consts, class fields.
    private static func ecmaScript(_ extensions: Set<String>, grammar: OpaquePointer) -> SymbolLanguage {
        SymbolLanguage(
            extensions: extensions,
            grammar: Language(language: grammar),
            symbols: """
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
            """,
            identifiers: [
                "identifier", "type_identifier", "property_identifier", "private_property_identifier",
                "shorthand_property_identifier", "shorthand_property_identifier_pattern",
            ],
            prose: [
                "comment", "html_comment", "string", "template_string", "template_literal_type", "regex", "jsx_text",
            ],
            interpolations: ["template_substitution", "template_type"],
            scopes: [
                "function_declaration", "generator_function_declaration", "method_definition",
                "arrow_function", "function_expression", "function", "generator_function",
                "class_static_block",
            ],
            qualifier: ECMAScript.qualifier,
            isExported: ECMAScript.isExported,
            split: ECMAScript.split
        )
    }
}

private enum ECMAScript {
    /// Classes and namespaces qualify what they hold.
    static func qualifier(_ node: Node, text: NSString) -> String? {
        guard ["class_declaration", "abstract_class_declaration", "class", "internal_module"].contains(node.nodeType ?? "") else {
            return nil
        }
        return node.child(byFieldName: "name")?.text(in: text)
    }

    /// Splits by the grammar's fields: `body` for functions, classes and
    /// namespaces, `value` for variables and fields. Types, interfaces and
    /// enums are all signature — every part of them is public surface.
    static func split(_ node: Node, name: Node, kind: inout SymbolKind, text: NSString) -> (signature: String, body: String) {
        switch kind {
        case .function, .method, .class, .module:
            if let body = node.child(byFieldName: "body") {
                return (node.text(before: body, in: text), body.text(in: text))
            }
            return (node.text(in: text), "")

        case .variable, .property:
            guard let value = node.child(byFieldName: "value") else {
                return (node.text(in: text), "")
            }
            // `const f = (a: A): R => …` is a function: its parameters and
            // return type are signature, the arrow body is body.
            if ["arrow_function", "function_expression", "function", "generator_function"].contains(value.nodeType ?? ""),
               let body = value.child(byFieldName: "body") {
                if kind == .variable { kind = .function }
                return (node.text(before: body, in: text), body.text(in: text))
            }
            // Plain values: name, type annotation and declaration keyword
            // are signature; the initializer is body.
            let keyword = node.parent?.child(at: 0).map { $0.text(in: text) } ?? ""
            return (keyword + " " + node.text(before: value, in: text), value.text(in: text))

        case .interface, .type, .enum:
            return (node.text(in: text), "")
        }
    }

    /// Exported: wrapped in an `export` statement (walking up through the
    /// declaration list for variables). Class members inherit their class's
    /// export unless private (`private` or `#name`).
    static func isExported(_ node: Node, text: NSString) -> Bool {
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
        return node.children.contains { $0.nodeType == "accessibility_modifier" && $0.text(in: text) == "private" }
    }
}
