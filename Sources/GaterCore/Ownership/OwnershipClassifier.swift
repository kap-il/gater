import Foundation

/// A symbol to classify, with the code Jev judges it by.
public struct OwnershipCandidate: Equatable {
    public var id: String
    public var path: String
    public var name: String
    public var kind: String
    public var code: String

    public init(id: String, path: String, name: String, kind: String, code: String) {
        self.id = id
        self.path = path
        self.name = name
        self.kind = kind
        self.code = code
    }
}

public struct OwnershipDecision: Equatable {
    public enum Status: String, Equatable {
        /// confidence ≥ threshold
        case assigned
        /// below threshold: dashed on the map, re-classified as work continues
        case uncertain
    }

    public var symbolId: String
    public var feature: String
    public var confidence: Double
    public var status: Status
    public var probabilities: [String: Double]

    /// The `ownership` log event (spec §4.4).
    public func event(model: String) -> GaterEvent {
        GaterEvent(kind: "ownership", extra: [
            "symbol": .string(symbolId),
            "feature": .string(feature),
            "confidence": .number(confidence),
            "status": .string(status.rawValue),
            "probabilities": .object(probabilities.mapValues { .number($0) }),
            "model": .string(model),
        ])
    }
}

/// Decides which feature each symbol *implements* (spec §4.7). This is the
/// judgment half of ownership; which features code *uses* is deterministic
/// and comes from LSP instead.
public struct OwnershipClassifier {
    public static let unassigned = "unassigned"
    public static let defaultThreshold = 0.88

    public var client: JevClient
    public var threshold: Double
    /// Symbols per request, and the code cap per symbol. Jev's input limit,
    /// measured 2026-09-25: 27k tokens accepted, 55k rejected
    /// (`max_tokens_exceeded`) — likely 32k. Defaults stay near 16k; a batch
    /// that still overflows is split and retried.
    public var batchSize: Int
    public var maxCodeCharacters: Int

    public init(client: JevClient, threshold: Double = defaultThreshold,
                batchSize: Int = 20, maxCodeCharacters: Int = 3000) {
        self.client = client
        self.threshold = threshold
        self.batchSize = batchSize
        self.maxCodeCharacters = maxCodeCharacters
    }

    /// Choice options: each live feature described by its dishes' directives
    /// (what the orchestrator asked for), plus `unassigned`.
    public static func options(from plan: Plan) -> [String: String] {
        var options: [String: String] = [:]
        for feature in plan.jevOptions where feature != unassigned {
            let directives = plan.dishes
                .filter { $0.feature == feature && $0.state.isActive }
                .map(\.directive)
                .filter { !$0.isEmpty }
            options[feature] = directives.isEmpty ? feature : directives.joined(separator: "; ")
        }
        options[unassigned] = "Implements none of the listed features: shared utilities, pre-existing code, or unclear."
        return options
    }

    /// Classifies `candidates` against the plan. Returns no decisions when
    /// the plan has no features yet (nothing to choose between).
    public func classify(_ candidates: [OwnershipCandidate], plan: Plan) async throws -> (decisions: [OwnershipDecision], model: String) {
        let options = Self.options(from: plan)
        guard options.count > 1, !candidates.isEmpty else { return ([], client.config.model) }

        var decisions: [OwnershipDecision] = []
        var model = client.config.model
        for start in stride(from: 0, to: candidates.count, by: batchSize) {
            let batch = Array(candidates[start..<min(start + batchSize, candidates.count)])
            let (batchDecisions, batchModel) = try await classifyBatch(batch, options: options)
            decisions += batchDecisions
            model = batchModel
        }
        return (decisions, model)
    }

    private func classifyBatch(_ batch: [OwnershipCandidate], options: [String: String]) async throws -> ([OwnershipDecision], String) {
        // One shared state holds every symbol; each question names its own.
        var symbols: [String: JSONValue] = [:]
        var questions: [String: (instructions: String, criteria: [String: String])] = [:]
        for (index, candidate) in batch.enumerated() {
            let key = "s\(index + 1)"
            symbols[key] = .object([
                "path": .string(candidate.path),
                "name": .string(candidate.name),
                "kind": .string(candidate.kind),
                "code": .string(String(candidate.code.prefix(maxCodeCharacters))),
            ])
            questions[key] = ("Which feature does symbol \(key) (\(candidate.name) in \(candidate.path)) implement?", options)
        }
        let state = JSONValue.object([
            "features": .object(options.filter { $0.key != Self.unassigned }.mapValues { .string($0) }),
            "symbols": .object(symbols),
        ])

        let response: JevClient.Response
        do {
            response = try await client.choose(state: state, questions: questions)
        } catch let JevClient.ClientError.http(status, body) where status == 400 && body.contains("max_tokens_exceeded") {
            // Too big for one request: halve it. A single symbol that alone
            // overflows is re-sent with its code cut down.
            if batch.count > 1 {
                let middle = batch.count / 2
                let (a, modelA) = try await classifyBatch(Array(batch[..<middle]), options: options)
                let (b, _) = try await classifyBatch(Array(batch[middle...]), options: options)
                return (a + b, modelA)
            }
            guard batch[0].code.count > 500 else { throw JevClient.ClientError.http(status: status, body: body) }
            var smaller = batch[0]
            smaller.code = String(smaller.code.prefix(min(smaller.code.count, maxCodeCharacters) / 4))
            return try await classifyBatch([smaller], options: options)
        }
        var decisions: [OwnershipDecision] = []
        for (index, candidate) in batch.enumerated() {
            guard let answer = response.answers["s\(index + 1)"] else { continue }
            decisions.append(OwnershipDecision(
                symbolId: candidate.id,
                feature: answer.choice,
                confidence: answer.confidence,
                status: answer.confidence >= threshold ? .assigned : .uncertain,
                probabilities: answer.probabilities))
        }
        return (decisions, response.model)
    }
}

extension OwnershipClassifier {
    /// Blocking variant for callers on their own serial background queue
    /// (the app's symbol queue): keeps classification ordered with parsing
    /// and avoids mixing GCD state with async captures. Never call it on
    /// the main thread.
    public func classifyBlocking(_ candidates: [OwnershipCandidate], plan: Plan) throws -> (decisions: [OwnershipDecision], model: String) {
        final class Box: @unchecked Sendable {
            var result: Result<(decisions: [OwnershipDecision], model: String), Error>?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let classifier = self
        Task.detached {
            do { box.result = .success(try await classifier.classify(candidates, plan: plan)) }
            catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}
