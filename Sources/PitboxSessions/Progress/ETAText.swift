import Foundation

/// One line of a reply as the ETA parser reads it.
struct ETALine: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case prose, blank
        /// Inside a fenced or indented code block (fence lines included): never read.
        case code
        /// A blockquote line or its lazy continuation: never read.
        case quote
    }

    var kind: Kind
    /// The line as written.
    var raw: [Unicode.Scalar]
    /// Prose lines: `raw` with inline code spans and double-quoted spans ("…", “…”) blanked to spaces; empty otherwise.
    var masked: [Unicode.Scalar]
}

/// A GitHub-style table among a reply's prose lines: a header row, a delimiter row, then body rows.
struct ETATable: Equatable, Sendable {
    var headerLine: Int
    var bodyLines: [Int]
    /// Every line the table takes (header, delimiter, body): forms 1-2 never read them.
    var lines: ClosedRange<Int> { headerLine...(bodyLines.last ?? headerLine + 1) }
}

/// The Markdown structure the ETA parser needs: which lines are code or quotes, inline code and double quotes
/// inside prose, and tables. A small reader of CommonMark's block rules: fences (backticks or tildes, inside quotes and
/// list items too), indented code after a blank line outside lists, blockquotes with lazy continuation lines.
enum ETAText {
    // MARK: Lines

    /// `text`'s lines, classified, prose ones masked.
    static func lines(of text: String) -> [ETALine] {
        var out: [ETALine] = []
        var fence: (character: Unicode.Scalar, length: Int)?
        var previous: ETALine.Kind = .blank
        var inIndentedCode = false
        var inList = false
        for raw in split(text) {
            if let open = fence {
                if closesFence(raw, character: open.character, length: open.length) { fence = nil }
                out.append(ETALine(kind: .code, raw: raw, masked: []))
                previous = .code
                continue
            }
            if isBlank(raw) {
                out.append(ETALine(kind: .blank, raw: raw, masked: []))
                previous = .blank
                continue
            }
            let indent = indentation(raw)
            let content = Array(raw.drop { $0 == " " || $0 == "\t" })
            if let opened = fenceOpening(strippingContainers(content)) {
                fence = opened
                inIndentedCode = false
                out.append(ETALine(kind: .code, raw: raw, masked: []))
                previous = .code
                continue
            }
            if indent <= 3, content.first == ">" {
                inIndentedCode = false
                out.append(ETALine(kind: .quote, raw: raw, masked: []))
                previous = .quote
                continue
            }
            if previous == .quote, !startsBlock(content) {
                out.append(ETALine(kind: .quote, raw: raw, masked: []))
                continue
            }
            if indent >= 4, !inList, inIndentedCode || previous == .blank {
                inIndentedCode = true
                out.append(ETALine(kind: .code, raw: raw, masked: []))
                previous = .code
                continue
            }
            inIndentedCode = false
            if indent < 4 {
                if listMarkerLength(content) != nil {
                    inList = true
                } else if previous == .blank {
                    inList = false
                }
            }
            out.append(ETALine(kind: .prose, raw: raw, masked: maskInline(raw)))
            previous = .prose
        }
        return out
    }

