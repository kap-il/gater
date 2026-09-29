import XCTest
@testable import G8rCore

final class G8rConfigTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("g8r-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".g8r"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ json: String) throws {
        try json.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func load(_ environment: [String: String] = [:]) -> G8rConfig {
        G8rConfig.load(repoRoot: root.path, environment: environment)
    }

    private let shared = """
        {
          "plans": ["PLAN.md", "specs/*.md"],
          "build_command": "swift build",
          "test_command": "swift test",
          "worktree_setup": "ln -sfn \\"$G8R_PLAN_ROOT/Vendor/x\\" Vendor/x",
          "ignore": ["Vendor/**", "planmap/**"]
        }
        """

    func testDefaultsWhenNoFileSaysAnything() {
        let config = load()
        XCTAssertEqual(config, G8rConfig())
        XCTAssertEqual(config.plans, ["PLAN.md", "plans/*.md", "docs/plans/*.md"])
        XCTAssertNil(config.buildCommand)
        XCTAssertNil(config.testCommand)
        XCTAssertNil(config.worktreeSetup)
        XCTAssertEqual(config.ignore, [])
    }

    func testReadsG8rJson() throws {
        try write("g8r.json", shared)
        XCTAssertEqual(load(), G8rConfig(
            plans: ["PLAN.md", "specs/*.md"], buildCommand: "swift build", testCommand: "swift test",
            worktreeSetup: "ln -sfn \"$G8R_PLAN_ROOT/Vendor/x\" Vendor/x", ignore: ["Vendor/**", "planmap/**"]))
    }

    func testTheLocalFileOverridesG8rJsonKeyByKey() throws {
        try write("g8r.json", shared)
        try write(".g8r/config.json", #"{"test_command": "swift test --filter Fast", "ignore": ["tmp/**"]}"#)

        let config = load()

        XCTAssertEqual(config.testCommand, "swift test --filter Fast")
        XCTAssertEqual(config.ignore, ["tmp/**"])
        XCTAssertEqual(config.buildCommand, "swift build", "a key the local file leaves out keeps its value")
        XCTAssertEqual(config.plans, ["PLAN.md", "specs/*.md"])
        XCTAssertEqual(config.worktreeSetup, "ln -sfn \"$G8R_PLAN_ROOT/Vendor/x\" Vendor/x")
    }

    func testTheEnvironmentOverridesBothFiles() throws {
        try write("g8r.json", shared)
        try write(".g8r/config.json", #"{"test_command": "local test", "build_command": "local build"}"#)

        let config = load(["G8R_TEST_COMMAND": "make check", "G8R_BUILD_COMMAND": "make"])

        XCTAssertEqual(config.testCommand, "make check")
        XCTAssertEqual(config.buildCommand, "make")
        XCTAssertEqual(load(["G8R_TEST_COMMAND": "make check"]).buildCommand, "local build")
        XCTAssertEqual(load(["G8R_BUILD_COMMAND": "make"]).testCommand, "local test")
        XCTAssertEqual(load(["G8R_BUILD_COMMAND": "make"]).plans, ["PLAN.md", "specs/*.md"])
    }

    func testTheEnvironmentAloneIsEnough() {
        let config = load(["G8R_BUILD_COMMAND": "make", "G8R_TEST_COMMAND": "make check", "PATH": "/usr/bin"])
        XCTAssertEqual(config, G8rConfig(buildCommand: "make", testCommand: "make check"))
    }

    func testTheLocalFileAloneStillWorks() throws {
        try write(".g8r/config.json", #"{"test_command": "npm test"}"#)
        XCTAssertEqual(load(), G8rConfig(testCommand: "npm test"))
    }

    func testANullInTheLocalFileTurnsAKeyOff() throws {
        try write("g8r.json", shared)
        try write(".g8r/config.json", #"{"test_command": null, "worktree_setup": null}"#)

        let config = load()

        XCTAssertNil(config.testCommand)
        XCTAssertNil(config.worktreeSetup)
        XCTAssertEqual(config.buildCommand, "swift build")
        XCTAssertEqual(load(["G8R_TEST_COMMAND": "make check"]).testCommand, "make check")
    }

    func testAFileThatIsNotJsonIsPassedOver() throws {
        try write("g8r.json", "{ plans: PLAN.md")
        try write(".g8r/config.json", #"["test_command", "npm test"]"#)
        XCTAssertEqual(load(), G8rConfig())

        try write(".g8r/config.json", #"{"test_command": "npm test"}"#)
        XCTAssertEqual(load().testCommand, "npm test", "one bad file doesn't take the other with it")
    }

    func testAnEmptyListOfPlansMeansNoPlans() throws {
        try write("g8r.json", #"{"plans": []}"#)
        XCTAssertEqual(load().plans, [])
    }
}
