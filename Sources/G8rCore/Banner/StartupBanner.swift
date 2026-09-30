import Foundation

/// The startup banner the first shell pane plays: a "G8R" wordmark over an
/// alligator that slides its sunglasses on. Frames are plain text; color is
/// added per character when the `/bin/sh` script is built.
public enum StartupBanner {
    public static let maxWidth = 72
    public static let maxHeight = 20
    public static let tagline = "the living map · g8r"

    static let wordmark = [
        "   ____    ___    ____",
        "  / ___|  ( _ )  |  _ \\",
        " | |  _   / _ \\  | |_) |",
        " | |_| | | (_) | |  _ <",
        "  \\____|  \\___/  |_| \\_\\",
    ]

    /// The gator, facing right. Row 0 holds the eye bumps, which the
    /// glasses land on in the last frame.
    static let gator = [
        "                          _   _",
        "           ___.------.__.(-)_(-).__________",
        "      __.-'  ^  ^  ^  ^                o  `\\",
        "  (@~-'  _.-.____________  `-._v_____v_.-' /",
        "        /_/ /_/     /_/    `-.________.-'",
    ]
    /// The relaxed, half-lidded eyes the glasses cover.
    static let eyes = "(-)_(-)"

    static let glasses = "[#]-[#]"
    static let glassesOn = "[*]=[#]"
    /// Column of the eyes' "(o)_(o)" in gator row 1.
    static let eyeColumn = 25
    static let dropRows = 3

    /// Frames, all the same height: glasses above the head, sliding down,
    /// then on the eyes with the tagline.
    public static var frames: [[String]] {
        (0...dropRows).map { step in frame(step: step) }
    }

    static func frame(step: Int) -> [String] {
        var lines = wordmark + [""]
        var drop = Array(repeating: "", count: dropRows)
        var art = gator
        if step < dropRows {
            drop[step] = String(repeating: " ", count: eyeColumn) + glasses
        } else {
            art[1] = overlay(art[1], glassesOn, at: eyeColumn)
            // The eye bumps are under the glasses now.
            art[0] = ""
        }
        lines += drop + art + [""]
        lines.append(step == dropRows ? "   " + tagline : "")
        return lines
    }

    static func overlay(_ line: String, _ s: String, at column: Int) -> String {
        var chars = Array(line)
        while chars.count < column + s.count { chars.append(" ") }
        for (i, c) in s.enumerated() { chars[column + i] = c }
        return String(chars)
    }

    // MARK: - Color

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> String { "\u{1B}[38;2;\(r);\(g);\(b)m" }
    static let forest = rgb(0x2F, 0x6B, 0x45)
    static let moss = rgb(0x5E, 0x9E, 0x5A)
    static let olive = rgb(0x55, 0x6B, 0x2F)
    static let teal = rgb(0x2E, 0x5A, 0x4C)
    static let bog = rgb(0x4A, 0x5A, 0x2A)
    static let lichen = rgb(0xCF, 0xDC, 0xC4)
    static let reset = "\u{1B}[0m"

    /// One frame line with ANSI colors, `row` being its index in the frame.
    /// One frame line with ANSI colors, `row` being its index in the frame.
    /// Wordmark: moss strokes over a forest base row. Gator: olive back,
    /// teal belly and jaw, bog legs; lichen for eyes, teeth and glasses.
    static func colored(_ line: String, row: Int) -> String {
        if row < wordmark.count { return (row == wordmark.count - 1 ? forest : moss) + line + reset }
        if line.contains(tagline) { return lichen + line + reset }
        let gatorRow = row - (wordmark.count + 1 + dropRows)
        let base = gatorRow == 4 ? teal : gatorRow == 3 ? teal : olive
        let glassRange = line.contains("[") ? eyeColumn..<(eyeColumn + glasses.count) : 0..<0
        let eyeRange = eyeColumn..<(eyeColumn + eyes.count)
        var out = "", current = ""
        for (col, c) in line.enumerated() {
            var color = base
            if glassRange.contains(col) || (gatorRow == 1 && eyeRange.contains(col)) || c == "v" { color = lichen }
            else if gatorRow == 4 && col < 24 { color = bog }
            else if gatorRow == 2 && c == "^" { color = bog }
            if color != current { out += color; current = color }
            out.append(c)
        }
        return out + reset
    }

    // MARK: - Script

    /// A `/bin/sh` script that draws each frame in place from the top of
    /// a cleared screen (it is the first thing in the pane), pauses between
    /// them (`$G8R_BANNER_DELAY`, default 0.2s per frame, 0.6s on the
    /// first), and leaves the cursor below the art with colors reset.
    /// `G8R_NO_BANNER=1` makes it do nothing.
    public static var script: String {
        let all = frames
                var parts = ["[ -n \"$G8R_NO_BANNER\" ] && exit 0", "d=${G8R_BANNER_DELAY:-0.2}", "printf '\\033[?25l\\033[H\\033[2J'"]
        for (i, frame) in all.enumerated() {
            if i > 0 {
                parts.append(i == 1 ? "sleep $d; sleep $d; sleep $d" : "sleep $d")
                parts.append("printf '\\033[H'")
            }
            let body = frame.enumerated().map { colored($0.element, row: $0.offset) + "\u{1B}[K\n" }.joined()
            parts.append("printf '%s' " + shellQuote(body))
        }
        parts.append("printf '\\033[0m\\033[?25h\\n'")
        return parts.joined(separator: "\n")
    }

    /// The command a pane runs to play the banner: the script as one
    /// single-quoted argument to `/bin/sh -c`, safe to splice into a larger
    /// command line.
    public static var command: String { "/bin/sh -c " + shellQuote(script) }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
