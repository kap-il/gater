import XCTest
@testable import GaterCore

final class GlobTests: XCTestCase {
    func testPatterns() {
        XCTAssertTrue(Glob.matches("src/auth/**", "src/auth/session.ts"))
        XCTAssertTrue(Glob.matches("src/auth/**", "src/auth/deep/x.ts"))
        XCTAssertFalse(Glob.matches("src/auth/**", "src/dashboard/x.ts"))
        XCTAssertTrue(Glob.matches("src/**/*.tsx", "src/dashboard/UserCard.tsx"))
        XCTAssertTrue(Glob.matches("src/**/*.tsx", "src/Top.tsx"))
        XCTAssertFalse(Glob.matches("src/*.ts", "src/a/b.ts"))
        XCTAssertTrue(Glob.matches("src/dashboard", "src/dashboard/UserCard.tsx"), "bare dir = everything under it")
        XCTAssertTrue(Glob.matches("FRUITS.md", "FRUITS.md"))
        XCTAssertFalse(Glob.isPathLike("getUser"))
        XCTAssertTrue(Glob.isPathLike("src/**"))
    }
}

final class OverlapDetectorTests: XCTestCase {
    private func delegate(_ id: String, _ feature: String, _ directive: String, to pane: String, scope: [String]) -> GaterEvent {
        GaterEvent(fields: ["kind": .string("delegation"), "ts": .string(id), "to": .string(pane),
                            "gater": .object(["type": .string("delegate"), "id": .string(id), "feature": .string(feature),
                                              "directive": .string(directive), "scope": .array(scope.map { .string($0) })])])
    }

    private func changed(_ pane: String, _ path: String, _ ids: [String]) -> GaterEvent {
        GaterEvent(fields: ["kind": .string("symbols_changed"), "pane": .string(pane), "path": .string(path),
                            "changes": .array(ids.map { .object(["id": .string($0)]) })])
    }

    private func owned(_ symbol: String, _ feature: String, _ status: String = "assigned", _ confidence: Double = 0.99) -> GaterEvent {
        GaterEvent(fields: ["kind": .string("ownership"), "symbol": .string(symbol), "feature": .string(feature),
                            "status": .string(status), "confidence": .number(confidence)])
    }

    private func refs(_ symbol: String, from: String, in pane: String, _ sites: [String]) -> GaterEvent {
        GaterEvent(fields: ["kind": .string("references"), "symbol": .string(symbol), "change": .string("signature"),
                            "from_pane": .string(from), "in_pane": .string(pane), "sites": .array(sites.map { .string($0) })])
    }

    private var plan: Plan {
        PlanReducer.replay([
            delegate("d-001", "Auth", "add session expiry", to: "delegate-auth", scope: ["src/auth/**", "src/users.ts"]),
            delegate("d-002", "Dashboard", "user card", to: "delegate-dash", scope: ["src/dashboard/**"]),
        ])
    }

    /// The golden scenario: A changes getUser, B's own new file calls it.
    func testPublicSurfaceChangeUsedInOtherAgentsCode() throws {
        var detector = OverlapDetector()
        _ = detector.apply(owned("src/users.ts#getUser", "Auth", "uncertain", 0.68), plan: plan)
        _ = detector.apply(changed("delegate-dash", "src/dashboard/UserCard.tsx", ["src/dashboard/UserCard.tsx#UserCard"]), plan: plan)

        let found = detector.apply(refs("src/users.ts#getUser", from: "delegate-auth", in: "delegate-dash",
                                        ["src/dashboard/UserCard.tsx:4"]), plan: plan)
        let overlap = try XCTUnwrap(found.first)
        XCTAssertEqual(overlap.kind, .publicSurface)
        XCTAssertEqual(overlap.feature, "Auth")
        XCTAssertEqual(overlap.panes, ["delegate-auth", "delegate-dash"])
        XCTAssertEqual(overlap.sites, ["src/dashboard/UserCard.tsx:4"])
        XCTAssertEqual(overlap.uncertain, ["src/users.ts#getUser": 0.68])

        XCTAssertTrue(detector.apply(refs("src/users.ts#getUser", from: "delegate-auth", in: "delegate-dash",
                                          ["src/dashboard/UserCard.tsx:4"]), plan: plan).isEmpty, "reported once")
        XCTAssertEqual(detector.apply(refs("src/users.ts#getUser", from: "delegate-auth", in: "delegate-dash",
                                           ["src/dashboard/UserCard.tsx:4", "src/dashboard/UserCard.tsx:9"]), plan: plan).count,
                       1, "a new use is new information")
    }

