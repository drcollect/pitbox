import Foundation

// B1 (hidden or deceptive characters) and the character facts B2 uses (docs/SHELL_LANGUAGE.md §3.4-§3.5).
// Built from the Unicode data of the macOS it runs on through `Unicode.Scalar.Properties`, so a newer macOS with newer
// Unicode data extends the policy by itself; the policy's version is `CommandClassifier.policyVersion`.

enum CommandCharacterPolicy {
    /// True for a B1 character: Cc and Cf except tab and newline, every Default_Ignorable_Code_Point, U+2028 and
    /// U+2029, and every space other than U+0020.
    static func isHidden(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v == 0x09 || v == 0x0A || v == 0x20 { return false }
        if v < 0x20 || v == 0x7F { return true }
        if v < 0x7F { return false }
        let p = s.properties
        switch p.generalCategory {
        case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: break
        }
        return p.isDefaultIgnorableCodePoint
    }

    /// Dashes that look like `-` (B2 at the start of an option word).
    static let dashLookAlikes: Set<UInt32> = [0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xFE58, 0xFE63,
                                              0xFF0D, 0x2043, 0x02D7, 0x1806]

    /// `U+202E`.
    static func codePoint(_ s: Unicode.Scalar) -> String {
        let hex = String(s.value, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    /// The character's Unicode name, e.g. "RIGHT-TO-LEFT OVERRIDE".
    static func name(_ s: Unicode.Scalar) -> String {
        s.properties.name ?? s.properties.nameAlias ?? "unnamed character"
    }

    /// Every B1 character of `text`, with its UTF-16 range.
    static func hiddenCharacters(in text: String) -> [(scalar: Unicode.Scalar, range: Range<Int>)] {
        var out: [(Unicode.Scalar, Range<Int>)] = []
        var offset = 0
        for s in text.unicodeScalars {
            let width = s.utf16.count
            if isHidden(s) { out.append((s, offset..<(offset + width))) }
            offset += width
        }
        return out
    }

    static func cleaned(_ text: String) -> CommandCleanedText {
        var kept = String.UnicodeScalarView()
        var removals: [CommandCleanedText.Removal] = []
        var offset = 0
        var line = 1
        for s in text.unicodeScalars {
            let width = s.utf16.count
            if isHidden(s) {
                removals.append(.init(scalar: s, utf16Range: offset..<(offset + width), line: line))
            } else {
                kept.append(s)
            }
            if s.value == 0x0A { line += 1 }
            offset += width
        }
        return CommandCleanedText(text: String(kept), removals: removals)
    }

    /// The non-ASCII characters of `text` that are not B1, each once, with the line of its first use.
    static func visibleNonASCII(in text: String) -> [(scalar: Unicode.Scalar, line: Int)] {
        var seen = Set<UInt32>()
        var out: [(Unicode.Scalar, Int)] = []
        var line = 1
        for s in text.unicodeScalars {
            if s.value == 0x0A { line += 1; continue }
            guard !s.isASCII, !isHidden(s), !seen.contains(s.value) else { continue }
            seen.insert(s.value)
            out.append((s, line))
        }
        return out
    }
}
