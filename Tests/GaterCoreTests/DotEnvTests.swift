import XCTest
@testable import GaterCore

final class DotEnvTests: XCTestCase {
    func testParse() {
        let values = DotEnv.parse("""
        # Jev
        JEV_API_KEY=sk-123
        export JEV_BASE_URL="https://api.example.com/v1"
        QUOTED='a b # not a comment'
        INLINE=value # comment
        EMPTY=
        not a line
        """)
        XCTAssertEqual(values["JEV_API_KEY"], "sk-123")
        XCTAssertEqual(values["JEV_BASE_URL"], "https://api.example.com/v1")
        XCTAssertEqual(values["QUOTED"], "a b # not a comment")
        XCTAssertEqual(values["INLINE"], "value")
        XCTAssertEqual(values["EMPTY"], "")
        XCTAssertEqual(values.count, 5)
    }

    func testEnvironmentOverridesFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gater-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try "JEV_API_KEY=from-file\nOTHER=1\n".write(to: file, atomically: true, encoding: .utf8)
        let values = DotEnv.load(path: file, environment: ["JEV_API_KEY": "from-env"])
        XCTAssertEqual(values["JEV_API_KEY"], "from-env")
        XCTAssertEqual(values["OTHER"], "1")
        XCTAssertEqual(DotEnv.load(path: file.appendingPathExtension("missing"), environment: [:]), [:])
    }
}
