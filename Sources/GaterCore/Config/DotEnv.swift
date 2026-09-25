import Foundation

/// Gater's secrets and settings file: `~/.gater/.env`.
///
/// It lives in the home directory, not in any repo, so keys (e.g.
/// JEV_API_KEY) can't be committed to a target repository or read by an
/// agent working in one. Real environment variables win over the file.
public enum DotEnv {
    public static func defaultPath(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".gater/.env")
    }

    /// `KEY=value` lines; `#` comments, blank lines, an optional `export `
    /// prefix, and single/double-quoted values are supported.
    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces) // inline comment
            }
            guard !key.isEmpty else { continue }
            values[key] = value
        }
        return values
    }

    /// The file's values overlaid with the process environment.
    public static func load(path: URL = defaultPath(),
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let file = (try? String(contentsOf: path, encoding: .utf8)).map(parse) ?? [:]
        return file.merging(environment) { _, env in env }
    }
}
