import Foundation

// Words as the rules read them: brace lists expanded (zsh expands `{rm,-rf,~}` into three words), program names,
// options split (`-rf` = `-r -f`), and local paths resolved against the home folder, the working folder and the
// variables the block set to literal text.

/// One command word: the scanner's word and, when nothing in it is filled in at run time, its text.
struct CWord {
    let word: ShellWord
    /// The literal text (one alternative of a brace list), nil when the word holds an expansion.
    let text: String?
    /// Starts with an unquoted `~` (the home folder).
    let tilde: Bool

    var range: Range<Int> { word.utf16Range }
    var isLiteral: Bool { text != nil }
    var hasPattern: Bool { word.hasPattern }
    /// The text before the first expansion (`-` of `"-$FLAGS"`).
    var staticPrefix: String {
        var out = ""
        for part in word.parts {
            switch part {
            case .text(let s, _, _, _): out += s
            case .tilde: out += "~"
            case .glob(let s, _), .braceList(let s, _, _): out += s
            default: return out
            }
        }
        return out
    }
    /// Names of the parameters in the word.
    var parameterNames: [String] {
        word.parts.compactMap { if case .parameter(let p) = $0 { return p.name }; return nil }
    }
    /// True when the word is only parameters and substitutions (quotes allowed): `"$DIR"`, `"$(pwd)"`, `${X:?}`.
    var isOnlyExpansions: Bool {
        var sawExpansion = false
        for part in word.parts {
            switch part {
            case .parameter, .commandSubstitution, .processSubstitution, .arithmetic: sawExpansion = true
            case .text(let s, _, _, _): if !s.isEmpty { return false }
            default: return false
            }
        }
        return sawExpansion
    }
}

/// An option the parser found.
struct ParsedOption {
    /// `r` for `-r`, `--recursive` for a long option.
    let name: String
    /// The option's value (attached or the next word), nil when none or when it is filled in at run time.
    let value: String?
    /// The next word when the value was given separately.
    let valueWord: CWord?
    /// The word the option came from.
    let word: CWord
}

/// Which options take a value.
struct ArgSpec {
    var values: Set<String> = []
    /// Short options whose value can only be attached (`-i.bak`, GNU `-i[SUFFIX]`).
    var attachedOnly: Set<String> = []

    static let none = ArgSpec()
    init(_ values: [String] = [], attachedOnly: [String] = []) {
        self.values = Set(values); self.attachedOnly = Set(attachedOnly)
    }
}

/// A command's words split into options and operands.
struct ParsedArgs {
    var options: [ParsedOption] = []
    var operands: [CWord] = []
    /// Words with expansions that begin like an option (`"-$FLAGS"`).
    var builtOptions: [CWord] = []

    func has(_ names: String...) -> Bool { options.contains { names.contains($0.name) } }
    func option(_ names: String...) -> ParsedOption? { options.first { names.contains($0.name) } }
    func values(_ names: String...) -> [String] { options.filter { names.contains($0.name) }.compactMap(\.value) }
}

extension CommandAnalysis {
    // MARK: Words

    /// Maps the placeholder brackets read for scanning back to `<` and `>`.
    func restore(_ s: String) -> String {
        guard neutralized else { return s }
        var u = Array(s.utf16)
        var changed = false
        for k in u.indices {
            if u[k] == Self.placeholderOpen { u[k] = Ch.less; changed = true }
            else if u[k] == Self.placeholderClose { u[k] = Ch.greater; changed = true }
        }
        return changed ? Ch.string(u) : s
    }

    /// The command words a scanner word becomes (brace lists expanded, at most 64).
    func expand(_ w: ShellWord) -> [CWord] {
        let firstIsTilde: Bool = { if case .tilde? = w.parts.first { return true }; return false }()
        let firstIsBrace: Bool = { if case .braceList? = w.parts.first { return true }; return false }()
        guard let literal = w.literalText else { return [CWord(word: w, text: nil, tilde: firstIsTilde)] }
        let hasBrace = w.parts.contains { if case .braceList = $0 { return true }; return false }
        guard hasBrace else { return [CWord(word: w, text: restore(literal), tilde: firstIsTilde)] }
        var acc = [""]
        for part in w.parts {
            let options: [String]
            switch part {
            case .text(let s, _, _, _): options = [s]
            case .tilde: options = ["~"]
            case .glob(let s, _): options = [s]
            case .braceList(let raw, let alternatives, _): options = alternatives ?? [raw]
            default: options = [""]
            }
            acc = acc.flatMap { a in options.map { a + $0 } }
            if acc.count > ShellBraceList.maxAlternatives {
                return [CWord(word: w, text: restore(literal), tilde: firstIsTilde)]
            }
        }
        return acc.map { CWord(word: w, text: restore($0), tilde: firstIsTilde || (firstIsBrace && $0.hasPrefix("~"))) }
    }

    /// The base name of a literal command word (`/bin/rm` → `rm`).
    static func baseName(_ text: String) -> String {
        var t = text
        while t.count > 1, t.hasSuffix("/") { t.removeLast() }
        if let slash = t.lastIndex(of: "/") { return String(t[t.index(after: slash)...]) }
        return t
    }

    // MARK: Options

