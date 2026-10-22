import Foundation

// The grammar of the accepted language (docs/SHELL_LANGUAGE.md §2): lists, and-or lists, pipelines, compound
// commands, simple commands, redirections and here-doc bodies. Words live in ShellScannerWords.swift. One parser
// reads one source; `$(…)`, `<(…)` and `>(…)` are read in place by the same parser, backticks by a parser over their
// re-read text.

/// A here-doc whose body starts after the next newline.
struct PendingHereDocument {
    let slot: Int
    let delimiter: [UInt16]
    let quoted: Bool
    let stripsTabs: Bool
    let operatorRange: Range<Int>
}

/// Where a list ends.
enum ShellStop: Hashable {
    case end, closeParen, closeBrace, caseTerminator
    case keyword(String)
}

final class ShellParser {
    let source: ShellSource
    let u: [UInt16]
    var i = 0
    var end: Int
    let run: ShellScanRun
    var substitutionDepth: Int
    var nesting: Int
    var pending: [PendingHereDocument] = []

    init(source: ShellSource, run: ShellScanRun, substitutionDepth: Int, nesting: Int) {
        self.source = source; self.u = source.units; self.end = source.units.count; self.run = run
        self.substitutionDepth = substitutionDepth; self.nesting = nesting
    }

    // MARK: Errors and positions

    func range(_ a: Int, _ b: Int) -> Range<Int> { source.range(a, b) }

    func problem(_ kind: ShellScanProblem.Kind, _ detail: String, _ a: Int, _ b: Int? = nil) -> ShellScanProblem {
        let lo = min(a, u.count), hi = min(max(b ?? (a + 1), lo), u.count)
        return ShellScanProblem(kind: kind, detail: detail, utf16Range: range(lo, hi))
    }

    func notAccepted(_ detail: String, _ a: Int, _ b: Int? = nil) -> ShellScanProblem {
        problem(.notAccepted, detail, a, b)
    }

    func syntax(_ detail: String, _ a: Int, _ b: Int? = nil) -> ShellScanProblem { problem(.syntax, detail, a, b) }

    func at(_ s: String) -> Bool {
        var k = i
        for c in s.utf16 {
            guard k < end, u[k] == c else { return false }
            k += 1
        }
        return true
    }

    func peek(_ offset: Int = 0) -> UInt16? { i + offset < end ? u[i + offset] : nil }

    func token(_ a: Int, _ b: Int) throws { try run.countToken(at: range(a, b)) }

    func enter(_ at: Int) throws {
        nesting += 1
        if nesting > ShellCommandScanner.maxNesting {
            throw problem(.tooDeep, "more than \(ShellCommandScanner.maxNesting) levels of nesting", at)
        }
    }

    // MARK: Blanks, comments, newlines

    /// Skips spaces, tabs and backslash-newline joins.
    func skipBlanks() {
        while i < end {
            if Ch.isBlank(u[i]) { i += 1; continue }
            if u[i] == Ch.backslash, i + 1 < end, u[i + 1] == Ch.newline { i += 2; continue }
            break
        }
    }

    /// Reads a comment at `#` up to the end of its line (the newline stays).
    func readComment() {
        let start = i
        while i < end, u[i] != Ch.newline { i += 1 }
        run.comments.append(range(start, i))
    }

    /// Skips blanks, comments and newlines, reading the here-doc bodies that follow each newline.
    func skipLinebreaks() throws {
        while true {
            skipBlanks()
            guard i < end else { return }
            if u[i] == Ch.hash { readComment(); continue }
            if u[i] == Ch.newline {
                i += 1
                try readPendingHereDocuments()
                continue
            }
            return
        }
    }

    /// A reserved word or `{`, `}`, `!`, `[[`, `]]` at `i`, when followed by a delimiter.
    func peekReservedWord() -> String? {
        var k = i
        while k < end, Ch.isLetter(u[k]) || u[k] == Ch.lbrace || u[k] == Ch.rbrace || u[k] == Ch.bang
            || u[k] == Ch.lbracket || u[k] == Ch.rbracket { k += 1 }
        guard k > i, k - i <= 9 else { return nil }
        if k < end, !Ch.isDelimiter(u[k]) { return nil }
        return Ch.string(u[i..<k])
    }

