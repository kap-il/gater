import Foundation

/// What the map can tell about a file from its path and text alone.
public enum CodeFiles {
    /// Extensions of files that are code. Only code that no plan mentions
    /// gets a node of its own; anything else no plan mentions is left off.
    static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp",
        "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs",
        "py", "rb", "go", "rs", "java", "kt", "kts", "cs", "php", "scala", "dart",
        "ex", "exs", "lua", "zig", "sh", "bash", "zsh",
    ]

    public static func isCode(_ path: String) -> Bool {
        codeExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Code under a `Tests/`, `tests/` or `__tests__/` directory, or named
    /// the way test files are.
    public static func isTest(_ path: String) -> Bool {
        guard isCode(path) else { return false }
        let parts = path.split(separator: "/")
        if parts.dropLast().contains(where: { ["Tests", "tests", "__tests__"].contains($0) }) { return true }
        let name = String(parts.last ?? "")
        return name.hasSuffix("Tests.swift") || name.contains(".test.") || name.contains(".spec.")
            || stem(name).hasSuffix("_test") || (name.hasPrefix("test_") && name.hasSuffix(".py"))
    }

    /// The file name without its extension: `PlanGraph.swift` → `PlanGraph`.
    public static func stem(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// What a test file is named after: its stem without the test suffix.
    /// `GlobTests.swift`, `glob.test.ts`, `glob_test.go` and `test_glob.py`
    /// are all about `glob`.
    public static func testSubject(_ path: String) -> String {
        var name = stem(path)
        for suffix in [".test", ".spec", "_test", "Tests", "Test"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
            break
        }
        if name.hasPrefix("test_"), name.count > 5 { name.removeFirst(5) }
        return name
    }

    /// Lines in a text, counting a last line that has no newline.
    public static func lineCount(_ text: String) -> Int {
        var lines = 0
        var last: UInt8 = 0x0A
        for byte in text.utf8 {
            if byte == 0x0A { lines += 1 }
            last = byte
        }
        return last == 0x0A ? lines : lines + 1
    }

    /// Test functions in a test file: XCTest's `func test…`, swift-testing's
    /// `@Test`, `it(…)` and `test(…)` in JavaScript and TypeScript, and
    /// `def test…` in Python.
    public static func testCount(source: String, path: String) -> Int {
        let pattern: String
        switch (path as NSString).pathExtension.lowercased() {
        case "swift":
            // An `@Test` function is counted once, even when named `test…`.
            pattern = #"@Test\b(?:\([^)]*\))?\s+(?:\w+\s+)*func\s+\w+|\bfunc\s+test\w*\s*\("#
        case "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs":
            pattern = #"(?<![\w.])(?:it|test)(?:\.only|\.skip)?\s*\("#
        case "py":
            pattern = #"\bdef\s+test\w*\s*\("#
        default:
            pattern = #"\b(?:func|fn|def|void)\s+test\w*\s*\("#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
    }
}
