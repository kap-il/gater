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
}
