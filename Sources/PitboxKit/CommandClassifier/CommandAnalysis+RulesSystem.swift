import Foundation

// Red lines about the system and credentials: R1 (administrator rights), R7 (Keychain and credentials), R8 (background
// services), R9 (macOS settings), R13 (stopping things), R15's assignment forms, and the dispatch of every program to
// its rule. The user's own Keychain forms are notes, not red lines: storing an item, and reading one into a variable
// without printing it.

extension CommandAnalysis {
    func programRules(_ seg: Segment) {
        let key = seg.key
        if CommandPatterns.downloaders.contains(key) { recordDownloads(seg) }
        checkPrivateKeyPrinting(seg)
        switch key {
        case "rm": ruleRemove(seg)
        case "unlink":
            addNote(.deletes, "Deletes 1 file; not to the Trash")
        case "shred", "srm":
            addFlag(.r2, "Deletes files for good, overwriting them first: \(shownList(parseArgs(seg.args).operands.map { describe($0) }))", in: seg)
        case "find": ruleFind(seg)
        case "git": ruleGit(seg)
        case "chmod", "chown", "chgrp": rulePermissions(seg)
        case "xattr": ruleXattr(seg)
        case "spctl": ruleSpctl(seg)
        case "su", "doas", "pkexec":
            addFlag(.r1, "Runs with administrator rights (\(key))", in: seg)
            if key == "su" { addNote(.asksSecret, "Asks for a password with hidden input (su)") }
        case "security": ruleSecurity(seg)
        case "gh": ruleGH(seg)
        case "ssh-add":
            addNote(.usesSSHAgent, CommandPatterns.NoteWords.usesSSHAgent)
            if parseArgs(seg.args).has("D") { addFlag(.r7, "Removes every key from your ssh-agent (ssh-add -D)", in: seg) }
        case "ssh-keygen": ruleSSHKeygen(seg)
        case "ssh-copy-id":
            let host = parseArgs(seg.args, ArgSpec(["i", "p", "o", "F", "t"])).operands.last.map(describe) ?? "a server"
            addFlag(.r10, "Adds your SSH key to \(host) (ssh-copy-id)", in: seg)
        case "launchctl":
            addFlag(.r8, "Starts or changes a background service (launchctl)", in: seg)
            if seg.args.first?.text == "kill" { addFlag(.r13, "Stops \(seg.args.dropFirst(2).first.map(describe) ?? "a service") (launchctl kill)", in: seg) }
        case "sfltool":
            addFlag(.r8, "Starts or changes a background service (sfltool)", in: seg)
        case "disown":
            addFlag(.r8, CommandPatterns.Words.keepsRunningAfterTab, in: seg)
        case "screen":
            let p = parseArgs(seg.args, ArgSpec(["S", "c", "e", "h", "L", "p", "s", "t", "T", "X"]))
            if p.has("d") || p.has("D") { addFlag(.r8, CommandPatterns.Words.keepsRunningAfterTab, in: seg) }
        case "tmux":
            let words = seg.args.compactMap(\.text)
            if let i = words.firstIndex(where: { ["new", "new-session", "new-window", "neww"].contains($0) }),
               words[(i + 1)...].contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("d") }) {
                addFlag(.r8, CommandPatterns.Words.keepsRunningAfterTab, in: seg)
            }
        case "defaults":
            let words = seg.args.compactMap(\.text).filter { !$0.hasPrefix("-") }
            if let verb = words.first?.lowercased(), ["write", "delete", "import", "rename"].contains(verb) {
                addFlag(.r9, "Changes a macOS setting (defaults \(verb)\(words.dropFirst().first.map { " " + shown($0) } ?? ""))", in: seg)
            }
        case "plistbuddy":
            let p = parseArgs(seg.args, ArgSpec(["c"]))
            for v in p.values("c") {
                let verb = v.split(separator: " ").first.map { $0.lowercased() } ?? ""
                if ["set", "add", "delete", "merge", "import", "clear"].contains(verb) {
                    addFlag(.r9, "Changes a macOS setting (PlistBuddy \(verb))", in: seg)
                }
            }
        case "plutil":
            if seg.args.contains(where: { ["-replace", "-insert", "-remove"].contains($0.text ?? "") }) {
                addFlag(.r9, "Changes a macOS setting (plutil)", in: seg)
            }
        case "pmset":
            if seg.args.first?.text != "-g" { addFlag(.r9, "Changes a macOS setting (pmset)", in: seg) }
        case "scutil":
            if seg.args.contains(where: { $0.text == "--set" }) { addFlag(.r9, "Changes a macOS setting (scutil --set)", in: seg) }
        case "softwareupdate":
            if seg.args.contains(where: { ["--install", "-i", "-ia", "--install-rosetta", "--fetch-full-installer"].contains($0.text ?? "") }) {
                addFlag(.r9, "Changes a macOS setting (softwareupdate --install)", in: seg)
            }
        case "systemsetup":
            addFlag(.r9, "Changes a macOS setting (systemsetup)", in: seg)
        case "kill":
            let p = parseArgs(seg.args, ArgSpec(["s", "n"]))
            if !p.has("l", "L") {
                addFlag(.r13, "Stops \(p.operands.isEmpty ? "a process" : "process " + shownList(p.operands.map { describe($0) }))", in: seg)
            }
        case "killall":
            let p = parseArgs(seg.args, ArgSpec(["u", "t", "c", "SIGNAL"]))
            addFlag(.r13, "Stops \(p.operands.isEmpty ? "processes" : shownList(p.operands.map { describe($0) }))", in: seg)
        case "pkill":
            let p = parseArgs(seg.args, ArgSpec(["U", "u", "G", "g", "P", "t", "F", "s", "J"]))
            addFlag(.r13, "Stops processes matching \(p.operands.first.map(describe) ?? "a pattern")", in: seg)
        case "shutdown", "halt":
            addFlag(.r13, "Stops the Mac (\(key))", in: seg)
        case "reboot":
            addFlag(.r13, "Restarts the Mac (reboot)", in: seg)
        case "read":
            let p = parseArgs(seg.args, ArgSpec(["d", "k", "n", "N", "p", "t", "u", "a", "A"]))
            addNote(.asksValue, CommandPatterns.NoteWords.asksValue)
            if p.has("s") { addNote(.asksSecret, CommandPatterns.NoteWords.asksSecret) }
        case "passwd":
            addNote(.asksSecret, "Asks for a password with hidden input (passwd)")
        case "tail":
            if parseArgs(seg.args, ArgSpec(["n", "c", "b"])).has("f", "F") { addNote(.keepsRunning, CommandPatterns.NoteWords.keepsRunning) }
        case "ping":
            if !parseArgs(seg.args, ArgSpec(["c", "i", "s", "t", "W", "S"])).has("c", "t") {
                addNote(.keepsRunning, CommandPatterns.NoteWords.keepsRunning)
            }
        default:
            if CommandPatterns.settingsPrograms.contains(key) {
                addFlag(.r9, "Changes a macOS setting (\(shown(seg.program ?? key)))", in: seg)
            } else if CommandPatterns.diskPrograms.contains(key) || key.hasPrefix("mkfs") || key.hasPrefix("newfs")
                        || key == "tmutil" || key == "umount" || key == "mount" {
                ruleDisks(seg)
            } else if CommandPatterns.longRunning.contains(key) {
                addNote(.keepsRunning, CommandPatterns.NoteWords.keepsRunning)
            }
        }
        ruleCode(seg)
        ruleNetwork(seg)
    }

    // MARK: R7: security, gh

    func ruleSecurity(_ seg: Segment) {
        guard let sub = seg.args.first?.text else { return }
        let rest = Array(seg.args.dropFirst())
        let lower = sub.lowercased()
        if lower.hasPrefix("delete-") {
            addFlag(.r7, CommandPatterns.Words.deletesKeychainItem + " (security \(sub))", in: seg)
            return
        }
        switch lower {
        case "dump-keychain":
            addFlag(.r7, "Shows the contents of a keychain (security dump-keychain)", in: seg)
        case "export":
            addFlag(.r7, "Exports Keychain items (security export)", in: seg)
        case "set-key-partition-list":
            addFlag(.r7, "Changes which apps may read Keychain items (security set-key-partition-list)", in: seg)
        case "unlock-keychain":
            addFlag(.r7, "Unlocks a keychain (security unlock-keychain)", in: seg)
        case "add-trusted-cert":
            addFlag(.r7, "Trusts a certificate for the whole Mac or your account (security add-trusted-cert)", in: seg)
        case "authorizationdb":
            addFlag(.r7, "Changes the Mac's authorization rules (security authorizationdb)", in: seg)
        case "create-keychain", "default-keychain", "set-keychain-settings":
            addFlag(.r7, "Creates or changes keychains (security \(sub))", in: seg)
        case "find-generic-password", "find-internet-password":
            let p = parseArgs(rest, Self.securityFindSpec)
            let item = p.values("s").first ?? p.values("a").first ?? p.values("l").first ?? "an item"
            if p.has("g") {
                addFlag(.r7, CommandPatterns.Words.showsSecret, in: seg)
            } else if p.has("w") {
                if let variable = keychainAssignment(of: seg) {
                    addNote(.readsKeychainItem, "Reads Keychain item \(shown(item)) into $\(variable), not shown")
                } else {
                    addFlag(.r7, CommandPatterns.Words.showsSecret, in: seg)
                }
            }
        case "add-generic-password", "add-internet-password":
            let p = parseArgs(rest, ArgSpec(["a", "c", "C", "D", "G", "j", "l", "s", "r", "P", "k", "t", "T"]))
            let item = p.values("s").first ?? p.values("l").first ?? "an item"
            addNote(.storesKeychainItem, "Stores Keychain item \(shown(item))")
            if let w = rest.firstIndex(where: { $0.text == "-w" }) {
                if w == rest.count - 1 {
                    addNote(.asksSecret, "Asks for the secret twice, with hidden input")
                } else if rest[w + 1].isLiteral, let v = rest[w + 1].text, !v.hasPrefix("-") {
                    addFlag(.r15, CommandPatterns.ruleWords[.r15] ?? "", in: seg, range: rest[w + 1].range)
                }
            }
        default:
            break
        }
    }

    /// The variable a `security … -w` substitution fills (`NAME="$(security …)"`, `export NAME="$(…)"`), nil when its
    /// output reaches the terminal, a pipe, a file or a command's arguments.
    func keychainAssignment(of seg: Segment) -> String? {
        guard !seg.redirections.contains(where: { $0.writesTarget && !$0.target.isDescriptorReference }),
              !segments.contains(where: { other in other.pipes.contains { ref in seg.pipes.contains { $0.id == ref.id && $0.position < ref.position } } })
        else { return nil }
        guard case .substitution(let parentID, let use) = seg.origin else { return nil }
        let parent = segments[parentID]
        if case .assignment(let name, _) = use { return name }
        if use == .argument, ["export", "typeset", "declare", "local", "readonly"].contains(parent.key) {
            for w in parent.args where w.range.contains(seg.range.lowerBound) {
                let prefix = w.staticPrefix
                if let eq = prefix.firstIndex(of: "=") { return String(prefix[..<eq]) }
            }
        }
        return nil
    }

    func ruleGH(_ seg: Segment) {
        let words = seg.args.compactMap(\.text)
        guard let first = words.first else { return }
        let second = words.dropFirst().first
        switch (first, second) {
        case ("auth", "token"):
            addFlag(.r7, CommandPatterns.Words.showsSecret + " (gh auth token)", in: seg)
        case ("auth", "logout"):
            addFlag(.r7, "Signs GitHub CLI out and removes its token (gh auth logout)", in: seg)
        case ("gist", "create"):
            let files = Array(seg.args.dropFirst(2)).filter { !($0.text ?? "").hasPrefix("-") }
            addFlag(.r12, "Uploads \(files.isEmpty ? "text" : shownList(files.map { describe($0) })) to GitHub (gh gist create)", in: seg)
        case ("release", "upload"):
            let files = Array(seg.args.dropFirst(3)).filter { !($0.text ?? "").hasPrefix("-") }
            addFlag(.r12, "Uploads \(files.isEmpty ? "files" : shownList(files.map { describe($0) })) to GitHub (gh release upload)", in: seg)
        default:
            break
        }
    }

    // MARK: R15: secrets given to assignments

    func checkSecretAssignments(_ seg: Segment) {
        var candidates: [(name: String, value: CWord, range: Range<Int>)] = []
        for a in seg.assignments {
            candidates.append((a.name, CWord(word: a.value, text: a.value.literalText.map(restore), tilde: false), a.utf16Range))
        }
        if ["export", "typeset", "declare", "local", "readonly"].contains(seg.key) {
            for w in seg.args {
                guard let t = w.text, let eq = t.firstIndex(of: "="), Self.isAssignmentWord(t) else { continue }
                let value = String(t[t.index(after: eq)...])
                let part = ShellWordPart.text(value, quoting: .none, decodedEscapes: false, utf16Range: w.range)
                candidates.append((String(t[..<eq]), CWord(word: ShellWord(parts: [part], utf16Range: w.range), text: value, tilde: false), w.range))
            }
        }
        for c in candidates {
            guard let value = c.value.text, !value.isEmpty, Self.isSecretName(c.name),
                  !value.hasPrefix("/"), !value.hasPrefix("~"), !value.hasPrefix("./"), !isPlaceholderText(value) else { continue }
            addFlag(.r15, CommandPatterns.ruleWords[.r15] ?? "", in: seg, range: c.range)
        }
        // A password in the text: `curl -u user:pass`, `sshpass -p pass`.
        if seg.key == "curl" {
            let p = parseArgs(seg.args, Self.curlSpec)
            for o in p.options where o.name == "u" || o.name == "--user" {
                if let v = o.value, let colon = v.firstIndex(of: ":"), v.index(after: colon) < v.endIndex,
                   o.valueWord?.isLiteral ?? true {
                    addFlag(.r15, CommandPatterns.ruleWords[.r15] ?? "", in: seg, range: o.valueWord?.range ?? o.word.range)
                }
            }
        }
        if seg.key == "sshpass", let p = parseArgs(seg.args, ArgSpec(["p", "f", "d", "e"])).option("p"), p.valueWord?.isLiteral ?? true {
            addFlag(.r15, CommandPatterns.ruleWords[.r15] ?? "", in: seg, range: p.valueWord?.range ?? p.word.range)
        }
    }

    static func isSecretName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return CommandPatterns.secretNameSuffixes.contains { upper.hasSuffix($0) } || upper.contains("PASSWORD")
            || upper.contains("SECRET")
    }
}
