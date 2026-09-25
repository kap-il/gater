import XCTest
@testable import GaterSymbols

final class SymbolExtractorTests: XCTestCase {
    private func symbols(_ source: String, path: String = "src/users.ts") throws -> [String: CodeSymbol] {
        Dictionary(try SymbolExtractor.symbols(source: source, path: path).map { ($0.qualifiedName, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    private let users = """
    import { db } from "./db";

    export interface User { id: string; name: string }
    export type UserId = string;
    export enum Role { Admin, Member }

    export function getUser(id: string): User {
      const cached = cache.get(id);
      function local() { return 1 }
      return cached ?? db.get(id);
    }

    function normalizeUser(u: User): User { return u }

    export const MAX_USERS = 100;
    export const findUser = async (name: string): Promise<User | undefined> => {
      return db.find(name);
    };

    export class UserService {
      private cache = new Map<string, User>();
      constructor(private readonly store: Store) {}
      getUser(id: string): User { return this.store.get(id) }
      private evict(id: string) { this.cache.delete(id) }
      #secret() {}
    }

    export namespace Legacy {
      export function oldGet(id: number) { return id }
    }
    """

    func testExtractsTopLevelAndClassSymbolsWithKindsAndIds() throws {
        let s = try symbols(users)
        XCTAssertEqual(Set(s.keys), [
            "User", "UserId", "Role", "getUser", "normalizeUser", "MAX_USERS", "findUser",
            "UserService", "UserService.cache", "UserService.constructor", "UserService.getUser",
            "UserService.evict", "UserService.#secret", "Legacy", "Legacy.oldGet",
        ], "locals like `cached` and `local` are not symbols")
        XCTAssertEqual(s["getUser"]?.id, "src/users.ts#getUser")
        XCTAssertEqual(s["getUser"]?.kind, .function)
        XCTAssertEqual(s["findUser"]?.kind, .function, "arrow-function consts are functions")
        XCTAssertEqual(s["MAX_USERS"]?.kind, .variable)
        XCTAssertEqual(s["User"]?.kind, .interface)
        XCTAssertEqual(s["UserId"]?.kind, .type)
        XCTAssertEqual(s["Role"]?.kind, .enum)
        XCTAssertEqual(s["UserService.getUser"]?.kind, .method)
        XCTAssertEqual(s["UserService.cache"]?.kind, .property)
        XCTAssertEqual(s["Legacy"]?.kind, .module)
    }

    func testExportStatus() throws {
        let s = try symbols(users)
        XCTAssertEqual(s["getUser"]?.isExported, true)
        XCTAssertEqual(s["normalizeUser"]?.isExported, false)
        XCTAssertEqual(s["findUser"]?.isExported, true)
        XCTAssertEqual(s["UserService.getUser"]?.isExported, true, "public member of exported class")
        XCTAssertEqual(s["UserService.evict"]?.isExported, false, "private member")
        XCTAssertEqual(s["UserService.#secret"]?.isExported, false, "#private member")
        XCTAssertEqual(s["Legacy.oldGet"]?.isExported, true)
    }

    func testLineRanges() throws {
        let s = try symbols(users)
        XCTAssertEqual(s["getUser"]?.startLine, 7)
        XCTAssertEqual(s["getUser"]?.endLine, 11)
    }

    func testTSXAndJavaScript() throws {
        let tsx = try symbols("""
        export function UserCard({ user }: Props) { return <div>{user.name}</div> }
        """, path: "src/dashboard.tsx")
        XCTAssertEqual(tsx["UserCard"]?.kind, .function)

        let js = try symbols("export function add(a, b) { return a + b }\nmodule.exports = { add }", path: "lib/math.js")
        XCTAssertEqual(js["add"]?.isExported, true)
    }

    func testUnsupportedLanguage() {
        XCTAssertFalse(SymbolExtractor.supports(path: "README.md"))
        XCTAssertThrowsError(try SymbolExtractor.symbols(source: "x", path: "a.py"))
    }

    func testOverloadsMergeIntoOneSymbol() throws {
        let s = try SymbolExtractor.symbols(source: """
        export function parse(x: string): number;
        export function parse(x: number): number;
        export function parse(x: any): number { return Number(x) }
        """, path: "p.ts")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.startLine, 1)
        XCTAssertEqual(s.first?.endLine, 3)
    }
}