    static let stopKeywords: Set<String> = ["then", "elif", "else", "fi", "do", "done", "esac"]
    static let notAcceptedReserved: Set<String> = ["function", "select", "coproc", "repeat", "foreach", "end",
                                                   "nocorrect", "always"]

    // MARK: Lists

    func parseTop() throws -> ShellScript {
        let (script, _) = try parseList([.end])
        if let p = pending.first {
            throw problem(.unterminatedHereDocument, "a here-doc without its end line", p.operatorRange.lowerBound,
                          p.operatorRange.upperBound)
        }
        return script
    }

    /// The stop at a command position, if any. Throws for a stop that does not belong here.
    func stopHere(_ stops: Set<ShellStop>) throws -> ShellStop? {
        guard i < end else { return stops.contains(.end) ? .end : nil }
        let c = u[i]
        if c == Ch.rparen {
            if stops.contains(.closeParen) { return .closeParen }
            throw syntax("a `)` without its `(`", i)
        }
        if c == Ch.semicolon, let n = peek(1), n == Ch.semicolon || n == Ch.amp || n == Ch.pipe {
            if stops.contains(.caseTerminator) { return .caseTerminator }
            throw syntax("`;;` outside a `case`", i, i + 2)
        }
        if let w = peekReservedWord() {
            if w == "}" {
                if stops.contains(.closeBrace) { return .closeBrace }
                throw syntax("a `}` without its `{`", i)
            }
            if Self.stopKeywords.contains(w) {
                if stops.contains(.keyword(w)) { return .keyword(w) }
                throw syntax("`\(w)` in the wrong place", i, i + w.utf16.count)
            }
        }
        return nil
    }

    /// Reads and-or lists until one of `stops`.
    func parseList(_ stops: Set<ShellStop>) throws -> (ShellScript, ShellStop) {
        let start = i
        try enter(start)
        defer { nesting -= 1 }
        var items: [ShellListItem] = []
        while true {
            try skipLinebreaks()
            if let stop = try stopHere(stops) { return (ShellScript(items: items, utf16Range: range(start, i)), stop) }
            guard i < end else { throw problem(.unclosed, "a command that is not finished", start, i) }
            let c = u[i]
            if c == Ch.semicolon || c == Ch.amp || c == Ch.pipe {
                throw syntax("a command is missing before `\(Ch.string([c]))`", i)
            }
            let andOr = try parseAndOr()
            skipBlanks()
            var terminator = ShellListItem.Terminator.none
            if i < end {
                let t = u[i]
                if t == Ch.semicolon, !(peek(1) == Ch.semicolon || peek(1) == Ch.amp || peek(1) == Ch.pipe) {
                    try token(i, i + 1)
                    i += 1
                    terminator = .semicolon
                } else if t == Ch.amp {
                    if peek(1) == Ch.pipe || peek(1) == Ch.bang {
                        throw notAccepted("zsh's `&|` and `&!`", i, i + 2)
                    }
                    try token(i, i + 1)
                    i += 1
                    terminator = .background
                } else if t == Ch.newline {
                    terminator = .newline
                } else if t == Ch.hash {
                    readComment()
                    terminator = (i < end) ? .newline : .none
                }
            }
            items.append(ShellListItem(andOr: andOr, terminator: terminator))
            if terminator == .none {
                if let stop = try stopHere(stops) { return (ShellScript(items: items, utf16Range: range(start, i)), stop) }
                guard i < end else { throw problem(.unclosed, "a command that is not finished", start, i) }
                throw syntax("an unexpected `\(Ch.string([u[i]]))`", i)
            }
        }
    }

