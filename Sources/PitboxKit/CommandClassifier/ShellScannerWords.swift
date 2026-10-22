import Foundation

// Words of the accepted language (docs/SHELL_LANGUAGE.md §2): single quotes, double quotes, `$'…'`, backslash
// escapes and joins, `$NAME`, `${NAME}`, `${NAME:-word}`, `${NAME:=word}`, `${NAME:?word}`, `${#NAME}`, `$1`-`$9`,
// `$?`, `$$`, `$@`, `$(…)`, backticks, `$((…))`, `<(…)`, `>(…)`, `~`, `~/…`, plain globs and brace lists. zsh
// constructs outside that list end the scan (B3): parameter flags and modifiers, subscripts, `=command`, `~user`,
// history words, glob qualifiers, nested `${…${…}}`.

/// Where a word is read: the rules for what ends it and what is special differ.
enum ShellWordContext: Equatable {
    case normal
    /// After `NAME=`: no globbing or brace lists, `~` at the start.
    case assignmentValue
    /// After `<<`: must be literal.
    case hereDocumentDelimiter
    /// Inside `[[ … ]]`: `<`, `>`, `(`, `)`, `|`, `&`, `!` are text.
    case condition
    /// A `case` pattern: `|` and `)` end it.
    case casePattern
    /// After `${NAME:-`: ends at `}`; blanks and operators are text.
    case parameterWord(inDoubleQuotes: Bool)

    var expandsFileNames: Bool { self == .normal }
}

extension ShellParser {
    // MARK: Words

