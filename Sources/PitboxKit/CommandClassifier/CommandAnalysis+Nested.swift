import Foundation

// Scripts a segment runs from text (docs/SHELL_LANGUAGE.md §3.1, A8): `sh -c '…'`, `eval …`, the words after an
// `ssh` host (unquoted once, as the remote shell reads them), a here-doc, here-string or pipe body that
// reaches a shell, `find -exec …`, `watch '…'`, `env -S '…'` and `su -c '…'`. Each is read by the scanner and walked
// like the text itself; its flags point at the enclosing top-level segment.

/// How a shell is started.
struct ShellInvocation {
    /// `-c`: the script word (nil when `-c` has no word).
    var inline: CWord?
    var hasInlineFlag = false
    /// A script file operand.
    var scriptFile: CWord?
    /// Reads its script from standard input (no operand, `-s`, or `-`).
    var readsStandardInput = false
}

/// Where `ssh` (and its relatives) connects and what it sends.
struct RemoteTarget {
    var hostWord: CWord?
    var host: String?
    var user: String?
    var command: [CWord] = []
    var options: [ParsedOption] = []
    /// `-o RemoteCommand=…`.
    var remoteCommand: (String, CWord)?
    /// `-o ProxyCommand=…` and `-o LocalCommand=…`: run here.
    var localCommands: [(String, CWord)] = []
}

extension CommandAnalysis {
    static let sshValueOptions: Set<String> = ["p", "i", "l", "o", "L", "R", "D", "J", "F", "E", "b", "c", "m", "O", "Q",
                                               "S", "W", "w", "B", "e", "I"]

    func isShell(_ key: String) -> Bool { CommandPatterns.shells.contains(key) }

    func isInterpreter(_ key: String) -> Bool {
        if isShell(key) { return true }
        for family in CommandPatterns.interpreterFamilies where key == family || key.hasPrefix(family) {
            let rest = key.dropFirst(family.count)
            if rest.isEmpty || rest.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        }
        return false
    }

    func walkNested(_ seg: Segment, _ ctx: WalkContext) {
        let mine = pendingScripts.filter { $0.segment == seg.id }
        pendingScripts.removeAll { $0.segment == seg.id }
        for item in mine { runNested(source(fromWords: [item.word]), kind: item.kind, parent: seg, scope: seg.scope) }
        guard seg.programIndex != nil, !seg.programIsBuilt || !seg.key.isEmpty else { return }
        let key = seg.key
        if isShell(key) {
            let inv = shellInvocation(seg)
            if let inline = inv.inline { runNested(source(fromWords: [inline]), kind: .shellString, parent: seg, scope: seg.scope) }
            if inv.readsStandardInput {
                for body in standardInputBodies(seg) { runNested(body, kind: .hereDocument, parent: seg, scope: seg.scope) }
            }
        } else if key == "eval" {
            if !seg.args.isEmpty { runNested(source(fromWords: seg.args), kind: .eval, parent: seg, scope: seg.scope) }
        } else if CommandPatterns.remoteShells.contains(key) {
            nestedRemote(seg)
        } else if key == "su" {
            let parsed = parseArgs(seg.args, ArgSpec(["c", "s", "--command", "--shell"]))
            if let c = parsed.option("c", "--command"), let w = c.valueWord {
                runNested(source(fromWords: [w]), kind: .su, parent: seg, scope: seg.scope)
            } else if let c = parsed.option("c", "--command"), let v = c.value {
                runNested(source(text: v, at: c.word.range), kind: .su, parent: seg, scope: seg.scope)
            }
        } else if key == "find" {
            nestedFindCommands(seg, ctx)
        }
        walkHiddenScripts(seg, ctx)
    }

    // MARK: Shells

    func shellInvocation(_ seg: Segment) -> ShellInvocation {
        var inv = ShellInvocation()
        let args = seg.args
        var k = 0
        var stdinFlag = false
        var dashEnd = false
        while k < args.count {
            guard let t = args[k].text else { break }
            if t == "--" { k += 1; break }
            if t == "-" { k += 1; dashEnd = true; break }
            if t.hasPrefix("--") {
                k += ["--rcfile", "--init-file"].contains(t) ? 2 : 1
                continue
            }
            if (t.hasPrefix("-") || t.hasPrefix("+")), t.count > 1 {
                let letters = t.dropFirst()
                if letters.contains("c") { inv.hasInlineFlag = true }
                if letters.contains("s") { stdinFlag = true }
                k += 1
                if letters.last == "o" || letters.last == "O" { k += 1 }
                continue
            }
            break
        }
        let rest = k < args.count ? Array(args[k...]) : []
        if inv.hasInlineFlag {
            inv.inline = rest.first
        } else if stdinFlag || dashEnd || rest.isEmpty {
            inv.readsStandardInput = true
        } else {
            inv.scriptFile = rest.first
        }
        return inv
    }

