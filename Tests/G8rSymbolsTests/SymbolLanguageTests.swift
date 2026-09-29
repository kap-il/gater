import XCTest
@testable import G8rSymbols

final class SymbolLanguageTests: XCTestCase {
    /// A query that doesn't compile leaves its language unreadable, and
    /// nothing says so until a file of that language is read.
    func testEveryQueryCompiles() {
        for language in SymbolLanguage.all {
            XCTAssertNotNil(language.query, "\(language.extensions.sorted())")
        }
    }

    func testNoExtensionIsReadByTwoLanguages() {
        let extensions = SymbolLanguage.all.flatMap(\.extensions)
        XCTAssertEqual(extensions.count, Set(extensions).count, "\(extensions.sorted())")
    }

    func testReadsTheExtensionsItDidBeforeTheTable() {
        for path in ["a.ts", "a.mts", "a.cts", "a.tsx", "a.js", "a.jsx", "a.mjs", "a.cjs", "A.TS"] {
            XCTAssertTrue(SymbolExtractor.supports(path: path), path)
        }
        for path in ["README.md", "a.py", "swift", "Package.resolved"] {
            XCTAssertFalse(SymbolExtractor.supports(path: path), path)
        }
    }
}
