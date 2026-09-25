import XCTest
@testable import GaterSymbols

final class CallCompatibilityTests: XCTestCase {
    private func arity(_ source: String, _ symbol: String) -> Arity? {
        CallCompatibility.arity(symbolId: "a.ts#\(symbol)", source: source, path: "a.ts")
    }

    func testArityCounts() {
        XCTAssertEqual(arity("export function getUser(id: string, opts: Opts): User { return x }", "getUser"),
                       Arity(required: 2, total: 2, hasRest: false))
        XCTAssertEqual(arity("export function getUser(id: string, opts?: Opts) {}", "getUser"),
                       Arity(required: 1, total: 2, hasRest: false))
        XCTAssertEqual(arity("export function f(a: A, b = 1, ...rest: R[]) {}", "f"),
                       Arity(required: 1, total: 2, hasRest: true))
        XCTAssertEqual(arity("export const f = (a: A, b: B) => a", "f"), Arity(required: 2, total: 2, hasRest: false))
        XCTAssertEqual(arity("export class S { get(id: string, force?: boolean) { return 1 } }", "S.get"),
                       Arity(required: 1, total: 2, hasRest: false))
        XCTAssertNil(arity("export interface User { id: string }", "User"))
    }

    func testCallArgumentCounts() {
        let source = """
        import { getUser } from "../users"
        export function UserCard({ id }: { id: string }) {
          const user = getUser(id)
          const other = api.getUser(id, { includeSession: true })
          return user
        }
        """
        XCTAssertEqual(CallCompatibility.argumentCounts(calling: "getUser", source: source, path: "c.tsx", line: 3), [1])
        XCTAssertEqual(CallCompatibility.argumentCounts(calling: "getUser", source: source, path: "c.tsx", line: 4), [2])
        XCTAssertEqual(CallCompatibility.argumentCounts(calling: "getUser", source: source, path: "c.tsx", line: 5), [])
    }

    /// The golden case: the new signature makes `opts` required.
    func testGoldenCallBreaks() throws {
        let new = try XCTUnwrap(arity("export function getUser(id: string, opts: { includeSession?: boolean }): User { return x }", "getUser"))
        XCTAssertFalse(new.accepts(1))
        XCTAssertTrue(new.accepts(2))
    }
}
