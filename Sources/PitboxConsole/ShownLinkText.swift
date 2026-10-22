import Foundation

/// The text an explicit (OSC 8) link shows on the screen, as the user reads it (docs/THREAT_MODEL.md, T36). SwiftTerm
/// hands a click only the link's target; `LinkPolicy` compares that with these texts.
///
/// For each run of cells linked to the target, the run is widened over the adjacent cells that are not blank, linked
/// or not, so plain `https://` printed right before a link showing `bank.example/login` reads as one address. A word goes
/// on across a soft wrap. A hard line break ends it, with one exception, leftward only: when the next row's first word
/// claims no address on its own but, joined to the last word of the row before (trailing blanks aside, which the eye does
/// not see), does, a run that reaches column 0 widens back over that word (also `https:` | `//bank.example/login`). So `https://bank.example/` at the end of a
/// row and a link showing `login` at column 0 of the next read as `https://bank.example/login`, wherever the row ended,
/// while a rule line (`────`) above a link, a list of linked addresses one per row, and a link at the end of a row stay
/// what they are. Pure: tests drive it directly; the console's view hands it the screen.
enum ShownLinkText {
    /// One screen row: its cells (wide characters' second halves left out) and whether the terminal wrapped it from the
    /// row before (a soft wrap).
    struct Row {
        var cells: [Cell]
        var isWrapped: Bool
    }

    struct Cell {
        var character: Character
        /// The cell's OSC 8 target is the link asked about.
        var linked: Bool
    }

    /// The shown text of every run of linked cells, top to bottom.
    static func texts(rows: [Row]) -> [String] {
        var slots: [Slot] = []
        for (number, row) in rows.enumerated() {
            if number > 0, !row.isWrapped {
                slots.append(.lineBreak(joinsLeftward: joins(after: slots, before: row.cells)))
            }
            slots += row.cells.map { .cell($0.character, linked: $0.linked) }
        }
        var texts: [String] = []
        var index = 0
        while index < slots.count {
            guard case .cell(_, linked: true) = slots[index] else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < slots.count, case .cell(_, linked: true) = slots[end + 1] { end += 1 }
            var run: [Character] = []
            for slot in slots[index...end] {
                if case .cell(let character, _) = slot { run.append(character) }
            }
            // Leftward: over non-blank cells, and across a line break that joins (its row's trailing blanks skipped).
            var prefix: [Character] = []
            var left = index
            leftward: while left > 0 {
                switch slots[left - 1] {
                case .cell(let character, _) where !isBlank(character):
                    prefix.append(character)
                    left -= 1
                case .lineBreak(joinsLeftward: true):
                    var before = left - 2
                    while before >= 0, case .cell(let character, _) = slots[before], isBlank(character) { before -= 1 }
                    guard before >= 0, case .cell(let character, _) = slots[before], !isBlank(character) else { break leftward }
                    left = before + 1
                default:
                    break leftward
                }
            }
            // Rightward: over non-blank cells up to the next blank or line break.
            var suffix: [Character] = []
            var right = end + 1
            while right < slots.count, case .cell(let character, _) = slots[right], !isBlank(character) {
                suffix.append(character)
                right += 1
            }
            texts.append(String(prefix.reversed()) + String(run) + String(suffix))
            index = right
        }
        return texts
    }

    // MARK: Internals

    private enum Slot {
        case cell(Character, linked: Bool)
        /// A hard line break; `joinsLeftward` when a word reaching column 0 goes on into the row before.
        case lineBreak(joinsLeftward: Bool)
    }

    private static func isBlank(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.isWhitespace || $0.value == 0 }
    }

    /// Whether a hard line break between `slots` (everything above) and a row of `next` cells joins leftward: the next
    /// row's first word, starting at column 0, claims no address alone, and the last word above (trailing blanks
    /// skipped) followed by it does.
    private static func joins(after slots: [Slot], before next: [Cell]) -> Bool {
        var position = slots.count - 1
        while position >= 0, case .cell(let character, _) = slots[position], isBlank(character) { position -= 1 }
        var trailing: [Character] = []
        while position >= 0, case .cell(let character, _) = slots[position], !isBlank(character) {
            trailing.append(character)
            position -= 1
        }
        guard !trailing.isEmpty, let first = next.first, !isBlank(first.character) else { return false }
        let leading = String(next.prefix { !isBlank($0.character) }.map(\.character))
        // Decided on the joined text: a break inside the claim (`https:` | `//bank.example/login`, `www` | `.bank…`) joins
        // too, though neither half claims an address alone.
        return !LinkPolicy.claimsAddress(leading) && LinkPolicy.claimsAddress(String(trailing.reversed()) + leading)
    }
}