    /// The text a segment's standard input carries when it is shown in the block: a here-doc, a here-string, or the
    /// literal output of `echo`/`printf`/`cat <<…` piped into it.
    func standardInputBodies(_ seg: Segment) -> [ShellSource] {
        var out: [ShellSource] = []
        for r in seg.redirections where r.fileDescriptor == nil || r.fileDescriptor == 0 {
            if let doc = r.hereDocument { out.append(source(ofHereDocument: doc)) }
            if r.op == .hereString { out.append(source(fromWords: expand(r.target))) }
        }
        for up in upstream(of: seg) {
            if let body = literalOutput(of: up) { out.append(body) }
        }
        return out
    }

    /// What `echo 'x'`, `printf 'x'` or `cat <<EOF` writes, when the block shows it.
    func literalOutput(of seg: Segment) -> ShellSource? {
        switch seg.key {
        case "echo", "print":
            let words = seg.args.drop { ($0.text ?? "").hasPrefix("-") && ($0.text ?? "").count > 1 }
            guard let first = words.first, words.allSatisfy(\.isLiteral) else { return nil }
            let text = words.compactMap(\.text).joined(separator: " ")
            return source(text: Self.decodeEchoEscapes(text), at: first.range)
        case "printf":
            guard let format = seg.args.first, let f = format.text else { return nil }
            let rest = seg.args.dropFirst()
            if !f.contains("%") { return source(text: Self.decodeEchoEscapes(f), at: format.range) }
            guard f == "%s\\n" || f == "%s" || f == "%s\\n\\n", rest.allSatisfy(\.isLiteral), let first = rest.first
            else { return nil }
            return source(text: rest.compactMap(\.text).joined(separator: f == "%s" ? "" : "\n"), at: first.range)
        case "cat":
            guard seg.args.isEmpty else { return nil }
            for r in seg.redirections where r.fileDescriptor == nil || r.fileDescriptor == 0 {
                if let doc = r.hereDocument { return source(ofHereDocument: doc) }
                if r.op == .hereString { return source(fromWords: expand(r.target)) }
            }
            return nil
        default:
            return nil
        }
    }

