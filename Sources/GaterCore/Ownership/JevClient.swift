import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for Jev (TypeSafe AI), POST /v1/systemone — verified against the
/// live OpenAPI spec (api.typesafe.ai/openapi.json, v0.2.0):
///
///     request:  { model, state, questions: { <name>: { type, instructions, criteria } } }
///     response: { model, answers: { <name>: { type: "choice", choice, confidence,
///                                             probabilities } }, usage }
///
/// Every question in a request shares one `state`, so batching many
/// questions means putting everything they refer to into that state.
public struct JevClient {
    public struct Config: Equatable {
        public var apiKey: String
        public var baseURL: URL
        public var model: String

        public init(apiKey: String, baseURL: URL = URL(string: "https://api.typesafe.ai")!,
                    model: String = "jev-latest") {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.model = model
        }

        /// From ~/.gater/.env (JEV_API_KEY, optional JEV_BASE_URL / JEV_MODEL).
        public static func from(environment: [String: String]) -> Config? {
            guard let key = environment["JEV_API_KEY"], !key.isEmpty else { return nil }
            var config = Config(apiKey: key)
            if let base = environment["JEV_BASE_URL"].flatMap(URL.init(string:)) { config.baseURL = base }
            if let model = environment["JEV_MODEL"], !model.isEmpty { config.model = model }
            return config
        }
    }

    public struct ChoiceAnswer: Equatable {
        public var choice: String
        public var confidence: Double
        public var probabilities: [String: Double]
    }

    public struct Response: Equatable {
        public var model: String
        public var answers: [String: ChoiceAnswer]
        public var inputTokens: Int
    }

    public enum ClientError: Error, Equatable {
        case http(status: Int, body: String)
        case malformedResponse(String)
    }

    /// Sends a request; swappable so tests never touch the network.
    public typealias Transport = (URLRequest) async throws -> (Data, Int)

    public let config: Config
    private let transport: Transport

    public init(config: Config, transport: Transport? = nil) {
        self.config = config
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Asks choice questions about `state`. Question names map to answers.
    public func choose(state: JSONValue, questions: [String: (instructions: String, criteria: [String: String])]) async throws -> Response {
        var questionObjects: [String: JSONValue] = [:]
        for (name, question) in questions {
            questionObjects[name] = .object([
                "type": .string("choice"),
                "instructions": .string(question.instructions),
                "criteria": .object(question.criteria.mapValues { .string($0) }),
            ])
        }
        let json = try await send(state: state, questions: questionObjects)
        let answers = json.value(atPath: "answers")?.objectValue ?? [:]
        var parsed: [String: ChoiceAnswer] = [:]
        for (name, answer) in answers {
            guard let choice = answer.value(atPath: "choice")?.stringValue,
                  case let .number(confidence)? = answer.value(atPath: "confidence") else { continue }
            var probabilities: [String: Double] = [:]
            for (option, value) in answer.value(atPath: "probabilities")?.objectValue ?? [:] {
                if case let .number(p) = value { probabilities[option] = p }
            }
            parsed[name] = ChoiceAnswer(choice: choice, confidence: confidence, probabilities: probabilities)
        }
        return Response(model: json.value(atPath: "model")?.stringValue ?? config.model,
                        answers: parsed, inputTokens: Self.inputTokens(json))
    }

    /// A yes/no ("noul") answer: the probability of yes, 0...1.
    public struct NoulResponse: Equatable {
        public var model: String
        public var answers: [String: Double]
        public var inputTokens: Int
    }

    /// Asks yes/no questions about `state`; each answer is P(yes).
    public func noul(state: JSONValue,
                     questions: [String: (instructions: String, yes: String, no: String)]) async throws -> NoulResponse {
        var questionObjects: [String: JSONValue] = [:]
        for (name, question) in questions {
            questionObjects[name] = .object([
                "type": .string("noul"),
                "instructions": .string(question.instructions),
                "criteria": .object(["true": .string(question.yes), "false": .string(question.no)]),
            ])
        }
        let json = try await send(state: state, questions: questionObjects)
        var parsed: [String: Double] = [:]
        for (name, answer) in json.value(atPath: "answers")?.objectValue ?? [:] {
            if case let .number(p)? = answer.value(atPath: "noul") { parsed[name] = p }
        }
        return NoulResponse(model: json.value(atPath: "model")?.stringValue ?? config.model,
                            answers: parsed, inputTokens: Self.inputTokens(json))
    }

    private static func inputTokens(_ json: JSONValue) -> Int {
        if case let .number(tokens)? = json.value(atPath: "usage.input_tokens") { return Int(tokens) }
        return 0
    }

    private func send(state: JSONValue, questions: [String: JSONValue]) async throws -> JSONValue {
        let body = JSONValue.object([
            "model": .string(config.model),
            "state": state,
            "questions": .object(questions),
        ])

        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(body)

        let (data, status) = try await transport(request)
        guard status == 200 else {
            throw ClientError.http(status: status, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              json.value(atPath: "answers")?.objectValue != nil else {
            throw ClientError.malformedResponse(String(decoding: data.prefix(500), as: UTF8.self))
        }
        return json
    }
}