    func testUsesInCodeTheOtherAgentNeverTouchedAreIgnored() {
        var detector = OverlapDetector()
        let found = detector.apply(refs("src/users.ts#getUser", from: "delegate-auth", in: "delegate-dash",
                                        ["src/legacy/old.ts:12"]), plan: plan)
        XCTAssertTrue(found.isEmpty, "outside delegate-dash's changed files and scope")
    }

    func testUsesInsideTheOtherAgentsScopeCount() {
        var detector = OverlapDetector()
        let found = detector.apply(refs("src/users.ts#getUser", from: "delegate-auth", in: "delegate-dash",
                                        ["src/dashboard/Existing.tsx:3"]), plan: plan)
        XCTAssertEqual(found.first?.feature, "Auth", "owner unknown: the changer's feature")
    }

    func testTwoAgentsOnTheSameFeature() throws {
        var detector = OverlapDetector()
        _ = detector.apply(changed("delegate-auth", "src/auth/session.ts", ["src/auth/session.ts#isExpired"]), plan: plan)
        _ = detector.apply(changed("delegate-dash", "src/auth/badge.ts", ["src/auth/badge.ts#badge"]), plan: plan)
        XCTAssertTrue(detector.apply(owned("src/auth/session.ts#isExpired", "Auth"), plan: plan).isEmpty)
        let overlap = try XCTUnwrap(detector.apply(owned("src/auth/badge.ts#badge", "Auth"), plan: plan).first)
        XCTAssertEqual(overlap.kind, .sharedFeature)
        XCTAssertEqual(overlap.panes, ["delegate-auth", "delegate-dash"])
        XCTAssertTrue(detector.apply(owned("src/auth/badge.ts#badge", "Auth"), plan: plan).isEmpty, "reported once")
    }

    func testUncertainAndUnassignedDontMakeSharedOccupancy() {
        var detector = OverlapDetector()
        _ = detector.apply(changed("delegate-auth", "a.ts", ["a.ts#x"]), plan: plan)
        _ = detector.apply(changed("delegate-dash", "b.ts", ["b.ts#y"]), plan: plan)
        XCTAssertTrue(detector.apply(owned("a.ts#x", "unassigned"), plan: plan).isEmpty)
        XCTAssertTrue(detector.apply(owned("b.ts#y", "unassigned"), plan: plan).isEmpty)
        XCTAssertTrue(detector.apply(owned("a.ts#x", "Auth", "uncertain", 0.5), plan: plan).isEmpty)
    }

    func testReplayDoesNotReReportLoggedOverlaps() {
        var first = OverlapDetector()
        let overlap = first.apply(refs("src/users.ts#getUser", from: "delegate-auth", in: "delegate-dash",
                                       ["src/dashboard/UserCard.tsx:4"]), plan: plan)[0]
        var restarted = OverlapDetector()
        restarted.replay([overlap.event], plan: plan)
        XCTAssertTrue(restarted.apply(refs("src/users.ts#getUser", from: "delegate-auth", in: "delegate-dash",
                                           ["src/dashboard/UserCard.tsx:4"]), plan: plan).isEmpty)
    }
}

