import XCTest
@testable import G8rSymbols

final class SwiftTests: XCTestCase {
    private func symbols(_ source: String, path: String = "Sources/App/Widget.swift") throws -> [String: CodeSymbol] {
        Dictionary(try SymbolExtractor.symbols(source: source, path: path).map { ($0.qualifiedName, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    private let widget = """
    import Foundation

    /// Draws one thing.
    public struct Widget: Codable {
        public var name: String
        let count = 0
        public private(set) var size = 3
        var area: Int { size * size }
        var first = 1, second = 2

        public init(name: String) {
            let local = name
            self.name = local
        }

        public func render(times: Int = 2) -> String {
            func helper() -> Int { 1 }
            struct Local {}
            return String(repeating: name, count: times + helper())
        }

        static func == (lhs: Widget, rhs: Widget) -> Bool { lhs.name == rhs.name }

        enum Mode { case fast, slow }
        final class Cache { struct Entry { func touch() {} } }
    }

    open class Base { open func run() {} }
    actor Counter { private var value = 0 }
    protocol Scanner { var ready: Bool { get }; func scan() }
    public protocol Plugin { func load(); init(path: String) }
    enum Plain { case only }
    public typealias Handler = (Widget) -> Void

    public extension Widget {
        func extended() {}
        private func hidden() {}
    }
    extension Widget.Mode { var label: String { "mode" } }
    extension Array where Element == Widget { func total() -> Int { count } }

    public func topLevel(_ widget: Widget) {}
    package func shared() {}
    private let secret = 42
    public var counter = 0
    let build: () -> Int = { let inside = 1; return inside }
    """

    func testSupportsSwift() {
        XCTAssertTrue(SymbolExtractor.supports(path: "Sources/App/Widget.swift"))
    }

    func testFindsDeclarationsAndNothingLocal() throws {
        XCTAssertEqual(Set(try symbols(widget).keys), [
            "Widget", "Widget.name", "Widget.count", "Widget.size", "Widget.area", "Widget.first", "Widget.second",
            "Widget.init", "Widget.render", "Widget.==", "Widget.Mode", "Widget.Cache", "Widget.Cache.Entry",
            "Widget.Cache.Entry.touch",
            "Base", "Base.run", "Counter", "Counter.value", "Scanner", "Scanner.ready", "Scanner.scan",
            "Plugin", "Plugin.load", "Plugin.init", "Plain", "Handler",
            "Widget.extended", "Widget.hidden", "Widget.Mode.label", "Array.total",
            "topLevel", "shared", "secret", "counter", "build",
        ], "locals like `local`, `helper`, `Local` and `inside` are not symbols, and neither is an extension")
    }

    func testKinds() throws {
        let s = try symbols(widget)
        XCTAssertEqual(s["Widget"]?.kind, .class, "struct")
        XCTAssertEqual(s["Base"]?.kind, .class, "class")
        XCTAssertEqual(s["Counter"]?.kind, .class, "actor")
        XCTAssertEqual(s["Scanner"]?.kind, .interface)
        XCTAssertEqual(s["Plain"]?.kind, .enum)
        XCTAssertEqual(s["Widget.Mode"]?.kind, .enum, "nested types keep their kind")
        XCTAssertEqual(s["Handler"]?.kind, .type)
        XCTAssertEqual(s["topLevel"]?.kind, .function)
        XCTAssertEqual(s["Widget.render"]?.kind, .method)
        XCTAssertEqual(s["Widget.init"]?.kind, .method)
        XCTAssertEqual(s["Widget.=="]?.kind, .method, "an operator is a func")
        XCTAssertEqual(s["Widget.extended"]?.kind, .method, "func in an extension")
        XCTAssertEqual(s["Scanner.scan"]?.kind, .method, "a protocol is a type")
        XCTAssertEqual(s["secret"]?.kind, .variable)
        XCTAssertEqual(s["build"]?.kind, .variable, "a closure in a let is still a let")
        XCTAssertEqual(s["Widget.name"]?.kind, .property)
        XCTAssertEqual(s["Widget.area"]?.kind, .property)
        XCTAssertEqual(s["Widget.Mode.label"]?.kind, .property, "var in an extension")
        XCTAssertEqual(s["Scanner.ready"]?.kind, .property)
    }

    func testQualifiedByEnclosingTypesAndExtendedType() throws {
        let s = try symbols(widget)
        XCTAssertEqual(s["Widget.Cache.Entry.touch"]?.id, "Sources/App/Widget.swift#Widget.Cache.Entry.touch")
        XCTAssertEqual(s["Widget.Cache.Entry.touch"]?.name, "touch")
        XCTAssertEqual(s["Widget.Mode.label"]?.name, "label", "an extension of a nested type is qualified by its whole path")
        XCTAssertEqual(s["Array.total"]?.name, "total", "a constraint on the extension is not part of the type")
    }

    func testExportedMeansPublicOrOpen() throws {
        let s = try symbols(widget)
        XCTAssertEqual(s["Widget"]?.isExported, true)
        XCTAssertEqual(s["Base"]?.isExported, true, "open")
        XCTAssertEqual(s["Base.run"]?.isExported, true)
        XCTAssertEqual(s["Counter"]?.isExported, false, "internal by default")
        XCTAssertEqual(s["shared"]?.isExported, false, "package is not public")
        XCTAssertEqual(s["secret"]?.isExported, false)
        XCTAssertEqual(s["Widget.name"]?.isExported, true)
        XCTAssertEqual(s["Widget.count"]?.isExported, false, "a public type's members are internal unless they say so")
        XCTAssertEqual(s["Widget.size"]?.isExported, true, "private(set) limits the setter, not the property")
    }

    func testAccessLevelTakenFromProtocolOrExtension() throws {
        let s = try symbols(widget)
        XCTAssertEqual(s["Plugin.load"]?.isExported, true, "a requirement is as visible as its protocol")
        XCTAssertEqual(s["Plugin.init"]?.isExported, true)
        XCTAssertEqual(s["Scanner.scan"]?.isExported, false)
        XCTAssertEqual(s["Widget.extended"]?.isExported, true, "member of a public extension")
        XCTAssertEqual(s["Widget.hidden"]?.isExported, false, "its own access level wins")
        XCTAssertEqual(s["Widget.Mode.label"]?.isExported, false, "the extension states no access level")
    }

    func testLineRanges() throws {
        let s = try symbols(widget)
        XCTAssertEqual(s["Widget"]?.startLine, 4, "the doc comment is not part of the declaration")
        XCTAssertEqual(s["Widget"]?.endLine, 26)
        XCTAssertEqual(s["Widget.init"]?.startLine, 11)
        XCTAssertEqual(s["Widget.init"]?.endLine, 14)
    }

    /// `nameLine` and `nameColumn` feed language-server queries, which
    /// count columns in UTF-16 units.
    func testNamePositionCountsUTF16Units() throws {
        let line = "let thumb = \"👍\"; struct Wide {}"
        let wide = try XCTUnwrap(symbols("// é\n" + line)["Wide"])
        XCTAssertEqual(wide.nameLine, 2)
        XCTAssertEqual(wide.nameColumn, (line as NSString).range(of: "Wide").location)
    }

    func testMembersUnderACompilerDirectiveAreFound() throws {
        let s = try symbols("""
        #if os(macOS)
        struct Window {
            #if DEBUG
            var frames = 0
            #endif
        }
        #endif
        """)
        XCTAssertEqual(Set(s.keys), ["Window", "Window.frames"])
    }

    func testOverloadsMergeIntoOneSymbol() throws {
        let s = try SymbolExtractor.symbols(source: """
        struct Parser {
            func parse(_ text: String) -> Int { 1 }
            func parse(_ number: Int) -> Int { 2 }
        }
        """, path: "Parser.swift")
        XCTAssertEqual(s.map(\.qualifiedName), ["Parser", "Parser.parse"])
        XCTAssertEqual(s.last?.startLine, 2)
        XCTAssertEqual(s.last?.endLine, 3)
    }

    func testDescribeGivesSignatureAndCode() throws {
        let source = "public struct Bus {\n    public func start(\n        on queue: Queue\n    ) throws -> Bool {\n        true\n    }\n    var first = 1, second: Int = 2\n}\n"
        let start = try XCTUnwrap(SymbolExtractor.describe(symbolId: "Bus.swift#Bus.start", source: source, path: "Bus.swift"))
        XCTAssertEqual(start.signature, "public func start( on queue: Queue ) throws -> Bool")
        XCTAssertTrue(start.code.hasPrefix("public func start("))
        XCTAssertTrue(start.code.hasSuffix("}"))

        let second = try XCTUnwrap(SymbolExtractor.describe(symbolId: "Bus.swift#Bus.second", source: source, path: "Bus.swift"))
        XCTAssertEqual(second.signature, "var second: Int", "each name in a shared declaration has its own signature")
    }

    // MARK: - Signature and body

    private func changes(_ before: String, _ after: String) throws -> [String: SymbolChange] {
        let old = try SymbolExtractor.symbols(source: before, path: "Bus.swift")
        let new = try SymbolExtractor.symbols(source: after, path: "Bus.swift")
        return Dictionary(SymbolDiff.diff(old: old, new: new).map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func testFunctionBodyAndSignature() throws {
        var c = try changes("public func start(id: String) -> Bool { true }",
                            "public func start(id: String) -> Bool {\n    log(id)\n    return true\n}")
        XCTAssertEqual(c["start"]?.change, .body)
        XCTAssertEqual(c["start"]?.isPublicSurface, false)

        c = try changes("public func start(id: String) -> Bool { true }",
                        "public func start(id: String, force: Bool) -> Bool { true }")
        XCTAssertEqual(c["start"]?.change, .signature)
        XCTAssertEqual(c["start"]?.isPublicSurface, true)

        c = try changes("func start() {}", "func start() async throws {}")
        XCTAssertEqual(c["start"]?.change, .signature)
    }

    func testAccessLevelIsSignature() throws {
        var c = try changes("func start() {}", "public func start() {}")
        XCTAssertEqual(c["start"]?.change, .signature)
        XCTAssertEqual(c["start"]?.isPublicSurface, true)
        c = try changes("public extension Bus { func start() {} }", "extension Bus { func start() {} }")
        XCTAssertEqual(c["Bus.start"]?.change, .signature, "the text is the same, what it exports is not")
        XCTAssertEqual(c["Bus.start"]?.isPublicSurface, true)
    }

    func testPropertyValueIsBodyButTypeIsSignature() throws {
        var c = try changes("public let limit: Int = 5", "public let limit: Int = 10")
        XCTAssertEqual(c["limit"]?.change, .body)
        c = try changes("public let limit: Int = 5", "public let limit: Double = 5")
        XCTAssertEqual(c["limit"]?.change, .signature)
        c = try changes("struct S { var area: Int { side * side } }", "struct S { var area: Int { side * side * 2 } }")
        XCTAssertEqual(c["S.area"]?.change, .body, "a computed property's getter")
        c = try changes("struct S { var n = 0 { didSet { a() } } }", "struct S { var n = 0 { didSet { b() } } }")
        XCTAssertEqual(c["S.n"]?.change, .body, "observers")
    }

    func testNamesDeclaredTogetherChangeApart() throws {
        let c = try changes("var first = 1, second = 2", "var first = 1, second = 3")
        XCTAssertNil(c["first"])
        XCTAssertEqual(c["second"]?.change, .body)
    }

    func testMethodChangesAreTypeBodyAndMethodSignature() throws {
        let c = try changes("public struct S { func get(id: String) -> Int { 1 } }",
                            "public struct S { func get(id: String, force: Bool) -> Int { 1 } }")
        XCTAssertEqual(c["S.get"]?.change, .signature)
        XCTAssertEqual(c["S"]?.change, .body, "a type's header is unchanged; its body changed")
    }

    func testEnumCasesAreSurfaceAndItsMethodsAreNot() throws {
        var c = try changes("public enum Mode { case fast }", "public enum Mode { case fast, slow }")
        XCTAssertEqual(c["Mode"]?.change, .signature)
        c = try changes("public enum Mode { case fast\n func speed() -> Int { 1 } }",
                        "public enum Mode { case fast\n func speed() -> Int { 2 } }")
        XCTAssertEqual(c["Mode"]?.change, .body)
        XCTAssertEqual(c["Mode.speed"]?.change, .body)
    }

    func testProtocolsAndTypealiasesAreAllSurface() throws {
        var c = try changes("public protocol P { func a() }", "public protocol P { func a(); func b() }")
        XCTAssertEqual(c["P"]?.change, .signature)
        XCTAssertEqual(c["P.b"]?.change, .added)
        c = try changes("public typealias Handler = (Int) -> Void", "public typealias Handler = (String) -> Void")
        XCTAssertEqual(c["Handler"]?.change, .signature)
    }

    func testFormattingOnlyIsNoChange() throws {
        let c = try changes(
            "public struct S { public func get(id: String, force: Bool) -> Int { store.get(id) } }",
            "public struct S {\n    public func get(\n        id: String,\n        force: Bool\n    ) -> Int {\n        store.get(id)\n    }\n}")
        XCTAssertTrue(c.isEmpty, "\(c)")
    }

    // MARK: - This repo

    /// Done when: every top-level type declared in `Sources/G8rCore` is
    /// found with the right kind. The folder is read as it is today, and
    /// what the engine finds is held against what a line scan finds.
    func testFindsEveryTopLevelTypeInG8rCore() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/G8rCore")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Swift files in \(folder.path)")

        var scannedTypes = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let scanned = Self.topLevelTypes(scanning: source)
            let found = try SymbolExtractor.symbols(source: source, path: file.lastPathComponent)
                .filter { $0.qualifiedName == $0.name && [.class, .interface, .enum, .type].contains($0.kind) }
            XCTAssertEqual(Dictionary(found.map { ($0.name, $0.kind) }, uniquingKeysWith: { a, _ in a }), scanned, file.path)
            scannedTypes += scanned.count
        }
        XCTAssertGreaterThan(scannedTypes, 0)
    }

    /// A line scan's idea of a file's top-level types: a declaration that
    /// starts a line, outside a multi-line string.
    private static func topLevelTypes(scanning source: String) -> [String: SymbolKind] {
        let kinds: [String: SymbolKind] = [
            "class": .class, "struct": .class, "actor": .class,
            "protocol": .interface, "enum": .enum, "typealias": .type,
        ]
        let declaration = try! NSRegularExpression(pattern:
            #"^(?:(?:@\w+(?:\([^)]*\))?|public|open|package|internal|fileprivate|private|final|indirect)\s+)*"#
            + #"(class|struct|actor|protocol|enum|typealias)\s+(\w+)"#)

        var types: [String: SymbolKind] = [:]
        var inString = false
        for line in source.components(separatedBy: .newlines) {
            if line.components(separatedBy: "\"\"\"").count % 2 == 0 {
                inString.toggle()
                continue
            }
            guard !inString,
                  let match = declaration.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            else { continue }
            let keyword = (line as NSString).substring(with: match.range(at: 1))
            types[(line as NSString).substring(with: match.range(at: 2))] = kinds[keyword]
        }
        return types
    }
}