    func parseAndOr() throws -> ShellAndOrList {
        var pipelines = [try parsePipeline()]
        var connectors: [ShellAndOrList.Connector] = []
        while true {
            skipBlanks()
            if at("&&") || at("||") {
                connectors.append(u[i] == Ch.amp ? .and : .or)
                try token(i, i + 2)
                i += 2
                try skipLinebreaks()
                pipelines.append(try parsePipeline())
            } else {
                return ShellAndOrList(pipelines: pipelines, connectors: connectors)
            }
        }
    }

    func parsePipeline() throws -> ShellPipeline {
        skipBlanks()
        let start = i
        var negated = false
        if peekReservedWord() == "!" {
            try token(i, i + 1)
            i += 1
            negated = true
            skipBlanks()
        }
        var commands = [try parseCommand()]
        while true {
            skipBlanks()
            guard i < end, u[i] == Ch.pipe, peek(1) != Ch.pipe else { break }
            // `|&` is `2>&1 |`: the standard error goes into the pipe as well.
            let width = peek(1) == Ch.amp ? 2 : 1
            try token(i, i + width)
            i += width
            try skipLinebreaks()
            commands.append(try parseCommand())
        }
        return ShellPipeline(negated: negated, commands: commands, utf16Range: range(start, i))
    }

    // MARK: Commands

    func parseCommand() throws -> ShellCommand {
        skipBlanks()
        guard i < end else { throw problem(.unclosed, "a command is missing at the end", i) }
        let start = i
        if u[i] == Ch.lparen {
            if peek(1) == Ch.lparen { return .compound(try parseArithmeticCommand()) }
            return .compound(try parseSubshell())
        }
        if let w = peekReservedWord() {
            switch w {
            case "{": return .compound(try parseGroup())
            case "if": return .compound(try parseIf())
            case "for": return .compound(try parseFor())
            case "while", "until": return .compound(try parseLoop(until: w == "until"))
            case "case": return .compound(try parseCase())
            case "[[": return .compound(try parseCondition())
            case "!": throw syntax("a second `!`", start)
            case "}", "]]": throw syntax("an unexpected `\(w)`", start, start + w.utf16.count)
            default:
                if Self.stopKeywords.contains(w) {
                    throw syntax("`\(w)` in the wrong place", start, start + w.utf16.count)
                }
                if Self.notAcceptedReserved.contains(w) {
                    throw notAccepted("`\(w)`", start, start + w.utf16.count)
                }
            }
        }
        return .simple(try parseSimpleCommand())
    }

    func consumeWord(_ w: String) throws {
        let n = w.utf16.count
        try token(i, i + n)
        i += n
    }

    func expectKeyword(_ w: String, opened: Int) throws {
        try skipLinebreaks()
        guard peekReservedWord() == w else {
            throw problem(.unclosed, "a compound command without its `\(w)`", opened, i)
        }
        try consumeWord(w)
    }

    func parseSubshell() throws -> ShellCompoundCommand {
        let start = i
        try token(i, i + 1)
        i += 1
        skipBlanks()
        if i < end, u[i] == Ch.rparen { throw notAccepted("an anonymous function `() …`", start, i + 1) }
        let (body, _) = try parseList([.closeParen])
        guard i < end, u[i] == Ch.rparen else { throw problem(.unclosed, "an unclosed `(`", start, i) }
        if body.items.isEmpty { throw syntax("an empty `( )`", start, i + 1) }
        try token(i, i + 1)
        i += 1
        let redirections = try parseTrailingRedirections()
        return ShellCompoundCommand(kind: .subshell(body), redirections: redirections, utf16Range: range(start, i))
    }

    func parseGroup() throws -> ShellCompoundCommand {
        let start = i
        try consumeWord("{")
        let (body, stop) = try parseList([.closeBrace])
        guard stop == .closeBrace else { throw problem(.unclosed, "an unclosed `{`", start, i) }
        if body.items.isEmpty { throw syntax("an empty `{ }`", start, i + 1) }
        try consumeWord("}")
        let redirections = try parseTrailingRedirections()
        return ShellCompoundCommand(kind: .group(body), redirections: redirections, utf16Range: range(start, i))
    }

