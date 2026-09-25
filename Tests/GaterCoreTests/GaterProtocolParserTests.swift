import XCTest
@testable import GaterCore

final class GaterProtocolParserTests: XCTestCase {

    func testParsesValidDelegateMessage() throws {
        let text = """
        GATER/1
        type: delegate
        id: d-007
        feature: Auth
        directive: add session expiry
        scope: src/auth/**
        ---
        Add a 30 minute idle timeout to the session.
        """

        let result = GaterProtocol.parseDelegationMessage(text)
        let message = try result.get()

        XCTAssertEqual(message.type, .delegate)
        XCTAssertEqual(message.id, "d-007")
        XCTAssertEqual(message.feature, "Auth")
        XCTAssertEqual(message.directive, "add session expiry")
        XCTAssertEqual(message.scope, ["src/auth/**"])
        XCTAssertNil(message.mergeInto)
        XCTAssertEqual(message.body, "Add a 30 minute idle timeout to the session.")
    }

    func testParsesMultiValueScope() throws {
        let text = """
        GATER/1
        type: delegate
        id: d-008
        feature: Dashboard
        directive: user card
        scope: src/dashboard.ts, src/components/UserCard.tsx
        ---
        Build the card.
        """
        let message = try GaterProtocol.parseDelegationMessage(text).get()
        XCTAssertEqual(message.scope, ["src/dashboard.ts", "src/components/UserCard.tsx"])
    }

    func testMergeRequiresMergeInto() {
        let text = """
        GATER/1
        type: merge
        id: d-009
        feature: Auth
        ---
        """
        let result = GaterProtocol.parseDelegationMessage(text)
        XCTAssertEqual(result, .failure(.missingField("merge_into")))
    }

    func testMergeIntoRejectedOnNonMergeType() {
        let text = """
        GATER/1
        type: delegate
        id: d-010
        feature: Auth
        directive: x
        merge_into: d-001
        ---
        body
        """
        let result = GaterProtocol.parseDelegationMessage(text)
        XCTAssertEqual(result, .failure(.unexpectedField("merge_into", forType: .delegate)))
    }

    func testCancelNeedsOnlyId() throws {
        let text = """
        GATER/1
        type: cancel
        id: d-007
        ---
        """
        let message = try GaterProtocol.parseDelegationMessage(text).get()
        XCTAssertEqual(message.type, .cancel)
        XCTAssertEqual(message.body, "")
    }

    func testFinishNeedsOnlyId() throws {
        let text = """
        GATER/1
        type: finish
        id: d-007
        ---
        """
        let message = try GaterProtocol.parseDelegationMessage(text).get()
        XCTAssertEqual(message.type, .finish)
    }

    func testInstructRequiresDirective() {
        let text = """
        GATER/1
        type: instruct
        id: d-007
        feature: Auth
        ---
        Call getUser with the new signature.
        """
        let result = GaterProtocol.parseDelegationMessage(text)
        XCTAssertEqual(result, .failure(.missingField("directive")))
    }

    func testRescopeAcceptsScopeAlone() throws {
        let text = """
        GATER/1
        type: rescope
        id: d-007
        scope: src/auth/session.ts
        ---
        """
        let message = try GaterProtocol.parseDelegationMessage(text).get()
        XCTAssertEqual(message.type, .rescope)
        XCTAssertEqual(message.scope, ["src/auth/session.ts"])
    }

    func testMissingHeaderRejected() {
        let text = "type: delegate\nid: d-007\n---\nbody"
        XCTAssertEqual(GaterProtocol.parseDelegationMessage(text), .failure(.missingHeader))
    }

    func testMissingDelimiterRejected() {
        let text = "GATER/1\ntype: delegate\nid: d-007\nfeature: Auth\ndirective: x"
        XCTAssertEqual(GaterProtocol.parseDelegationMessage(text), .failure(.missingDelimiter))
    }

    func testInvalidTypeRejected() {
        let text = "GATER/1\ntype: bogus\nid: d-007\n---\nbody"
        XCTAssertEqual(GaterProtocol.parseDelegationMessage(text), .failure(.invalidType("bogus")))
    }

    func testMalformedHeaderLineRejected() {
        let text = "GATER/1\ntype delegate\nid: d-007\n---\nbody"
        XCTAssertEqual(GaterProtocol.parseDelegationMessage(text), .failure(.malformedHeaderLine("type delegate")))
    }

    func testDelegateRequiresNonEmptyBody() {
        let text = """
        GATER/1
        type: delegate
        id: d-007
        feature: Auth
        directive: x
        ---
        """
        XCTAssertEqual(GaterProtocol.parseDelegationMessage(text), .failure(.emptyBody))
    }

    func testExtractsDoneNote() throws {
        let text = """
        Some closing chatter from the model.

        GATER-DONE d-007
        did: added 30 minute idle timeout
        assumed: dashboard reads session via getUser()
        touched: src/auth/session.ts, src/auth/config.ts
        """
        let note = try XCTUnwrap(GaterProtocol.extractDoneNote(from: text))
        XCTAssertEqual(note.dishId, "d-007")
        XCTAssertEqual(note.did, "added 30 minute idle timeout")
        XCTAssertEqual(note.assumed, "dashboard reads session via getUser()")
        XCTAssertEqual(note.touched, ["src/auth/session.ts", "src/auth/config.ts"])
    }

    func testExtractDoneNoteReturnsNilWhenAbsent() {
        XCTAssertNil(GaterProtocol.extractDoneNote(from: "just a normal Stop message, nothing to see"))
    }

    func testExtractDoneNoteWithoutTouchedIsStillValid() throws {
        let text = """
        GATER-DONE d-002
        did: fixed the bug
        assumed: nothing else calls this
        """
        let note = try XCTUnwrap(GaterProtocol.extractDoneNote(from: text))
        XCTAssertEqual(note.touched, [])
    }

    /// Seen live: a summary line with the same prefix precedes the block.
    func testDoneNoteAfterSummaryLine() throws {
        let text = """
        GATER-DONE d-002: UserCard added and committed (44bb1d7 on gater/dash).

        GATER-DONE d-002
        did: Added src/dashboard/UserCard.tsx
        assumed: getUser is synchronous
        touched: src/dashboard/UserCard.tsx
        """
        let note = try XCTUnwrap(GaterProtocol.extractDoneNote(from: text))
        XCTAssertEqual(note.dishId, "d-002")
        XCTAssertEqual(note.did, "Added src/dashboard/UserCard.tsx")
        XCTAssertEqual(note.touched, ["src/dashboard/UserCard.tsx"])
    }

    func testDoneNoteHeaderWithTrailingColon() throws {
        let note = try XCTUnwrap(GaterProtocol.extractDoneNote(from: "GATER-DONE d-007:\ndid: x\nassumed: y"))
        XCTAssertEqual(note.dishId, "d-007")
    }
}
