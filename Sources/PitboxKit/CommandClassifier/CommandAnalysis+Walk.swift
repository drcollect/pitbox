import Foundation

// The tree becomes segments (docs/SHELL_LANGUAGE.md §3.1): every simple command, in lists, pipelines, compound
// commands, substitutions and nested scripts. Substitutions run before their command, so they are walked first; the
// variables and the working folder the block sets are tracked in order (a subshell's changes do not leak out).

struct WalkContext {
    /// The top-level segment the walked commands belong to; nil at the top level.
    var top: Int?
    var scope: SegmentScope = .local
    var origin: SegmentOrigin = .top
    var pipes: [PipeRef] = []
    var background = false
    /// Redirections of the compound commands around.
    var inherited: [ShellRedirection] = []
    var depth = 0
}

extension CommandAnalysis {
    /// The folder the command starts in: the context's `runFolder`, else the home folder. A `cd` in the text is
    /// tracked as part of the command, never taken as the starting folder.
    func startWalk() {
        folder = context.runFolder.flatMap { $0.hasPrefix("/") ? Self.normalize($0) : nil } ?? home
    }

    func makeSegment(range: Range<Int>, ctx: WalkContext) -> Segment {
        let s = Segment(id: segments.count, scope: ctx.scope, range: range, origin: ctx.origin)
        segments.append(s)
        if let top = ctx.top {
            s.top = top
        } else {
            s.top = s.id
            topIndex[s.id] = tops.count
            tops.append(s.id)
        }
        s.pipes = ctx.pipes
        for ref in ctx.pipes { pipeMembers[ref.id, default: []].append((s.id, ref.position)) }
        s.background = ctx.background
        s.depth = ctx.depth
        s.variables = variables
        s.folder = folder
        return s
    }

    func walk(_ script: ShellScript, _ ctx: WalkContext) {
        for item in script.items {
            var c = ctx
            if item.terminator == .background { c.background = true }
            for pipeline in item.andOr.pipelines { walk(pipeline, c) }
        }
    }

    func walk(_ p: ShellPipeline, _ ctx: WalkContext) {
        guard p.commands.count > 1 else {
            if let c = p.commands.first { walk(c, ctx) }
            return
        }
        pipeCounter += 1
        let id = pipeCounter
        for (k, command) in p.commands.enumerated() {
            var c = ctx
            c.pipes.append(PipeRef(id: id, position: k))
            walk(command, c)
        }
    }

    func walk(_ command: ShellCommand, _ ctx: WalkContext) {
        switch command {
        case .simple(let s): walkSimple(s, ctx)
        case .compound(let k): walkCompound(k, ctx)
        }
    }

    func walkCompound(_ k: ShellCompoundCommand, _ ctx: WalkContext) {
        var c = ctx
        c.inherited += k.redirections
        let first = segments.count
        var loose: [(ShellWord, SubstitutionUse)] = []
        switch k.kind {
        case .subshell(let body):
            let saved = (variables, folder)
            walk(body, c)
            (variables, folder) = saved
        case .group(let body):
            walk(body, c)
        case .ifClause(let branches, let elseBody):
            for b in branches { walk(b.condition, c); walk(b.body, c) }
            if let e = elseBody { walk(e, c) }
        case .forLoop(let name, let items, let body):
            loose = (items ?? []).map { ($0, .loopWords) }
            variables[name] = loopValue(items)
            walk(body, c)
        case .whileLoop(let condition, let body), .untilLoop(let condition, let body):
            walk(condition, c)
            walk(body, c)
        case .caseClause(let subject, let items):
            loose = [(subject, .argument)]
            for item in items { walk(item.body, c) }
        case .condition(let words):
            let seg = makeSegment(range: k.utf16Range, ctx: c)
            seg.pseudo = "[["
            seg.redirections = c.inherited
            for w in words { walkSubstitutions(in: w, of: seg, use: .condition) }
        case .arithmetic(let a):
            let seg = makeSegment(range: k.utf16Range, ctx: c)
            seg.pseudo = "(("
            seg.redirections = c.inherited
            checkArithmeticValues(a, of: seg)
            for e in a.expansions { walkSubstitutions(in: e, of: seg, use: .arithmetic) }
        }
        for r in k.redirections {
            if r.op == .hereString { loose.append((r.target, .hereString)) }
            else if r.hereDocument == nil { loose.append((r.target, .redirectTarget)) }
            if let doc = r.hereDocument, !doc.delimiterQuoted { loose.append((doc.content, .hereDocument)) }
        }
        guard !loose.isEmpty else { return }
        let parent = segments.count > first ? segments[first] : makeSegment(range: k.utf16Range, ctx: c)
        for (w, use) in loose { walkSubstitutions(in: w, of: parent, use: use) }
    }