    func parseIf() throws -> ShellCompoundCommand {
        let start = i
        try consumeWord("if")
        var branches: [ShellConditionalBranch] = []
        var elseBody: ShellScript?
        while true {
            let (condition, stop) = try parseList([.keyword("then")])
            guard stop == .keyword("then"), !condition.items.isEmpty else {
                throw syntax("an `if` without its condition", start, i)
            }
            try consumeWord("then")
            let (body, next) = try parseList([.keyword("elif"), .keyword("else"), .keyword("fi")])
            if body.items.isEmpty { throw syntax("an empty `then`", start, i) }
            branches.append(ShellConditionalBranch(condition: condition, body: body))
            if next == .keyword("elif") { try consumeWord("elif"); continue }
            if next == .keyword("else") {
                try consumeWord("else")
                let (e, _) = try parseList([.keyword("fi")])
                if e.items.isEmpty { throw syntax("an empty `else`", start, i) }
                elseBody = e
            }
            try consumeWord("fi")
            break
        }
        let redirections = try parseTrailingRedirections()
        return ShellCompoundCommand(kind: .ifClause(branches: branches, elseBody: elseBody), redirections: redirections,
                                    utf16Range: range(start, i))
    }

    func parseFor() throws -> ShellCompoundCommand {
        let start = i
        try consumeWord("for")
        skipBlanks()
        if at("((") { throw notAccepted("a C-style `for ((…))`", start, i + 2) }
        let nameStart = i
        while i < end, Ch.isNameChar(u[i]) { i += 1 }
        guard i > nameStart, Ch.isNameStart(u[nameStart]), i >= end || Ch.isDelimiter(u[i]) else {
            throw notAccepted("this form of `for`", start, max(i, nameStart + 1))
        }
        let name = Ch.string(u[nameStart..<i])
        try token(nameStart, i)
        skipBlanks()
        var items: [ShellWord]?
        if i < end, u[i] == Ch.lparen { throw notAccepted("zsh's `for name (…)`", start, i + 1) }
        if peekReservedWord() == "in" {
            try consumeWord("in")
            var list: [ShellWord] = []
            while true {
                skipBlanks()
                guard i < end else { throw problem(.unclosed, "a `for` without `do`", start, i) }
                let c = u[i]
                if c == Ch.semicolon || c == Ch.newline { break }
                if c == Ch.hash { readComment(); break }
                if Ch.isMeta(c) { throw syntax("an unexpected `\(Ch.string([c]))` in a `for` list", i) }
                list.append(try readWord(.normal))
            }
            items = list
        } else {
            // `for name; do` or `for name` and a newline: the positional parameters.
            let n = peekReservedWord()
            if i < end, u[i] != Ch.semicolon, u[i] != Ch.newline, n != "do" {
                throw notAccepted("this form of `for`", start, i)
            }
        }
        if i < end, u[i] == Ch.semicolon { try token(i, i + 1); i += 1 }
        try skipLinebreaks()
        guard peekReservedWord() == "do" else { throw notAccepted("a `for` without `do … done`", start, i) }
        try consumeWord("do")
        let (body, _) = try parseList([.keyword("done")])
        if body.items.isEmpty { throw syntax("an empty `do … done`", start, i) }
        try consumeWord("done")
        let redirections = try parseTrailingRedirections()
        return ShellCompoundCommand(kind: .forLoop(variable: name, items: items, body: body), redirections: redirections,
                                    utf16Range: range(start, i))
    }

    func parseLoop(until: Bool) throws -> ShellCompoundCommand {
        let start = i
        try consumeWord(until ? "until" : "while")
        let (condition, _) = try parseList([.keyword("do")])
        if condition.items.isEmpty { throw syntax("a loop without its condition", start, i) }
        try consumeWord("do")
        let (body, _) = try parseList([.keyword("done")])
        if body.items.isEmpty { throw syntax("an empty `do … done`", start, i) }
        try consumeWord("done")
        let redirections = try parseTrailingRedirections()
        let kind: ShellCompoundCommand.Kind = until ? .untilLoop(condition: condition, body: body)
            : .whileLoop(condition: condition, body: body)
        return ShellCompoundCommand(kind: kind, redirections: redirections, utf16Range: range(start, i))
    }