    func readWord(_ ctx: ShellWordContext) throws -> ShellWord {
        let start = i
        var parts: [ShellWordPart] = []
        var lit: [UInt16] = []
        var litStart = i

        func flush(_ upTo: Int) {
            guard !lit.isEmpty else { return }
            parts.append(.text(Ch.string(lit), quoting: .none, decodedEscapes: false, utf16Range: range(litStart, upTo)))
            lit.removeAll(keepingCapacity: true)
        }
        func append(_ c: UInt16, at pos: Int) {
            if lit.isEmpty { litStart = pos }
            lit.append(c)
        }

        var isParameterWord = false
        var paramInDoubleQuotes = false
        if case .parameterWord(let q) = ctx { isParameterWord = true; paramInDoubleQuotes = q }

        scan: while i < end {
            let c = u[i]
            let atStart = (i == start)
            // What ends the word.
            if isParameterWord {
                if c == Ch.rbrace { break scan }
                if c == Ch.lbrace { throw notAccepted("a `{` inside `${…}`", i) }
            } else if ctx == .condition {
                if Ch.isBlank(c) || c == Ch.newline { break scan }
                if c == Ch.semicolon { throw notAccepted("a `;` inside `[[ … ]]`", i) }
            } else if ctx == .casePattern {
                if Ch.isBlank(c) || c == Ch.newline || c == Ch.pipe || c == Ch.rparen { break scan }
                if c == Ch.lparen { throw notAccepted("a zsh pattern group `(…)` in a `case`", i) }
                if Ch.isMeta(c) { break scan }
            } else {
                if Ch.isBlank(c) || c == Ch.newline { break scan }
                if Ch.isMeta(c) {
                    if ctx == .normal, atStart, c == Ch.less || c == Ch.greater, peek(1) == Ch.lparen {
                        parts.append(try readProcessSubstitution())
                        continue scan
                    }
                    if c == Ch.lparen {
                        throw notAccepted("a `(` inside a word (a zsh glob qualifier or pattern)", i)
                    }
                    break scan
                }
                if ctx == .normal, atStart, c == Ch.hash { throw syntax("a comment where a word belongs", i) }
            }

            switch c {
            case Ch.backslash:
                guard i + 1 < end else { throw problem(.trailingBackslash, "a `\\` at the very end", i) }
                let n = u[i + 1]
                if n == Ch.newline { i += 2; continue scan }
                flush(i)
                var len = 1
                if Ch.isHighSurrogate(n), i + 2 < end, Ch.isLowSurrogate(u[i + 2]) { len = 2 }
                parts.append(.text(Ch.string(u[(i + 1)..<(i + 1 + len)]), quoting: .backslash, decodedEscapes: false,
                                   utf16Range: range(i, i + 1 + len)))
                i += 1 + len
            case Ch.squote:
                if paramInDoubleQuotes { throw notAccepted("a `'` inside a quoted `${…}`", i) }
                flush(i)
                parts.append(try readSingleQuoted())
            case Ch.dquote:
                flush(i)
                parts.append(contentsOf: try readDoubleQuoted())
            case Ch.dollar:
                flush(i)
                if let p = try readDollar(quoted: false, inParameterWord: isParameterWord) {
                    parts.append(p)
                } else {
                    append(Ch.dollar, at: i)
                    i += 1
                }
            case Ch.backtick:
                flush(i)
                parts.append(try readBackticks(quoted: false))
            case Ch.star, Ch.question:
                if ctx.expandsFileNames {
                    flush(i)
                    parts.append(.glob(Ch.string([c]), utf16Range: range(i, i + 1)))
                } else {
                    append(c, at: i)
                }
                i += 1
            case Ch.lbracket:
                if ctx.expandsFileNames, let close = globBracketEnd(from: i) {
                    flush(i)
                    parts.append(.glob(Ch.string(u[i...close]), utf16Range: range(i, close + 1)))
                    i = close + 1
                } else {
                    append(c, at: i)
                    i += 1
                }
            case Ch.lbrace:
                if ctx.expandsFileNames, let brace = try readBraceList() {
                    flush(i)
                    parts.append(brace)
                } else {
                    append(c, at: i)
                    i += 1
                }
            case Ch.tilde where atStart && ctx != .hereDocumentDelimiter:
                let n = peek(1)
                let ends = n.map { Ch.isDelimiter($0) || $0 == Ch.slash } ?? true
                    || (isParameterWord && n == Ch.rbrace) || (ctx == .assignmentValue && n == Ch.colon)
                guard ends else { throw notAccepted("`~user`, `~+` or `~-`", i, i + 2) }
                parts.append(.tilde(utf16Range: range(i, i + 1)))
                i += 1
            case Ch.equals where atStart && ctx == .normal:
                if let n = peek(1), !Ch.isDelimiter(n) {
                    throw notAccepted("zsh's `=command` expansion", i, i + 2)
                }
                append(c, at: i)
                i += 1
            case Ch.bang where !isParameterWord:
                if let n = peek(1), !(Ch.isBlank(n) || n == Ch.newline || n == Ch.equals) {
                    if !(ctx == .condition && n == Ch.tilde) {
                        throw notAccepted("a history word `!…`", i, i + 2)
                    }
                }
                append(c, at: i)
                i += 1
            default:
                append(c, at: i)
                i += 1
            }
        }
        flush(i)
        if parts.isEmpty {
            if ctx == .assignmentValue || isParameterWord {
                return ShellWord(parts: [], utf16Range: range(start, i))
            }
            throw syntax("a word is missing", start)
        }
        try token(start, i)
        return ShellWord(parts: parts, utf16Range: range(start, i))
    }

    func readSingleQuoted() throws -> ShellWordPart {
        let start = i
        var k = i + 1
        while k < end, u[k] != Ch.squote { k += 1 }
        guard k < end else { throw problem(.unclosedQuote, "an unclosed `'`", start, end) }
        let text = Ch.string(u[(start + 1)..<k])
        i = k + 1
        return .text(text, quoting: .single, decodedEscapes: false, utf16Range: range(start, i))
    }

