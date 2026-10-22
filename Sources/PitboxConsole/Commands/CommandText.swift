import Foundation
import PitboxKit

/// The hidden and deceptive characters of block reason B1 (docs/SHELL_LANGUAGE.md §3.4). The sheet shows each one
/// escaped in place (`⟨U+202E⟩`), never only in a tooltip, in the command area and in every piece of session text. The
/// predicate is the classifier's own (`CommandClassifier.isHiddenCharacter`), so the characters shown escaped are
/// exactly the ones that block an offer.
enum CommandHiddenCharacters {
    /// The classifier's policy version (the character policy is part of it).
    static var policyVersion: Int { CommandClassifier.policyVersion }

    /// True for a character of B1: every Cc and Cf except tab and newline (carriage return included), every
    /// Default_Ignorable_Code_Point, U+2028 and U+2029, and every space other than U+0020.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        CommandClassifier.isHiddenCharacter(scalar)
    }

    /// `U+00E9`
    static func codePoint(_ scalar: Unicode.Scalar) -> String {
        "U+" + String(format: scalar.value > 0xFFFF ? "%05X" : "%04X", scalar.value)
    }

    /// `⟨U+202E⟩`: how a hidden character is shown in place.
    static func escaped(_ scalar: Unicode.Scalar) -> String { "⟨" + codePoint(scalar) + "⟩" }

    /// Whether `text` holds any hidden character.
    static func containsHidden(_ text: String) -> Bool { text.unicodeScalars.contains(where: isHidden) }

    /// `text` with every hidden character removed, for Copy cleaned (B1; `CommandClassifier.cleanedText`), and
    /// the UTF-16 offsets in the cleaned text where something was removed (for the marks on the sheet). Several removed
    /// in a row share a mark.
    static func cleaned(_ text: String) -> (text: String, marks: [Int], removed: Int) {
        let cleaned = CommandClassifier.cleanedText(text)
        var marks: [Int] = []
        var removedBefore = 0
        for removal in cleaned.removals {
            let offset = removal.utf16Range.lowerBound - removedBefore
            if marks.last != offset { marks.append(offset) }
            removedBefore += removal.utf16Range.count
        }
        return (cleaned.text, marks, cleaned.removals.count)
    }
}

/// The one renderer for session text on the sheet and in the bar: titles, nicknames, "You asked", captions, the reply,
/// newer replies. Plain text only (no markup, no links, nothing interpreted); hidden characters escaped in place; lines
/// hard-wrapped at `lineWidth` characters; capped. The sheet draws the result in quotes, in regular weight, on its own
/// faint background.
enum CommandPlainText {
    /// At most this many characters on one line of the sheet.
    static let lineWidth = 80

    /// `text` escaped, wrapped and capped: at most `maxLines` lines of at most `lineWidth` characters and
    /// `maxCharacters` characters in all; "…" marks a cut.
    static func render(_ text: String, maxLines: Int, maxCharacters: Int = 4_000) -> String {
        var escaped = ""
        escaped.reserveCapacity(min(text.utf8.count, maxCharacters * 2))
        var count = 0
        var cut = false
        for scalar in text.unicodeScalars {
            if count >= maxCharacters { cut = true; break }
            if scalar == "\n" { escaped.append("\n"); count += 1; continue }
            if scalar == "\t" { escaped.append("    "); count += 4; continue }
            if CommandHiddenCharacters.isHidden(scalar) {
                let shown = CommandHiddenCharacters.escaped(scalar)
                escaped += shown
                count += shown.count
            } else {
                escaped.unicodeScalars.append(scalar)
                count += 1
            }
        }
        var lines: [String] = []
        for line in escaped.split(separator: "\n", omittingEmptySubsequences: false) {
            for piece in wrap(String(line)) {
                if lines.count == maxLines { cut = true; break }
                lines.append(piece)
            }
            if lines.count == maxLines, cut { break }
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { lines.removeLast() }
        if cut, !lines.isEmpty {
            let last = lines[lines.count - 1]
            lines[lines.count - 1] = String(last.prefix(lineWidth - 1)) + "…"
        }
        return lines.joined(separator: "\n")
    }

    /// Session text on a single line: hidden characters escaped, line breaks shown as " ⏎ " (so nothing can push host
    /// text onto another line), tabs as four spaces, at most `maxCharacters` ("…" marks a cut). Not wrapped: the view
    /// wraps it.
    static func singleLine(_ text: String, maxCharacters: Int = 160) -> String {
        var out = ""
        var count = 0
        for scalar in text.unicodeScalars {
            let piece: String
            if scalar == "\n" { piece = " ⏎ " } else if scalar == "\t" { piece = "    " }
            else if CommandHiddenCharacters.isHidden(scalar) { piece = CommandHiddenCharacters.escaped(scalar) }
            else { piece = String(scalar) }
            if count + piece.count > maxCharacters {
                return String(out.prefix(max(0, maxCharacters - 1))) + "…"
            }
            out += piece
            count += piece.count
        }
        return out
    }

    /// Splits a line into pieces of at most `lineWidth` characters, at the last space when one is in the second half.
    static func wrap(_ line: String) -> [String] {
        var rest = Substring(line)
        var pieces: [String] = []
        while rest.count > lineWidth {
            let window = rest.prefix(lineWidth)
            if let space = window.lastIndex(of: " "), rest.distance(from: rest.startIndex, to: space) >= lineWidth / 2 {
                pieces.append(String(rest[rest.startIndex..<space]))
                rest = rest[rest.index(after: space)...]
            } else {
                pieces.append(String(window))
                rest = rest.dropFirst(lineWidth)
            }
        }
        pieces.append(String(rest))
        return pieces
    }
}
