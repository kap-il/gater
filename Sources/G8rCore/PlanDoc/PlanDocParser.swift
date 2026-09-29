import Foundation

/// Reads a doc written in the plan doc format (PLAN.md, "Plan doc format").
/// No model is involved: the same text always gives the same components.
public enum PlanDocParser {
    public static func parse(text: String, doc: String)
        -> (title: String, components: [PlanComponent], retired: [RetiredComponent]) {
        let outline = PlanDocOutline(text)
        var components: [PlanComponent] = []
        var retired: [RetiredComponent] = []
        var retiredLevel: Int?

        for (position, heading) in outline.headings.enumerated() {
            if let level = retiredLevel, heading.level <= level { retiredLevel = nil }
            if heading.text.lowercased() == "retired" {
                retiredLevel = heading.level
                continue
            }
            if retiredLevel != nil {
                retired.append(RetiredComponent(name: heading.text, why: collapsed(outline.body(position)),
                                                doc: doc, line: heading.index + 1))
                continue
            }
            guard let named = identity(of: heading) else { continue }

            let own = ownLines(of: position, in: outline)
            let bullets = fields(in: own, of: outline)
            components.append(PlanComponent(
                id: named.id, name: named.name,
                summary: summary(in: own, of: outline),
                doc: doc, line: heading.index + 1, heading: heading.text,
                text: outline.body(position),
                paths: items(bullets["code"]), needs: items(bullets["needs"]), changes: items(bullets["changes"]),
                doneWhen: bullets["done when"].flatMap { $0.isEmpty ? nil : $0 }))
        }
        return (outline.title ?? doc, components, retired)
    }

    /// The id and name of a component heading: level 2 to 4, `<id>: <Name>`.
    private static func identity(of heading: PlanDocOutline.Heading) -> (id: String, name: String)? {
        guard (2...4).contains(heading.level),
              heading.text.range(of: "^[a-z][a-z0-9-]*: .*\\S", options: .regularExpression) != nil,
              let colon = heading.text.firstIndex(of: ":") else { return nil }
        let name = heading.text[heading.text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (String(heading.text[..<colon]), name)
    }

    private static let keys: Set<String> = ["needs", "changes", "code", "done when"]

    /// The lines that are about this component alone: its section, up to
    /// the first component section nested in it. What a nested component
    /// needs, and how it is summed up, is its own.
    private static func ownLines(of position: Int, in outline: PlanDocOutline) -> Range<Int> {
        let section = outline.section(position)
        let nested = outline.headings[(position + 1)...]
            .first { $0.index < section.upperBound && identity(of: $0) != nil }
        return section.lowerBound..<(nested?.index ?? section.upperBound)
    }

    /// The bullets that are read, by lowercased key.
    private static func fields(in lines: Range<Int>, of outline: PlanDocOutline) -> [String: String] {
        var fields: [String: String] = [:]
        var key: String?
        for index in lines {
            let line = outline.lines[index]
            let content = line.trimmingCharacters(in: .whitespaces)
            if outline.fenced[index] {
                key = nil
            } else if let bullet = bullet(line) {
                key = bullet.key
                fields[bullet.key] = bullet.value
            } else if let current = key, line.first == " " || line.first == "\t", !content.isEmpty {
                fields[current, default: ""] += " " + content
            } else {
                key = nil
            }
        }
        return fields
    }

    private static func bullet(_ line: String) -> (key: String, value: String)? {
        guard line.hasPrefix("- "), let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased()
        guard keys.contains(key) else { return nil }
        return (key, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private static func items(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",")
            .map { $0.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The first sentence of the first paragraph. Lists, tables, code and
    /// headings aren't paragraphs, so a section that opens with its bullets
    /// is summed up by the prose after them.
    private static func summary(in lines: Range<Int>, of outline: PlanDocOutline) -> String {
        var blocks: [[String]] = [[]]
        for index in lines {
            let line = outline.lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || outline.fenced[index] {
                if !blocks[blocks.count - 1].isEmpty { blocks.append([]) }
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        let marks = ["- ", "* ", "+ ", "|", "#"]
        let paragraph = blocks.first { block in
            block.first.map { line in !marks.contains { line.hasPrefix($0) } } ?? false
        }
        let text = collapsed((paragraph ?? []).joined(separator: " "))
        guard let end = text.range(of: "[.!?](?=\\s)", options: .regularExpression) else { return text }
        return String(text[..<end.upperBound])
    }

    /// The text on one line, with every run of whitespace as one space.
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
