import Foundation

// Red lines about files, folders and disks: R2 (deleting for good), R4 (permissions and Gatekeeper), R6 (git history),
// R7's private SSH keys, R10 (SSH keys), R14 (disks) and B6 (known destroyers), with the R18 parts of `git` and
// `find`. docs/SHELL_LANGUAGE.md §5 and §8 (A6, A10, A11, A21, A22) are the reading.

/// `git` with its global options looked through.
struct GitInvocation {
    let subcommand: String
    let subcommandWord: CWord
    let words: [CWord]
    let args: ParsedArgs
    /// `-c name=value` words.
    let configWords: [CWord]
}

extension CommandAnalysis {
    // MARK: R2 and B6: rm

    func ruleRemove(_ seg: Segment) {
        let p = parseArgs(seg.args)
        let recursive = p.has("r", "R", "--recursive")
        let force = p.has("f", "--force")
        var risky = recursive || force || !p.builtOptions.isEmpty
        var shownTargets: [String] = []
        for op in p.operands {
            if recursive, let what = destroyerTarget(op, in: seg) {
                addFlag(.b6, "Known destroyer: deletes everything in \(what)", in: seg, range: op.range)
            }
            if op.text == nil || op.hasPattern || op.tilde || isHomeOrParent(op, in: seg) { risky = true }
            shownTargets.append(describe(op))
        }
        if risky {
            let targets = shownTargets.isEmpty ? "" : ": " + shownList(shownTargets)
            addFlag(.r2, "Deletes files and folders; not to the Trash" + targets, in: seg)
        } else if !p.operands.isEmpty {
            let n = p.operands.count
            addNote(.deletes, "Deletes \(n) file\(n == 1 ? "" : "s"); not to the Trash")
        }
    }

    /// `~`, `$HOME` or `..` as an rm target (R2 even without options).
    func isHomeOrParent(_ op: CWord, in seg: Segment) -> Bool {
        if let t = op.text, t == ".." || t.hasPrefix("../") || t.hasSuffix("/..") { return true }
        if op.parameterNames.contains("HOME") { return true }
        return false
    }

    /// How a B6 target reads ("~", "/", "the folder it runs in"), or nil when the word is not a known destroyer
    /// target. A word that is only a variable or a substitution not set to a literal earlier in the block is one
    /// (docs/SHELL_LANGUAGE.md A10); so is a word that names one when its unset variables are empty (`"$DIR/"`).
    func destroyerTarget(_ op: CWord, in seg: Segment) -> String? {
        if let values = texts(of: op, in: seg) {
            for v in values { if let what = destroyerValue(v, tilde: op.tilde || op.word.parts.first.map(isHomeParameter) == true, in: seg) { return what } }
            return nil
        }
        if op.isOnlyExpansions { return "whatever `\(shownRaw(source(op.range)))` holds when it runs" }
        // Unset variables and substitutions read as empty: `"$DIR/"` is `/`.
        var text = ""
        for part in op.word.parts {
            switch part {
            case .text(let s, _, _, _): text += restore(s)
            case .tilde: text += "~"
            case .glob(let s, _), .braceList(let s, _, _): text += s
            case .parameter(let param):
                if param.form == .errorIfUnset { return nil }
                if let values = value(of: param.name, in: seg), values.count == 1 { text += values[0] }
            default:
                text += ""
            }
        }
        if text.isEmpty { return "whatever `\(shownRaw(source(op.range)))` holds when it runs" }
        return destroyerValue(text, tilde: false, in: seg)
    }

    func isHomeParameter(_ part: ShellWordPart) -> Bool {
        if case .parameter(let p) = part { return p.name == "HOME" }
        return false
    }