    func parseCase() throws -> ShellCompoundCommand {
        let start = i
        try consumeWord("case")
        skipBlanks()
        guard i < end, !Ch.isDelimiter(u[i]) else { throw syntax("a `case` without its word", start, i) }
        let subject = try readWord(.normal)
        try skipLinebreaks()
        guard peekReservedWord() == "in" else { throw syntax("a `case` without `in`", start, i) }
        try consumeWord("in")
        var items: [ShellCaseItem] = []
        while true {
            try skipLinebreaks()
            guard i < end else { throw problem(.unclosed, "a `case` without `esac`", start, i) }
            if peekReservedWord() == "esac" { try consumeWord("esac"); break }
            if u[i] == Ch.lparen { try token(i, i + 1); i += 1 }
            var patterns: [ShellWord] = []
            while true {
                skipBlanks()
                guard i < end else { throw problem(.unclosed, "a `case` without `esac`", start, i) }
                if Ch.isDelimiter(u[i]) { throw syntax("a `case` pattern is missing", i) }
                patterns.append(try readWord(.casePattern))
                skipBlanks()
                guard i < end else { throw problem(.unclosed, "a `case` without `esac`", start, i) }
                if u[i] == Ch.pipe { try token(i, i + 1); i += 1; continue }
                if u[i] == Ch.rparen { try token(i, i + 1); i += 1; break }
                throw syntax("an unexpected character in a `case` pattern", i)
            }
            let (body, stop) = try parseList([.caseTerminator, .keyword("esac")])
            items.append(ShellCaseItem(patterns: patterns, body: body))
            if stop == .caseTerminator {
                try token(i, i + 2)
                i += 2
            }
        }
        let redirections = try parseTrailingRedirections()
        return ShellCompoundCommand(kind: .caseClause(subject: subject, items: items), redirections: redirections,
                                    utf16Range: range(start, i))
    }

    func parseCondition() throws -> ShellCompoundCommand {
        let start = i
        try consumeWord("[[")
        var words: [ShellWord] = []
        while true {
            while i < end {
                if Ch.isBlank(u[i]) { i += 1; continue }
                if u[i] == Ch.newline { i += 1; try readPendingHereDocuments(); continue }
                if u[i] == Ch.backslash, i + 1 < end, u[i + 1] == Ch.newline { i += 2; continue }
                break
            }
            guard i < end else { throw problem(.unclosed, "an unclosed `[[`", start, i) }
            if peekReservedWord() == "]]" { try consumeWord("]]"); break }
            if u[i] == Ch.hash { throw notAccepted("a `#` word inside `[[ … ]]`", i) }
            if peekReservedWord() == "}" { throw syntax("a `}` inside `[[ … ]]`", i) }
            words.append(try readWord(.condition))
        }
        if words.isEmpty { throw syntax("an empty `[[ ]]`", start, i) }
        let redirections = try parseTrailingRedirections()
        return ShellCompoundCommand(kind: .condition(words: words), redirections: redirections, utf16Range: range(start, i))
    }

    func parseArithmeticCommand() throws -> ShellCompoundCommand {
        let start = i
        try token(i, i + 2)
        i += 2
        let arithmetic = try readArithmetic(from: start)
        let redirections = try parseTrailingRedirections()
        return ShellCompoundCommand(kind: .arithmetic(arithmetic), redirections: redirections, utf16Range: range(start, i))
    }

    /// Redirections after a compound command; a word there is a syntax error.
    func parseTrailingRedirections() throws -> [ShellRedirection] {
        var out: [ShellRedirection] = []
        while true {
            skipBlanks()
            guard i < end else { return out }
            if try isRedirectionStart() { out.append(try parseRedirection()); continue }
            let c = u[i]
            if Ch.isDelimiter(c) || c == Ch.hash { return out }
            if peekReservedWord() == "}" { return out }
            throw syntax("a word after a compound command", i)
        }
    }

