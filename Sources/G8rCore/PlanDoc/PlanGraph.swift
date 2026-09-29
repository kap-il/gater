import Foundation

/// One component as a plan doc describes it. Nothing here is measured:
/// whether the component exists, and what it really uses, comes from the
/// code.
public struct PlanComponent: Codable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    /// Plan-root-relative path of the plan doc.
    public var doc: String
    /// 1-based line of the heading.
    public var line: Int
    public var heading: String
    /// The section's body, verbatim.
    public var text: String
    /// Where its code lives: files, directories ending in `/`, or globs.
    public var paths: [String]
    /// Ids it can't be built without.
    public var needs: [String]
    /// Ids of existing components it modifies.
    public var changes: [String]
    public var doneWhen: String?
}

/// A component a plan doc lists as gone, kept so the map can say why.
public struct RetiredComponent: Codable, Equatable {
    public var name: String
    public var why: String
    public var doc: String
    public var line: Int
}

public struct PlanDocInfo: Codable, Equatable {
    public var path: String
    public var title: String
}

/// Everything the plan docs of a repo say, in one shape, whichever reader
/// each doc went through.
public struct PlanGraph: Codable, Equatable {
    public var docs: [PlanDocInfo]
    /// Ids are unique: a second definition of an id is left out and
    /// reported in `problems`.
    public var components: [PlanComponent]
    public var retired: [RetiredComponent]
    /// Duplicate ids, needs or changes that name nothing, cycles in needs.
    public var problems: [String]

    public func component(_ id: String) -> PlanComponent? {
        components.first { $0.id == id }
    }
}