    /// B6 on one literal value of an rm target: `/`, the home folder, `/Users`, `..`, a bare `*`, the folder the command
    /// runs in by any spelling (`.`, `./`, `$PWD`, its full path), the top system folders, a volume root
    /// (`/System/Volumes/Data`, `/Volumes/X`), a top-level system folder of a mounted volume, and the home folder's own
    /// top folders. Relative values are read against the folder the command runs in.
    func destroyerValue(_ raw: String, tilde: Bool, in seg: Segment) -> String? {
        var v = raw
        if v == "~" || v.hasPrefix("~/") { v = home + v.dropFirst() }
        if v == "*" || v == "./*" { return "the folder it runs in (`*`)" }
        if v == ".." || v == "../" || v == "../*" || v == "./.." { return "the folder above (`..`)" }
        let star = v.hasSuffix("/*")
        var trimmed = star ? String(v.dropLast(2)) : v
        if star, trimmed.isEmpty { return "/" }
        if !trimmed.hasPrefix("/") {
            let relative = Self.normalize(trimmed)
            // `.`, `./`, `./.`: the folder the command runs in.
            if relative.isEmpty || relative == "." { return runFolderWords(seg) }
            if relative.split(separator: "/").allSatisfy({ $0 == ".." }) { return "the folder above (`\(relative)`)" }
            guard let folder = seg.folder else { return nil }
            trimmed = Self.normalize(folder + "/" + relative)
        }
        var path = Self.normalize(trimmed)
        var lower = path.lowercased()
        if let folder = seg.folder, lower == folder.lowercased(), folder.lowercased() != home.lowercased() {
            return runFolderWords(seg)
        }
        // The data volume holds the same folders as the firmlinked paths: `/System/Volumes/Data/Users` is `/Users`.
        let data = "/system/volumes/data"
        if lower == data { return "the data volume (/System/Volumes/Data)" }
        if lower.hasPrefix(data + "/") {
            path = String(path.dropFirst(data.count))
            lower = path.lowercased()
        }
        if lower == "/" { return "/" }
        if lower == home.lowercased() { return star ? "~ (every file in it)" : "~" }
        if lower == "/users" { return "/Users" }
        if CommandPatterns.destroyerSystemFolders.contains(where: { $0.lowercased() == lower }) { return path }
        let parts = lower.split(separator: "/").map(String.init)
        if parts == ["system", "volumes"] || (parts.count == 3 && parts[0] == "system" && parts[1] == "volumes") {
            return path                                   // a system volume
        }
        if parts.count == 2, parts[0] == "volumes" { return path }          // a whole mounted volume
        if parts.count == 3, parts[0] == "volumes", Self.volumeTopFolders.contains(parts[2]) { return path }
        if let rel = homeRelative(path),
           CommandPatterns.destroyerHomeFolders.contains(where: { $0.lowercased() == rel.lowercased() }) {
            return "~/" + rel
        }
        return nil
    }

    /// The top-level system folders of a volume (B6 on a mounted volume too).
    static let volumeTopFolders: Set<String> = ["users", "library", "system", "applications", "usr", "bin", "sbin", "etc",
                                                "var", "private", "opt", "cores"]

    /// How the folder the command runs in is named in B6's words.
    func runFolderWords(_ seg: Segment) -> String {
        guard let folder = seg.folder else { return "the folder it runs in (`.`)" }
        return "the folder it runs in (\(shortFolder(folder)))"
    }

    /// A22: a program built at run time followed by destroyer words (`$(echo rm) -rf ~`, `rm${IFS}-rf${IFS}~`).
    func checkBuiltDestroyer(_ seg: Segment) {
        guard seg.programIsBuilt, let k = seg.programIndex else { return }
        let w = seg.words[k]
        var words: [String] = []
        if w.parameterNames.contains("IFS") {
            var current = ""
            for part in w.word.parts {
                switch part {
                case .parameter(let p) where p.name == "IFS":
                    words.append(current)
                    current = ""
                case .text(let s, _, _, _): current += s
                case .tilde: current += "~"
                case .glob(let s, _), .braceList(let s, _, _): current += s
                default: current += "?"
                }
            }
            words.append(current)
            words = Array(words.dropFirst().filter { !$0.isEmpty })
        }
        let options = words.filter { $0.hasPrefix("-") } + seg.args.compactMap(\.text).filter { $0.hasPrefix("-") }
        let recursive = options.contains { o in
            o == "--recursive" || o == "--force" || (!o.hasPrefix("--") && (o.contains("r") || o.contains("R") || o.contains("f")))
        }
        guard recursive else { return }
        for t in words where !t.hasPrefix("-") {
            if let what = destroyerValue(t, tilde: t.hasPrefix("~"), in: seg) {
                addFlag(.b6, "Known destroyer: a command built at run time deletes everything in \(what)", in: seg, range: w.range)
                return
            }
        }
        for op in parseArgs(seg.args).operands {
            if let what = destroyerTarget(op, in: seg) {
                addFlag(.b6, "Known destroyer: a command built at run time deletes everything in \(what)", in: seg, range: op.range)
                return
            }
        }
    }

    // MARK: find

