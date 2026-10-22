import Darwin
import Foundation

/// Finds the ETA a reply states, in order of preference within one text:
///
/// 1. **the user's form** (the rule line in their `~/.claude/CLAUDE.md`): `ETA:`, at most one space, `H:MM` or
///    `HH:MM` from 00:00 to 23:59 not followed by a digit, optionally a zone:
///    `(?<![A-Za-z])ETA:[ ]?([01]?\d|2[0-3]):([0-5]\d)(?!\d)`.
/// 2. **Other labelled forms:** `ETA`, optionally with a parenthesis (`ETA (UTC)`), a colon or bold (`**ETA:**`), and a
///    value within the next `CodeTuning.etaValueWindow` characters (`ETA for the build ~23:24`); or a label line (only
///    `ETA`, a zone and a colon) with the value on one of the next `CodeTuning.etaLabelLines` lines.
/// 3. **Tables:** a header cell holding the word `ETA` (optionally with a zone) makes its column's cells values, but
///    only when the table is unambiguous: one body row, or exactly one row is the session's own (its first cell, markup
///    removed, equals the headline or contains the nickname, ignoring case, `-` read as a space).
///
/// Within a form the last statement in the text wins. Fenced and indented code, inline code, blockquotes and double
/// quotes are never read; table rows are read only as tables. Values are `ETAValue`'s shapes; anything else gives
/// nothing. Pure and table-driven: the vectors are in `Tests/PitboxSessionsTests/Progress/ETAParserTests.swift`.
enum ETAParser {
    /// The session facts a table's rows are matched with.
    struct Context: Equatable, Sendable {
        var headline: String?
        var nickname: String?
    }

    /// One statement of a text.
    struct Statement: Equatable, Sendable {
        /// Lower is less preferred.
        enum Form: Int, Comparable, Sendable {
            case table = 1, labelled = 2, rule = 3
            static func < (a: Form, b: Form) -> Bool { a.rawValue < b.rawValue }
        }

        var value: ETAClockValue
        var form: Form
        /// Where its label (or table row) is: line and column.
        var line: Int
        var column: Int
    }

    /// The preferred statement of `text`, or nil.
    static func statement(in text: String, context: Context) -> Statement? {
        guard mayHoldLabel(text) else { return nil }
        return statements(in: text, context: context).max { a, b in
            (a.form, a.line, a.column) < (b.form, b.line, b.column)
        }
    }

    /// Every statement of `text` (for tests and `statement(in:context:)`).
    static func statements(in text: String, context: Context) -> [Statement] {
        guard mayHoldLabel(text) else { return [] }
        let lines = ETAText.lines(of: text)
        let tables = ETAText.tables(in: lines)
        var inTable = Set<Int>()
        for table in tables { inTable.formUnion(table.lines) }
        var out: [Statement] = []
        for (index, line) in lines.enumerated() where line.kind == .prose && !inTable.contains(index) {
            out.append(contentsOf: labelled(line.masked, line: index, lines: lines, inTable: inTable))
        }
        for table in tables {
            if let statement = tableStatement(table, lines: lines, context: context) { out.append(statement) }
        }
        return out
    }

    /// A quick test before any parsing: the bytes `ETA` occur (most texts have none).
    static func mayHoldLabel(_ text: String) -> Bool {
        var copy = text
        return copy.withUTF8 { bytes -> Bool in
            guard let base = bytes.baseAddress, bytes.count >= 3 else { return false }
            return memmem(base, bytes.count, "ETA", 3) != nil
        }
    }

    // MARK: Forms 1 and 2

    private static func labelled(_ s: [Unicode.Scalar], line: Int, lines: [ETALine], inTable: Set<Int>) -> [Statement] {
        var out: [Statement] = []
        var i = 0
        while i + 2 < s.count {
            guard isLabel(s, at: i) else {
                i += 1
                continue
            }
            let end = i + 3
            if let outcome = usersForm(s, labelEnd: end) {
                if case .clock(let value) = outcome {
                    out.append(Statement(value: value, form: .rule, line: line, column: i))
                }
            } else {
                switch ETAValue.scan(s, from: end, window: CodeTuning.etaValueWindow) {
                case .clock(let value):
                    out.append(Statement(value: value, form: .labelled, line: line, column: i))
                case .void:
                    break
                case .none:
                    if let value = labelLineValue(s, labelStart: i, line: line, lines: lines, inTable: inTable) {
                        out.append(Statement(value: value, form: .labelled, line: line, column: i))
                    }
                }
            }
            i = end
        }
        return out
    }

    /// `ETA` as a word: no letter or digit right before or after it (`BETA`, `ETAs` are not labels).
    static func isLabel(_ s: [Unicode.Scalar], at i: Int) -> Bool {
        guard i + 2 < s.count, s[i] == "E", s[i + 1] == "T", s[i + 2] == "A" else { return false }
        func isWordScalar(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic || ETAText.isDigit(c) }
        if i > 0, isWordScalar(s[i - 1]) { return false }
        if i + 3 < s.count, isWordScalar(s[i + 3]) { return false }
        return true
    }

