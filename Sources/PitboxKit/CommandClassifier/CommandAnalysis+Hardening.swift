import Foundation

// Places where a command hides inside another one's words, found by reading the reader adversarially: a shell started on
// `/dev/stdin`, `sh -c '"$@"' _ rm -rf ~` (the command is in the arguments), AppleScript's `do shell script "…"`, the
// programs `git -c core.pager=…` and `rsync -e …` start, `awk`'s `system()`, arithmetic that evaluates a variable
// holding `$(…)`, and decoded text written to a file and then run. Each is read as a nested script, or flagged when it
// cannot be.

extension CommandAnalysis {
    static let standardInputPaths: Set<String> = ["/dev/stdin", "/dev/fd/0", "/proc/self/fd/0", "-"]

    /// Nested scripts beyond the ones of `walkNested`.
    func walkHiddenScripts(_ seg: Segment, _ ctx: WalkContext) {
        let key = seg.key
        if isShell(key) {
            let inv = shellInvocation(seg)
            if let file = inv.scriptFile, let t = file.text, Self.standardInputPaths.contains(t) {
                for body in standardInputBodies(seg) { runNested(body, kind: .hereDocument, parent: seg, scope: seg.scope) }
            }
            if let inline = inv.inline, let script = inline.text, Self.usesPositionalParameters(script),
               let k = seg.args.firstIndex(where: { $0.range == inline.range }) {
                let rest = Array(seg.args[(k + 1)...])
                let words = script.contains("$0") ? rest : Array(rest.dropFirst())
                if !words.isEmpty { runWordSegment(words, kind: .shellString, parent: seg) }
            }
        }
        if key == "source" || key == ".", let first = seg.args.first?.text, Self.standardInputPaths.contains(first) {
            for body in standardInputBodies(seg) { runNested(body, kind: .hereDocument, parent: seg, scope: seg.scope) }
        }
        if key == "osascript" {
            for w in seg.args {
                guard let t = w.text else { continue }
                for script in Self.appleScriptShellScripts(t) {
                    runNested(source(text: script, at: w.range), kind: .shellString, parent: seg, scope: seg.scope)
                }
            }
        }
        if key == "git", let g = gitInvocation(seg) {
            var values: [(String, Range<Int>)] = []
            for c in g.configWords {
                guard let t = c.text else { continue }
                let pair = t.hasPrefix("-c") ? String(t.dropFirst(2)) : t
                if let eq = pair.firstIndex(of: "="), Self.gitRunsValue(String(pair[..<eq])) {
                    values.append((String(pair[pair.index(after: eq)...]), c.range))
                }
            }
            if g.subcommand == "config" {
                let ops = g.args.operands
                if ops.count >= 2, let k = ops[0].text, Self.gitRunsValue(k), let v = ops[1].text { values.append((v, ops[1].range)) }
            }
            for (value, range) in values {
                let command = value.hasPrefix("!") ? String(value.dropFirst()) : value
                runNested(source(text: command, at: range), kind: .shellString, parent: seg, scope: seg.scope)
            }
        }
        if key == "rsync" {
            let p = parseArgs(seg.args, Self.rsyncSpec)
            for o in p.options where o.name == "e" || o.name == "--rsh" {
                if let v = o.value { runNested(source(text: v, at: o.valueWord?.range ?? o.word.range), kind: .shellString, parent: seg, scope: seg.scope) }
            }
        }
    }

    static func usesPositionalParameters(_ script: String) -> Bool {
        ["$@", "$*", "${@}", "${*}", "$0"].contains { script.contains($0) }
            || (1...9).contains { script.contains("$\($0)") || script.contains("${\($0)}") }
    }

    static func gitRunsValue(_ key: String) -> Bool {
        let k = key.lowercased()
        return ["core.pager", "core.sshcommand", "core.editor", "core.askpass", "core.fsmonitor", "sequence.editor",
                "diff.external", "credential.helper", "gpg.program", "pager.log", "pager.diff", "pager.show"].contains(k)
            || k.hasPrefix("alias.")
    }

