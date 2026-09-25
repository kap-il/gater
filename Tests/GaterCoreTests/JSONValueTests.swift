import XCTest
@testable import GaterCore

final class JSONValueTests: XCTestCase {
    func testDecodesHeterogeneousObject() throws {
        let json = """
        {
          "kind": "overlap",
          "node": "Auth",
          "panes": ["pane-A", "pane-B"],
          "confidence": 0.88,
          "resolved": false,
          "detail": null
        }
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: json.data(using: .utf8)!)
        guard case .object(let obj) = value else { return XCTFail("expected object") }

        XCTAssertEqual(obj["kind"]?.stringValue, "overlap")
        XCTAssertEqual(obj["panes"]?.arrayValue?.compactMap { $0.stringValue }, ["pane-A", "pane-B"])
        if case .number(let confidence) = obj["confidence"]! {
            XCTAssertEqual(confidence, 0.88, accuracy: 0.0001)
        } else {
            XCTFail("expected number")
        }
        XCTAssertEqual(obj["resolved"], .bool(false))
        XCTAssertEqual(obj["detail"], .null)
    }

    func testDottedPathLookup() throws {
        let json = #"{"tool_input": {"message": "hello"}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(value.value(atPath: "tool_input.message")?.stringValue, "hello")
        XCTAssertNil(value.value(atPath: "tool_input.missing"))
        XCTAssertNil(value.value(atPath: "nope.message"))
    }

    func testGaterEventRoundTrip() throws {
        let event = GaterEvent(kind: "edit", extra: [
            "pane": .string("pane-A"),
            "path": .string("src/auth/session.ts")
        ])
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(GaterEvent.self, from: data)
        XCTAssertEqual(decoded.kind, "edit")
        XCTAssertEqual(decoded.pane, "pane-A")
        XCTAssertEqual(decoded["path"]?.stringValue, "src/auth/session.ts")
    }
}