    func readDoubleQuoted() throws -> [ShellWordPart] {
        let start = i
        i += 1
        var parts: [ShellWordPart] = []
        var lit: [UInt16] = []
        var litStart = i
        func flush(_ upTo: Int) {
            guard !lit.isEmpty else { return }
            parts.append(.text(Ch.string(lit), quoting: .double, decodedEscapes: false, utf16Range: range(litStart, upTo)))
            lit.removeAll(keepingCapacity: true)
        }
        func append(_ c: UInt16, at pos: Int) {
            if lit.isEmpty { litStart = pos }
            lit.append(c)
        }
        while true {
            guard i < end else { throw problem(.unclosedQuote, "an unclosed `\"`", start, end) }
            let c = u[i]
            if c == Ch.dquote {
                flush(i)
                i += 1
                break
            }
            if c == Ch.backslash, i + 1 < end {
                let n = u[i + 1]
                if n == Ch.newline { i += 2; continue }
                if n == Ch.dollar || n == Ch.backtick || n == Ch.dquote || n == Ch.backslash {
                    append(n, at: i)
                    i += 2
                    continue
                }
                append(c, at: i)
                i += 1
                continue
            }
            if c == Ch.dollar {
                flush(i)
                if let p = try readDollar(quoted: true, inParameterWord: false) {
                    parts.append(p)
                } else {
                    append(c, at: i)
                    i += 1
                }
                continue
            }
            if c == Ch.backtick {
                flush(i)
                parts.append(try readBackticks(quoted: true))
                continue
            }
            append(c, at: i)
            i += 1
        }
        if parts.isEmpty {
            parts.append(.text("", quoting: .double, decodedEscapes: false, utf16Range: range(start, i)))
        } else if parts.count == 1, case .text(let t, let q, let d, _) = parts[0] {
            parts[0] = .text(t, quoting: q, decodedEscapes: d, utf16Range: range(start, i))
        }
        return parts
    }

    // MARK: $ expansions

    /// An expansion at `$`, or nil when this `$` is a plain character.
    func readDollar(quoted: Bool, inParameterWord: Bool) throws -> ShellWordPart? {
        let start = i
        guard let n = peek(1) else { return nil }
        switch n {
        case Ch.squote where !quoted:
            return try readAnsiC()
        case Ch.dquote where !quoted:
            throw notAccepted("`$\"…\"`", start, start + 2)
        case Ch.lbrace:
            if inParameterWord { throw notAccepted("a nested `${…${…}}`", start, start + 2) }
            return .parameter(try readBracedParameter(quoted: quoted))
        case Ch.lparen:
            if peek(2) == Ch.lparen { return .arithmetic(try readArithmeticExpansion()) }
            return try readCommandSubstitution(quoted: quoted)
        case Ch.lbracket:
            throw notAccepted("`$[…]` arithmetic", start, start + 2)
        case Ch.tilde, Ch.equals, Ch.caret, Ch.plus:
            throw notAccepted("zsh's `$\(Ch.string([n]))name`", start, start + 2)
        default:
            break
        }
        if Ch.isNameStart(n) || Ch.isDigit(n) {
            var k = i + 1
            if Ch.isNameStart(n) {
                while k < end, Ch.isNameChar(u[k]) { k += 1 }
            } else {
                while k < end, Ch.isDigit(u[k]) { k += 1 }
            }
            let name = Ch.string(u[(i + 1)..<k])
            try rejectZshSuffix(at: k, start: start)
            i = k
            return .parameter(ShellParameter(name: name, form: .plain, word: nil, quoted: quoted,
                                             utf16Range: range(start, k)))
        }
        if n == Ch.question || n == Ch.dollar || n == Ch.at || n == Ch.hash || n == Ch.star || n == Ch.bang
            || n == Ch.minus {
            if n == Ch.hash, let m = peek(2), Ch.isNameStart(m) {
                var k = i + 2
                while k < end, Ch.isNameChar(u[k]) { k += 1 }
                let name = Ch.string(u[(i + 2)..<k])
                try rejectZshSuffix(at: k, start: start)
                i = k
                return .parameter(ShellParameter(name: name, form: .length, word: nil, quoted: quoted,
                                                 utf16Range: range(start, k)))
            }
            i += 2
            return .parameter(ShellParameter(name: Ch.string([n]), form: .plain, word: nil, quoted: quoted,
                                             utf16Range: range(start, i)))
        }
        return nil
    }

    /// zsh reads `$name[…]` as a subscript and `$name:h` as a modifier; neither is in the accepted language.
    func rejectZshSuffix(at k: Int, start: Int) throws {
        guard k < end else { return }
        if u[k] == Ch.lbracket { throw notAccepted("a zsh subscript `$name[…]`", start, k + 1) }
        if u[k] == Ch.colon, k + 1 < end, Ch.isLetter(u[k + 1]) || u[k + 1] == Ch.amp {
            throw notAccepted("a zsh modifier `$name:…`", start, k + 2)
        }
    }

