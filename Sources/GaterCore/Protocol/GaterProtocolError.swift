import Foundation

public enum GaterProtocolError: Error, Equatable, CustomStringConvertible {
    case missingHeader
    case missingDelimiter
    case malformedHeaderLine(String)
    case missingField(String)
    case invalidType(String)
    case unexpectedField(String, forType: GaterMessageType)
    case emptyBody

    public var description: String {
        switch self {
        case .missingHeader:
            return "message must start with the line 'GATER/1'"
        case .missingDelimiter:
            return "message is missing the '---' delimiter separating the header from the body"
        case .malformedHeaderLine(let line):
            return "header line is not 'key: value': \(line)"
        case .missingField(let field):
            return "missing required field '\(field)'"
        case .invalidType(let value):
            return "invalid type '\(value)', must be one of: \(GaterMessageType.allCases.map(\.rawValue).joined(separator: ", "))"
        case .unexpectedField(let field, let type):
            return "field '\(field)' is not valid for type '\(type.rawValue)'"
        case .emptyBody:
            return "type 'delegate' requires free-form instructions after the '---' delimiter"
        }
    }
}
