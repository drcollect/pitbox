import Foundation

// Pieces the scanner shares: the text it reads (possibly re-read text with a map back to the original offsets), the
// characters it cares about, the budget of one scan, the pass that fills in here-doc bodies, and brace lists.

/// UTF-16 text being read. Re-read text (the inside of backticks after its escapes are removed, or a remote command
/// joined from words) keeps, for every unit, the offset it came from in the original text.
struct ShellSource {
    let units: [UInt16]
    private let origin: [Int]?
    private let originEnd: Int

    init(units: [UInt16]) {
        self.units = units; origin = nil; originEnd = units.count
    }

    /// `origin[i]` is the original offset of `units[i]`; `originEnd` the original offset just past the text.
    init(units: [UInt16], origin: [Int], originEnd: Int) {
        precondition(units.count == origin.count, "one origin per unit")
        self.units = units; self.origin = origin; self.originEnd = originEnd
    }

    /// Original offset of position `i` (0...units.count).
    func map(_ i: Int) -> Int {
        guard let origin else { return i }
        return i < origin.count ? origin[i] : originEnd
    }

    /// Original range of `[a, b)`.
    func range(_ a: Int, _ b: Int) -> Range<Int> {
        guard let origin else { return a..<max(a, b) }
        let start = map(a)
        guard b > a else { return start..<start }
        return start..<max(start, origin[b - 1] + 1)
    }
}

/// ASCII code units the scanner looks at.
enum Ch {
    static let tab: UInt16 = 0x09, newline: UInt16 = 0x0A, space: UInt16 = 0x20, bang: UInt16 = 0x21
    static let dquote: UInt16 = 0x22, hash: UInt16 = 0x23, dollar: UInt16 = 0x24, percent: UInt16 = 0x25
    static let amp: UInt16 = 0x26, squote: UInt16 = 0x27, lparen: UInt16 = 0x28, rparen: UInt16 = 0x29
    static let star: UInt16 = 0x2A, plus: UInt16 = 0x2B, comma: UInt16 = 0x2C, minus: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E, slash: UInt16 = 0x2F, colon: UInt16 = 0x3A, semicolon: UInt16 = 0x3B
    static let less: UInt16 = 0x3C, equals: UInt16 = 0x3D, greater: UInt16 = 0x3E, question: UInt16 = 0x3F
    static let at: UInt16 = 0x40, lbracket: UInt16 = 0x5B, backslash: UInt16 = 0x5C, rbracket: UInt16 = 0x5D
    static let caret: UInt16 = 0x5E, underscore: UInt16 = 0x5F, backtick: UInt16 = 0x60, lbrace: UInt16 = 0x7B
    static let pipe: UInt16 = 0x7C, rbrace: UInt16 = 0x7D, tilde: UInt16 = 0x7E

    static func isBlank(_ c: UInt16) -> Bool { c == space || c == tab }
    /// The characters that end an unquoted word (besides blanks and newlines).
    static func isMeta(_ c: UInt16) -> Bool {
        c == semicolon || c == amp || c == pipe || c == less || c == greater || c == lparen || c == rparen
    }
    static func isDelimiter(_ c: UInt16) -> Bool { isBlank(c) || c == newline || isMeta(c) }
    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    static func isLetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    static func isNameStart(_ c: UInt16) -> Bool { isLetter(c) || c == underscore }
    static func isNameChar(_ c: UInt16) -> Bool { isNameStart(c) || isDigit(c) }
    static func isHighSurrogate(_ c: UInt16) -> Bool { c >= 0xD800 && c <= 0xDBFF }
    static func isLowSurrogate(_ c: UInt16) -> Bool { c >= 0xDC00 && c <= 0xDFFF }

    static func string(_ units: ArraySlice<UInt16>) -> String { String(decoding: units, as: UTF16.self) }
    static func string(_ units: [UInt16]) -> String { String(decoding: units, as: UTF16.self) }
}

/// What one scan shares across nested readers: the token budget, the comments and the here-doc bodies.
final class ShellScanRun {
    var tokens = 0
    var comments: [Range<Int>] = []
    var hereDocuments: [ShellHereDocument] = []
    /// Bodies read so far, by slot.
    var bodies: [Int: ShellHereDocument] = [:]
    var nextSlot = 0

    func countToken(at range: @autoclosure () -> Range<Int>) throws {
        tokens += 1
        if tokens > ShellCommandScanner.maxTokens {
            throw ShellScanProblem(kind: .tooManyTokens,
                                   detail: "more than \(ShellCommandScanner.maxTokens) words and operators",
                                   utf16Range: range())
        }
    }

