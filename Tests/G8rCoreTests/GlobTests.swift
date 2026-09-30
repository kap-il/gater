import XCTest
@testable import G8rCore

final class GlobTests: XCTestCase {
    func testPatterns() {
        XCTAssertTrue(Glob.matches("src/auth/**", "src/auth/session.ts"))
        XCTAssertTrue(Glob.matches("src/auth/**", "src/auth/deep/x.ts"))
        XCTAssertFalse(Glob.matches("src/auth/**", "src/dashboard/x.ts"))
        XCTAssertTrue(Glob.matches("src/**/*.tsx", "src/dashboard/UserCard.tsx"))
        XCTAssertTrue(Glob.matches("src/**/*.tsx", "src/Top.tsx"))
        XCTAssertFalse(Glob.matches("src/*.ts", "src/a/b.ts"))
        XCTAssertTrue(Glob.matches("src/dashboard", "src/dashboard/UserCard.tsx"), "bare dir = everything under it")
        XCTAssertTrue(Glob.matches("FRUITS.md", "FRUITS.md"))
        XCTAssertFalse(Glob.isPathLike("getUser"))
        XCTAssertTrue(Glob.isPathLike("src/**"))
    }

    func testTrailingSlashNamesADirectory() {
        XCTAssertTrue(Glob.matches("a/b/", "a/b/c.swift"))
        XCTAssertTrue(Glob.matches("a/b/", "a/b/deep/c.swift"))
        XCTAssertFalse(Glob.matches("a/b/", "a/bc/d.swift"))
        XCTAssertFalse(Glob.matches("a/b/", "a/b"))
        XCTAssertTrue(Glob.matches("src/*/", "src/auth/x.ts"))
        XCTAssertFalse(Glob.matches("src/*/", "src/x.ts"))
    }
}