    func parseArgs(_ words: [CWord], _ spec: ArgSpec = .none, stopAtFirstOperand: Bool = false) -> ParsedArgs {
        var out = ParsedArgs()
        var k = 0
        var ended = false
        while k < words.count {
            let w = words[k]
            k += 1
            guard let t = w.text else {
                if !ended, w.staticPrefix.hasPrefix("-") { out.builtOptions.append(w) } else { out.operands.append(w) }
                continue
            }
            if ended || t == "-" || !t.hasPrefix("-") {
                out.operands.append(w)
                if stopAtFirstOperand { ended = true }
                continue
            }
            if t == "--" { ended = true; continue }
            if t.hasPrefix("--") {
                if let eq = t.firstIndex(of: "=") {
                    out.options.append(ParsedOption(name: String(t[..<eq]), value: String(t[t.index(after: eq)...]),
                                                    valueWord: nil, word: w))
                } else if spec.values.contains(t), k < words.count {
                    out.options.append(ParsedOption(name: t, value: words[k].text, valueWord: words[k], word: w))
                    k += 1
                } else {
                    out.options.append(ParsedOption(name: t, value: nil, valueWord: nil, word: w))
                }
                continue
            }
            let chars = Array(t.dropFirst())
            var j = 0
            while j < chars.count {
                let c = String(chars[j])
                let rest = String(chars[(j + 1)...])
                if spec.values.contains(c) {
                    if !rest.isEmpty {
                        out.options.append(ParsedOption(name: c, value: rest, valueWord: nil, word: w))
                    } else if k < words.count {
                        out.options.append(ParsedOption(name: c, value: words[k].text, valueWord: words[k], word: w))
                        k += 1
                    } else {
                        out.options.append(ParsedOption(name: c, value: nil, valueWord: nil, word: w))
                    }
                    break
                }
                if spec.attachedOnly.contains(c) {
                    out.options.append(ParsedOption(name: c, value: rest.isEmpty ? nil : rest, valueWord: nil, word: w))
                    break
                }
                out.options.append(ParsedOption(name: c, value: nil, valueWord: nil, word: w))
                j += 1
            }
        }
        return out
    }

    // MARK: Paths

    /// Collapses `//`, `.` and `..`; keeps a leading `/`.
    static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            if piece == "." { continue }
            if piece == ".." {
                if let last = parts.last, last != ".." { parts.removeLast() } else if !absolute { parts.append(piece) }
                continue
            }
            parts.append(piece)
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : joined
    }

    /// The possible texts of a word with the block's literal variables, the home folder and `~` filled in; nil when
    /// something in it is only known at run time.
    func texts(of cw: CWord, in segment: Segment) -> [String]? {
        if let t = cw.text {
            if cw.tilde { return [home + String(t.dropFirst())] }
            return [t]
        }
        var acc = [""]
        for (index, part) in cw.word.parts.enumerated() {
            let options: [String]
            switch part {
            case .text(let s, _, _, _): options = [restore(s)]
            case .tilde: options = index == 0 ? [home] : ["~"]
            case .glob(let s, _): options = [s]
            case .braceList(let raw, let alternatives, _): options = alternatives ?? [raw]
            case .parameter(let p):
                guard p.form == .plain || p.form == .braced, let values = value(of: p.name, in: segment) else { return nil }
                options = values
            default: return nil
            }
            acc = acc.flatMap { a in options.map { a + $0 } }
            if acc.count > 16 { return nil }
        }
        return acc
    }

    /// A variable's literal values before `segment` runs.
    func value(of name: String, in segment: Segment) -> [String]? {
        if case .literal(let values)? = segment.variables[name] { return values }
        if segment.variables[name] != nil { return nil }
        switch name {
        case "HOME": return [home]
        case "USER", "LOGNAME": return [facts.userName]
        case "SHELL": return ["/bin/zsh"]
        case "PWD": return segment.folder.map { [$0] }
        default: return nil
        }
    }

    /// The absolute local paths a word names (several when a variable holds several values), nil when unknown.
    func localPaths(_ cw: CWord, in segment: Segment) -> [String]? {
        guard let values = texts(of: cw, in: segment) else { return nil }
        var out: [String] = []
        for v in values {
            if v.hasPrefix("/") { out.append(Self.normalize(v)); continue }
            guard let folder = segment.folder else { return nil }
            out.append(Self.normalize(folder + "/" + v))
        }
        return out
    }

    /// `path` equals `folder` or lies inside it (case-insensitively: the volumes are).
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let p = path.lowercased(), f = folder.lowercased()
        if f == "/" { return true }
        return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    /// The path relative to the home folder, when inside it (`.zshrc`, `Library/LaunchAgents/x.plist`).
    func homeRelative(_ path: String) -> String? {
        if path.lowercased() == home.lowercased() { return "" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// How a path is shown: inside the home folder as `~/…`.
    func shownPath(_ path: String) -> String {
        if let rel = homeRelative(path) { return shown(rel.isEmpty ? "~" : "~/" + rel) }
        return shown(path)
    }

    /// A word as written, for Pitbox's words: its text, or "whatever `$X` holds when it runs".
    func describe(_ cw: CWord) -> String {
        if let t = cw.text { return shown(t) }
        return "whatever `" + shownRaw(source(cw.range)) + "` holds when it runs"
    }

    /// Command text inside backticks: B1 escaped and cut, no quotes added.
    func shownRaw(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            if CommandCharacterPolicy.isHidden(scalar) { out += "⟨" + CommandCharacterPolicy.codePoint(scalar) + "⟩" }
            else if scalar == "`" { out += "'" }
            else { out.unicodeScalars.append(scalar) }
        }
        if out.count > 60 { out = String(out.prefix(29)) + "…" + String(out.suffix(29)) }
        return out
    }
}
