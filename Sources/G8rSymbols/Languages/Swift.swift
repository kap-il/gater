import Foundation
import SwiftTreeSitter
import TreeSitterSwift

extension SymbolLanguage {
    /// Swift, read with alex-pinkus/tree-sitter-swift.
    ///
    /// In that grammar one node type, `class_declaration`, covers class,
    /// struct, actor, enum and extension, and its `declaration_kind` says
    /// which. An extension names its type with a `user_type` where the
    /// others have a `type_identifier`, so the patterns below pass over it:
    /// an extension declares nothing of its own, it only qualifies its
    /// members.
    static let swift = SymbolLanguage(
        extensions: ["swift"],
        grammar: Language(language: tree_sitter_swift()),
        symbols: """
        (class_declaration declaration_kind: ["class" "struct" "actor"] name: (type_identifier) @name) @definition.class
        (class_declaration declaration_kind: "enum" name: (type_identifier) @name) @definition.enum
        (protocol_declaration name: (type_identifier) @name) @definition.interface
        (typealias_declaration name: (type_identifier) @name) @definition.type
        (function_declaration "func" . name: _ @name) @definition.function
        (protocol_function_declaration "func" . name: _ @name) @definition.function
        (init_declaration name: "init" @name) @definition.method
        (property_declaration name: (pattern bound_identifier: (simple_identifier) @name)) @definition.variable
        (protocol_property_declaration name: (pattern bound_identifier: (simple_identifier) @name)) @definition.variable
        """,
        identifiers: ["simple_identifier", "type_identifier"],
        prose: [
            "comment", "multiline_comment",
            "line_string_literal", "multi_line_string_literal", "raw_string_literal", "regex_literal",
        ],
        interpolations: ["interpolated_expression"],
        // Every block of code is a `statements` node, and nothing else is:
        // the members of a type and the top of a file hang off their parent
        // directly.
        scopes: ["statements"],
        qualifier: SwiftRules.qualifier,
        isExported: SwiftRules.isExported,
        split: SwiftRules.split
    )
}

private enum SwiftRules {
    /// Types qualify what they hold, and an extension qualifies its members
    /// by the type it extends.
    static func qualifier(_ node: Node, text: NSString) -> String? {
        guard ["class_declaration", "protocol_declaration"].contains(node.nodeType ?? ""),
              let name = node.child(byFieldName: "name") else { return nil }
        // An extension names its type as a path that may carry generic
        // arguments, `Outer<Int>.Inner`. The path alone is the type.
        guard name.nodeType == "user_type" else { return name.text(in: text) }
        return name.children.filter { $0.nodeType == "type_identifier" }
            .map { $0.text(in: text) }
            .joined(separator: ".")
    }

    /// Exported: `public` or `open`. A declaration that states no access
    /// level takes it from where it is, in the two places Swift says so: a
    /// protocol's requirements are as visible as the protocol, and the
    /// members of a `public extension` are public.
    static func isExported(_ node: Node, text: NSString) -> Bool {
        if let access = accessLevel(of: node, text: text) {
            return access == "public" || access == "open"
        }
        guard isMember(node), let owner = node.parent?.parent else { return false }
        let lendsAccess = owner.nodeType == "protocol_declaration"
            || owner.child(byFieldName: "declaration_kind")?.text(in: text) == "extension"
        return lendsAccess && isExported(owner, text: text)
    }

    /// The access level a declaration states, or nil when it states none.
    /// `private(set)` limits the setter only, so it isn't one.
    private static func accessLevel(of node: Node, text: NSString) -> String? {
        node.children.first { $0.nodeType == "modifiers" }?
            .children.first { $0.nodeType == "visibility_modifier" && $0.childCount == 1 }?
            .text(in: text)
    }

    private static func isMember(_ node: Node) -> Bool {
        ["class_body", "enum_class_body", "protocol_body"].contains(node.parent?.nodeType ?? "")
    }

    /// Functions and types split at their body. A protocol and a typealias
    /// are all signature, every part of them being public surface.
    static func split(_ node: Node, name: Node, kind: inout SymbolKind, text: NSString) -> (signature: String, body: String) {
        // The query can't see where a declaration is: in a type or an
        // extension a func is a method and a var is a property.
        if isMember(node) {
            if kind == .function { kind = .method }
            if kind == .variable { kind = .property }
        }

        switch kind {
        case .function, .method, .class, .module:
            guard let body = node.child(byFieldName: "body") else { return (node.text(in: text), "") }
            return (node.text(before: body, in: text), body.text(in: text))

        case .enum:
            guard let body = node.child(byFieldName: "body") else { return (node.text(in: text), "") }
            // An enum's cases are its surface. The rest of its body, the
            // methods and computed properties, is implementation.
            let cases = body.children.filter { $0.nodeType == "enum_entry" }.map { $0.text(in: text) }
            return (([node.text(before: body, in: text)] + cases).joined(separator: "\n"), body.text(in: text))

        case .variable, .property:
            return splitProperty(node, name: name, text: text)

        case .interface, .type:
            return (node.text(in: text), "")
        }
    }

    /// The name and type annotation are signature. The initializer, the
    /// computed body and the observers are body.
    ///
    /// `var a = 1, b = 2` is one node declaring two names, so each name's
    /// share is cut out of it: what they have in common, the modifiers and
    /// `var`, then from its own pattern up to the comma before the next.
    private static func splitProperty(_ node: Node, name: Node, text: NSString) -> (signature: String, body: String) {
        var patterns: [Node] = []
        var implementations: [Node] = []
        for (index, child) in node.children.enumerated() {
            switch node.fieldNameForChild(at: index) {
            case "name": patterns.append(child)
            case "value", "computed_value": implementations.append(child)
            default: if child.nodeType == "willset_didset_block" { implementations.append(child) }
            }
        }
        guard let first = patterns.first,
              let own = patterns.last(where: { $0.range.location <= name.range.location }) else {
            return (node.text(in: text), "")
        }
        let next = patterns.first { $0.range.location > own.range.location }
        let start = own.range.location
        let end = next?.previousSibling?.range.location ?? NSMaxRange(node.range)
        let cut = implementations.first { (start..<end).contains($0.range.location) }?.range.location ?? end
        return (
            node.text(before: first, in: text) + text.substring(with: NSRange(location: start, length: cut - start)),
            text.substring(with: NSRange(location: cut, length: end - cut))
        )
    }
}
