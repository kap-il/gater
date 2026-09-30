import Foundation
import XCTest
@testable import G8rCore

final class StartupBannerTests: XCTestCase {
    func testFramesFitAPane() {
        for frame in StartupBanner.frames {
            XCTAssertLessThanOrEqual(frame.count, StartupBanner.maxHeight)
            for line in frame { XCTAssertLessThanOrEqual(line.count, StartupBanner.maxWidth, line) }
        }
    }

    func testFramesShareHeight() {
        let frames = StartupBanner.frames
        XCTAssertGreaterThanOrEqual(frames.count, 3)
        XCTAssertEqual(Set(frames.map(\.count)).count, 1)
    }

    func testFinalFrameWearsGlasses() {
        let last = StartupBanner.frames.last!.joined(separator: "\n")
        XCTAssertTrue(last.contains(StartupBanner.glassesOn))
        XCTAssertTrue(last.contains(StartupBanner.tagline))
        XCTAssertFalse(last.contains(StartupBanner.eyes))
        XCTAssertTrue(StartupBanner.frames.first!.joined().contains(StartupBanner.eyes))
    }

    private func run(_ args: [String], env: [String: String] = [:]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testScriptIsValidSh() throws {
        XCTAssertEqual(try run(["-n", "-c", StartupBanner.script]).0, 0)
        // Spliced the way LaunchConfig.loginShell does.
        XCTAssertEqual(try run(["-n", "-c", StartupBanner.command + "; exec /bin/sh -l"]).0, 0)
    }

    func testScriptPlaysAndResets() throws {
        let (status, out) = try run(["-c", StartupBanner.command], env: ["G8R_BANNER_DELAY": "0.01"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains(StartupBanner.tagline))
        XCTAssertTrue(out.contains("[*]=[#]"))
        XCTAssertTrue(out.hasSuffix("\u{1B}[0m\u{1B}[?25h\n"))
    }

    func testNoBannerSkips() throws {
        let (status, out) = try run(["-c", StartupBanner.command], env: ["G8R_NO_BANNER": "1"])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, "")
    }
}
