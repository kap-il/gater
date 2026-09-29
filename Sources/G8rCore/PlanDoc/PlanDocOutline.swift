import Foundation

/// The headings of a markdown doc and the lines under each. The parser and
/// the extractor both read sections through this, so a section means the
/// same lines to both.
struct PlanDocOutline {
    struct Heading: Equatable {
        /// 0-based index of the heading's line.
        var index: Int
        var level: Int
        var text: String
    }

    let lines: [String]
    /// True for the lines of a code fence, the fence marks included.
    /// Nothing on such a line is structure.
    let fenced: [Bool]
    let headings: [Heading]

    init(_ text: String) {
        // `isNewline` takes "\r\n" as one break, so a doc saved on Windows
        // has the same line numbers.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var fenced: [Bool] = []
        var headings: [Heading] = []
        var open: (mark: Character, count: Int)?
        for (index, line) in lines.enumerated() {
            if let fence = Self.fence(line) {
                fenced.append(true)
                if let opened = open {
                    if fence.mark == opened.mark, fence.count >= opened.count, fence.bare { open = nil }
                } else {
                    open = (fence.mark, fence.count)
                }
                continue
            }
            fenced.append(open != nil)
            if open == nil, let heading = Self.heading(line) {
                headings.append(Heading(index: index, level: heading.level, text: heading.text))
            }
        }
        self.lines = lines
        self.fenced = fenced
        self.headings = headings
    }

    /// The first level-1 heading.
    var title: String? {
        headings.first { $0.level == 1 }?.text
    }

    /// The lines of a heading's section: from the line after the heading to
    /// the next heading of the same or a higher level.
    func section(_ position: Int) -> Range<Int> {
        let heading = headings[position]
        let end = headings[(position + 1)...].first { $0.level <= heading.level }?.index ?? lines.count
        return (heading.index + 1)..<end
    }

    func body(_ position: Int) -> String {
        lines[section(position)].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let marks = line.prefix { $0 == "#" }
        let rest = line.dropFirst(marks.count)
        guard (1...6).contains(marks.count), let next = rest.first, next == " " || next == "\t" else { return nil }
        return (marks.count, rest.trimmingCharacters(in: .whitespaces))
    }

    /// A line of three or more backticks or tildes. `bare` is true when
    /// nothing follows them, which is what lets the line close a fence:
    /// "```swift" inside an open fence is part of the code.
    private static func fence(_ line: String) -> (mark: Character, count: Int, bare: Bool)? {
        let indent = line.prefix { $0 == " " }
        let rest = line.dropFirst(indent.count)
        guard indent.count <= 3, let mark = rest.first, mark == "`" || mark == "~" else { return nil }
        let marks = rest.prefix { $0 == mark }
        guard marks.count >= 3 else { return nil }
        let after = rest.dropFirst(marks.count)
        return (mark, marks.count, after.allSatisfy { $0 == " " || $0 == "\t" })
    }
}