    /// The strings of `do shell script "…"` in an AppleScript, unescaped.
    static func appleScriptShellScripts(_ text: String) -> [String] {
        var out: [String] = []
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: "do shell script", options: .caseInsensitive, range: search) {
            var k = r.upperBound
            while k < text.endIndex, text[k] == " " { k = text.index(after: k) }
            guard k < text.endIndex, text[k] == "\"" else { search = r.upperBound..<text.endIndex; continue }
            k = text.index(after: k)
            var s = ""
            var closed = false
            while k < text.endIndex {
                let c = text[k]
                if c == "\\", text.index(after: k) < text.endIndex {
                    k = text.index(after: k)
                    s.append(text[k])
                } else if c == "\"" {
                    closed = true
                    break
                } else {
                    s.append(c)
                }
                k = text.index(after: k)
            }
            if closed { out.append(s) }
            search = (closed ? text.index(after: k) : text.endIndex)..<text.endIndex
        }
        return out
    }

    /// A command given as words (from `find -exec`, or the arguments of `sh -c '"$@"'`), classified like a segment.
    func runWordSegment(_ words: [CWord], kind: NestedKind, parent seg: Segment) {
        guard seg.depth < ShellCommandScanner.maxSubstitutionDepth, let first = words.first, let last = words.last else { return }
        var c = childContext(of: seg, origin: .nested(parent: seg.id, kind: kind))
        c.depth = seg.depth + 1
        let inner = makeSegment(range: first.range.lowerBound..<last.range.upperBound, ctx: c)
        inner.words = words
        resolveProgram(inner)
        walkNested(inner, c)
    }

    // MARK: Rules

    func applyHardeningRules(_ seg: Segment) {
        let key = seg.key
        ruleArchives(seg)
        if ["awk", "gawk", "mawk", "nawk"].contains(key) {
            let p = parseArgs(seg.args, ArgSpec(["F", "v", "f"]))
            let program = p.has("f") ? nil : p.operands.first?.text
            if let program, program.contains("system(") || program.contains("| \"") || program.contains("|\"")
                || program.contains("\" |") || program.contains("\"|") {
                addFlag(.r18, "Runs shell commands from inside awk; \(AppIdentity.displayName) does not read awk", in: seg)
                for script in Self.awkSystemStrings(program) {
                    runNested(source(text: script, at: seg.range), kind: .shellString, parent: seg, scope: seg.scope)
                    applyRulesToNewSegments()
                }
            } else if p.has("f") {
                addFlag(.r18, "Runs code from \(p.option("f")?.value.map(shown) ?? "an awk file") that is not shown here", in: seg)
            }
        }
        // Deleting or moving away a startup or settings file changes it too.
        if ["rm", "unlink", "shred", "srm", "mv"].contains(key) {
            let p = parseArgs(seg.args)
            let targets = key == "mv" ? Array(p.operands.dropLast()) : p.operands
            for t in targets {
                guard let paths = localPaths(t, in: seg) else { continue }
                for path in paths where isProtectedSettingsPath(path) {
                    addFlag(.r5, "Changes a startup or settings file: \(shownPath(path)) (\(key == "mv" ? "moves it away" : "deletes it"))",
                            in: seg, range: t.range)
                }
            }
        }
        // A recursive copy into the home folder itself can replace any startup file.
        if ["cp", "rsync", "ditto"].contains(key) {
            let p = parseArgs(seg.args, key == "rsync" ? Self.rsyncSpec : ArgSpec(["t", "S"]))
            let recursive = (key == "ditto" && !p.has("x")) || p.has("r", "R", "a", "--recursive", "--archive")
            if recursive, p.operands.count >= 2, let dest = p.operands.last, let paths = localPaths(dest, in: seg),
               paths.contains(where: { $0.lowercased() == home.lowercased() }) {
                addFlag(.r5, "Changes a startup or settings file: it copies a folder into your home folder (~)", in: seg,
                        range: dest.range)
            }
        }
        // find of a whole destroyer folder with nothing narrowing it down.
        if key == "find" {
            let args = seg.args
            var starts: [CWord] = []
            for w in args { if let t = w.text, t.hasPrefix("-") || t == "(" || t == "!" { break }; starts.append(w) }
            let narrowing: Set<String> = ["-name", "-iname", "-path", "-ipath", "-regex", "-iregex", "-wholename",
                                          "-iwholename", "-newer", "-mtime", "-mmin", "-size", "-inum", "-samefile",
                                          "-empty", "-user", "-group", "-perm", "-atime", "-ctime", "-amin", "-cmin",
                                          "-links", "-uid", "-gid", "-newermt"]
            let words = Set(args.compactMap(\.text))
            let deletes = words.contains("-delete") || zip(args, args.dropFirst()).contains { a, b in
                ["-exec", "-execdir", "-ok", "-okdir"].contains(a.text ?? "") && ["rm", "shred", "srm"].contains(Self.baseName(b.text ?? "").lowercased())
            }
            if deletes, words.isDisjoint(with: narrowing) {
                for s in starts {
                    if let what = destroyerTarget(s, in: seg) {
                        addFlag(.b6, "Known destroyer: deletes everything in \(what)", in: seg, range: s.range)
                    }
                }
            }
        }
        // Decoded text written to a file, then run (B5 through a file).
        if isDecoder(seg) {
            for r in seg.redirections where r.replacesTarget || r.op == .append {
                if let paths = expand(r.target).first.flatMap({ localPaths($0, in: seg) }) {
                    for p in paths { decodedFiles.append((p, seg.id)) }
                }
            }
            if key == "base64", let o = parseArgs(seg.args, ArgSpec(["o", "i", "b"])).option("o"), let w = o.valueWord,
               let paths = localPaths(w, in: seg) {
                for p in paths { decodedFiles.append((p, seg.id)) }
            }
        }
        var runs: [CWord] = []
        if let k = seg.programIndex { runs.append(seg.words[k]) }
        if isShell(key) || isInterpreter(key), let f = scriptFileWord(seg) { runs.append(f) }
        if key == "source" || key == ".", let f = seg.args.first { runs.append(f) }
        for w in runs {
            guard let paths = localPaths(w, in: seg) else { continue }
            if decodedFiles.contains(where: { d in d.segment < seg.id && paths.contains { $0.lowercased() == d.path.lowercased() } }) {
                addFlag(.b5, CommandPatterns.ruleWords[.b5] ?? "", in: seg, range: w.range)
            }
        }
    }

    /// The literal strings of `system("…")` in an awk program.
    static func awkSystemStrings(_ program: String) -> [String] {
        var out: [String] = []
        var search = program.startIndex..<program.endIndex
        while let r = program.range(of: "system(\"", range: search) {
            guard let close = program[r.upperBound...].firstIndex(of: "\"") else { break }
            out.append(String(program[r.upperBound..<close]))
            search = program.index(after: close)..<program.endIndex
        }
        return out
    }

    /// Rules for segments added after the rules pass started (nested scripts found by a rule).
    func applyRulesToNewSegments() {
        while rulesApplied < segments.count {
            let s = segments[rulesApplied]
            rulesApplied += 1
            applyRules(s)
        }
    }

    // MARK: Arithmetic that evaluates a variable holding a command

    /// `x='a[$(cmd)]'; echo $((x))`: arithmetic evaluates the variable's text, subscripts and substitutions included.
    func checkArithmeticValues(_ a: ShellArithmetic, of seg: Segment) {
        var names = a.bareNames
        for e in a.expansions { if case .parameter(let p) = e { names.append(p.name) } }
        for name in Set(names) {
            guard case .literal(let values)? = variables[name] else { continue }
            for v in values where v.contains("$(") || v.contains("`") {
                addFlag(.r11, "Arithmetic reads $\(name), whose text holds a command; what runs is not what you see",
                        a.utf16Range, segment: seg.id)
                runNested(source(text: v, at: a.utf16Range), kind: .eval, parent: seg, scope: seg.scope)
            }
        }
    }
}
