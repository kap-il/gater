import XCTest
@testable import GaterCore

final class OwnershipTests: XCTestCase {
    private func plan() -> Plan {
        func delegate(_ id: String, _ feature: String, _ directive: String) -> GaterEvent {
            GaterEvent(fields: ["kind": .string("delegation"), "ts": .string(id),
                                "gater": .object(["type": .string("delegate"), "id": .string(id),
                                                  "feature": .string(feature), "directive": .string(directive),
                                                  "scope": .array([])])])
        }
        return PlanReducer.replay([delegate("d-001", "Auth", "add session expiry"),
                                   delegate("d-002", "Dashboard", "user card"),
                                   delegate("d-003", "Auth", "refresh tokens")])
    }

    /// Records requests and replies with canned answers.
    private final class FakeJev {
        var requests: [JSONValue] = []
        var reply: (JSONValue) -> JSONValue

        init(reply: @escaping (JSONValue) -> JSONValue) { self.reply = reply }

        lazy var transport: JevClient.Transport = { [unowned self] request in
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            self.requests.append(body)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
            return (try JSONEncoder().encode(self.reply(body)), 200)
        }
    }

    private func answer(_ choice: String, _ confidence: Double) -> JSONValue {
        .object(["type": .string("choice"), "choice": .string(choice), "confidence": .number(confidence),
                 "probabilities": .object([choice: .number(confidence)])])
    }

    private func candidate(_ name: String) -> OwnershipCandidate {
        OwnershipCandidate(id: "src/x.ts#\(name)", path: "src/x.ts", name: name, kind: "function", code: "function \(name)() {}")
    }

    func testOptionsComeFromLiveFeaturesAndDirectives() {
        let options = OwnershipClassifier.options(from: plan())
        XCTAssertEqual(options["Auth"], "add session expiry; refresh tokens")
        XCTAssertEqual(options["Dashboard"], "user card")
        XCTAssertNotNil(options["unassigned"])
        XCTAssertEqual(options.count, 3)
    }

    func testBatchedRequestShapeAndThreshold() async throws {
        let fake = FakeJev { _ in
            .object(["model": .string("jev-1.13.0"),
                     "answers": .object(["s1": self.answer("Auth", 0.95), "s2": self.answer("Dashboard", 0.61)]),
                     "usage": .object(["input_tokens": .number(700), "output_tokens": .number(90)])])
        }
        let client = JevClient(config: .init(apiKey: "test-key"), transport: fake.transport)
        let result = try await OwnershipClassifier(client: client)
            .classify([candidate("isSessionExpired"), candidate("UserCard")], plan: plan())

        XCTAssertEqual(result.model, "jev-1.13.0")
        XCTAssertEqual(result.decisions.map(\.status), [.assigned, .uncertain], "0.88 threshold")
        XCTAssertEqual(result.decisions.map(\.symbolId), ["src/x.ts#isSessionExpired", "src/x.ts#UserCard"])

        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.value(atPath: "model")?.stringValue, "jev-latest")
        XCTAssertEqual(request.value(atPath: "state.symbols.s1.name")?.stringValue, "isSessionExpired")
        XCTAssertEqual(request.value(atPath: "questions.s2.type")?.stringValue, "choice")
        XCTAssertEqual(request.value(atPath: "questions.s2.criteria")?.objectValue?.keys.sorted(),
                       ["Auth", "Dashboard", "unassigned"])
        XCTAssertNil(request.value(atPath: "state.features.unassigned"))

        let event = result.decisions[0].event(model: result.model)
        XCTAssertEqual(event.kind, "ownership")
        XCTAssertEqual(event["feature"]?.stringValue, "Auth")
    }

    func testBatchesLargeSetsAndCapsCode() async throws {
        let fake = FakeJev { body in
            let names = body.value(atPath: "questions")?.objectValue?.keys.sorted() ?? []
            return .object(["model": .string("m"), "usage": .object([:]),
                            "answers": .object(Dictionary(uniqueKeysWithValues: names.map { ($0, self.answer("unassigned", 0.9)) }))])
        }
        var big = candidate("huge")
        big.code = String(repeating: "x", count: 10_000)
        let client = JevClient(config: .init(apiKey: "test-key"), transport: fake.transport)
        let classifier = OwnershipClassifier(client: client, batchSize: 2, maxCodeCharacters: 100)
        let result = try await classifier.classify([candidate("a"), candidate("b"), big], plan: plan())
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertEqual(result.decisions.count, 3)
        XCTAssertEqual(fake.requests[1].value(atPath: "state.symbols.s1.code")?.stringValue?.count, 100)
    }

    func testNoFeaturesMeansNoCall() async throws {
        let fake = FakeJev { _ in .null }
        let client = JevClient(config: .init(apiKey: "test-key"), transport: fake.transport)
        let result = try await OwnershipClassifier(client: client).classify([candidate("a")], plan: Plan())
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testHTTPErrorsSurface() async {
        let client = JevClient(config: .init(apiKey: "test-key"), transport: { _ in (Data("nope".utf8), 401) })
        do {
            _ = try await OwnershipClassifier(client: client).classify([candidate("a")], plan: plan())
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? JevClient.ClientError, .http(status: 401, body: "nope"))
        }
    }

    func testConfigFromEnvironment() {
        XCTAssertNil(JevClient.Config.from(environment: [:]))
        let config = JevClient.Config.from(environment: ["JEV_API_KEY": "k", "JEV_MODEL": "jev-preview"])
        XCTAssertEqual(config?.model, "jev-preview")
        XCTAssertEqual(config?.baseURL.absoluteString, "https://api.typesafe.ai")
    }

    func testOversizedBatchIsSplitAndRetried() async throws {
        let fake = FakeJev { body in
            let names = body.value(atPath: "questions")?.objectValue?.keys.sorted() ?? []
            return .object(["model": .string("m"), "usage": .object([:]),
                            "answers": .object(Dictionary(uniqueKeysWithValues: names.map { ($0, self.answer("Auth", 0.99)) }))])
        }
        var calls = 0
        let client = JevClient(config: .init(apiKey: "test-key"), transport: { request in
            calls += 1
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            if (body.value(atPath: "questions")?.objectValue?.count ?? 0) > 2 {
                return (Data(#"{"detail":{"error_type":"max_tokens_exceeded"}}"#.utf8), 400)
            }
            return try await fake.transport(request)
        })
        let result = try await OwnershipClassifier(client: client)
            .classify((1...4).map { candidate("f\($0)") }, plan: plan())
        XCTAssertEqual(result.decisions.count, 4)
        XCTAssertEqual(calls, 3, "one rejected request of 4, then two of 2")
    }
}