    func ruleFind(_ seg: Segment) {
        var starts: [String] = []
        var k = 0
        let args = seg.args
        while k < args.count, let t = args[k].text, ["-H", "-L", "-P", "-E", "-X", "-x", "-s", "-d"].contains(t) { k += 1 }
        while k < args.count, let t = args[k].text, !t.hasPrefix("-"), t != "(", t != "!" {
            starts.append(shown(t)); k += 1
        }
        let place = starts.isEmpty ? "" : ": in " + shownList(starts)
        var j = k
        while j < args.count {
            guard let t = args[j].text else { j += 1; continue }
            if t == "-delete" {
                addFlag(.r2, "Deletes what find matches; not to the Trash" + place, in: seg, range: args[j].range)
            }
            if ["-exec", "-execdir", "-ok", "-okdir"].contains(t) {
                let command = args[(j + 1)...].prefix { $0.text != ";" && $0.text != "+" }
                let name = command.first?.text.map { Self.baseName($0).lowercased() } ?? ""
                addFlag(.r18, "Runs a command for every file find matches (\(t)); what it matches is not shown here",
                        in: seg, range: args[j].range)
                if ["rm", "shred", "srm", "unlink", "rmdir"].contains(name) {
                    addFlag(.r2, "Deletes what find matches; not to the Trash" + place, in: seg, range: args[j].range)
                }
                j += command.count + 1
            }
            j += 1
        }
    }

    // MARK: git