final class ReviewAndWakeTests: XCTestCase {
    private func surfaceInput() -> ReviewInput {
        let overlap = Overlap(key: "k", kind: .publicSurface, feature: "Auth", panes: ["delegate-auth", "delegate-dash"],
                              symbol: "src/users.ts#getUser", change: "signature", fromPane: "delegate-auth",
                              inPane: "delegate-dash", sites: ["src/dashboard/UserCard.tsx:4"],
                              uncertain: ["src/users.ts#getUser": 0.68])
        return ReviewInput(overlap: overlap,
                           parties: [OverlapParty(pane: "delegate-auth", dish: "d-001", directive: "add session expiry"),
                                     OverlapParty(pane: "delegate-dash", dish: "d-002", directive: "dashboard user card")],
                           oldSignature: "export function getUser(id: string): User",
                           newSignature: "export function getUser(id: string, opts: Opts): User",
                           newCode: "export function getUser(id: string, opts: Opts): User { … }",
                           siteLines: ["src/dashboard/UserCard.tsx:4:   const user = getUser(id)"])
    }

    func testVerdictRules() {
        XCTAssertTrue(ReviewVerdict(probability: 0.93, model: "m").shouldWake(), "conflict")
        XCTAssertTrue(ReviewVerdict(probability: 0.30, model: "m").shouldWake(), "unsure")
        XCTAssertFalse(ReviewVerdict(probability: 0.05, model: "m").shouldWake(), "confidently compatible")
        XCTAssertEqual(ReviewVerdict(probability: 0.05, model: "m").confidence, 0.95, accuracy: 1e-9)
    }

    /// Matches the spec §4.9 example line for line.
    func testWakeMessageFormat() {
        let text = WakeMessage.render(surfaceInput(), verdict: ReviewVerdict(probability: 0.88, model: "m"))
        XCTAssertEqual(text, """
        [GATER] overlap on Auth
        delegate-auth (d-001 "add session expiry") changed getUser(): signature export function getUser(id: string): User -> export function getUser(id: string, opts: Opts): User
        delegate-dash (d-002 "dashboard user card") calls getUser() at src/dashboard/UserCard.tsx:4 (old signature)
        Jev: conflict=yes (0.88)
        Uncertain ownership involved: src/users.ts#getUser (0.68)
        """)
    }

    func testReviewerSendsStateAndParsesNoul() throws {
        var sent: JSONValue?
        let client = JevClient(config: .init(apiKey: "k"), transport: { request in
            sent = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            return (Data(#"{"model":"jev-1.13.0","answers":{"conflict":{"type":"noul","noul":0.91}},"usage":{"input_tokens":400,"output_tokens":5}}"#.utf8), 200)
        })
        let verdict = try ConflictReviewer(client: client).reviewBlocking(surfaceInput())
        XCTAssertEqual(verdict.probability, 0.91)
        XCTAssertTrue(verdict.conflict)
        XCTAssertEqual(sent?.value(atPath: "questions.conflict.type")?.stringValue, "noul")
        XCTAssertEqual(sent?.value(atPath: "state.used_by")?.stringValue, "delegate-dash")
        XCTAssertEqual(sent?.value(atPath: "state.uses")?.arrayValue?.count, 1)
        XCTAssertEqual(sent?.value(atPath: "state.agents.delegate-auth.directive")?.stringValue, "add session expiry")
        XCTAssertEqual(verdict.event(overlap: surfaceInput().overlap)["verdict"]?.stringValue, "conflict")
    }

    func testParserFactsReachStateAndMessage() {
        var input = surfaceInput()
        input.callChecks = ["src/dashboard/UserCard.tsx:4: passes 1 argument; the new signature requires 2"]
        input.breaksCalls = true
        let state = ConflictReviewer.state(for: input, maxCode: 1000)
        XCTAssertEqual(state.value(atPath: "call_checks.some_call_breaks"), .bool(true))
        let text = WakeMessage.render(input, verdict: ReviewVerdict(probability: 0.97, model: "m"))
        XCTAssertTrue(text.contains("(old signature, now breaks: passes 1 argument; the new signature requires 2)"), text)
    }
}
