import Foundation

// The rules every segment gets (docs/SHELL_LANGUAGE.md §3, §5), and the dispatch to the program rules in the other
// rule files. Patterns match the program and the words of that segment only: `echo "rm -rf ~"` matches nothing.

/// A file a segment writes, for R5, R10, R21 and the "Writes" note.
struct WriteRecord {
    let segment: Int
    let range: Range<Int>
    /// As the sheet names it.
    let shown: String
    /// Absolute local paths, nil when unknown.
    let paths: [String]?
    /// Replaces the file (`>`, `cp`, `tee`), as opposed to appending to it or editing it.
    let replaces: Bool
    /// For a copy: the names it puts into the destination when that is a folder.
    var intoFolder: [String] = []
}

extension CommandAnalysis {
    func applyRules(_ seg: Segment) {
        checkLookAlikes(seg)
        collectWrites(seg)
        guard seg.pseudo == nil else { return }
        if seg.background {
            addFlag(.r8, CommandPatterns.Words.keepsRunningAfterTab, in: seg)
        }
        if let k = seg.programIndex, seg.programIsBuilt {
            addFlag(.r11, CommandPatterns.ruleWords[.r11] ?? "", in: seg, range: seg.words[k].range)
            checkBuiltDestroyer(seg)
        }
        for w in seg.words + seg.assignments.map({ CWord(word: $0.value, text: nil, tilde: false) })
        where w.parameterNames.contains("IFS") {
            addFlag(.r11, CommandPatterns.ruleWords[.r11] ?? "", in: seg, range: w.range)
        }
        for (i, key) in seg.wrapperKeys.enumerated() {
            let w = seg.wrappers[i]
            switch key {
            case "sudo", "doas":
                addFlag(.r1, "Runs with administrator rights (\(key))", in: seg, range: w.range)
                if key == "sudo" { addNote(.asksSecret, "Asks for your password with hidden input (sudo)") }
            case "nohup", "setsid":
                addFlag(.r8, CommandPatterns.Words.keepsRunningAfterTab, in: seg, range: w.range)
            case "xargs":
                addFlag(.r18, "Runs a command for every line xargs reads; what it reads is not shown here",
                        in: seg, range: w.range)
            case "watch":
                addNote(.keepsRunning, CommandPatterns.NoteWords.keepsRunning)
            default:
                break
            }
        }
        checkProgramPath(seg)
        checkRunsDownload(seg)
        checkOptionWords(seg)
        checkSecretAssignments(seg)
        if seg.programIndex != nil, !seg.key.isEmpty {
            programRules(seg)
            applyHardeningRules(seg)
        }
        checkHosts(seg)
        checkCodeSources(seg)
    }

    // MARK: B2