    static func scan(_ source: ShellSource) -> ShellScan {
        var scalars = 0
        for u in source.units where !Ch.isLowSurrogate(u) { scalars += 1 }
        if scalars > ShellCommandScanner.maxCharacters {
            let p = ShellScanProblem(kind: .tooLong,
                                     detail: "more than \(ShellCommandScanner.maxCharacters) characters",
                                     utf16Range: 0..<source.units.count)
            return ShellScan(script: nil, problem: p, comments: [], hereDocuments: [], tokenCount: 0)
        }
        let run = ShellScanRun()
        let parser = ShellParser(source: source, run: run, substitutionDepth: 0, nesting: 0)
        do {
            let script = try parser.parseTop()
            let filled = run.fill(script)
            return ShellScan(script: filled, problem: nil, comments: run.comments.sorted { $0.lowerBound < $1.lowerBound },
                             hereDocuments: run.hereDocuments.sorted { $0.bodyRange.lowerBound < $1.bodyRange.lowerBound },
                             tokenCount: run.tokens)
        } catch let problem as ShellScanProblem {
            return ShellScan(script: nil, problem: problem, comments: run.comments, hereDocuments: run.hereDocuments,
                             tokenCount: run.tokens)
        } catch {
            let p = ShellScanProblem(kind: .syntax, detail: "an unexpected reading error", utf16Range: 0..<0)
            return ShellScan(script: nil, problem: p, comments: [], hereDocuments: [], tokenCount: run.tokens)
        }
    }
}

// MARK: Filling in here-doc bodies

extension ShellScanRun {
    /// Replaces each here-doc placeholder with its body (bodies are read after the line that names them).
    func fill(_ script: ShellScript) -> ShellScript {
        ShellScript(items: script.items.map { item in
            ShellListItem(andOr: ShellAndOrList(pipelines: item.andOr.pipelines.map(fill), connectors: item.andOr.connectors),
                          terminator: item.terminator)
        }, utf16Range: script.utf16Range)
    }

    private func fill(_ p: ShellPipeline) -> ShellPipeline {
        ShellPipeline(negated: p.negated, commands: p.commands.map(fill), utf16Range: p.utf16Range)
    }

    private func fill(_ c: ShellCommand) -> ShellCommand {
        switch c {
        case .simple(let s):
            return .simple(ShellSimpleCommand(
                assignments: s.assignments.map {
                    ShellAssignment(name: $0.name, appends: $0.appends, value: fill($0.value), utf16Range: $0.utf16Range)
                },
                words: s.words.map(fill), redirections: s.redirections.map(fill), utf16Range: s.utf16Range))
        case .compound(let k):
            return .compound(ShellCompoundCommand(kind: fill(k.kind), redirections: k.redirections.map(fill),
                                                  utf16Range: k.utf16Range))
        }
    }

    private func fill(_ k: ShellCompoundCommand.Kind) -> ShellCompoundCommand.Kind {
        switch k {
        case .subshell(let s): return .subshell(fill(s))
        case .group(let s): return .group(fill(s))
        case .ifClause(let branches, let elseBody):
            return .ifClause(branches: branches.map { ShellConditionalBranch(condition: fill($0.condition), body: fill($0.body)) },
                             elseBody: elseBody.map(fill))
        case .forLoop(let v, let items, let body): return .forLoop(variable: v, items: items?.map(fill), body: fill(body))
        case .whileLoop(let c, let b): return .whileLoop(condition: fill(c), body: fill(b))
        case .untilLoop(let c, let b): return .untilLoop(condition: fill(c), body: fill(b))
        case .caseClause(let subject, let items):
            return .caseClause(subject: fill(subject),
                               items: items.map { ShellCaseItem(patterns: $0.patterns.map(fill), body: fill($0.body)) })
        case .condition(let words): return .condition(words: words.map(fill))
        case .arithmetic(let a): return .arithmetic(fill(a))
        }
    }

    private func fill(_ r: ShellRedirection) -> ShellRedirection {
        var doc = r.hereDocument
        if let d = doc, d.slot >= 0, let body = bodies[d.slot] { doc = body }
        if var d = doc { d.content = fill(d.content); doc = d }
        return ShellRedirection(fileDescriptor: r.fileDescriptor, op: r.op, target: fill(r.target), hereDocument: doc,
                                utf16Range: r.utf16Range)
    }

    private func fill(_ w: ShellWord) -> ShellWord {
        ShellWord(parts: w.parts.map(fill), utf16Range: w.utf16Range)
    }

    private func fill(_ part: ShellWordPart) -> ShellWordPart {
        switch part {
        case .text, .tilde, .glob, .braceList: return part
        case .parameter(var p):
            p.word = p.word.map(fill)
            return .parameter(p)
        case .commandSubstitution(let s, let b, let q, let r): return .commandSubstitution(fill(s), backticks: b, quoted: q, utf16Range: r)
        case .processSubstitution(let s, let w, let r): return .processSubstitution(fill(s), writes: w, utf16Range: r)
        case .arithmetic(let a): return .arithmetic(fill(a))
        }
    }

