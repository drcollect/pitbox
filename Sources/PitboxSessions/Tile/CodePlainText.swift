import Foundation

/// The one renderer for session text on the block (docs/THREAT_MODEL.md): titles, nicknames, TL;DRs, Ask
/// lines, steps, todos, folders and command previews are model-written and untrusted. They are shown as plain text
/// only (drawn as plain strings: no markup, no links, no data detectors), capped, with every hidden or deceptive
/// character of B1 shown escaped in place as `⟨U+202E⟩`, never dropped and never interpreted.
enum CodePlainText {
    /// B1, from the Unicode data of the macOS it runs on: every character of category Cc or Cf except tab and
    /// newline, every Default_Ignorable_Code_Point, U+2028 and U+2029, and every space other than U+0020.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\t" || scalar == "\n" || scalar == " " { return false }
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator: return true
        default: return properties.isDefaultIgnorableCodePoint
        }
    }

    /// `⟨U+202E⟩`.
    static func escaped(_ scalar: Unicode.Scalar) -> String {
        "⟨U+" + String(format: "%04X", scalar.value) + "⟩"
    }

    /// One line: newlines and tabs become spaces and runs of spaces shrink to one (prose only), B1 characters are
    /// escaped, and the result is cut at `limit` characters with "…". Nil or blank stays nil.
    static func line(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let out = render(text, limit: limit, keepNewlines: false, collapseSpaces: true)
        return out.isEmpty ? nil : out
    }

    /// Several lines (the peek's TL;DR and Ask line): newlines are kept, at most `maxLines` of them; otherwise as `line`.
    static func block(_ text: String?, limit: Int, maxLines: Int) -> String? {
        guard let text else { return nil }
        var out = render(text, limit: limit, keepNewlines: true, collapseSpaces: true)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > maxLines { out = lines.prefix(maxLines).joined(separator: "\n") + "…" }
        else { out = lines.joined(separator: "\n") }
        return out.isEmpty ? nil : out
    }

    /// A command preview (the first line of an offer): spaces are kept as they are (they matter in a command; the sheet
    /// shows them marked), tabs show as `→`, B1 characters escaped, cut at `limit`.
    static func command(_ text: String, limit: Int) -> String {
        render(text.replacingOccurrences(of: "\t", with: "→"), limit: limit, keepNewlines: false, collapseSpaces: false)
    }

    private static func render(_ text: String, limit: Int, keepNewlines: Bool, collapseSpaces: Bool) -> String {
        let limit = max(1, limit)
        // Bound the work before anything else: a title of a million combining marks is still one character.
        let bound = limit * 4 + 16
        let cutInput = !text.unicodeScalars.dropFirst(bound).isEmpty
        var scalars = text.unicodeScalars.prefix(bound).map { $0 }
        // A Windows line end is an ordinary newline; a lone carriage return stays a B1 character.
        var index = 0
        var normalized: [Unicode.Scalar] = []
        normalized.reserveCapacity(scalars.count)
        while index < scalars.count {
            if scalars[index] == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1; continue }
            normalized.append(scalars[index])
            index += 1
        }
        scalars = normalized
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in scalars {
            var piece: [Unicode.Scalar]
            if scalar == "\n" {
                piece = keepNewlines ? ["\n"] : [" "]
            } else if scalar == "\t" {
                piece = [" "]
            } else if isHidden(scalar) {
                piece = Array(escaped(scalar).unicodeScalars)
            } else {
                piece = [scalar]
            }
            for item in piece {
                let isSpace = item == " "
                if collapseSpaces, isSpace, lastWasSpace { continue }
                out.append(item)
                lastWasSpace = isSpace || item == "\n"
            }
        }
        var result = String(out)
        if collapseSpaces { result = result.trimmingCharacters(in: CharacterSet(charactersIn: " \n")) }
        if result.count > limit { result = String(result.prefix(limit - 1)) + "…" }
        else if cutInput, !result.isEmpty { result = String(result.prefix(max(0, limit - 1))) + "…" }
        return result
    }
}