    func readBracedParameter(quoted: Bool) throws -> ShellParameter {
        let start = i
        i += 2
        guard i < end else { throw problem(.unclosed, "an unclosed `${`", start, end) }
        let first = u[i]
        if first == Ch.lparen { throw notAccepted("zsh parameter flags `${(…)…}`", start, i + 1) }
        if first == Ch.tilde || first == Ch.equals || first == Ch.caret || first == Ch.plus {
            throw notAccepted("zsh's `${\(Ch.string([first]))…}`", start, i + 1)
        }
        if first == Ch.bang { throw notAccepted("an indirect `${!…}`", start, i + 1) }
        var form = ShellParameter.Form.braced
        if first == Ch.hash, peek(1) != Ch.rbrace {
            form = .length
            i += 1
        }
        let nameStart = i
        if i < end, Ch.isNameStart(u[i]) {
            while i < end, Ch.isNameChar(u[i]) { i += 1 }
        } else if i < end, Ch.isDigit(u[i]) {
            while i < end, Ch.isDigit(u[i]) { i += 1 }
        } else if i < end, [Ch.question, Ch.at, Ch.dollar, Ch.star, Ch.minus, Ch.hash].contains(u[i]) {
            i += 1
        }
        guard i > nameStart else {
            if i >= end { throw problem(.unclosed, "an unclosed `${`", start, end) }
            throw notAccepted("this `${…}`", start, i + 1)
        }
        let name = Ch.string(u[nameStart..<i])
        guard i < end else { throw problem(.unclosed, "an unclosed `${`", start, end) }
        let c = u[i]
        if c == Ch.rbrace {
            i += 1
            return ShellParameter(name: name, form: form, word: nil, quoted: quoted, utf16Range: range(start, i))
        }
        if form == .length { throw notAccepted("this form of `${#…}`", start, i + 1) }
        if c == Ch.colon, let n = peek(1), n == Ch.minus || n == Ch.equals || n == Ch.question {
            form = n == Ch.minus ? .useDefault : (n == Ch.equals ? .assignDefault : .errorIfUnset)
            i += 2
            let word = try readWord(.parameterWord(inDoubleQuotes: quoted))
            guard i < end, u[i] == Ch.rbrace else { throw problem(.unclosed, "an unclosed `${`", start, i) }
            i += 1
            return ShellParameter(name: name, form: form, word: word, quoted: quoted, utf16Range: range(start, i))
        }
        if c == Ch.colon { throw notAccepted("a zsh modifier or substring `${name:…}`", start, i + 2) }
        if c == Ch.lbracket { throw notAccepted("a subscript `${name[…]}`", start, i + 1) }
        throw notAccepted("the parameter operation `${name\(Ch.string([c]))…}`", start, i + 1)
    }