    private func fill(_ a: ShellArithmetic) -> ShellArithmetic {
        ShellArithmetic(expression: a.expression, expansions: a.expansions.map(fill), bareNames: a.bareNames,
                        utf16Range: a.utf16Range)
    }
}

// MARK: Brace lists

/// zsh's brace lists, `{a,b}`, `{a,{b,c}}`, `{1..5}`, `{01..10..2}`, `{a..e}`, on plain text only.
enum ShellBraceList {
    static let maxAlternatives = 64

    /// The alternatives of the brace list `text` (which starts with `{` and ends with its matching `}`), nil when it
    /// is not a brace list zsh expands or when it would produce more than `maxAlternatives` words.
    static func alternatives(_ text: String) -> [String]? {
        let chars = Array(text)
        var i = 0
        guard let result = parseBrace(chars, &i), i == chars.count else { return nil }
        return result
    }

    /// Parses `{…}` at `i`; returns its words, or nil when it is not a brace expansion.
    private static func parseBrace(_ c: [Character], _ i: inout Int) -> [String]? {
        guard i < c.count, c[i] == "{" else { return nil }
        let open = i
        // A range: {x..y} or {x..y..z} without nested braces or commas.
        if let close = matching(c, open), !c[(open + 1)..<close].contains(","), !c[(open + 1)..<close].contains("{"),
           let r = range(String(c[(open + 1)..<close])) {
            i = close + 1
            return r
        }
        i += 1
        var alternatives: [[String]] = [[""]]
        var commas = 0
        while i < c.count {
            let ch = c[i]
            if ch == "}" {
                i += 1
                guard commas > 0 else { return nil }
                return limit(alternatives.flatMap { $0 })
            }
            if ch == "," {
                commas += 1
                alternatives.append([""])
                i += 1
                continue
            }
            if ch == "{" {
                var j = i
                if let inner = parseBrace(c, &j) {
                    guard let product = limit(alternatives[alternatives.count - 1].flatMap { prefix in inner.map { prefix + $0 } })
                    else { return nil }
                    alternatives[alternatives.count - 1] = product
                    i = j
                    continue
                }
            }
            alternatives[alternatives.count - 1] = alternatives[alternatives.count - 1].map { $0 + String(ch) }
            i += 1
        }
        return nil
    }

    private static func matching(_ c: [Character], _ open: Int) -> Int? {
        var depth = 0
        for k in open..<c.count {
            if c[k] == "{" { depth += 1 } else if c[k] == "}" { depth -= 1; if depth == 0 { return k } }
        }
        return nil
    }

    private static func limit(_ words: [String]) -> [String]? { words.count <= maxAlternatives ? words : nil }

    /// `1..5`, `5..1`, `01..10`, `1..10..3`, `a..e`.
    private static func range(_ body: String) -> [String]? {
        let pieces = body.components(separatedBy: "..")
        guard pieces.count == 2 || pieces.count == 3, !pieces[0].isEmpty, !pieces[1].isEmpty else { return nil }
        var step = 1
        if pieces.count == 3 {
            guard let s = Int(pieces[2]), s != 0 else { return nil }
            step = abs(s)
        }
        if let a = Int(pieces[0]), let b = Int(pieces[1]) {
            let width = (pieces[0].hasPrefix("0") || pieces[1].hasPrefix("0") || pieces[0].hasPrefix("-0"))
                ? max(pieces[0].count, pieces[1].count) : 0
            // Untrusted numbers: never let the arithmetic trap.
            let (difference, overflow) = b.subtractingReportingOverflow(a)
            guard !overflow, difference != Int.min, abs(difference) / step < maxAlternatives else { return nil }
            let count = abs(difference) / step + 1
            let dir = b >= a ? step : -step
            return (0..<count).map { k in
                let v = a + k * dir
                let s = String(abs(v))
                let padded = width > 0 ? String(repeating: "0", count: max(0, width - s.count - (v < 0 ? 1 : 0))) + s : s
                return v < 0 ? "-" + padded : padded
            }
        }
        let x = Array(pieces[0].unicodeScalars), y = Array(pieces[1].unicodeScalars)
        guard x.count == 1, y.count == 1, x[0].isASCII, y[0].isASCII, x[0].properties.isAlphabetic,
              y[0].properties.isAlphabetic else { return nil }
        let a = Int(x[0].value), b = Int(y[0].value)
        let count = abs(b - a) / step + 1
        guard count <= maxAlternatives else { return nil }
        let dir = b >= a ? step : -step
        return (0..<count).compactMap { k in Unicode.Scalar(UInt32(a + k * dir)).map { String(Character($0)) } }
    }
}
