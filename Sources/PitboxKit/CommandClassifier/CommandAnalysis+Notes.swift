import Foundation

// The grey notes (informational; they never change the button) that are not added by a rule, Fetch file recognition
// (docs/SHELL_LANGUAGE.md §4.2) and the untagged-block reading.

extension CommandAnalysis {
    static let knownEnvironment: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "TERM", "PWD",
                                                "?", "$", "@", "#", "*", "!", "-", "0", "IFS"]

    func collectNotes() {
        if facts.turnReadWeb { addNote(.readWeb, CommandPatterns.NoteWords.readWeb) }
        finalizeWrites()
        if tops.count >= 2 {
            addNote(.runsSeveral, "Runs \(tops.count) commands" + (topItems > 1 ? "; " + CommandPatterns.NoteWords.laterLinesRun : ""))
        }
        var names: [String] = []
        var globs: [String] = []
        var braces: [String] = []
        for seg in segments where !seg.isRemote {
            var words = seg.words
            words += seg.assignments.map { CWord(word: $0.value, text: nil, tilde: false) }
            words += seg.redirections.filter { $0.hereDocument == nil }.map { CWord(word: $0.target, text: nil, tilde: false) }
            for w in words {
                for name in w.parameterNames where !Self.knownEnvironment.contains(name) && !names.contains(name) {
                    if case .literal? = seg.variables[name] { continue }
                    if Int(name) != nil { continue }
                    names.append(name)
                }
                for part in w.word.parts {
                    if case .glob = part { globs.append(source(w.range)); break }
                    if case .braceList(let raw, _, _) = part { braces.append(raw); break }
                }
            }
        }
        for n in names.prefix(6) { addNote(.usesVariable, "Uses $\(n), filled in when it runs") }
        if let g = globs.first { addNote(.usesGlob, "Uses `\(shownRaw(g))`, expanded when it runs") }
        if let b = braces.first { addNote(.usesGlob, "Uses `\(shownRaw(b))`, expanded when it runs") }
        if let f = fetch {
            let name = f.destinationName ?? Self.baseName(f.remotePath)
            addNote(.fetchShape, "Copies \(shown(name)) from \(shown(f.alias)) into Downloads")
            notes.removeAll { $0.kind == .notQuarantined || $0.kind == .writes }
        }
        if options.blockKind == .untagged { addNote(.untaggedBlock, CommandPatterns.NoteWords.untaggedBlock) }
        let nonASCII = CommandCharacterPolicy.visibleNonASCII(in: text)
        if !nonASCII.isEmpty {
            let listed = nonASCII.prefix(8).map { "\(String(Character($0.scalar))) (\(CommandCharacterPolicy.codePoint($0.scalar))) in line \($0.line)" }
            addNote(.nonASCII, "Non-ASCII characters: " + listed.joined(separator: ", ")
                    + (nonASCII.count > 8 ? " and \(nonASCII.count - 8) more" : ""))
        }
        if options.shell == .clean { addNote(.cleanShell, CommandPatterns.NoteWords.cleanShell) }
    }

    // MARK: Fetch file

    static let fetchUserPattern = try? NSRegularExpression(pattern: "^[a-z_][a-z0-9_-]{0,31}$")

    func recognizeFetch() {
        guard options.recognizesFetchFile, facts.place == .ssh, let alias = facts.sshAlias, readable, topItems == 1,
              segments.count == 1, let seg = segments.first, let simple = seg.simple, simple.assignments.isEmpty,
              seg.redirections.isEmpty, !seg.background, seg.pipes.isEmpty, seg.wrappers.isEmpty, seg.programIndex == 0,
              seg.key == "scp" || seg.key == "rsync", !seg.programIsBuilt else { return }
        var operands: [CWord] = []
        for w in seg.args {
            if let t = w.text, t.hasPrefix("-") {
                if seg.key == "scp" {
                    guard t.count > 1, !t.hasPrefix("--"), t.dropFirst().allSatisfy({ "pqCv".contains($0) }) else { return }
                } else if t.hasPrefix("--") {
                    guard t == "--progress" || t == "--partial" else { return }
                } else {
                    guard t.count > 1, t.dropFirst().allSatisfy({ "avzhtP".contains($0) }) else { return }
                }
                continue
            }
            operands.append(w)
        }
        guard operands.count == 2 else { return }
        let source = operands[0], destination = operands[1]
        guard let sourceText = source.text, !source.hasPattern, let remote = remoteOperand(source) else { return }
        _ = sourceText
        let names = ([facts.sshAlias, facts.resolvedHostName].compactMap { $0 } + facts.serverNames).map { $0.lowercased() }
        guard names.contains(remote.host.lowercased()) else { return }
        if let user = remote.user {
            let ns = user as NSString
            guard Self.fetchUserPattern?.firstMatch(in: user, range: NSRange(location: 0, length: ns.length)) != nil else { return }
        }
        let path = remote.path
        guard !path.isEmpty, path.utf16.count <= 1_024, !path.hasSuffix("/"), path != "~",
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !path.unicodeScalars.contains(where: { "*?[]{}$`;&|<>()\\'\"!\n\t".unicodeScalars.contains($0) || $0.value < 0x20 }),
              !path.dropFirst().contains("~") || path.hasPrefix("~/") && !path.dropFirst(2).contains("~")
        else { return }
        guard let name = fetchDestination(destination, in: seg) else { return }
        fetch = FetchFileRequest(alias: alias, replyUser: remote.user, remotePath: path, destinationName: name.isEmpty ? nil : name)
    }

    /// The file name after `~/Downloads/` ("" for the folder itself), nil when the word is not one of the Fetch file
    /// forms.
    func fetchDestination(_ w: CWord, in seg: Segment) -> String? {
        var rest: String
        if let t = w.text {
            if w.tilde {
                guard t == "~/Downloads" || t.hasPrefix("~/Downloads/") else { return nil }
                rest = String(t.dropFirst("~/Downloads".count))
            } else {
                let prefix = "/Users/\(facts.userName)/Downloads"
                guard t.lowercased() == prefix.lowercased() || t.lowercased().hasPrefix(prefix.lowercased() + "/") else { return nil }
                rest = String(t.dropFirst(prefix.count))
            }
        } else {
            guard w.parameterNames == ["HOME"], case .parameter(let p)? = w.word.parts.first, p.form == .plain || p.form == .braced,
                  w.word.parts.dropFirst().allSatisfy({ if case .text = $0 { return true }; return false }) else { return nil }
            let tail = w.word.parts.dropFirst().compactMap { part -> String? in
                if case .text(let s, _, _, _) = part { return s }
                return nil
            }.joined()
            guard tail == "/Downloads" || tail.hasPrefix("/Downloads/") else { return nil }
            rest = String(tail.dropFirst("/Downloads".count))
        }
        if rest.isEmpty || rest == "/" { return "" }
        rest.removeFirst()
        guard !rest.contains("/"), rest != ".", rest != "..", !rest.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        return rest
    }

    // MARK: Untagged blocks

    static func untaggedBlockReadsAsCommands(_ text: String, programsOnCleanPath: Set<String>?) -> Bool {
        guard let programs = programsOnCleanPath else { return false }
        let scan = ShellCommandScanner.scan(text)
        guard let script = scan.script, !script.items.isEmpty else { return false }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("$ ") || t.hasPrefix("% ") || t.hasPrefix("> ") { return false }
        }
        let facts = CommandSessionFacts(place: .local, homeDirectory: "/", userName: "", turnOrigin: .human)
        let analysis = CommandAnalysis(text: text, context: CommandContext(facts: facts), options: CommandClassifierOptions())
        analysis.startWalk()
        analysis.walk(script, WalkContext())
        for id in analysis.tops {
            let s = analysis.segments[id]
            if s.pseudo != nil { continue }
            guard let first = s.words.first else { continue }
            guard let t = first.text else { return false }
            let name = baseName(t)
            if CommandPatterns.shellBuiltins.contains(name) || programs.contains(name) || programs.contains(t) { continue }
            return false
        }
        return true
    }
}
