import XCTest
@testable import G8rCore

final class MapViewerTests: XCTestCase {
    /// A map with only codemap's fields: no edge kinds, timeline or tests.
    private func codemapOnly() -> LivingMap {
        LivingMap(repo: "demo", head: "abc1234", generated: "2026-09-30T00:00:00Z",
                  docs: [PlanDocInfo(path: "PLAN.md", title: "Demo")],
                  nodes: [
                      MapNode(id: "core", name: "Core", summary: "Has </script> in it", status: .built,
                              doc: "PLAN.md", loc: 10,
                              files: [MapFile(path: "Sources/Core/A.swift", loc: 10,
                                              symbols: [MapSymbol(kind: "struct", name: "Widget")])]),
                      MapNode(id: "ui", name: "UI", summary: "", status: .planned, doc: "PLAN.md",
                              needs: ["core"], wave: 1, blockedBy: [], blast: []),
                  ],
                  edges: [MapEdge(from: "ui", to: "core", declared: true, measured: false)],
                  retired: [], problems: [])
    }

    func testPageEmbedsTheMapAndLoadsNothing() throws {
        let map = codemapOnly()
        let page = try MapViewer.page(for: map)
        XCTAssertTrue(page.contains(try MapViewer.scriptJSON(map)))
        XCTAssertTrue(page.contains("\"id\":\"core\""))
        XCTAssertFalse(page.contains("/*G8R_MAP*/null"))
        XCTAssertFalse(page.contains("http://"))
        XCTAssertFalse(page.contains("https://"))
        XCTAssertNil(page.range(of: #"(src|href)\s*=\s*["']?(https?:)?//"#, options: .regularExpression))
        // A string in the map can't end the script element.
        XCTAssertEqual(page.components(separatedBy: "</script>").count - 1,
                       try MapViewer.shell().components(separatedBy: "</script>").count - 1)
    }

    func testEmbeddedJSONDecodesBackToTheMap() throws {
        let map = codemapOnly()
        let json = try MapViewer.scriptJSON(map)
        XCTAssertEqual(try JSONDecoder().decode(LivingMap.self, from: Data(json.utf8)), map)
    }

    func testShellHasNoMap() throws {
        let shell = try MapViewer.shell()
        XCTAssertTrue(shell.contains("window.G8R_MAP = /*G8R_MAP*/null"))
        XCTAssertTrue(shell.contains("window.g8r = { setMap"))
        XCTAssertFalse(shell.contains("http://"))
        XCTAssertFalse(shell.contains("https://"))
    }

    func testSymbolLinesFindDeclarations() {
        let text = "import Foundation\n// uses Widget\nstruct Widget {\n}\nfunc make() {}\n"
        let lines = MapViewer.symbolLines(in: text, symbols: [MapSymbol(kind: "struct", name: "Widget"),
                                                               MapSymbol(kind: "function", name: "make"),
                                                               MapSymbol(kind: "class", name: "Absent")])
        XCTAssertEqual(lines, [2, 4])
    }

    func testWatchedFilesAreThePlanDocsAndConfig() {
        let files = MapViewer.watchedFiles(planRoot: "/repo", map: codemapOnly())
        XCTAssertEqual(files, ["/repo/PLAN.md", "/repo/g8r.json"])
    }
}