    /// The user's form at a label: nil when its shape does not apply (form 2 reads the label then), else the clock or
    /// void (a 12-hour mark, a foreign zone or a day word after it).
    private static func usersForm(_ s: [Unicode.Scalar], labelEnd: Int) -> ETAValueOutcome? {
        guard labelEnd < s.count, s[labelEnd] == ":" else { return nil }
        var k = labelEnd + 1
        if k < s.count, s[k] == " " { k += 1 }
        guard k < s.count, ETAText.isDigit(s[k]), case .valid(let hour, let minute, let end)? = ETAValue.readClock(s, at: k)
        else { return nil }
        switch ETAValue.tail(s, hour: hour, minute: minute, end: end, zone: .none) {
        case .outcome(let outcome): return outcome
        case .skip: return nil
        }
    }

    /// A label line (only `ETA`, a zone and a colon, with markup and a list marker around them): the first value on
    /// the next `CodeTuning.etaLabelLines` non-blank lines, in the label's zone unless the value has its own.
    private static func labelLineValue(_ s: [Unicode.Scalar], labelStart: Int, line: Int, lines: [ETALine],
                                       inTable: Set<Int>) -> ETAClockValue? {
        let markup: Set<Unicode.Scalar> = ["*", "_", "#", " ", "\t"]
        // Before the label: whitespace, markup and one list marker only.
        var before = Array(s[..<labelStart].drop { markup.contains($0) })
        if let marker = ETAText.listMarkerLength(before) { before.removeFirst(marker) }
        guard before.allSatisfy({ markup.contains($0) }) else { return nil }
        // After it: markup, an optional zone (in a parenthesis or as a word), markup, a colon, markup to the end.
        var k = labelStart + 3
        while k < s.count, markup.contains(s[k]) { k += 1 }
        var zone: ETAZoneMark = .none
        if k < s.count, s[k] == "(" {
            guard let (mark, end) = ETAValue.parenthetical(s, at: k) else { return nil }
            zone = mark
            k = end
        } else if k < s.count, s[k].properties.isAlphabetic {
            let (word, end) = ETAValue.readWord(s, at: k)
            let (mark, _) = ETAValue.zoneWord(word, s, end: end)
            guard mark != .none || word.lowercased() == "local" else { return nil }
            zone = mark == .none ? .local : mark
            k = end
        }
        while k < s.count, markup.contains(s[k]) { k += 1 }
        guard k < s.count, s[k] == ":" else { return nil }
        k += 1
        guard s[k...].allSatisfy({ markup.contains($0) }) else { return nil }
        guard zone != .foreign else { return nil }
        var seen = 0
        var index = line + 1
        while index < lines.count, seen < CodeTuning.etaLabelLines {
            let next = lines[index]
            index += 1
            guard next.kind != .blank else { continue }
            seen += 1
            guard next.kind == .prose, !inTable.contains(index - 1) else { continue }
            var start = 0
            while start < next.masked.count, next.masked[start] == " " || next.masked[start] == "\t" { start += 1 }
            if let marker = ETAText.listMarkerLength(Array(next.masked[start...])) { start += marker }
            if case .clock(let value) = ETAValue.scan(next.masked, from: start, window: nil, zone: zone) { return value }
        }
        return nil
    }

    // MARK: Form 3

    private static func tableStatement(_ table: ETATable, lines: [ETALine], context: Context) -> Statement? {
        let header = ETAText.cells(lines[table.headerLine].raw)
        guard let column = header.firstIndex(where: { cell in (0..<cell.count).contains { isLabel(cell, at: $0) } }),
              !table.bodyLines.isEmpty else { return nil }
        let zone = headerZone(header[column])
        guard zone != .foreign else { return nil }
        let row: Int
        if table.bodyLines.count == 1 {
            row = table.bodyLines[0]
        } else {
            let headline = context.headline.map { ETAText.plain(Array($0.unicodeScalars)) }.flatMap { $0.isEmpty ? nil : $0 }
            let nickname = context.nickname.map { ETAText.plain(Array($0.unicodeScalars)) }.flatMap { $0.count >= 3 ? $0 : nil }
            let own = table.bodyLines.filter { index in
                guard let first = ETAText.cells(lines[index].raw).first else { return false }
                let name = ETAText.plain(first)
                guard !name.isEmpty else { return false }
                return name == headline || nickname.map { name.contains($0) } == true
            }
            guard own.count == 1 else { return nil }
            row = own[0]
        }
        let cells = ETAText.cells(lines[row].raw)
        guard column < cells.count else { return nil }
        let cell = ETAText.maskInline(cells[column])
        guard case .clock(let value) = ETAValue.scan(cell, from: 0, window: nil, zone: zone) else { return nil }
        return Statement(value: value, form: .table, line: row, column: 0)
    }

    /// The zone a header cell names after its `ETA` (`ETA (UTC)`, `ETA UTC`).
    private static func headerZone(_ cell: [Unicode.Scalar]) -> ETAZoneMark {
        guard let label = (0..<cell.count).first(where: { isLabel(cell, at: $0) }) else { return .none }
        var k = label + 3
        while k < cell.count {
            let c = cell[k]
            if c == "(" {
                if let (mark, end) = ETAValue.parenthetical(cell, at: k) {
                    if mark != .local { return mark }
                    k = end
                    continue
                }
            } else if c.properties.isAlphabetic {
                let (word, end) = ETAValue.readWord(cell, at: k)
                let (mark, _) = ETAValue.zoneWord(word, cell, end: end)
                if mark != .none { return mark }
                k = end
                continue
            }
            k += 1
        }
        return .none
    }
}
