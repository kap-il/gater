import Foundation

/// Path globs as used in GATER/1 `scope:` (e.g. `src/auth/**`, `*.ts`).
/// `**` crosses directories, `*` and `?` stay within one path segment.
public enum Glob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        var regex = "^"
        var chars = Array(pattern)
        if chars.first == "/" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                if i + 2 < chars.count, chars[i + 2] == "/" {
                    regex += "(?:.*/)?"
                    i += 3
                } else {
                    regex += ".*"
                    i += 2
                }
                continue
            }
            switch c {
            case "*": regex += "[^/]*"
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        // A bare directory (`src/auth`) covers everything under it.
        if !pattern.contains("*"), !pattern.contains("?") { regex += "(?:/.*)?" }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }

    /// Scope entries that look like paths (the rest may name symbols).
    public static func isPathLike(_ entry: String) -> Bool {
        entry.contains("/") || entry.contains("*") || entry.contains(".")
    }
}
