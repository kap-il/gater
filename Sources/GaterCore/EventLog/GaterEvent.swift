import Foundation

/// One line of `.gater/events.jsonl`. Fields are a free-form bag rather than
/// a fixed struct because each `kind` (delegation, edit, overlap, ...) has
/// its own shape — see the event log schema in the spec.
public struct GaterEvent: Codable, Equatable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(kind: String, ts: Date = Date(), extra: [String: JSONValue] = [:]) {
        var fields = extra
        fields["kind"] = .string(kind)
        fields["ts"] = .string(ISO8601DateFormatter().string(from: ts))
        self.fields = fields
    }

    public var kind: String? { fields["kind"]?.stringValue }
    public var ts: String? { fields["ts"]?.stringValue }
    public var pane: String? { fields["pane"]?.stringValue }

    public subscript(key: String) -> JSONValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.fields = try container.decode([String: JSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}