    func readAnsiC() throws -> ShellWordPart {
        let start = i
        i += 2
        var buf: [UInt16] = []
        var decoded = false
        func push(_ value: UInt32, at pos: Int) throws {
            guard value != 0 else { throw notAccepted("a NUL character in `$'…'`", start, pos) }
            guard let scalar = Unicode.Scalar(value) else { throw notAccepted("an invalid character in `$'…'`", start, pos) }
            buf.append(contentsOf: Array(String(Character(scalar)).utf16))
        }
        func hex(_ maxDigits: Int) -> UInt32? {
            var v: UInt32 = 0
            var n = 0
            while n < maxDigits, i < end, let d = Self.hexValue(u[i]) {
                v = v &* 16 &+ d
                i += 1
                n += 1
            }
            return n > 0 ? v : nil
        }
        while true {
            guard i < end else { throw problem(.unclosedQuote, "an unclosed `$'`", start, end) }
            let c = u[i]
            if c == Ch.squote { i += 1; break }
            guard c == Ch.backslash else { buf.append(c); i += 1; continue }
            guard i + 1 < end else { throw problem(.unclosedQuote, "an unclosed `$'`", start, end) }
            let escStart = i
            let n = u[i + 1]
            i += 2
            switch n {
            case 0x6E: buf.append(0x0A)           // n
            case 0x74: buf.append(0x09)           // t
            case 0x72: buf.append(0x0D)           // r
            case 0x61: buf.append(0x07)           // a
            case 0x62: buf.append(0x08)           // b
            case 0x65, 0x45: buf.append(0x1B)     // e E
            case 0x66: buf.append(0x0C)           // f
            case 0x76: buf.append(0x0B)           // v
            case Ch.backslash, Ch.squote, Ch.dquote, Ch.question: buf.append(n)
            case 0x78:                            // x
                if let v = hex(2) { decoded = true; try push(v, at: i) } else { buf.append(Ch.backslash); buf.append(n) }
            case 0x75:                            // u
                if let v = hex(4) { decoded = true; try push(v, at: i) } else { buf.append(Ch.backslash); buf.append(n) }
            case 0x55:                            // U
                if let v = hex(8) { decoded = true; try push(v, at: i) } else { buf.append(Ch.backslash); buf.append(n) }
            case 0x30...0x37:                     // octal
                var v = UInt32(n - 0x30)
                var digits = 1
                while digits < 3, i < end, u[i] >= 0x30, u[i] <= 0x37 {
                    v = v * 8 + UInt32(u[i] - 0x30)
                    i += 1
                    digits += 1
                }
                decoded = true
                try push(v, at: i)
            case 0x63:                            // c
                guard i < end else { throw problem(.unclosedQuote, "an unclosed `$'`", start, end) }
                decoded = true
                try push(UInt32(u[i] & 0x1F), at: i + 1)
                i += 1
            default:
                _ = escStart
                buf.append(Ch.backslash)
                buf.append(n)
            }
        }
        return .text(Ch.string(buf), quoting: .ansiC, decodedEscapes: decoded, utf16Range: range(start, i))
    }

    static func hexValue(_ c: UInt16) -> UInt32? {
        switch c {
        case 0x30...0x39: return UInt32(c - 0x30)
        case 0x41...0x46: return UInt32(c - 0x41 + 10)
        case 0x61...0x66: return UInt32(c - 0x61 + 10)
        default: return nil
        }
    }

    // MARK: Substitutions

    func checkSubstitutionDepth(_ start: Int) throws {
        if substitutionDepth >= ShellCommandScanner.maxSubstitutionDepth {
            throw problem(.tooDeep, "more than \(ShellCommandScanner.maxSubstitutionDepth) levels of substitutions",
                          start, start + 2)
        }
    }

    func readCommandSubstitution(quoted: Bool) throws -> ShellWordPart {
        let start = i
        try checkSubstitutionDepth(start)
        i += 2
        substitutionDepth += 1
        defer { substitutionDepth -= 1 }
        let (script, stop) = try parseList([.closeParen])
        guard stop == .closeParen, i < end, u[i] == Ch.rparen else {
            throw problem(.unclosed, "an unclosed `$(`", start, i)
        }
        i += 1
        try token(start, i)
        return .commandSubstitution(script, backticks: false, quoted: quoted, utf16Range: range(start, i))
    }

    func readProcessSubstitution() throws -> ShellWordPart {
        let start = i
        let writes = u[i] == Ch.greater
        try checkSubstitutionDepth(start)
        i += 2
        substitutionDepth += 1
        defer { substitutionDepth -= 1 }
        let (script, stop) = try parseList([.closeParen])
        guard stop == .closeParen, i < end, u[i] == Ch.rparen else {
            throw problem(.unclosed, writes ? "an unclosed `>(`" : "an unclosed `<(`", start, i)
        }
        i += 1
        try token(start, i)
        return .processSubstitution(script, writes: writes, utf16Range: range(start, i))
    }

