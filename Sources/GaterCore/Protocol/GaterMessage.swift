import Foundation

public enum GaterMessageType: String, Codable, CaseIterable {
    case delegate
    case rescope
    case cancel
    case merge
    case instruct
    case finish
}

/// A parsed `GATER/1` block — the header every cross-session delegation
/// message from the orchestrator must lead with.
public struct GaterMessage: Codable, Equatable {
    public let type: GaterMessageType
    public let id: String
    public let feature: String?
    public let directive: String?
    public let scope: [String]
    public let mergeInto: String?
    public let body: String

    public init(
        type: GaterMessageType,
        id: String,
        feature: String? = nil,
        directive: String? = nil,
        scope: [String] = [],
        mergeInto: String? = nil,
        body: String = ""
    ) {
        self.type = type
        self.id = id
        self.feature = feature
        self.directive = directive
        self.scope = scope
        self.mergeInto = mergeInto
        self.body = body
    }
}

/// The `GATER-DONE` closing note a delegate sends at the end of a unit of work.
public struct GaterDoneNote: Codable, Equatable {
    public let dishId: String
    public let did: String
    public let assumed: String
    public let touched: [String]

    public init(dishId: String, did: String, assumed: String, touched: [String] = []) {
        self.dishId = dishId
        self.did = did
        self.assumed = assumed
        self.touched = touched
    }
}
