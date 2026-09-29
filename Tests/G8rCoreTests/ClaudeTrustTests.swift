import XCTest
@testable import G8rCore

final class ClaudeTrustTests: XCTestCase {
    private var config: URL!

    override func setUpWithError() throws {
        config = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
        try #"{"numStartups": 3, "projects": {"/w/app": {"hasTrustDialogAccepted": true, "allowedTools": ["x"]}, "/w/other": {"hasTrustDialogAccepted": false}}}"#
            .write(to: config, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: config) }

    func testTrustIsInheritedFromParents() {
        XCTAssertTrue(ClaudeTrust.isTrusted("/w/app", config: config))
        XCTAssertTrue(ClaudeTrust.isTrusted("/w/app/src", config: config))
        XCTAssertFalse(ClaudeTrust.isTrusted("/w/other", config: config))
        XCTAssertFalse(ClaudeTrust.isTrusted("/w/app-auth", config: config), "a sibling worktree isn't inside the repo")
    }

    func testTrustingAWorktreePreservesEverythingElse() throws {
        try ClaudeTrust.trustWorktree("/w/app-auth", createdFrom: "/w/app", config: config)
        XCTAssertTrue(ClaudeTrust.isTrusted("/w/app-auth", config: config))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: config))
        XCTAssertEqual(json.value(atPath: "numStartups"), .number(3))
        XCTAssertEqual(json.objectValue?["projects"]?.objectValue?["/w/app"]?.value(atPath: "allowedTools")?.arrayValue?.count, 1)
    }

    func testRefusesWhenTheRepoIsntTrusted() {
        XCTAssertThrowsError(try ClaudeTrust.trustWorktree("/w/other-x", createdFrom: "/w/other", config: config)) {
            XCTAssertEqual($0 as? ClaudeTrust.TrustError, .repositoryNotTrusted("/w/other"))
        }
        XCTAssertFalse(ClaudeTrust.isTrusted("/w/other-x", config: config))
    }
}