    /// Backticks: the inside, with `\``, `\$`, `\\` (and `\"` inside double quotes) unescaped, read as a script.
    func readBackticks(quoted: Bool) throws -> ShellWordPart {
        let start = i
        try checkSubstitutionDepth(start)
        i += 1
        var buf: [UInt16] = []
        var origin: [Int] = []
        while true {
            guard i < end else { throw problem(.unclosed, "an unclosed backtick", start, end) }
            let c = u[i]
            if c == Ch.backtick { break }
            if c == Ch.backslash, i + 1 < end {
                let n = u[i + 1]
                if n == Ch.backtick || n == Ch.dollar || n == Ch.backslash || (quoted && n == Ch.dquote) {
                    buf.append(n)
                    origin.append(source.map(i + 1))
                    i += 2
                    continue
                }
            }
            buf.append(c)
            origin.append(source.map(i))
            i += 1
        }
        let close = i
        i += 1
        let inner = ShellSource(units: buf, origin: origin, originEnd: source.map(close))
        let parser = ShellParser(source: inner, run: run, substitutionDepth: substitutionDepth + 1, nesting: nesting + 1)
        let script = try parser.parseTop()
        try token(start, i)
        return .commandSubstitution(script, backticks: true, quoted: quoted, utf16Range: range(start, i))
    }

    func readArithmeticExpansion() throws -> ShellArithmetic {
        let start = i
        try checkSubstitutionDepth(start)
        i += 3
        return try readArithmetic(from: start)
    }

    /// Reads an arithmetic expression after `((` up to its `))`.
    func readArithmetic(from start: Int) throws -> ShellArithmetic {
        substitutionDepth += 1
        defer { substitutionDepth -= 1 }
        let exprStart = i
        var depth = 0
        var expansions: [ShellWordPart] = []
        var bare: [String] = []
        while true {
            guard i < end else { throw problem(.unclosed, "an unclosed `((`", start, end) }
            let c = u[i]
            switch c {
            case Ch.lparen:
                depth += 1
                i += 1
            case Ch.rparen:
                if depth == 0 {
                    guard let n = peek(1) else { throw problem(.unclosed, "an unclosed `((`", start, end) }
                    guard n == Ch.rparen else { throw notAccepted("a `((` that is not arithmetic", start, i + 1) }
                    let expression = Ch.string(u[exprStart..<i])
                    i += 2
                    try token(start, i)
                    return ShellArithmetic(expression: expression, expansions: expansions, bareNames: bare,
                                           utf16Range: range(start, i))
                }
                depth -= 1
                i += 1
            case Ch.dollar:
                if let p = try readDollar(quoted: true, inParameterWord: false) { expansions.append(p) } else { i += 1 }
            case Ch.backtick:
                expansions.append(try readBackticks(quoted: true))
            case Ch.squote, Ch.dquote, Ch.backslash:
                throw notAccepted("quotes or `\\` inside arithmetic", i)
            case Ch.semicolon:
                throw notAccepted("a `;` inside arithmetic", i)
            case Ch.newline:
                if !pending.isEmpty { throw notAccepted("a here-doc next to a line break inside arithmetic", i) }
                i += 1
            default:
                if Ch.isNameStart(c) {
                    let s = i
                    while i < end, Ch.isNameChar(u[i]) { i += 1 }
                    bare.append(Ch.string(u[s..<i]))
                } else if Ch.isDigit(c) {
                    while i < end, Ch.isNameChar(u[i]) || u[i] == Ch.hash { i += 1 }
                } else {
                    i += 1
                }
            }
        }
    }

    // MARK: Globs and brace lists

    /// The `]` closing a glob bracket at `k`, if it closes within the word.
    func globBracketEnd(from k: Int) -> Int? {
        var j = k + 1
        if j < end, u[j] == Ch.bang || u[j] == Ch.caret { j += 1 }
        if j < end, u[j] == Ch.rbracket { j += 1 }
        while j < end {
            let c = u[j]
            if c == Ch.rbracket { return j }
            if Ch.isDelimiter(c) || c == Ch.squote || c == Ch.dquote || c == Ch.backslash || c == Ch.dollar
                || c == Ch.backtick { return nil }
            j += 1
        }
        return nil
    }