    /// B2: a non-ASCII character in a program name or an option (hosts and users are checked with the hosts).
    func checkLookAlikes(_ seg: Segment) {
        var programWords = seg.wrappers
        if let k = seg.programIndex { programWords.append(seg.words[k]) }
        for w in programWords {
            if let s = firstNonASCII(source(w.range)) {
                addFlag(.b2, "Look-alike character \(lookAlike(s)) in the program name \(shownRaw(source(w.range)))", in: seg,
                        range: w.range)
            }
        }
        let before = seg.programIndex.map { Array(seg.words[0..<$0]) } ?? seg.words
        for (k, w) in before.enumerated() where k > 0 {
            guard let t = w.text, let previous = before[k - 1].text else { continue }
            if ["-u", "-g", "--user", "--group"].contains(previous) || t.hasPrefix("--user=") || t.hasPrefix("--group="),
               let s = firstNonASCII(t) {
                addFlag(.b2, "Look-alike character \(lookAlike(s)) in the user name \(shownRaw(t))", in: seg, range: w.range)
            }
        }
        let optionArea = seg.programIndex.map { Array(seg.words[0..<$0]) + seg.args } ?? seg.words
        for w in optionArea where !programWords.contains(where: { $0.range == w.range }) {
            let raw = w.text ?? w.staticPrefix
            let scalars = Array(raw.unicodeScalars)
            guard let first = scalars.first else { continue }
            // A dash look-alike starts an option when letters or digits follow it (`‐rf`); `—` alone is punctuation.
            let optionLike = scalars.dropFirst().first.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) } ?? false
            if CommandCharacterPolicy.dashLookAlikes.contains(first.value), optionLike {
                addFlag(.b2, "Look-alike character \(lookAlike(first)) in an option", in: seg, range: w.range)
            } else if first == "-", let s = firstNonASCII(raw) {
                addFlag(.b2, "Look-alike character \(lookAlike(s)) in the option \(shownRaw(raw))", in: seg, range: w.range)
            }
        }
    }

    /// The first visible non-ASCII character (hidden ones are B1's, not look-alikes).
    func firstNonASCII(_ s: String) -> Unicode.Scalar? {
        s.unicodeScalars.first { !$0.isASCII && !CommandCharacterPolicy.isHidden($0) }
    }

    /// `‘с’ (U+0441 CYRILLIC SMALL LETTER ES)`.
    func lookAlike(_ s: Unicode.Scalar) -> String {
        let shownChar = CommandCharacterPolicy.isHidden(s) ? "⟨" + CommandCharacterPolicy.codePoint(s) + "⟩" : String(Character(s))
        return "‘\(shownChar)’ (\(CommandCharacterPolicy.codePoint(s)) \(CommandCharacterPolicy.name(s)))"
    }

    // MARK: R18: a program given by a path

    func checkProgramPath(_ seg: Segment) {
        guard let k = seg.programIndex, !seg.programIsBuilt || !seg.key.isEmpty else { return }
        let w = seg.words[k]
        guard let values = texts(of: w, in: seg), values.count == 1 else { return }
        let path = values[0]
        guard path.contains("/") else { return }
        let absolute = path.hasPrefix("/") ? Self.normalize(path) : (seg.folder.map { Self.normalize($0 + "/" + path) } ?? path)
        let folderOfProgram = (absolute as NSString).deletingLastPathComponent
        let system = CommandPatterns.systemProgramFolders.contains { Self.isInside(folderOfProgram, $0) }
        if !system {
            let shownProgram = path.hasPrefix("/") ? shownPath(absolute) : shown(path)
            addFlag(.r18, "Runs code from \(shownProgram) that is not shown here", in: seg, range: w.range)
        }
    }

    // MARK: Words anywhere in a segment

    func checkOptionWords(_ seg: Segment) {
        for w in seg.words {
            guard let t = w.text?.lowercased() else { continue }
            let squeezed = t.replacingOccurrences(of: " ", with: "")
            if squeezed.contains("stricthostkeychecking=no") || squeezed.contains("stricthostkeychecking=off")
                || squeezed.contains("userknownhostsfile=/dev/null") {
                addFlag(.r10, CommandPatterns.Words.turnsOffHostKeys, in: seg, range: w.range)
            }
        }
        for a in seg.assignments {
            guard let t = a.value.literalText?.lowercased() else { continue }
            if t.contains("stricthostkeychecking=no") || t.contains("userknownhostsfile=/dev/null") {
                addFlag(.r10, CommandPatterns.Words.turnsOffHostKeys, in: seg, range: a.utf16Range)
            }
        }
    }

    // MARK: Writes (R5, R10, B6 onto disks; R21 and "Writes" later)

    func collectWrites(_ seg: Segment) {
        for r in seg.redirections where r.writesTarget {
            for cw in expand(r.target) {
                if let t = cw.text, Self.isDisk(t) {
                    addFlag(.b6, "Known destroyer: overwrites the disk \(shown(t))", in: seg, range: r.utf16Range)
                    continue
                }
                if let t = cw.text, CommandPatterns.deviceTargets.contains(where: { t == $0 || ($0.hasSuffix("/") && t.hasPrefix($0)) }) {
                    continue
                }
                recordWrite(seg, cw, replaces: r.replacesTarget, range: r.utf16Range)
            }
        }
        guard seg.programIndex != nil, !seg.key.isEmpty else { return }
        let names = copiedNames(seg)
        for (cw, replaces) in programWriteTargets(seg) {
            recordWrite(seg, cw, replaces: replaces, range: cw.range, intoFolder: names)
        }
        switch seg.key {
        case "crontab":
            addFlag(.r5, "Changes a startup or settings file: your crontab (crontab)", in: seg)
        case "at", "batch":
            addFlag(.r5, "Schedules a command to run later (\(seg.key))", in: seg)
        case "git":
            if let g = gitInvocation(seg), g.subcommand == "config", g.args.has("--global", "--system"),
               !g.args.has("--get", "--get-all", "--get-regexp", "--list", "l", "--get-urlmatch", "--show-origin") ||
                g.args.has("--unset", "--unset-all", "--add", "--replace-all", "--remove-section", "--rename-section", "-e", "--edit") {
                let file = g.args.has("--system") ? "/etc/gitconfig" : "~/.gitconfig"
                addFlag(.r5, "Changes a startup or settings file: \(file) (git config)", in: seg)
            }
        default:
            break
        }
    }

    /// The files a program itself writes, with whether it replaces them.
    func programWriteTargets(_ seg: Segment) -> [(CWord, Bool)] {
        let key = seg.key
        switch key {
        case "tee":
            let p = parseArgs(seg.args)
            let append = p.has("a", "--append")
            return p.operands.map { ($0, !append) }
        case "cp", "mv", "install", "ditto", "ln", "gcp", "gmv":
            let spec: ArgSpec = key == "install" ? ArgSpec(["B", "f", "g", "m", "o", "l", "M", "T", "D", "N", "S"])
                : ArgSpec(["t", "S", "--target-directory", "--suffix", "--backup"])
            let p = parseArgs(seg.args, spec)
            if key == "install", p.has("d") { return [] }
            if key == "ditto", p.has("x") { return [] }          // an extraction: ruleArchives
            var replaces = !p.has("n", "i", "--no-clobber", "--interactive")
            if key == "ln" { replaces = p.has("f", "F", "--force") }
            if let t = p.option("t", "--target-directory"), let dir = t.valueWord {
                return [(dir, replaces)]
            }
            guard p.operands.count >= (key == "ln" ? 1 : 2), let dest = p.operands.last else { return [] }
            if key == "ln", p.operands.count == 1 { return [] }
            return [(dest, replaces)]
        case "rsync":
            let p = parseArgs(seg.args, Self.rsyncSpec)
            guard p.operands.count >= 2, let dest = p.operands.last, !isRemoteOperand(dest) else { return [] }
            return [(dest, !p.has("--ignore-existing"))]
        case "scp":
            let p = parseArgs(seg.args, Self.scpSpec)
            guard p.operands.count >= 2, let dest = p.operands.last, !isRemoteOperand(dest) else { return [] }
            return [(dest, true)]
        case "sed":
            let p = parseArgs(seg.args, ArgSpec(["e", "f", "i", "I", "l"]))
            guard p.has("i", "I", "--in-place") else { return [] }
            let files = p.has("e", "f") ? p.operands : Array(p.operands.dropFirst())
            return files.map { ($0, false) }
        case "perl":
            let p = parseArgs(seg.args, ArgSpec(["e", "E", "M", "m", "I", "x", "C", "F", "l", "0"], attachedOnly: ["i"]))
            guard p.has("i") else { return [] }
            let files = p.has("e", "E") ? p.operands : Array(p.operands.dropFirst())
            return files.map { ($0, false) }
        case "truncate":
            let p = parseArgs(seg.args, ArgSpec(["s", "r", "--size", "--reference"]))
            return p.operands.map { ($0, false) }
        case "curl":
            let p = parseArgs(seg.args, Self.curlSpec)
            return p.options.filter { $0.name == "o" || $0.name == "--output" }.compactMap { $0.valueWord }.map { ($0, true) }
        case "wget":
            let p = parseArgs(seg.args, Self.wgetSpec)
            return p.options.filter { $0.name == "O" || $0.name == "--output-document" }.compactMap { $0.valueWord }
                .map { ($0, true) }
        default:
            return []
        }
    }

    /// The base names a copy (`cp`, `mv`, `scp`, `rsync`, `ditto`, `install`, `ln`) puts into a folder destination.
    func copiedNames(_ seg: Segment) -> [String] {
        let spec: ArgSpec
        switch seg.key {
        case "cp", "mv", "ditto", "ln", "gcp", "gmv": spec = ArgSpec(["t", "S", "--target-directory", "--suffix"])
        case "install": spec = ArgSpec(["B", "f", "g", "m", "o", "l", "M", "T", "D", "N", "S"])
        case "scp": spec = Self.scpSpec
        case "rsync": spec = Self.rsyncSpec
        default: return []
        }
        let operands = parseArgs(seg.args, spec).operands
        return operands.dropLast().compactMap { w -> String? in
            let path = remoteOperand(w)?.path ?? w.text
            guard let p = path, !p.hasSuffix("/") else { return nil }
            let name = Self.baseName(p)
            return name.isEmpty || name == "." || name == ".." || name == "~" ? nil : name
        }
    }

    func recordWrite(_ seg: Segment, _ cw: CWord, replaces: Bool, range: Range<Int>, intoFolder: [String] = []) {
        var paths: [String]?
        if seg.isRemote { paths = nil } else { paths = localPaths(cw, in: seg) }
        // A destination ending in `/` is a folder: the copy writes the files inside it.
        if let p = paths, let t = cw.text, t.hasSuffix("/") || t == "." || t == "~", !intoFolder.isEmpty {
            paths = p.flatMap { folder in intoFolder.map { Self.normalize(folder + "/" + $0) } }
        }
        let shownTarget: String = {
            if let p = paths, p.count == 1 { return shownPath(p[0]) }
            return describe(cw)
        }()
        // R5 and R10 by path; in a remote command by its text (the server's files).
        let candidates: [String] = paths ?? remoteStylePaths(cw)
        let suffix = remoteSuffix(seg)
        for path in candidates {
            if isSSHTrustFile(path) {
                addFlag(.r10, "Changes which SSH keys and hosts are trusted: \(shownTarget)\(suffix)", in: seg, range: range)
            }
            if isProtectedSettingsPath(path) {
                addFlag(.r5, "Changes a startup or settings file: \(shownTarget)\(suffix)", in: seg, range: range)
            }
        }
        if paths == nil, seg.folder == nil || cw.text != nil, let t = cw.text, !seg.isRemote {
            // After a `cd` Pitbox cannot follow: a protected dotfile by name (docs/SHELL_LANGUAGE.md A12).
            let base = Self.baseName(t)
            if CommandPatterns.startupFiles.contains(base) {
                addFlag(.r5, "Changes a startup or settings file: \(shown(t))", in: seg, range: range)
            }
        }
        if !seg.isRemote {
            var record = WriteRecord(segment: seg.id, range: range, shown: shownTarget, paths: paths, replaces: replaces)
            if let t = cw.text, !(t.hasSuffix("/") || t == "." || t == "~") { record.intoFolder = intoFolder }
            writeRecords.append(record)
        }
    }

    /// For a remote command: `~/x` read against a stand-in home, absolute paths as they are.
    func remoteStylePaths(_ cw: CWord) -> [String] {
        guard let t = cw.text else { return [] }
        if cw.tilde { return [Self.normalize(home + String(t.dropFirst()))] }
        if t.hasPrefix("/") { return [Self.normalize(t)] }
        return []
    }

    func remoteSuffix(_ seg: Segment) -> String {
        if case .remote(let host) = seg.scope { return " (on \(shown(host)))" }
        return ""
    }

    /// R5's list: the protected startup and settings files.
    func isProtectedSettingsPath(_ path: String) -> Bool {
        if let rel = homeRelative(path) {
            if rel.isEmpty { return false }
            if CommandPatterns.startupFiles.contains(where: { $0.lowercased() == rel.lowercased() }) { return true }
            for folder in CommandPatterns.settingsFolders where Self.isInside("/" + rel, "/" + folder) { return true }
            for prefix in CommandPatterns.settingsFolderPrefixes where rel.lowercased().hasPrefix(prefix.lowercased()) {
                return true
            }
            return false
        }
        if CommandPatterns.temporaryFolders.contains(where: { Self.isInside(path, $0) }) { return false }
        return CommandPatterns.settingsSystemFolders.contains { Self.isInside(path, $0) }
    }

    /// R10's files.
    func isSSHTrustFile(_ path: String) -> Bool {
        guard let rel = homeRelative(path) else { return false }
        return CommandPatterns.sshTrustFiles.contains { $0.lowercased() == rel.lowercased() }
    }

    static func isDisk(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.hasPrefix("/dev/disk") || l.hasPrefix("/dev/rdisk")
    }

    /// `[user@]host:path` (a transfer's remote operand), `host::module` or `rsync://…`.
    func isRemoteOperand(_ cw: CWord) -> Bool { remoteOperand(cw) != nil }

    /// The user, host and path of a remote operand.
    func remoteOperand(_ cw: CWord) -> (user: String?, host: String, path: String)? {
        let staticText = cw.staticPrefix
        guard let t = cw.text ?? (staticText.contains(":") ? staticText : nil), !cw.tilde else { return nil }
        if t.lowercased().hasPrefix("rsync://") || t.lowercased().hasPrefix("sftp://") || t.lowercased().hasPrefix("scp://"),
           let scheme = t.range(of: "://") {
            let rest = t[scheme.upperBound...]
            let hostPart = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            var host = hostPart
            var user: String?
            if let at = host.lastIndex(of: "@") { user = String(host[..<at]); host = String(host[host.index(after: at)...]) }
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
            let path = rest.split(separator: "/", maxSplits: 1).dropFirst().first.map { "/" + $0 } ?? "/"
            return host.isEmpty ? nil : (user, host, path)
        }
        guard let colon = t.firstIndex(of: ":") else { return nil }
        let before = t[..<colon]
        if before.isEmpty || before.contains("/") { return nil }
        var host = String(before)
        var user: String?
        if let at = host.lastIndex(of: "@") { user = String(host[..<at]); host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var path = String(t[t.index(after: colon)...])
        if path.hasPrefix(":") { path.removeFirst() }       // rsync host::module
        return host.isEmpty ? nil : (user, host, path)
    }
}