    static func decodeEchoEscapes(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let n = it.next() else { out.append("\\"); break }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\\": out.append("\\")
            default: out.append("\\"); out.append(n)
            }
        }
        return out
    }

    // MARK: Remote commands (sent to another machine)

    func remoteTarget(_ seg: Segment) -> RemoteTarget {
        var t = RemoteTarget()
        let args = seg.args
        var values = Self.sshValueOptions
        if seg.key == "autossh" { values.insert("M") }
        if seg.key == "mosh" { values = ["p"] }
        if seg.key == "et" { values = ["c", "p", "t", "r", "x", "u", "l", "f"] }
        var k = 0
        while k < args.count {
            let w = args[k]
            if let s = w.text, s == "--" {
                k += 1
                if t.hostWord == nil, k < args.count { t.hostWord = args[k]; k += 1 }
                break
            }
            if let s = w.text, s.hasPrefix("-"), s.count > 1 {
                if s.hasPrefix("--") {
                    t.options.append(ParsedOption(name: s, value: nil, valueWord: nil, word: w))
                    k += 1
                    continue
                }
                let chars = Array(s.dropFirst()).map(String.init)
                var j = 0
                var tookNext = false
                while j < chars.count {
                    let c = chars[j]
                    if values.contains(c) {
                        let rest = chars[(j + 1)...].joined()
                        if !rest.isEmpty {
                            t.options.append(ParsedOption(name: c, value: rest, valueWord: nil, word: w))
                        } else if k + 1 < args.count {
                            t.options.append(ParsedOption(name: c, value: args[k + 1].text, valueWord: args[k + 1], word: w))
                            tookNext = true
                        }
                        break
                    }
                    t.options.append(ParsedOption(name: c, value: nil, valueWord: nil, word: w))
                    j += 1
                }
                k += tookNext ? 2 : 1
                continue
            }
            if t.hostWord == nil { t.hostWord = w; k += 1; continue }
            break
        }
        if t.hostWord != nil, k < args.count { t.command = Array(args[k...]) }
        if let hw = t.hostWord, let text = hw.text {
            var h = text
            if h.lowercased().hasPrefix("ssh://") { h = String(h.dropFirst(6)) }
            if let at = h.lastIndex(of: "@") { t.user = String(h[..<at]); h = String(h[h.index(after: at)...]) }
            if seg.key == "et" || text.lowercased().hasPrefix("ssh://"), let colon = h.firstIndex(of: ":") {
                h = String(h[..<colon])
            }
            if h.hasSuffix("/") { h.removeLast() }
            t.host = h
        }
        for o in t.options where o.name == "o" {
            guard let v = o.value else { continue }
            let (name, value) = Self.sshOption(v)
            switch name {
            case "remotecommand": t.remoteCommand = (value, o.valueWord ?? o.word)
            case "proxycommand", "localcommand": t.localCommands.append((value, o.valueWord ?? o.word))
            default: break
            }
        }
        if seg.key == "et", let c = t.options.first(where: { $0.name == "c" }), let v = c.value {
            t.remoteCommand = (v, c.valueWord ?? c.word)
        }
        return t
    }

    /// `Name=value` or `Name value` of an `-o` option, the name lowercased.
    static func sshOption(_ v: String) -> (String, String) {
        if let eq = v.firstIndex(where: { $0 == "=" || $0 == " " }) {
            let value = v[v.index(after: eq)...].drop { $0 == " " || $0 == "=" }
            return (v[..<eq].lowercased(), String(value))
        }
        return (v.lowercased(), "")
    }

    func nestedRemote(_ seg: Segment) {
        let t = remoteTarget(seg)
        for (command, word) in t.localCommands {
            runNested(source(text: command, at: word.range), kind: .shellString, parent: seg, scope: seg.scope)
        }
        guard let host = t.host, !host.isEmpty else { return }
        let scope = SegmentScope.remote(host)
        var sends = false
        if !t.command.isEmpty {
            sends = true
            runNested(source(fromWords: t.command), kind: .remote, parent: seg, scope: scope)
        }
        if let (command, word) = t.remoteCommand {
            sends = true
            runNested(source(text: command, at: word.range), kind: .remote, parent: seg, scope: scope)
        }
        let noStdin = t.options.contains { $0.name == "n" || $0.name == "N" || $0.name == "W" || $0.name == "G" }
        if !noStdin {
            for r in seg.redirections where (r.fileDescriptor == nil || r.fileDescriptor == 0)
                && (r.op == .input || r.op == .hereDocument || r.op == .hereDocumentStrippingTabs || r.op == .hereString) {
                sends = true
                if let doc = r.hereDocument { runNested(source(ofHereDocument: doc), kind: .remote, parent: seg, scope: scope) }
                if r.op == .hereString { runNested(source(fromWords: expand(r.target)), kind: .remote, parent: seg, scope: scope) }
            }
            let ups = upstream(of: seg)
            if !ups.isEmpty {
                sends = true
                for up in ups { if let body = literalOutput(of: up) { runNested(body, kind: .remote, parent: seg, scope: scope) } }
            }
        }
        if sends {
            let name = Self.remoteHostName(host)
            seg.sendsTo = name
            if segments[seg.top].sendsTo == nil { segments[seg.top].sendsTo = name }
        }
    }

    /// The host of `.remote(host:)`: without a user or a port.
    static func remoteHostName(_ host: String) -> String { host }

    // MARK: find -exec

    func nestedFindCommands(_ seg: Segment, _ ctx: WalkContext) {
        guard seg.depth < ShellCommandScanner.maxSubstitutionDepth else {
            addFlag(.b3, "\(AppIdentity.displayName) can't read this shell syntax (commands inside commands more than \(ShellCommandScanner.maxSubstitutionDepth) levels deep); use Copy",
                    seg.range, segment: seg.id)
            return
        }
        let args = seg.args
        var k = 0
        while k < args.count {
            guard let t = args[k].text, ["-exec", "-execdir", "-ok", "-okdir"].contains(t) else { k += 1; continue }
            var j = k + 1
            var words: [CWord] = []
            while j < args.count, !(args[j].text == ";" || args[j].text == "+") { words.append(args[j]); j += 1 }
            if !words.isEmpty, let first = words.first, let last = words.last {
                var c = childContext(of: seg, origin: .nested(parent: seg.id, kind: .findExec))
                c.depth = seg.depth + 1
                let inner = makeSegment(range: first.range.lowerBound..<last.range.upperBound, ctx: c)
                inner.words = words
                resolveProgram(inner)
                walkNested(inner, c)
            }
            k = j + 1
        }
    }

    // MARK: Reading a nested script

    func runNested(_ source: ShellSource, kind: NestedKind, parent seg: Segment, scope: SegmentScope) {
        guard seg.depth < ShellCommandScanner.maxSubstitutionDepth else {
            addFlag(.b3, "\(AppIdentity.displayName) can't read this shell syntax (scripts inside scripts more than \(ShellCommandScanner.maxSubstitutionDepth) levels deep); use Copy",
                    seg.range, segment: seg.id)
            return
        }
        let scan = ShellScanRun.scan(source)
        if let p = scan.problem {
            addProblem(p, segment: seg.id, inside: kind == .remote ? "in the command it sends" : "in the script it runs")
            return
        }
        guard let script = scan.script else { return }
        var c = childContext(of: seg, origin: .nested(parent: seg.id, kind: kind))
        c.scope = scope
        c.depth = seg.depth + 1
        let saved = (variables, folder)
        if case .remote = scope { variables = [:]; folder = nil }
        walk(script, c)
        (variables, folder) = saved
    }

    /// Re-read text built from words (separated by spaces), each unit mapped back to where it came from.
    func source(fromWords words: [CWord]) -> ShellSource {
        var out: [UInt16] = []
        var origin: [Int] = []
        for (n, w) in words.enumerated() {
            if n > 0 { out.append(Ch.space); origin.append(w.range.lowerBound) }
            if let t = w.text, w.hasPattern, w.word.literalText.map(restore) != t {
                for u in t.utf16 { out.append(u); origin.append(w.range.lowerBound) }
                continue
            }
            for part in w.word.parts {
                switch part {
                case .text(let s, _, _, let r):
                    let su = Array(s.utf16)
                    let base = r.count == su.count + 2 ? r.lowerBound + 1 : r.lowerBound
                    for (i, u) in su.enumerated() { out.append(u); origin.append(min(base + i, max(r.lowerBound, r.upperBound - 1))) }
                case .tilde(let r):
                    out.append(Ch.tilde); origin.append(r.lowerBound)
                case .glob(let s, let r), .braceList(let s, _, let r):
                    for (i, u) in s.utf16.enumerated() { out.append(u); origin.append(min(r.lowerBound + i, max(r.lowerBound, r.upperBound - 1))) }
                default:
                    let r = part.utf16Range
                    for k in r where k < units.count { out.append(units[k]); origin.append(k) }
                }
            }
        }
        return ShellSource(units: out, origin: origin, originEnd: words.last?.range.upperBound ?? 0)
    }

    /// Re-read text known only as a string (an option's value), mapped to the start of `range`.
    func source(text: String, at range: Range<Int>) -> ShellSource {
        let u = Array(text.utf16)
        let base = range.lowerBound
        return ShellSource(units: u, origin: u.indices.map { min(base + $0, max(base, range.upperBound - 1)) },
                           originEnd: range.upperBound)
    }

    func source(ofHereDocument doc: ShellHereDocument) -> ShellSource {
        if doc.delimiterQuoted { return source(text: doc.body, at: doc.bodyRange) }
        return source(fromWords: [CWord(word: doc.content, text: nil, tilde: false)])
    }

    // MARK: Data flow

    /// Segments whose output reaches this segment's standard input (earlier stages of its pipelines, transitively).
    /// Each pipeline is expanded once per lookup, so a long pipeline costs linear time per lookup.
    func upstream(of seg: Segment) -> [Segment] {
        if walkDone, let cached = upstreamCache[seg.id] { return cached.map { segments[$0] } }
        var seen = Set<Int>([seg.id])
        var expanded: [Int: Int] = [:]
        var out: [Int] = []
        var queue = [seg.id]
        while let s = queue.popLast() {
            for ref in segments[s].pipes {
                if let done = expanded[ref.id], done >= ref.position { continue }
                expanded[ref.id] = max(expanded[ref.id] ?? -1, ref.position)
                for (other, position) in pipeMembers[ref.id] ?? [] where position < ref.position && !seen.contains(other) {
                    seen.insert(other)
                    out.append(other)
                    queue.append(other)
                }
            }
        }
        if walkDone { upstreamCache[seg.id] = out }
        return out.map { segments[$0] }
    }
}