    /// A brace list at `{`, or nil when this `{` is a plain character. A brace list with quotes or expansions inside
    /// is not read (B3): zsh would expand it, and the words it makes could hide a command.
    func readBraceList() throws -> ShellWordPart? {
        let start = i
        var k = i + 1
        var depth = 1
        var plain = true
        var separator = false
        while k < end {
            let c = u[k]
            if c == Ch.squote {
                plain = false
                k += 1
                while k < end, u[k] != Ch.squote { k += 1 }
                k += 1
                continue
            }
            if c == Ch.dquote {
                plain = false
                k += 1
                while k < end, u[k] != Ch.dquote { if u[k] == Ch.backslash { k += 1 }; k += 1 }
                k += 1
                continue
            }
            if c == Ch.backslash || c == Ch.dollar || c == Ch.backtick {
                plain = false
                k += c == Ch.backslash ? 2 : 1
                continue
            }
            if Ch.isDelimiter(c) { break }
            if c == Ch.lbrace { depth += 1 }
            else if c == Ch.rbrace { depth -= 1; if depth == 0 { break } }
            else if c == Ch.comma { separator = true }
            else if c == Ch.dot, k + 1 < end, u[k + 1] == Ch.dot { separator = true }
            k += 1
        }
        let closed = k < end && u[k] == Ch.rbrace && depth == 0
        guard plain else {
            if separator { throw notAccepted("a brace list with quotes or expansions in it", start, min(k + 1, end)) }
            return nil
        }
        guard closed else { return nil }
        let text = Ch.string(u[start...k])
        switch ShellBraceList.expand(text) {
        case .notBraceList:
            return nil
        case .tooMany:
            i = k + 1
            return .braceList(text, alternatives: nil, utf16Range: range(start, i))
        case .alternatives(let words):
            i = k + 1
            return .braceList(text, alternatives: words, utf16Range: range(start, i))
        }
    }

    // MARK: Here-doc bodies

    /// The expansions in an unquoted here-doc body (`i` at the body, `end` at its end): like double quotes, but `"`
    /// is text.
    func readHereDocumentExpansions(stripsTabs: Bool) throws -> [ShellWordPart] {
        let start = i
        var parts: [ShellWordPart] = []
        var lit: [UInt16] = []
        var litStart = i
        var lineStart = true
        func flush(_ upTo: Int) {
            guard !lit.isEmpty else { return }
            parts.append(.text(Ch.string(lit), quoting: .double, decodedEscapes: false, utf16Range: range(litStart, upTo)))
            lit.removeAll(keepingCapacity: true)
        }
        func append(_ c: UInt16, at pos: Int) {
            if lit.isEmpty { litStart = pos }
            lit.append(c)
        }
        while i < end {
            let c = u[i]
            if stripsTabs, lineStart, c == Ch.tab { i += 1; continue }
            lineStart = false
            if c == Ch.newline {
                append(c, at: i)
                i += 1
                lineStart = true
                continue
            }
            if c == Ch.backslash, i + 1 < end, u[i + 1] == Ch.dollar || u[i + 1] == Ch.backtick || u[i + 1] == Ch.backslash {
                append(u[i + 1], at: i)
                i += 2
                continue
            }
            if c == Ch.dollar {
                flush(i)
                if let p = try readDollar(quoted: true, inParameterWord: false) {
                    parts.append(p)
                } else {
                    append(c, at: i)
                    i += 1
                }
                continue
            }
            if c == Ch.backtick {
                flush(i)
                parts.append(try readBackticks(quoted: false))
                continue
            }
            append(c, at: i)
            i += 1
        }
        flush(i)
        if parts.isEmpty { parts.append(.text("", quoting: .double, decodedEscapes: false, utf16Range: range(start, i))) }
        return parts
    }
}

extension ShellBraceList {
    enum Expansion: Equatable { case notBraceList, tooMany, alternatives([String]) }

    /// What zsh makes of the plain brace list `text`.
    static func expand(_ text: String) -> Expansion {
        if let words = alternatives(text) { return .alternatives(words) }
        return isBraceListShape(text) ? .tooMany : .notBraceList
    }

    /// True when `text` has the shape of a brace list (a top-level comma, or `x..y`), whatever its size.
    static func isBraceListShape(_ text: String) -> Bool {
        let inner = text.dropFirst().dropLast()
        var depth = 0
        for ch in inner {
            if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 } else if ch == ",", depth == 0 { return true }
        }
        let pieces = inner.components(separatedBy: "..")
        return (pieces.count == 2 || pieces.count == 3) && !pieces[0].isEmpty && !pieces[1].isEmpty
            && !inner.contains("{")
    }
}
