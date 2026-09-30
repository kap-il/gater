import XCTest
@testable import G8rCore

final class ChangeRequestTests: XCTestCase {
    private func map(files: Int = 3, section: String = "The map viewer page.\n\nIt draws nodes.") -> LivingMap {
        LivingMap(repo: "demo", head: nil, generated: "", docs: [], nodes: [
            MapNode(id: "graphview", name: "Graph view", summary: "Draws the map.", status: .proven,
                    doc: "PLAN.md", needs: ["codemap"], paths: ["Sources/Viewer/"],
                    files: (0..<files).map { MapFile(path: "Sources/Viewer/F\($0).swift", loc: 10, symbols: []) },
                    section: MapSection(doc: "PLAN.md", line: 853, heading: "graphview: Graph view", text: section),
                    doneWhen: "the page renders every node."),
            MapNode(id: "codemap", name: "Code map", summary: "", status: .built),
            MapNode(id: "evidence", name: "Evidence", summary: "", status: .built),
            MapNode(id: "clickbuild", name: "Click to build", summary: "", status: .planned),
        ], edges: [
            MapEdge(from: "graphview", to: "codemap", declared: true, measured: true),
            MapEdge(from: "graphview", to: "evidence", declared: false, measured: true),
            MapEdge(from: "clickbuild", to: "graphview", declared: true, measured: false),
        ], retired: [], problems: [])
    }

    func testTheUsersWordsComeFirstThenTheNode() {
        let prompt = ChangeRequest.prompt(for: "graphview", in: map(), text: "  yo fix the header, it looks weird\n")
        XCTAssertTrue(prompt.hasPrefix("yo fix the header, it looks weird\n\n"), prompt)
        XCTAssertTrue(prompt.contains("`graphview` component (Graph view)"))
        XCTAssertTrue(prompt.contains("PLAN.md:853, \"graphview: Graph view\""))
        XCTAssertTrue(prompt.contains("It draws nodes."))
        XCTAssertTrue(prompt.contains("Done when: the page renders every node."))
        XCTAssertTrue(prompt.contains("- Sources/Viewer/F0.swift\n- Sources/Viewer/F1.swift"))
        XCTAssertTrue(prompt.contains("It needs `codemap` (Code map), `evidence` (Evidence)."), prompt)
        XCTAssertTrue(prompt.contains("Needed by `clickbuild` (Click to build)."))
        XCTAssertTrue(prompt.contains("Keep the change inside those files where you can."))
        XCTAssertTrue(prompt.contains("say which one and why"))
        XCTAssertFalse(prompt.contains("```"), "no dumps")
    }

    func testLongSectionsAndFileListsAreCapped() {
        let long = (1...200).map { "Line \($0) of a very long plan section." }.joined(separator: "\n")
        let prompt = ChangeRequest.prompt(for: "graphview", in: map(files: 40, section: long), text: "fix it")
        XCTAssertTrue(prompt.contains("Line 1 of"))
        XCTAssertFalse(prompt.contains("Line 200 of"))
        XCTAssertTrue(prompt.contains(" …"))
        XCTAssertTrue(prompt.contains("F11.swift"))
        XCTAssertFalse(prompt.contains("F12.swift"))
        XCTAssertTrue(prompt.contains("- and 28 more"))
        XCTAssertLessThan(prompt.count, 2600)
    }

    func testNothingToSendWithoutTextOrNode() {
        XCTAssertEqual(ChangeRequest.prompt(for: "graphview", in: map(), text: "  \n"), "")
        XCTAssertEqual(ChangeRequest.prompt(for: "nope", in: map(), text: "fix"), "")
    }

    func testOnlyNodesWithCodeTakeChanges() {
        for status: NodeStatus in [.built, .proven, .unproven, .failing, .unplanned] {
            XCTAssertTrue(ChangeRequest.accepts(status), status.rawValue)
        }
        XCTAssertFalse(ChangeRequest.accepts(.planned))
        XCTAssertFalse(ChangeRequest.accepts(.building))
    }

    func testTrimCutsAtALineBreak() {
        XCTAssertEqual(ChangeRequest.trimmed("short", to: 10), "short")
        XCTAssertEqual(ChangeRequest.trimmed("aaaa bbbb\ncccc dddd", to: 14), "aaaa bbbb …")
    }

    func testStatusLineSaysQueuedWhenBusy() {
        XCTAssertEqual(ChangeRequest.sent(to: .claudeCode, pane: "shell-1", queued: false), "Sent to claude in shell-1.")
        XCTAssertTrue(ChangeRequest.sent(to: .codex, pane: "shell-2", queued: true).hasPrefix("Queued for codex in shell-2"))
    }
}