    /// Lines split at `\n`, `\r\n` and `\r`.
    static func split(_ text: String) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var afterCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if afterCR {
                    afterCR = false
                    continue
                }
                lines.append(current)
                current = []
            } else if scalar == "\r" {
                lines.append(current)
                current = []
                afterCR = true
                continue
            } else {
                current.append(scalar)
            }
            afterCR = false
        }
        lines.append(current)
        return lines
    }

    /// Inline code spans (a run of n backticks to the next run of exactly n) and double-quoted spans blanked.
    static func maskInline(_ line: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var s = line
        var i = 0
        while i < s.count {
            guard s[i] == "`" else {
                i += 1
                continue
            }
            var run = i
            while run < s.count, s[run] == "`" { run += 1 }
            let length = run - i
            var j = run
            var closed: Int?
            while j < s.count {
                if s[j] == "`" {
                    var end = j
                    while end < s.count, s[end] == "`" { end += 1 }
                    if end - j == length {
                        closed = end
                        break
                    }
                    j = end
                } else {
                    j += 1
                }
            }
            if let closed {
                for k in i..<closed { s[k] = " " }
                i = closed
            } else {
                i = run
            }
        }
        var open: (index: Int, curly: Bool)?
        i = 0
        while i < s.count {
            let c = s[i]
            if let current = open {
                if (current.curly && c == "\u{201D}") || (!current.curly && c == "\"") {
                    for k in current.index...i { s[k] = " " }
                    open = nil
                }
            } else if c == "\"" {
                open = (i, false)
            } else if c == "\u{201C}" {
                open = (i, true)
            }
            i += 1
        }
        return s
    }

    // MARK: Tables

    /// The tables among `lines`' prose lines.
    static func tables(in lines: [ETALine]) -> [ETATable] {
        var out: [ETATable] = []
        var i = 0
        while i + 1 < lines.count {
            let header = lines[i], delimiter = lines[i + 1]
            guard header.kind == .prose, delimiter.kind == .prose, header.raw.contains("|"),
                  isDelimiterRow(delimiter.raw), cells(header.raw).count == cells(delimiter.raw).count else {
                i += 1
                continue
            }
            var body: [Int] = []
            var j = i + 2
            while j < lines.count, lines[j].kind == .prose, lines[j].raw.contains("|") {
                body.append(j)
                j += 1
            }
            out.append(ETATable(headerLine: i, bodyLines: body))
            i = j
        }
        return out
    }

    /// A row's cells: one leading and one trailing pipe dropped, split at pipes not escaped with a backslash.
    static func cells(_ row: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var s = Array(trimmed(row))
        if s.first == "|" { s.removeFirst() }
        if s.last == "|", s.count < 2 || s[s.count - 2] != "\\" { s.removeLast() }
        var out: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var previous: Unicode.Scalar?
        for c in s {
            if c == "|", previous != "\\" {
                out.append(current)
                current = []
            } else {
                current.append(c)
            }
            previous = c
        }
        out.append(current)
        return out
    }

    /// `| --- | :---: |`: every cell hyphens with optional colons at its ends.
    static func isDelimiterRow(_ row: [Unicode.Scalar]) -> Bool {
        guard row.contains("|") else { return false }
        let parts = cells(row)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { cell in
            var t = trimmed(cell)
            if t.first == ":" { t.removeFirst() }
            if t.last == ":" { t.removeLast() }
            return !t.isEmpty && t.allSatisfy { $0 == "-" }
        }
    }

    /// A cell or a name as compared with the session's headline and nickname: Markdown links reduced to their text,
    /// emphasis and code marks removed, `-` and `_` read as spaces, lowercase, whitespace collapsed.
    static func plain(_ cell: [Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        var i = 0
        var lastSpace = true
        func add(_ c: Unicode.Scalar) {
            let space = c.properties.isWhitespace
            if space {
                if !lastSpace { out.append(" ") }
            } else {
                out.append(c)
            }
            lastSpace = space
        }
        while i < cell.count {
            let c = cell[i]
            if c == "]", i + 1 < cell.count, cell[i + 1] == "(" {
                // `[text](target)`: the target is dropped.
                var j = i + 2
                while j < cell.count, cell[j] != ")" { j += 1 }
                i = j + 1
                continue
            }
            switch c {
            case "*", "`", "~", "[", "]": break
            case "-", "_": add(" ")
            default: add(c)
            }
            i += 1
        }
        return String(out).lowercased().trimmingCharacters(in: .whitespaces)
    }

    // MARK: Helpers

    static func isBlank(_ line: [Unicode.Scalar]) -> Bool { line.allSatisfy { $0.properties.isWhitespace } }

    /// An ASCII digit.
    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }

    /// An ASCII letter.
    static func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A)
    }

    static func trimmed(_ s: [Unicode.Scalar]) -> ArraySlice<Unicode.Scalar> {
        guard let first = s.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = s.lastIndex(where: { !$0.properties.isWhitespace }) else { return [] }
        return s[first...last]
    }

    /// Leading whitespace in columns (a tab reaches the next multiple of 4).
    static func indentation(_ line: [Unicode.Scalar]) -> Int {
        var columns = 0
        for c in line {
            if c == " " { columns += 1 } else if c == "\t" { columns += 4 - columns % 4 } else { break }
        }
        return columns
    }

    /// The length of a list marker at the start (`- `, `* `, `+ `, `1. `, `1) `), or nil.
    static func listMarkerLength(_ content: [Unicode.Scalar]) -> Int? {
        guard let first = content.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            return content.count == 1 || content[1] == " " || content[1] == "\t" ? 1 : nil
        }
        var digits = 0
        while digits < content.count, digits < 9, isDigit(content[digits]) { digits += 1 }
        guard digits > 0, digits < content.count, content[digits] == "." || content[digits] == ")" else { return nil }
        let after = digits + 1
        return after == content.count || content[after] == " " || content[after] == "\t" ? after : nil
    }

    /// The content with leading blockquote markers and one list marker removed (fences may sit inside them).
    static func strippingContainers(_ content: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var s = content
        while let first = s.first, first == ">" || first == " " || first == "\t" { s.removeFirst() }
        if let marker = listMarkerLength(s) {
            s.removeFirst(marker)
            while let first = s.first, first == " " || first == "\t" { s.removeFirst() }
        }
        return s
    }

    /// Three or more backticks or tildes; a backtick fence's info string holds no backtick.
    static func fenceOpening(_ s: [Unicode.Scalar]) -> (character: Unicode.Scalar, length: Int)? {
        guard let c = s.first, c == "`" || c == "~" else { return nil }
        var length = 0
        while length < s.count, s[length] == c { length += 1 }
        guard length >= 3 else { return nil }
        if c == "`", s[length...].contains("`") { return nil }
        return (c, length)
    }

    static func closesFence(_ raw: [Unicode.Scalar], character: Unicode.Scalar, length: Int) -> Bool {
        let s = strippingContainers(Array(raw.drop { $0 == " " || $0 == "\t" }))
        var run = 0
        while run < s.count, s[run] == character { run += 1 }
        return run >= length && s[run...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Whether a line starts a block of its own (so it is no lazy continuation of a quote).
    static func startsBlock(_ content: [Unicode.Scalar]) -> Bool {
        guard let first = content.first else { return true }
        return first == "#" || first == "|" || first == ">" || listMarkerLength(content) != nil
            || fenceOpening(content) != nil || isThematicBreak(content)
    }

    static func isThematicBreak(_ content: [Unicode.Scalar]) -> Bool {
        guard let mark = content.first, mark == "-" || mark == "*" || mark == "_" else { return false }
        var count = 0
        for c in content {
            if c == mark { count += 1 } else if c != " " && c != "\t" { return false }
        }
        return count >= 3
    }
}
