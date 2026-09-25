import Foundation

/// Parses and validates the `GATER/1` delegation format and the
/// `GATER-DONE` closing-note format (spec §4.3). This is format enforcement
/// only — it never decides whether a delegation *should* happen.
public enum GaterProtocol {
    private static let knownHeaderKeys: Set<String> = [
        "type", "id", "feature", "directive", "scope", "merge_into"
    ]

    /// Human-readable block used in PreToolUse stderr so Claude can retry
    /// in the right format.
    public static let expectedFormatHelp = """
    GATER/1
    type: delegate | rescope | cancel | merge | instruct | finish
    id: <dish id, e.g. d-007>
    feature: <feature name>
    directive: <one line: what is being asked>
    scope: <comma-separated paths/globs or symbols>
    merge_into: <dish id>          # only for type=merge
    ---
    <free-form instructions to the delegate>
    """

    public static func parseDelegationMessage(_ text: String) -> Result<GaterMessage, GaterProtocolError> {
        var lines = text.components(separatedBy: "\n")

        // Drop leading blank lines so a message with incidental leading
        // whitespace isn't rejected for something cosmetic.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let headerLine = lines.first,
              headerLine.trimmingCharacters(in: .whitespaces) == "GATER/1" else {
            return .failure(.missingHeader)
        }
        lines.removeFirst()

        var fields: [String: String] = [:]
        var delimiterFound = false
        var bodyLines: [String] = []

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                delimiterFound = true
                index += 1
                break
            }
            if trimmed.isEmpty {
                index += 1
                continue
            }
            guard let colonIndex = line.firstIndex(of: ":") else {
                return .failure(.malformedHeaderLine(line))
            }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
            index += 1
        }

        guard delimiterFound else {
            return .failure(.missingDelimiter)
        }
        bodyLines = Array(lines[index...])
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        guard let typeRaw = fields["type"] else {
            return .failure(.missingField("type"))
        }
        guard let type = GaterMessageType(rawValue: typeRaw) else {
            return .failure(.invalidType(typeRaw))
        }
        guard let id = fields["id"], !id.isEmpty else {
            return .failure(.missingField("id"))
        }

        let feature = fields["feature"]
        let directive = fields["directive"]
        let scope = (fields["scope"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let mergeInto = fields["merge_into"]

        if let mergeInto, !mergeInto.isEmpty, type != .merge {
            return .failure(.unexpectedField("merge_into", forType: type))
        }

        switch type {
        case .delegate:
            guard let feature, !feature.isEmpty else { return .failure(.missingField("feature")) }
            guard let directive, !directive.isEmpty else { return .failure(.missingField("directive")) }
            guard !body.isEmpty else { return .failure(.emptyBody) }
        case .rescope:
            let hasDirective = !(directive ?? "").isEmpty
            let hasScope = !scope.isEmpty
            guard hasDirective || hasScope else { return .failure(.missingField("directive or scope")) }
        case .merge:
            guard let mergeInto, !mergeInto.isEmpty else { return .failure(.missingField("merge_into")) }
        case .instruct:
            guard let directive, !directive.isEmpty else { return .failure(.missingField("directive")) }
        case .cancel, .finish:
            break
        }

        let message = GaterMessage(
            type: type,
            id: id,
            feature: feature,
            directive: directive,
            scope: scope,
            mergeInto: mergeInto,
            body: body
        )
        return .success(message)
    }

    /// Scans free text for a `GATER-DONE <id>` block. Returns `nil` (not an
    /// error) when the text doesn't contain one, since not every `Stop`
    /// event ends a unit of work.
    /// Finds a GATER-DONE block in free text. Delegates often lead with a
    /// summary line like `GATER-DONE d-002: UserCard added` before the real
    /// block (seen live), so every `GATER-DONE <id>` line is tried and the
    /// first one followed by `did:` / `assumed:` fields wins.
    public static func extractDoneNote(from text: String) -> GaterDoneNote? {
        let lines = text.components(separatedBy: "\n")
        for (headerIndex, rawHeader) in lines.enumerated() {
            let headerLine = rawHeader.trimmingCharacters(in: .whitespaces)
            guard headerLine.hasPrefix("GATER-DONE ") else { continue }
            // The id is the first token, minus trailing punctuation.
            let dishId = headerLine.dropFirst("GATER-DONE ".count)
                .split(separator: " ").first.map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: ":.,;"))
                ?? ""
            guard !dishId.isEmpty else { continue }

            var fields: [String: String] = [:]
            for line in lines[(headerIndex + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { break }
                guard let colonIndex = line.firstIndex(of: ":") else { break }
                let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                fields[key] = value
            }

            guard let did = fields["did"], let assumed = fields["assumed"] else { continue }
            let touched = (fields["touched"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return GaterDoneNote(dishId: dishId, did: did, assumed: assumed, touched: touched)
        }
        return nil
    }
}