    func gitInvocation(_ seg: Segment) -> GitInvocation? {
        let words = seg.args
        var k = 0
        var configs: [CWord] = []
        let withValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--exec-path",
                                      "--super-prefix"]
        while k < words.count, let t = words[k].text, t.hasPrefix("-") {
            if t == "-c" { if k + 1 < words.count { configs.append(words[k + 1]) }; k += 2; continue }
            if t.hasPrefix("-c"), t.count > 2 { configs.append(words[k]); k += 1; continue }
            if withValue.contains(t) { k += 2; continue }
            k += 1
        }
        guard k < words.count, let sub = words[k].text else { return nil }
        let rest = Array(words[(k + 1)...])
        let spec: ArgSpec
        switch sub {
        case "push": spec = ArgSpec(["o", "--push-option", "--repo", "--receive-pack", "--exec"])
        case "clean": spec = ArgSpec(["e", "--exclude"])
        case "checkout": spec = ArgSpec(["b", "B", "--orphan", "--conflict", "--pathspec-from-file"])
        case "restore": spec = ArgSpec(["s", "--source", "--pathspec-from-file"])
        case "branch": spec = ArgSpec(["u", "--set-upstream-to", "--contains", "--merged", "--no-merged", "--points-at",
                                       "--sort", "--format"])
        case "config": spec = ArgSpec(["f", "--file", "--blob", "--type", "--default", "--comment"])
        case "commit": spec = ArgSpec(["m", "F", "C", "c", "t", "--author", "--date", "--file", "--message",
                                       "--reuse-message", "--template", "--fixup", "--squash", "--cleanup"])
        case "stash": spec = ArgSpec(["m", "--message", "--pathspec-from-file"])
        case "reset", "gc", "reflog", "update-ref", "filter-branch", "filter-repo": spec = .none
        default: spec = .none
        }
        return GitInvocation(subcommand: sub, subcommandWord: words[k], words: rest, args: parseArgs(rest, spec),
                             configWords: configs)
    }

    func ruleGit(_ seg: Segment) {
        addNote(.usesSSHAgent, CommandPatterns.NoteWords.usesSSHAgent)
        guard let g = gitInvocation(seg) else { return }
        for c in g.configWords {
            addFlag(.r18, "Runs code from git configuration given here (git -c \(shown(c.text ?? source(c.range))))",
                    in: seg, range: c.range)
        }
        let a = g.args
        let operands = a.operands.compactMap(\.text)
        let r2 = "Deletes files and folders; not to the Trash"
        switch g.subcommand {
        case "clean":
            if a.has("f", "--force"), !a.has("n", "--dry-run") { addFlag(.r2, r2 + " (git clean)", in: seg) }
        case "reset":
            if a.has("--hard") { addFlag(.r2, "Throws away uncommitted changes for good (git reset --hard)", in: seg) }
        case "checkout":
            let dashdash = g.words.contains { $0.text == "--" }
            if (dashdash && !operands.isEmpty) || operands.contains(".") || a.has("f", "--force") {
                addFlag(.r2, "Throws away uncommitted changes for good (git checkout)", in: seg)
            }
        case "restore":
            let stagedOnly = a.has("S", "--staged") && !a.has("W", "--worktree")
            if !operands.isEmpty, !stagedOnly {
                addFlag(.r2, "Throws away uncommitted changes for good (git restore)", in: seg)
            }
        case "stash":
            if let first = operands.first, first == "drop" || first == "clear" {
                addFlag(.r2, "Deletes stashed changes for good (git stash \(first))", in: seg)
            }
        case "branch":
            if a.has("D") || (a.has("d", "--delete") && a.has("f", "--force")) {
                addFlag(.r2, "Deletes a branch that may not be merged (git branch -D)", in: seg)
            }
        case "push":
            rulePush(seg, g)
        case "filter-branch", "filter-repo":
            addFlag(.r6, "Rewrites or deletes history (git \(g.subcommand))", in: seg)
        case "reflog":
            if operands.first == "expire" { addFlag(.r6, "Rewrites or deletes history (git reflog expire)", in: seg) }
        case "gc":
            if a.values("--prune").contains(where: { $0 == "now" || $0 == "all" }) {
                addFlag(.r6, "Rewrites or deletes history (git gc --prune=now)", in: seg)
            }
        case "update-ref":
            if a.has("d") { addFlag(.r6, "Rewrites or deletes history (git update-ref -d)", in: seg) }
        case "config":
            let readOnly = a.has("--get", "--get-all", "--get-regexp", "--list", "l", "--get-urlmatch")
            if let key = operands.first?.lowercased(), !readOnly {
                let runsCode = ["core.hookspath", "core.fsmonitor", "core.sshcommand", "core.pager", "core.editor",
                                "core.askpass", "credential.helper", "diff.external", "gpg.program", "sequence.editor"]
                if runsCode.contains(key) || key.hasPrefix("alias.") || (key.hasPrefix("filter.") && (key.hasSuffix(".clean") || key.hasSuffix(".smudge"))) {
                    addFlag(.r18, "Runs code git is set to run (git config \(shown(operands[0])))", in: seg)
                }
            }
        default:
            break
        }
    }

    func rulePush(_ seg: Segment, _ g: GitInvocation) {
        let a = g.args
        let remote = a.operands.first?.text.map(shown) ?? "the default remote"
        var rewrites = a.has("f", "--force", "--force-with-lease", "--force-if-includes", "--mirror", "--all", "--delete",
                             "d", "--prune")
        for op in a.operands.dropFirst() {
            if let t = op.text, t.hasPrefix("+") || t.hasPrefix(":") { rewrites = true }
        }
        if rewrites { addFlag(.r6, "Rewrites or deletes history on \(remote)", in: seg) }
    }

    // MARK: R4

    func rulePermissions(_ seg: Segment) {
        let key = seg.key
        var recursive = false
        var mode: CWord?
        var targets: [CWord] = []
        var owner: CWord?
        for w in seg.args {
            guard let t = w.text else { if mode == nil && key == "chmod" { mode = w } else { targets.append(w) }; continue }
            if t.hasPrefix("-"), !(key == "chmod" && Self.isSymbolicMode(t)), mode == nil, owner == nil, targets.isEmpty {
                if t.dropFirst().contains("R") { recursive = true }
                continue
            }
            if key == "chmod", mode == nil { mode = w; continue }
            if key != "chmod", owner == nil { owner = w; continue }
            targets.append(w)
        }
        let shownTargets = shownList(targets.map { describe($0) })
        let what = targets.isEmpty ? "" : shownTargets
        if recursive {
            addFlag(.r4, "Changes permissions of \(what) and everything inside it", in: seg)
            for t in targets {
                if let paths = localPaths(t, in: seg), paths.contains("/") {
                    addFlag(.b6, "Known destroyer: changes the permissions of every file on the disk (`\(key) -R` on /)", in: seg, range: t.range)
                } else if let m = mode?.text, Self.isNoAccess(m), let paths = localPaths(t, in: seg),
                          paths.contains(where: { $0.lowercased() == home.lowercased() || $0.lowercased() == "/users" }) {
                    addFlag(.b6, "Known destroyer: takes every permission from \(describe(t))", in: seg, range: t.range)
                }
            }
        }
        if key == "chmod", let m = mode?.text, Self.isRiskyMode(m) {
            addFlag(.r4, "Changes permissions of \(what) (\(shown(m)): \(Self.modeMeaning(m)))", in: seg, range: mode?.range)
        }
        for t in targets {
            guard let paths = localPaths(t, in: seg) else { continue }
            for path in paths where isProtectedPermissionPath(path) {
                addFlag(.r4, "Changes permissions of \(shownPath(path))", in: seg, range: t.range)
            }
        }
    }

    func isProtectedPermissionPath(_ path: String) -> Bool {
        if path == "/" { return true }
        if CommandPatterns.protectedSystemFolders.contains(where: { Self.isInside(path, $0) }) { return true }
        let parts = path.split(separator: "/")
        if parts.count >= 2, parts[0].lowercased() == "users" {
            let user = parts[1].lowercased()
            return user != facts.userName.lowercased() && user != "shared"
        }
        return false
    }

    static func isSymbolicMode(_ t: String) -> Bool {
        let clauses = t.split(separator: ",", omittingEmptySubsequences: false)
        return !clauses.isEmpty && clauses.allSatisfy { c in
            var s = Substring(c)
            while let f = s.first, "ugoa".contains(f) { s = s.dropFirst() }
            guard let op = s.first, "+-=".contains(op) else { return false }
            return s.dropFirst().allSatisfy { "rwxXstugo+-=".contains($0) }
        }
    }

    static func isNoAccess(_ m: String) -> Bool { ["000", "0000", "a-rwx", "a=", "ugo-rwx", "ugo="].contains(m) }

    /// World-writable, setuid or setgid modes.
    static func isRiskyMode(_ m: String) -> Bool {
        if m.allSatisfy(\.isNumber), (3...4).contains(m.count) {
            let digits = m.compactMap { Int(String($0)) }
            guard digits.allSatisfy({ $0 < 8 }) else { return false }
            if digits.count == 4, digits[0] & 6 != 0 { return true }
            return (digits.last ?? 0) & 2 != 0
        }
        if m.hasPrefix("+a") || m.hasPrefix("=a") || m.hasPrefix("-a") && m.count > 2 { return true }
        for clause in m.split(separator: ",") {
            var who = ""
            var s = Substring(clause)
            while let f = s.first, "ugoa".contains(f) { who.append(f); s = s.dropFirst() }
            guard let op = s.first, op == "+" || op == "=" else { continue }
            let perms = s.dropFirst()
            if perms.contains("s") { return true }
            if perms.contains("w"), who.contains("a") || who.contains("o") { return true }
        }
        return false
    }

    static func modeMeaning(_ m: String) -> String {
        if m.contains("s") || (m.count == 4 && m.first.map { "246".contains($0) || "357".contains($0) } == true && m.allSatisfy(\.isNumber)) {
            return "runs with its owner's rights"
        }
        return "anyone may change it"
    }

    func ruleXattr(_ seg: Segment) {
        let p = parseArgs(seg.args)
        if p.has("c") || (p.has("d") && p.operands.first?.text?.lowercased() == "com.apple.quarantine") {
            addFlag(.r4, CommandPatterns.Words.removesQuarantine, in: seg)
        }
    }

    func ruleSpctl(_ seg: Segment) {
        for w in seg.args {
            guard let t = w.text else { continue }
            if ["--master-disable", "--global-disable", "--add", "--disable", "--remove"].contains(t) {
                addFlag(.r4, "Changes the Gatekeeper download check (spctl \(t))", in: seg, range: w.range)
            }
        }
    }

    // MARK: Disks (R14, B6)

    func ruleDisks(_ seg: Segment) {
        let key = seg.key
        switch key {
        case "dd":
            addFlag(.r14, "Works on disks or volumes (dd)", in: seg)
            for w in seg.args {
                guard let t = w.text, t.lowercased().hasPrefix("of=") else { continue }
                if Self.isDisk(String(t.dropFirst(3))) {
                    addFlag(.b6, "Known destroyer: overwrites the disk \(shown(String(t.dropFirst(3))))", in: seg, range: w.range)
                }
            }
        case "diskutil":
            addFlag(.r14, "Works on disks or volumes (diskutil)", in: seg)
            let words = seg.args.compactMap(\.text)
            let erasing: Set<String> = ["erasedisk", "erasevolume", "partitiondisk", "zerodisk", "randomdisk", "secureerase",
                                        "reformat", "erasecd"]
            if let verb = words.first?.lowercased(), erasing.contains(verb) || words.first?.lowercased() == "apfs" {
                let apfsErase = verb == "apfs" && words.count > 1 && ["deletecontainer", "erasevolume", "deletevolume"].contains(words[1].lowercased())
                if erasing.contains(verb) || apfsErase {
                    for t in words.dropFirst() where Self.isInternalDisk(t) {
                        addFlag(.b6, "Known destroyer: erases the internal disk (\(shown(t)))", in: seg)
                        break
                    }
                }
            }
        case "tmutil":
            if let verb = seg.args.first?.text?.lowercased(),
               ["delete", "disable", "deletelocalsnapshots", "deleteinprogress", "thinlocalsnapshots"].contains(verb) {
                addFlag(.r14, "Works on disks or volumes (tmutil \(verb))", in: seg)
            }
        case "umount":
            if parseArgs(seg.args).has("f") { addFlag(.r14, "Works on disks or volumes (umount -f)", in: seg) }
        case "mount":
            if !parseArgs(seg.args, ArgSpec(["t", "o"])).operands.isEmpty {
                addFlag(.r14, "Works on disks or volumes (mount)", in: seg)
            }
        default:
            addFlag(.r14, "Works on disks or volumes (\(shown(seg.program ?? key)))", in: seg)
        }
    }

    static func isInternalDisk(_ t: String) -> Bool {
        let l = t.lowercased()
        if l == "/" || l == "/system/volumes/data" || l == "macintosh hd" { return true }
        let name = l.hasPrefix("/dev/r") ? String(l.dropFirst(6)) : (l.hasPrefix("/dev/") ? String(l.dropFirst(5)) : l)
        for disk in CommandPatterns.internalDisks {
            if name == disk || (name.hasPrefix(disk + "s") && name.dropFirst(disk.count + 1).allSatisfy(\.isNumber)) {
                return true
            }
        }
        return false
    }

    // MARK: R10 and R7's keys

    func ruleSSHKeygen(_ seg: Segment) {
        let p = parseArgs(seg.args, ArgSpec(["a", "b", "C", "D", "E", "F", "f", "I", "J", "j", "K", "m", "M", "N", "n", "O",
                                             "P", "R", "r", "s", "t", "V", "w", "Y", "Z", "z"]))
        let defaultKeys = [home + "/.ssh/id_ed25519", home + "/.ssh/id_rsa"]
        localTargets.append(contentsOf: defaultKeys)
        if let r = p.option("R") {
            addFlag(.r10, "Removes the host key of \(r.value.map(shown) ?? "a host") from known_hosts (ssh-keygen -R)", in: seg)
            return
        }
        if p.has("l", "y", "F", "e", "i", "B", "L", "Q", "H", "k") || p.has("Y") { return }
        var keyFile: String?
        if let f = p.option("f") {
            if let w = f.valueWord, let paths = localPaths(w, in: seg), paths.count == 1 { keyFile = paths[0] }
            else if let v = f.value { keyFile = v.hasPrefix("/") ? Self.normalize(v) : seg.folder.map { Self.normalize($0 + "/" + v) } }
        }
        if let keyFile { localTargets.append(keyFile) }
        let facts = context.pathFacts
        let candidates = keyFile.map { [$0] } ?? defaultKeys
        let known = candidates.compactMap { facts[$0] }
        if !facts.isEmpty, known.count == candidates.count, known.allSatisfy({ $0 == .missing }) { return }
        let shownKey = keyFile.map(shownPath) ?? "~/.ssh/id_ed25519 or ~/.ssh/id_rsa"
        addFlag(.r10, "Replaces an SSH key: \(shownKey)", in: seg)
        if !p.has("N") { addNote(.asksSecret, "Asks for a passphrase with hidden input (ssh-keygen)") }
    }

    /// R7: printing a private SSH key (`cat ~/.ssh/id_ed25519`, `pbcopy < ~/.ssh/id_rsa`).
    func checkPrivateKeyPrinting(_ seg: Segment) {
        let printers: Set<String> = ["cat", "less", "more", "head", "tail", "bat", "strings", "xxd", "od", "hexdump",
                                     "base64", "pbcopy", "nl", "tac", "view", "vim", "nano"]
        guard printers.contains(seg.key) else { return }
        var words = parseArgs(seg.args, ArgSpec(["n", "c"])).operands
        for r in seg.redirections where r.op == .input { words.append(contentsOf: expand(r.target)) }
        for w in words {
            guard let paths = localPaths(w, in: seg) else { continue }
            for path in paths {
                guard let rel = homeRelative(path)?.lowercased(), rel.hasPrefix(".ssh/id_"), !rel.hasSuffix(".pub") else { continue }
                let action = seg.key == "pbcopy" ? "Copies your private SSH key to the clipboard"
                    : "Shows your private SSH key on screen; it stays in the tab until you close it"
                addFlag(.r7, action, in: seg, range: w.range)
            }
        }
    }
}