    /// A `for` variable: literal when every word is.
    func loopValue(_ items: [ShellWord]?) -> VariableValue {
        guard let items else { return .unknown }
        var values: [String] = []
        for w in items {
            for cw in expand(w) {
                guard let t = cw.text, !cw.word.parts.contains(where: { if case .glob = $0 { return true }; return false })
                else { return .unknown }
                values.append(cw.tilde ? home + String(t.dropFirst()) : t)
                if values.count > 16 { return .unknown }
            }
        }
        return .literal(values)
    }

    @discardableResult
    func walkSimple(_ s: ShellSimpleCommand, _ ctx: WalkContext) -> Segment {
        let seg = makeSegment(range: s.utf16Range, ctx: ctx)
        seg.simple = s
        seg.assignments = s.assignments
        seg.redirections = ctx.inherited + s.redirections
        for (k, w) in s.words.enumerated() { walkSubstitutions(in: w, of: seg, use: k == 0 ? .commandWord : .argument) }
        for a in s.assignments {
            walkSubstitutions(in: a.value, of: seg, use: .assignment(name: a.name, standalone: s.words.isEmpty))
        }
        for r in s.redirections {
            if r.op == .hereString {
                walkSubstitutions(in: r.target, of: seg, use: .hereString)
            } else if r.op == .input, case .processSubstitution(let script, _, _)? = r.target.parts.first,
                      r.target.parts.count == 1 {
                walkFeedingSubstitution(script, into: seg)
            } else if r.hereDocument == nil {
                walkSubstitutions(in: r.target, of: seg, use: .redirectTarget)
            }
            if let doc = r.hereDocument, !doc.delimiterQuoted {
                walkSubstitutions(in: doc.content, of: seg, use: .hereDocument)
            }
        }
        seg.words = s.words.flatMap { expand($0) }
        resolveProgram(seg)
        applyEffects(seg)
        walkNested(seg, ctx)
        return seg
    }

    func childContext(of seg: Segment, origin: SegmentOrigin) -> WalkContext {
        var c = WalkContext()
        c.top = seg.top
        c.scope = seg.scope
        c.origin = origin
        c.depth = seg.depth
        return c
    }

    func walkSubstitutions(in w: ShellWord, of seg: Segment, use: SubstitutionUse) {
        for part in w.parts { walkSubstitutions(in: part, of: seg, use: use) }
    }

    func walkSubstitutions(in part: ShellWordPart, of seg: Segment, use: SubstitutionUse) {
        switch part {
        case .commandSubstitution(let script, _, _, _):
            let c = childContext(of: seg, origin: .substitution(parent: seg.id, use: use))
            let saved = (variables, folder)
            walk(script, c)
            (variables, folder) = saved
        case .processSubstitution(let script, let writes, _):
            var c = childContext(of: seg, origin: .processSubstitution(parent: seg.id, writes: writes))
            if writes {
                // `tee >(sh)`: what the command writes into the file is what the inner commands read.
                pipeCounter += 1
                seg.pipes.append(PipeRef(id: pipeCounter, position: 0))
                pipeMembers[pipeCounter, default: []].append((seg.id, 0))
                c.pipes = [PipeRef(id: pipeCounter, position: 1)]
            }
            let saved = (variables, folder)
            walk(script, c)
            (variables, folder) = saved
        case .parameter(let p):
            if let w = p.word { walkSubstitutions(in: w, of: seg, use: use) }
        case .arithmetic(let a):
            checkArithmeticValues(a, of: seg)
            for e in a.expansions { walkSubstitutions(in: e, of: seg, use: .arithmetic) }
        default:
            break
        }
    }

    /// `cmd < <(inner)`: the inner commands' output is the command's standard input.
    func walkFeedingSubstitution(_ script: ShellScript, into seg: Segment) {
        pipeCounter += 1
        seg.pipes.append(PipeRef(id: pipeCounter, position: 1))
        pipeMembers[pipeCounter, default: []].append((seg.id, 1))
        var c = childContext(of: seg, origin: .processSubstitution(parent: seg.id, writes: false))
        c.pipes = [PipeRef(id: pipeCounter, position: 0)]
        let saved = (variables, folder)
        walk(script, c)
        (variables, folder) = saved
    }