    // MARK: Simple commands

    static let notAcceptedCommands: Set<String> = [
        "alias", "unalias", "functions", "unfunction", "setopt", "unsetopt", "emulate", "autoload", "zmodload", "trap",
        "noglob", "nocorrect", "-", "hash", "unhash", "enable", "disable", "bindkey", "zle", "zstyle", "compdef",
        "sched", "zcompile", "vared", "zparseopts", "zformat", "ztcp", "zsocket", "zpty", "zftp",
    ]

    func parseSimpleCommand() throws -> ShellSimpleCommand {
        let start = i
        var last = i
        var assignments: [ShellAssignment] = []
        var words: [ShellWord] = []
        var redirections: [ShellRedirection] = []
        while true {
            last = i
            skipBlanks()
            guard i < end else { break }
            let c = u[i]
            if c == Ch.newline || c == Ch.semicolon || c == Ch.pipe || c == Ch.rparen { break }
            if try isRedirectionStart() { redirections.append(try parseRedirection()); continue }
            if c == Ch.amp { break }
            if c == Ch.hash { break }
            if c == Ch.lparen {
                if words.count == 1 {
                    var k = i + 1
                    while k < end, Ch.isBlank(u[k]) { k += 1 }
                    if k < end, u[k] == Ch.rparen { throw notAccepted("a function definition", start, k + 1) }
                }
                throw notAccepted("a `(` inside a command (a zsh pattern or qualifier)", i)
            }
            if peekReservedWord() == "}" { break }
            if words.isEmpty, let a = try readAssignmentIfAny() { assignments.append(a); continue }
            let w = try readWord(.normal)
            // zsh's `{name}>file` allocates a named descriptor: not in the accepted language.
            if i < end, u[i] == Ch.less || u[i] == Ch.greater, let t = w.literalText, t.count > 2, t.hasPrefix("{"),
               t.hasSuffix("}"), t.dropFirst().dropLast().unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }) {
                throw notAccepted("a named descriptor `{name}>`", w.utf16Range.lowerBound, w.utf16Range.upperBound, original: true)
            }
            if words.isEmpty, let t = w.literalText, Self.notAcceptedCommands.contains(t) {
                throw notAccepted("`\(t)`", w.utf16Range.lowerBound, w.utf16Range.upperBound, original: true)
            }
            words.append(w)
        }
        if words.isEmpty, assignments.isEmpty, redirections.isEmpty {
            throw syntax("a command is missing", start)
        }
        // The command ends where its last word or redirection ends, not after the blanks that follow.
        return ShellSimpleCommand(assignments: assignments, words: words, redirections: redirections,
                                  utf16Range: range(start, max(start, last)))
    }

    func notAccepted(_ detail: String, _ a: Int, _ b: Int, original: Bool) -> ShellScanProblem {
        ShellScanProblem(kind: .notAccepted, detail: detail, utf16Range: a..<max(a, b))
    }

    /// `NAME=value` or `NAME+=value` at `i`.
    func readAssignmentIfAny() throws -> ShellAssignment? {
        guard i < end, Ch.isNameStart(u[i]) else { return nil }
        var k = i
        while k < end, Ch.isNameChar(u[k]) { k += 1 }
        if k < end, u[k] == Ch.lbracket {
            var j = k + 1
            while j < end, u[j] != Ch.rbracket, !Ch.isDelimiter(u[j]) { j += 1 }
            if j + 1 < end, u[j] == Ch.rbracket, u[j + 1] == Ch.equals || (u[j + 1] == Ch.plus && j + 2 < end && u[j + 2] == Ch.equals) {
                throw notAccepted("an array element assignment `name[…]=`", i, j + 2)
            }
        }
        var appends = false
        if k < end, u[k] == Ch.plus, k + 1 < end, u[k + 1] == Ch.equals { appends = true; k += 1 }
        guard k < end, u[k] == Ch.equals else { return nil }
        let start = i
        let name = Ch.string(u[i..<(appends ? k - 1 : k)])
        i = k + 1
        if i < end, u[i] == Ch.lparen { throw notAccepted("an array assignment `name=(…)`", start, i + 1) }
        let value = try readWord(.assignmentValue)
        try token(start, i)
        return ShellAssignment(name: name, appends: appends, value: value, utf16Range: range(start, i))
    }

    // MARK: Redirections

    /// True at a redirection operator (`2>`, `<`, `&>`, …), false at `<(`/`>(` (process substitution words).
    func isRedirectionStart() throws -> Bool {
        guard i < end else { return false }
        var k = i
        if Ch.isDigit(u[k]) {
            while k < end, Ch.isDigit(u[k]) { k += 1 }
            guard k < end, u[k] == Ch.less || u[k] == Ch.greater else { return false }
            if k - i > 1 { throw notAccepted("a descriptor number above 9", i, k + 1) }
        } else if u[k] == Ch.amp {
            return k + 1 < end && u[k + 1] == Ch.greater
        }
        guard k < end, u[k] == Ch.less || u[k] == Ch.greater else { return false }
        if k + 1 < end, u[k + 1] == Ch.lparen { return k != i ? true : false }
        if u[k] == Ch.less, isNumericGlob(at: k) { throw notAccepted("a zsh number pattern `<1-9>`", k) }
        return true
    }

    /// `<…>` holding only digits and one `-` is a zsh numeric glob, not a redirection.
    func isNumericGlob(at k: Int) -> Bool {
        var j = k + 1
        var dash = false
        while j < end, Ch.isDigit(u[j]) || (u[j] == Ch.minus && !dash) {
            if u[j] == Ch.minus { dash = true }
            j += 1
        }
        return dash && j < end && u[j] == Ch.greater
    }

    func parseRedirection() throws -> ShellRedirection {
        let start = i
        var fd: Int?
        if Ch.isDigit(u[i]) { fd = Int(u[i] - 0x30); i += 1 }
        let op: ShellRedirection.Operator
        if u[i] == Ch.amp {
            i += 2
            if i < end, u[i] == Ch.greater { i += 1; op = .appendOutputAndError } else { op = .outputAndError }
            if i < end, u[i] == Ch.pipe || u[i] == Ch.bang { throw notAccepted("zsh's `&>|` and `&>!`", start, i + 1) }
        } else if u[i] == Ch.less {
            if at("<<<") { i += 3; op = .hereString }
            else if at("<<-") { i += 3; op = .hereDocumentStrippingTabs }
            else if at("<<") { i += 2; op = .hereDocument }
            else if at("<&") { i += 2; op = .duplicateInput }
            else if at("<>") { throw notAccepted("`<>`", start, i + 2) }
            else { i += 1; op = .input }
        } else {
            if at(">>") {
                i += 2
                if i < end, u[i] == Ch.pipe || u[i] == Ch.bang { throw notAccepted("zsh's `>>|` and `>>!`", start, i + 1) }
                op = .append
            } else if at(">|") { i += 2; op = .clobber }
            else if at(">!") { throw notAccepted("zsh's `>!`", start, i + 2) }
            else if at(">&") { i += 2; op = .duplicateOutput }
            else { i += 1; op = .output }
        }
        if fd != nil, op == .outputAndError || op == .appendOutputAndError {
            throw syntax("a descriptor before `&>`", start, i)
        }
        try token(start, i)
        let opEnd = i
        skipBlanks()
        guard i < end, !Ch.isDelimiter(u[i]) || at("<(") || at(">(") else {
            throw syntax("a redirection without its target", start, opEnd)
        }
        if u[i] == Ch.hash { throw syntax("a redirection without its target", start, opEnd) }
        if op == .hereDocument || op == .hereDocumentStrippingTabs {
            return try parseHereDocumentOperator(start: start, op: op, fd: fd, opEnd: opEnd)
        }
        let target = try readWord(.normal)
        if op == .duplicateInput, !target.isDescriptorReference {
            throw notAccepted("`<&` with a file", start, i)
        }
        return ShellRedirection(fileDescriptor: fd, op: op, target: target, hereDocument: nil, utf16Range: range(start, i))
    }

    func parseHereDocumentOperator(start: Int, op: ShellRedirection.Operator, fd: Int?, opEnd: Int) throws
        -> ShellRedirection {
        let word = try readWord(.hereDocumentDelimiter)
        guard let delimiter = word.literalText, !delimiter.isEmpty, !word.hasPattern else {
            throw notAccepted("this here-doc delimiter", start, i)
        }
        let slot = run.nextSlot
        run.nextSlot += 1
        pending.append(PendingHereDocument(slot: slot, delimiter: Array(delimiter.utf16), quoted: word.isQuoted,
                                           stripsTabs: op == .hereDocumentStrippingTabs, operatorRange: start..<i))
        var placeholder = ShellHereDocument(delimiter: delimiter, delimiterQuoted: word.isQuoted,
                                            stripsTabs: op == .hereDocumentStrippingTabs, body: "", bodyRange: 0..<0,
                                            content: ShellWord(parts: [], utf16Range: 0..<0))
        placeholder.slot = slot
        return ShellRedirection(fileDescriptor: fd, op: op, target: word, hereDocument: placeholder,
                                utf16Range: range(start, i))
    }

    // MARK: Here-doc bodies

    /// Reads the bodies of the here-docs named on the line that just ended (at `i`, after its newline).
    func readPendingHereDocuments() throws {
        guard !pending.isEmpty else { return }
        let docs = pending
        pending.removeAll()
        for p in docs { try readHereDocumentBody(p) }
    }

    func readHereDocumentBody(_ p: PendingHereDocument) throws {
        let bodyStart = i
        var lineStart = i
        var bodyEnd = -1
        var text: [UInt16] = []
        while lineStart < end {
            var lineEnd = lineStart
            while lineEnd < end, u[lineEnd] != Ch.newline { lineEnd += 1 }
            var contentStart = lineStart
            if p.stripsTabs { while contentStart < lineEnd, u[contentStart] == Ch.tab { contentStart += 1 } }
            if lineEnd - contentStart == p.delimiter.count, Array(u[contentStart..<lineEnd]) == p.delimiter {
                bodyEnd = lineStart
                i = lineEnd < end ? lineEnd + 1 : lineEnd
                break
            }
            if !p.quoted {
                var backslashes = 0
                var k = lineEnd - 1
                while k >= contentStart, u[k] == Ch.backslash { backslashes += 1; k -= 1 }
                if backslashes % 2 == 1 {
                    throw notAccepted("a line join (`\\` at a line end) inside an unquoted here-doc", k + 1, lineEnd)
                }
            }
            text.append(contentsOf: u[contentStart..<lineEnd])
            text.append(Ch.newline)
            lineStart = lineEnd + 1
        }
        guard bodyEnd >= 0 else {
            throw problem(.unterminatedHereDocument, "a here-doc without its end line", p.operatorRange.lowerBound,
                          p.operatorRange.upperBound)
        }
        let bodyRange = range(bodyStart, bodyEnd)
        let content: ShellWord
        if p.quoted {
            content = ShellWord(parts: [.text(Ch.string(text), quoting: .single, decodedEscapes: false,
                                              utf16Range: bodyRange)], utf16Range: bodyRange)
        } else {
            let resume = i
            i = bodyStart
            let savedEnd = end
            end = bodyEnd
            defer { end = savedEnd }
            let parts = try readHereDocumentExpansions(stripsTabs: p.stripsTabs)
            end = savedEnd
            i = resume
            content = ShellWord(parts: parts, utf16Range: bodyRange)
        }
        try run.countToken(at: bodyRange)
        let doc = ShellHereDocument(delimiter: Ch.string(p.delimiter), delimiterQuoted: p.quoted, stripsTabs: p.stripsTabs,
                                    body: Ch.string(text), bodyRange: bodyRange, content: content)
        run.bodies[p.slot] = doc
        run.hereDocuments.append(doc)
    }
}
