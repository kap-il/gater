import Foundation

/// The one thing the viewer reads. codemap measures the base of it; each
/// stage after that fills in fields of its own. Optional fields are left
/// out of the JSON when they are nil, so a map with only codemap's fields
/// is still a whole map.
public struct LivingMap: Codable, Equatable {
    /// The plan root's folder name.
    public var repo: String
    /// Short hash of the code root's `HEAD`; nil before the first commit.
    public var head: String?
    /// When the map was measured, ISO 8601 in UTC.
    public var generated: String
    public var docs: [PlanDocInfo]
    public var nodes: [MapNode]
    public var edges: [MapEdge]
    public var retired: [RetiredComponent]
    /// Set by timeline.
    public var timeline: [TimelinePoint]
    /// The last test run as a whole. Set by evidence.
    public var tests: TestRunSummary?
    public var problems: [String]

    public init(repo: String, head: String?, generated: String, docs: [PlanDocInfo], nodes: [MapNode],
                edges: [MapEdge], retired: [RetiredComponent], timeline: [TimelinePoint] = [],
                tests: TestRunSummary? = nil, problems: [String]) {
        self.repo = repo
        self.head = head
        self.generated = generated
        self.docs = docs
        self.nodes = nodes
        self.edges = edges
        self.retired = retired
        self.timeline = timeline
        self.tests = tests
        self.problems = problems
    }

    public func node(_ id: String) -> MapNode? {
        nodes.first { $0.id == id }
    }
}

public enum NodeStatus: String, Codable, Equatable {
    /// codemap: a plan names it and it has no code yet.
    case planned
    /// codemap: a plan names it and it has code. evidence refines this.
    case built
    /// codemap: it has code and no plan mentions it.
    case unplanned
    /// evidence
    case proven, unproven, failing
    /// clickbuild: a build session for it is open.
    case building
}

public struct MapNode: Codable, Equatable {
    /// The plan's id, or `unplanned:<directory>` for code no plan mentions.
    public var id: String
    public var name: String
    public var summary: String
    public var status: NodeStatus
    /// The plan doc it comes from; nil for unplanned code.
    public var doc: String?
    public var needs: [String]
    public var changes: [String]
    /// Where its code lives, as the plan writes it.
    public var paths: [String]
    /// Lines in its code files. Test files don't count.
    public var loc: Int
    public var files: [MapFile]
    public var section: MapSection?
    public var doneWhen: String?
    /// Nil when no test file is attributed to it.
    public var tests: NodeTests?
    /// Set by timeline.
    public var git: NodeGit?
    /// Planned nodes only. Nil for a planned node that a cycle in the plan
    /// keeps from ever being built.
    public var wave: Int?
    /// Planned nodes only: the needs that aren't built.
    public var blockedBy: [String]?
    /// Planned nodes only: the components that use what it changes.
    public var blast: [String]?
    /// Set by clickbuild.
    public var prompt: String?
    public var building: Bool?
    public var notes: [String]?

    public init(id: String, name: String, summary: String, status: NodeStatus, doc: String? = nil,
                needs: [String] = [], changes: [String] = [], paths: [String] = [], loc: Int = 0,
                files: [MapFile] = [], section: MapSection? = nil, doneWhen: String? = nil,
                tests: NodeTests? = nil, git: NodeGit? = nil, wave: Int? = nil,
                blockedBy: [String]? = nil, blast: [String]? = nil, prompt: String? = nil,
                building: Bool? = nil, notes: [String]? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.status = status
        self.doc = doc
        self.needs = needs
        self.changes = changes
        self.paths = paths
        self.loc = loc
        self.files = files
        self.section = section
        self.doneWhen = doneWhen
        self.tests = tests
        self.git = git
        self.wave = wave
        self.blockedBy = blockedBy
        self.blast = blast
        self.prompt = prompt
        self.building = building
        self.notes = notes
    }
}

public struct MapFile: Codable, Equatable {
    /// Code-root-relative.
    public var path: String
    /// Lines, for code files; 0 for anything else.
    public var loc: Int
    /// Its top-level declarations.
    public var symbols: [MapSymbol]

    public init(path: String, loc: Int, symbols: [MapSymbol]) {
        self.path = path
        self.loc = loc
        self.symbols = symbols
    }
}

public struct MapSymbol: Codable, Equatable {
    public var kind: String
    public var name: String

    public init(kind: String, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// Where a node's plan section is, and what it says.
public struct MapSection: Codable, Equatable {
    public var doc: String
    public var line: Int
    public var heading: String
    public var text: String

    public init(doc: String, line: Int, heading: String, text: String) {
        self.doc = doc
        self.line = line
        self.heading = heading
        self.text = text
    }
}

public struct NodeTests: Codable, Equatable {
    public var files: [String]
    /// Test functions in those files.
    public var count: Int
    /// Set by evidence.
    public var passed: Int?
    public var failed: Int?

    public init(files: [String], count: Int, passed: Int? = nil, failed: Int? = nil) {
        self.files = files
        self.count = count
        self.passed = passed
        self.failed = failed
    }
}

public struct NodeGit: Codable, Equatable {
    public var commits: Int
    public var first: CommitRef?
    public var last: CommitRef?

    public init(commits: Int, first: CommitRef?, last: CommitRef?) {
        self.commits = commits
        self.first = first
        self.last = last
    }
}

public struct CommitRef: Codable, Equatable {
    public var sha: String
    /// Seconds since 1970.
    public var t: Int
    public var subject: String

    public init(sha: String, t: Int, subject: String) {
        self.sha = sha
        self.t = t
        self.subject = subject
    }
}

/// One commit of the map's growth: lines per component after it.
public struct TimelinePoint: Codable, Equatable {
    public var sha: String
    public var t: Int
    public var subject: String
    public var loc: [String: Int]

    public init(sha: String, t: Int, subject: String, loc: [String: Int]) {
        self.sha = sha
        self.t = t
        self.subject = subject
        self.loc = loc
    }
}

public struct TestRunSummary: Codable, Equatable {
    public var ranAt: String
    public var command: String
    public var passed: Int
    public var failed: Int
    public var exit: Int32

    public init(ranAt: String, command: String, passed: Int, failed: Int, exit: Int32) {
        self.ranAt = ranAt
        self.command = command
        self.passed = passed
        self.failed = failed
        self.exit = exit
    }
}

public enum EdgeKind: String, Codable, Equatable {
    case planned, confirmed, unrealized, indirect, undeclared
}

/// One component using another. It runs from the component that needs to
/// the one needed.
public struct MapEdge: Codable, Equatable {
    public var from: String
    public var to: String
    /// The plan says `from` needs `to`.
    public var declared: Bool
    /// `from`'s code uses names only `to` declares.
    public var measured: Bool
    /// Those names, most used first.
    public var symbols: [String]
    /// How many times they are used, all told.
    public var refs: Int
    /// Set by drift.
    public var kind: EdgeKind?
    public var implied: Bool?

    public init(from: String, to: String, declared: Bool, measured: Bool, symbols: [String] = [],
                refs: Int = 0, kind: EdgeKind? = nil, implied: Bool? = nil) {
        self.from = from
        self.to = to
        self.declared = declared
        self.measured = measured
        self.symbols = symbols
        self.refs = refs
        self.kind = kind
        self.implied = implied
    }
}