    // MARK: Effects on the rest of the block

    func applyEffects(_ seg: Segment) {
        if seg.simple?.words.isEmpty == true {
            for a in seg.assignments { variables[a.name] = assignedValue(a.value, in: seg) }
        }
        guard seg.programIndex != nil, !seg.programIsBuilt else { return }
        switch seg.key {
        case "export", "typeset", "declare", "local", "readonly", "integer", "float":
            for w in seg.args {
                if let (name, value) = declaration(w, in: seg) { variables[name] = value }
            }
        case "read":
            let parsed = parseArgs(seg.args, ArgSpec(["d", "k", "n", "N", "p", "t", "u", "a", "A"]))
            var any = false
            for op in parsed.operands {
                guard let t = op.text else { continue }
                let name = t.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }) {
                    variables[name] = .unknown
                    any = true
                }
            }
            if !any { variables["REPLY"] = .unknown }
        case "unset":
            for w in seg.args { if let t = w.text { variables.removeValue(forKey: t) } }
        case "cd", "pushd":
            if seg.isRemote { folder = nil; return }
            let parsed = parseArgs(seg.args, .none)
            if parsed.operands.isEmpty {
                folder = parsed.options.isEmpty || parsed.options.allSatisfy({ ["q", "s", "L", "P"].contains($0.name) }) ? home : nil
            } else if parsed.operands.count == 1, parsed.operands[0].text != "-",
                      let paths = localPaths(parsed.operands[0], in: seg), paths.count == 1 {
                folder = paths[0]
            } else {
                folder = nil
            }
        case "popd":
            folder = nil
        default:
            break
        }
    }

    /// The value an assignment gives its variable.
    func assignedValue(_ w: ShellWord, in seg: Segment) -> VariableValue {
        if let item = keychainItem(in: w) { return .keychain(item: item) }
        let cw = CWord(word: w, text: w.literalText.map(restore), tilde: { if case .tilde? = w.parts.first { return true }; return false }())
        if let values = texts(of: cw, in: seg) { return .literal(values) }
        return .unknown
    }

    /// `export NAME=value` and its relatives.
    func declaration(_ cw: CWord, in seg: Segment) -> (String, VariableValue)? {
        let prefix = cw.staticPrefix
        guard let eq = prefix.firstIndex(of: "=") else { return nil }
        let name = String(prefix[..<eq])
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first),
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") })
        else { return nil }
        if let item = keychainItem(in: cw.word) { return (name, .keychain(item: item)) }
        if let t = cw.text, let e = t.firstIndex(of: "=") {
            var value = String(t[t.index(after: e)...])
            if value == "~" || value.hasPrefix("~/") { value = home + value.dropFirst() }
            return (name, .literal([value]))
        }
        return (name, .unknown)
    }

    /// The Keychain item when a word is `"$(security find-generic-password -s NAME -w)"` (the user's form).
    func keychainItem(in w: ShellWord) -> String? {
        var found: ShellScript?
        for part in w.parts {
            switch part {
            case .commandSubstitution(let script, _, _, _):
                if found != nil { return nil }
                found = script
            case .text: continue
            default: return nil
            }
        }
        guard let script = found, script.items.count == 1, script.items[0].andOr.pipelines.count == 1,
              script.items[0].andOr.pipelines[0].commands.count == 1,
              case .simple(let s) = script.items[0].andOr.pipelines[0].commands[0] else { return nil }
        let words = s.words.flatMap { expand($0) }
        guard words.count >= 2, let p = words[0].text, Self.baseName(p).lowercased() == "security",
              let sub = words[1].text, sub == "find-generic-password" || sub == "find-internet-password" else { return nil }
        let parsed = parseArgs(Array(words.dropFirst(2)), Self.securityFindSpec)
        guard parsed.has("w") else { return nil }
        return parsed.values("s").first ?? parsed.values("a").first ?? parsed.values("l").first ?? "an item"
    }

    static let securityFindSpec = ArgSpec(["a", "c", "C", "D", "G", "j", "l", "s", "r", "P", "k", "t"])
}
