import XCTest
@testable import GaterSymbols

/// Spec Phase 4 acceptance: edits produce correct `signature` vs `body`
/// classification.
final class SymbolDiffTests: XCTestCase {
    private func changes(_ before: String, _ after: String, path: String = "src/users.ts") throws -> [String: SymbolChange] {
        let old = try SymbolExtractor.symbols(source: before, path: path)
        let new = try SymbolExtractor.symbols(source: after, path: path)
        return Dictionary(SymbolDiff.diff(old: old, new: new).map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The golden scenario (spec §6): A changes getUser(id) → getUser(id, opts).
    func testAddingAParameterIsASignatureChange() throws {
        let c = try changes(
            "export function getUser(id: string): User { return db.get(id) }",
            "export function getUser(id: string, opts: Opts): User { return db.get(id, opts) }")
        XCTAssertEqual(c["getUser"]?.change, .signature)
        XCTAssertEqual(c["getUser"]?.isPublicSurface, true)
    }

    func testBodyOnlyEditIsABodyChange() throws {
        let c = try changes(
            "export function getUser(id: string): User { return db.get(id) }",
            "export function getUser(id: string): User {\n  log(id)\n  return db.get(id)\n}")
        XCTAssertEqual(c["getUser"]?.change, .body)
        XCTAssertEqual(c["getUser"]?.isPublicSurface, false)
    }

    func testReturnTypeChangeIsSignature() throws {
        let c = try changes("export function f(): A { return a }", "export function f(): B { return a }")
        XCTAssertEqual(c["f"]?.change, .signature)
    }

    func testExportToggleIsSignature() throws {
        var c = try changes("function f() {}", "export function f() {}")
        XCTAssertEqual(c["f"]?.change, .signature)
        XCTAssertEqual(c["f"]?.isPublicSurface, true)
        c = try changes("export function f() {}", "function f() {}")
        XCTAssertEqual(c["f"]?.isPublicSurface, true, "un-exporting breaks importers too")
    }

    func testArrowFunctionConst() throws {
        var c = try changes("export const f = (a: A) => a.x", "export const f = (a: A) => a.y")
        XCTAssertEqual(c["f"]?.change, .body)
        c = try changes("export const f = (a: A) => a.x", "export const f = (a: A, b: B) => a.x")
        XCTAssertEqual(c["f"]?.change, .signature)
    }

    func testConstValueIsBodyButTypeIsSignature() throws {
        var c = try changes("export const LIMIT: number = 5", "export const LIMIT: number = 10")
        XCTAssertEqual(c["LIMIT"]?.change, .body)
        c = try changes("export const LIMIT: number = 5", "export const LIMIT: bigint = 5n")
        XCTAssertEqual(c["LIMIT"]?.change, .signature)
    }

    func testTypesAndInterfacesAreAllSurface() throws {
        let c = try changes("export interface User { id: string }", "export interface User { id: string; age: number }")
        XCTAssertEqual(c["User"]?.change, .signature)
    }

    func testMethodChangesAreClassBodyAndMethodSignature() throws {
        let c = try changes(
            "export class S { get(id: string) { return 1 } }",
            "export class S { get(id: string, force: boolean) { return 1 } }")
        XCTAssertEqual(c["S.get"]?.change, .signature)
        XCTAssertEqual(c["S"]?.change, .body, "a class's header is unchanged; its body changed")
    }

    func testAddedAndRemoved() throws {
        let c = try changes("export function a() {}", "export function b() {}")
        XCTAssertEqual(c["a"]?.change, .removed)
        XCTAssertEqual(c["b"]?.change, .added)
        XCTAssertEqual(c["b"]?.isPublicSurface, true)
    }

    func testFormattingOnlyIsNoChange() throws {
        let c = try changes(
            "export function getUser(id: string): User { return db.get(id) }",
            "export function getUser(\n  id: string,\n): User {\n  return db.get(id);\n}".replacingOccurrences(of: ";", with: ""))
        XCTAssertTrue(c.isEmpty, "\(c)")
    }

    func testUnchangedFileHasNoChanges() throws {
        let src = "export function a() { return 1 }\nexport class B { m() {} }"
        XCTAssertTrue(try changes(src, src).isEmpty)
    }
}
