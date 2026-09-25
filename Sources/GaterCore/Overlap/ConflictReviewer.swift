import Foundation

/// One side of an overlap: the pane and what the orchestrator asked of it.
public struct OverlapParty: Equatable {
    public var pane: String
    public var dish: String?
    public var directive: String?

    public init(pane: String, dish: String?, directive: String?) {
        self.pane = pane
        self.dish = dish
        self.directive = directive
    }

    /// `delegate-auth (d-001 "add session expiry")`
    public var label: String {
        guard let dish else { return pane }
        return directive.map { "\(pane) (\(dish) \"\($0)\")" } ?? "\(pane) (\(dish))"
    }
}

/// Everything the review question and the wake message are built from.
public struct ReviewInput: Equatable {
    public var overlap: Overlap
    public var parties: [OverlapParty]
    /// publicSurface: the symbol's signature in the user's copy and the
    /// changer's copy, the changed code, and the using lines.
    public var oldSignature: String?
    public var newSignature: String?
    public var newCode: String?
    /// `path:line: code`
    public var siteLines: [String]
    /// sharedFeature: code each pane changed in the shared feature.
    public var changesByPane: [String: [String]]

    public init(overlap: Overlap, parties: [OverlapParty], oldSignature: String? = nil, newSignature: String? = nil,
                newCode: String? = nil, siteLines: [String] = [], changesByPane: [String: [String]] = [:]) {
        self.overlap = overlap
        self.parties = parties
        self.oldSignature = oldSignature
        self.newSignature = newSignature
        self.newCode = newCode
        self.siteLines = siteLines
        self.changesByPane = changesByPane
    }

    func party(_ pane: String?) -> OverlapParty? {
        parties.first { $0.pane == pane }
    }
}

public struct ReviewVerdict: Equatable {
    /// Jev's P(conflict).
    public var probability: Double
    public var model: String

    public var conflict: Bool { probability >= 0.5 }
    public var confidence: Double { max(probability, 1 - probability) }

    /// Spec §4.9: wake if Jev says conflict, or isn't confident either way.
    public func shouldWake(threshold: Double = OwnershipClassifier.defaultThreshold) -> Bool {
        conflict || confidence < threshold
    }

    /// The `review` log event.
    public func event(overlap: Overlap) -> GaterEvent {
        GaterEvent(kind: "review", extra: [
            "overlap_id": .string(overlap.key),
            "verdict": .string(conflict ? "conflict" : "compatible"),
            "confidence": .number(confidence),
            "p_conflict": .number(probability),
            "model": .string(model),
        ])
    }
}

/// Asks Jev whether overlapping changes conflict (spec §4.9 step 2).
public struct ConflictReviewer {
    public var client: JevClient
    public var maxCodeCharacters: Int

    public init(client: JevClient, maxCodeCharacters: Int = 4000) {
        self.client = client
        self.maxCodeCharacters = maxCodeCharacters
    }

    static let question = (
        instructions: "Do these two agents' changes conflict?",
        yes: "They conflict: one agent's change breaks or contradicts the other's code or goal (for example a call site written against a signature that has since changed), so one of them must adapt.",
        no: "They are compatible: the code still works together and the goals don't contradict."
    )

    static func state(for input: ReviewInput, maxCode: Int) -> JSONValue {
        var agents: [String: JSONValue] = [:]
        for party in input.parties {
            agents[party.pane] = .object([
                "dish": party.dish.map { .string($0) } ?? .null,
                "directive": party.directive.map { .string($0) } ?? .null,
            ])
        }
        var state: [String: JSONValue] = [
            "overlap": .string(input.overlap.kind == .publicSurface
                ? "One agent changed the public surface of a symbol that the other agent's code uses."
                : "Both agents are changing code that implements the same feature."),
            "feature": .string(input.overlap.feature),
            "agents": .object(agents),
        ]
        if input.overlap.kind == .publicSurface {
            state["changed_by"] = input.overlap.fromPane.map { .string($0) } ?? .null
            state["used_by"] = input.overlap.inPane.map { .string($0) } ?? .null
            state["symbol"] = input.overlap.symbol.map { .string($0) } ?? .null
            state["change"] = input.overlap.change.map { .string($0) } ?? .null
            state["signature_before"] = input.oldSignature.map { .string($0) } ?? .null
            state["signature_after"] = input.newSignature.map { .string($0) } ?? .null
            state["changed_code"] = input.newCode.map { .string(String($0.prefix(maxCode))) } ?? .null
            state["uses"] = .array(input.siteLines.map { .string($0) })
        } else {
            state["changes"] = .object(input.changesByPane.mapValues { snippets in
                .array(snippets.map { .string(String($0.prefix(maxCode / max(snippets.count, 1)))) })
            })
        }
        return .object(state)
    }

    public func review(_ input: ReviewInput) async throws -> ReviewVerdict {
        let q = Self.question
        let response = try await client.noul(
            state: Self.state(for: input, maxCode: maxCodeCharacters),
            questions: ["conflict": (q.instructions, q.yes, q.no)])
        guard let p = response.answers["conflict"] else {
            throw JevClient.ClientError.malformedResponse("no answer for conflict")
        }
        return ReviewVerdict(probability: p, model: response.model)
    }

    /// For callers on their own serial background queue (see
    /// OwnershipClassifier.classifyBlocking).
    public func reviewBlocking(_ input: ReviewInput) throws -> ReviewVerdict {
        final class Box: @unchecked Sendable { var result: Result<ReviewVerdict, Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let reviewer = self
        Task.detached {
            do { box.result = .success(try await reviewer.review(input)) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

/// The terse, structured message injected into the orchestrator's pane
/// (spec §4.9 step 3). Only overlaps wake it, to keep its context lean.
public enum WakeMessage {
    public static func render(_ input: ReviewInput, verdict: ReviewVerdict?) -> String {
        let overlap = input.overlap
        var lines = ["[GATER] overlap on \(overlap.feature)"]

        switch overlap.kind {
        case .publicSurface:
            let symbol = overlap.symbol.map(shortName) ?? "?"
            let from = input.party(overlap.fromPane)?.label ?? overlap.fromPane ?? "?"
            let user = input.party(overlap.inPane)?.label ?? overlap.inPane ?? "?"
            var changed = "\(from) changed \(symbol): \(overlap.change ?? "signature")"
            if let before = input.oldSignature, let after = input.newSignature {
                changed += " \(clip(before)) -> \(clip(after))"
            }
            lines.append(changed)
            lines.append("\(user) calls \(symbol) at \(overlap.sites.joined(separator: ", ")) (old signature)")
        case .sharedFeature:
            let labels = overlap.panes.map { input.party($0)?.label ?? $0 }
            lines.append("\(labels.joined(separator: " and ")) are both changing \(overlap.feature) code")
        }

        if let verdict {
            lines.append(String(format: "Jev: conflict=%@ (%.2f)", verdict.conflict ? "yes" : "no", verdict.confidence))
        } else {
            lines.append("Jev: review unavailable")
        }
        if !overlap.uncertain.isEmpty {
            let list = overlap.uncertain.sorted { $0.key < $1.key }
                .map { String(format: "%@ (%.2f)", $0.key, $0.value) }
            lines.append("Uncertain ownership involved: \(list.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// `src/users.ts#getUser` → `getUser()`
    static func shortName(_ id: String) -> String {
        let name = id.split(separator: "#").last.map(String.init) ?? id
        return name + "()"
    }

    static func clip(_ s: String, limit: Int = 120) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }
}
