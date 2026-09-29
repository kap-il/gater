import XCTest
@testable import G8rSymbols

final class SymbolUsesTests: XCTestCase {
    /// Done when: `uses` counts a type named in code and ignores the same
    /// name in a comment or a string.
    func testSwiftCountsANameInCodeAndNotInProse() {
        let uses = SymbolExtractor.uses(source: """
        // EventBus in a comment
        /* EventBus in a block comment */
        /// EventBus in a doc comment
        let label = "EventBus in a string"
        let long = \"""
            EventBus in a multi-line string
            \"""
        let raw = #"EventBus in a raw string"#
        let bus: EventBus = EventBus.shared
        func start(_ bus: EventBus) { bus.start() }
        """, path: "Sources/App/Main.swift")

        XCTAssertEqual(uses["EventBus"], 3, "the type annotation, the call and the parameter")
        XCTAssertEqual(uses["bus"], 3)
        XCTAssertEqual(uses["start"], 2, "declaring a name is an appearance of it")
        XCTAssertEqual(uses["shared"], 1)
        XCTAssertNil(uses["comment"])
        XCTAssertNil(uses["string"])
        XCTAssertNil(uses["func"], "keywords are not identifiers")
    }

    func testCodeInterpolatedIntoAStringIsInsideTheString() {
        let uses = SymbolExtractor.uses(source: #"let line = "on \(EventBus.shared)""#, path: "Main.swift")
        XCTAssertEqual(uses, ["line": 1])
    }

    func testTypeScriptCountsANameInCodeAndNotInProse() {
        let uses = SymbolExtractor.uses(source: """
        import { Gadget } from "./Gadget";
        // Gadget in a comment
        /** Gadget in a doc comment */
        const label = "Gadget in a string";
        const long = `Gadget in a template`;
        const pattern = /Gadget/;
        export function make(): Gadget { return new Gadget(label.length) }
        """, path: "src/make.ts")

        XCTAssertEqual(uses["Gadget"], 3, "the import, the return type and the call")
        XCTAssertEqual(uses["label"], 2)
        XCTAssertEqual(uses["length"], 1, "a property is a name too")
        XCTAssertNil(uses["comment"])
        XCTAssertNil(uses["template"])
    }

    func testTSXAndJavaScript() {
        let tsx = SymbolExtractor.uses(source: """
        export function Card({ user }: Props) { return <Gadget name="Gadget">Gadget in text {user.name}</Gadget> }
        """, path: "src/card.tsx")
        XCTAssertEqual(tsx["Gadget"], 2, "the opening and closing tags")
        XCTAssertEqual(tsx["user"], 2)
        XCTAssertEqual(tsx["Props"], 1)

        let js = SymbolExtractor.uses(source: "function add(a, b) { return a + b }\nmodule.exports = { add }", path: "lib/math.js")
        XCTAssertEqual(js["add"], 2)
    }

    func testUnknownLanguageHasNoUses() {
        XCTAssertEqual(SymbolExtractor.uses(source: "class Gadget: pass", path: "gadget.py"), [:])
    }

    func testEmptyFileHasNoUses() {
        XCTAssertEqual(SymbolExtractor.uses(source: "", path: "Empty.swift"), [:])
    }
}
