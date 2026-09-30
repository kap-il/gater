import XCTest
@testable import G8rTerminal

final class ProcessDirectoryTests: XCTestCase {
    private let size = PTYSize(cols: 40, rows: 5, cellWidth: 8, cellHeight: 16)

    /// Reads the folder a real child `cd`s into, as the map follows a shell.
    func testReadsAChildsWorkingDirectory() throws {
        let config = LaunchConfig(executable: "/bin/sh", arguments: ["sh", "-c", "cd /tmp && sleep 5"],
                                  environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/")
        let process = try PTYProcess(config: config, size: size)
        process.start()
        defer { process.terminate() }

        // /tmp is a symlink; the kernel reports the real folder.
        let expected = String(cString: realpath("/tmp", nil))
        let deadline = Date().addingTimeInterval(5)
        var seen: String?
        while Date() < deadline {
            seen = process.workingDirectory
            if seen == expected { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(seen, expected)
        XCTAssertEqual(ProcessDirectory.workingDirectory(of: process.pid), expected)
        XCTAssertNotNil(process.foregroundProcessGroup)
    }

    func testAMissingProcessHasNoDirectory() {
        XCTAssertNil(ProcessDirectory.workingDirectory(of: 999_999))
    }
}
