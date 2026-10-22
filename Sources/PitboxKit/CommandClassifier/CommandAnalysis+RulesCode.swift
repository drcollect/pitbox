import Foundation

// Red lines about code that runs: R3 (downloaded code run at once), B5 (decoded text run), R11 (built commands),
// R16 (installers), R18 (code that is not shown) and R19 (controlling other apps). A shell or interpreter's code comes
// from its standard input (pipes, here-docs, here-strings), a script file (also `<(…)`), or an inline word (`-c`,
// `eval`); each source is followed back to the segments that produce it.

extension CommandAnalysis {
    // MARK: R3 and B5: where a shell's code comes from

    /// True when `seg` runs code it reads: a shell, an interpreter, `eval`, `source` or `.`.
    func checkCodeSources(_ seg: Segment) {
        guard seg.programIndex != nil, !seg.key.isEmpty else { return }
        let key = seg.key
        var sources: [Segment] = []
        var fromStandardInput = false
        if isShell(key) || isInterpreter(key) {
            let inv = isShell(key) ? shellInvocation(seg) : interpreterInvocation(seg)
            if let inline = inv.inline { sources += produced(by: seg, within: inline.range) }
            if let file = inv.scriptFile {
                // `bash /dev/stdin`, `sh /dev/fd/0`: the script is the pipe.
                if let t = file.text, Self.standardInputPaths.contains(t) { fromStandardInput = true }
                else { sources += produced(by: seg, within: file.range) }
            }
            if inv.readsStandardInput { fromStandardInput = true }
        } else if key == "eval" || key == "source" || key == "." {
            for a in seg.args { sources += produced(by: seg, within: a.range) }
            if key != "eval", let first = seg.args.first?.text, Self.standardInputPaths.contains(first) {
                fromStandardInput = true
            }
        } else {
            return
        }
        if fromStandardInput { sources += upstream(of: seg) }
        var all: [Segment] = []
        var seen = Set<Int>()
        for s in sources where !seen.contains(s.id) {
            seen.insert(s.id)
            all.append(s)
            for u in upstream(of: s) where !seen.contains(u.id) { seen.insert(u.id); all.append(u) }
        }
        for s in all {
            if CommandPatterns.downloaders.contains(s.key) {
                let host = urlHosts(in: s).first.map(shown) ?? "the internet"
                addFlag(.r3, "Runs code it downloads from \(host) without showing it", in: seg)
            } else if s.key == "pbpaste" {
                addFlag(.r3, "Runs code from the clipboard without showing it", in: seg)
            } else if let host = s.sendsTo ?? (CommandPatterns.remoteShells.contains(s.key) ? remoteTarget(s).host : nil) {
                addFlag(.r3, "Runs code it gets from \(shown(host)) without showing it", in: seg)
            }
            if isDecoder(s) {
                addFlag(.b5, CommandPatterns.ruleWords[.b5] ?? "", in: seg)
            }
        }
        if fromStandardInput {
            let fed = seg.redirections.contains { ($0.fileDescriptor ?? 0) == 0 && ($0.hereDocument != nil || $0.op == .hereString || $0.op == .input) }
            if fed || !upstream(of: seg).isEmpty {
                addFlag(.r18, "Runs code given to \(shown(seg.program ?? key)) on its input; only what the block shows is checked",
                        in: seg)
            }
        }
        // Download, chmod +x and run in one block.
        if let file = isShell(key) || isInterpreter(key) ? scriptFileWord(seg) : nil, wasDownloaded(file, in: seg) {
            addFlag(.r3, "Runs code it downloaded in this block without showing it", in: seg, range: file.range)
        }
        if key == "source" || key == ".", let file = seg.args.first, wasDownloaded(file, in: seg) {
            addFlag(.r3, "Runs code it downloaded in this block without showing it", in: seg, range: file.range)
        }
    }

    /// The segments that run inside one word of `seg` (its substitutions), with what they nest.
    func produced(by seg: Segment, within range: Range<Int>) -> [Segment] {
        var out: [Segment] = []
        var parents = Set([seg.id])
        for s in segments where s.id > seg.id {
            guard let p = s.parent, parents.contains(p) else { continue }
            if p == seg.id {
                guard range.contains(s.range.lowerBound) || s.range.lowerBound == range.lowerBound else { continue }
                if case .nested = s.origin { continue }
            }
            parents.insert(s.id)
            out.append(s)
        }
        return out
    }

    func isDecoder(_ s: Segment) -> Bool {
        let p = parseArgs(s.args)
        switch s.key {
        case "base64", "gbase64": return p.has("d", "D", "--decode")
        case "xxd": return p.has("r", "-revert")
        case "openssl":
            let words = s.args.compactMap(\.text)
            return (words.contains("enc") || words.contains("base64") || words.first?.hasPrefix("-") == true) && words.contains("-d")
        case "uudecode", "gunzip", "zcat", "bzcat", "xzcat", "zstdcat", "unxz", "bunzip2", "rev": return true
        case "gzip", "bzip2", "xz", "zstd": return p.has("d", "--decompress")
        case "printf": return s.args.contains { ($0.text ?? "").range(of: "\\\\(x[0-9A-Fa-f]|[0-7]{1,3}|u[0-9A-Fa-f])", options: .regularExpression) != nil }
        case "echo", "print":
            return s.args.contains { ($0.text ?? "").range(of: "\\\\(x[0-9A-Fa-f]|0[0-7]{1,3}|u[0-9A-Fa-f])", options: .regularExpression) != nil }
        default: return false
        }
    }

    /// The script file a shell or interpreter runs, if any.
    func scriptFileWord(_ seg: Segment) -> CWord? {
        isShell(seg.key) ? shellInvocation(seg).scriptFile : interpreterInvocation(seg).scriptFile
    }

    func wasDownloaded(_ w: CWord, in seg: Segment) -> Bool {
        guard let paths = localPaths(w, in: seg) else { return false }
        return downloads.contains { d in d.segment < seg.id && paths.contains { $0.lowercased() == d.path.lowercased() } }
    }

    /// Notes what a downloader writes (for "download, chmod +x and run").
    func recordDownloads(_ seg: Segment) {
        var targets: [String] = []
        let urls = urlWords(in: seg)
        switch seg.key {
        case "curl":
            let p = parseArgs(seg.args, Self.curlSpec)
            for o in p.options where o.name == "o" || o.name == "--output" {
                if let w = o.valueWord, let paths = localPaths(w, in: seg) { targets += paths }
                else if let v = o.value, let f = seg.folder { targets.append(Self.normalize(v.hasPrefix("/") ? v : f + "/" + v)) }
            }
            if p.has("O", "--remote-name", "--remote-name-all"), let f = seg.folder {
                for u in urls { if let name = Self.urlFileName(u) { targets.append(Self.normalize(f + "/" + name)) } }
            }
        case "wget":
            let p = parseArgs(seg.args, Self.wgetSpec)
            if let o = p.option("O", "--output-document"), let w = o.valueWord, let paths = localPaths(w, in: seg) {
                targets += paths
            } else if let f = seg.folder {
                for u in urls { if let name = Self.urlFileName(u) { targets.append(Self.normalize(f + "/" + name)) } }
            }
        default:
            break
        }
        for r in seg.redirections where r.replacesTarget || r.op == .append {
            if let paths = expand(r.target).first.flatMap({ localPaths($0, in: seg) }) { targets += paths }
        }
        for t in targets { downloads.append((t, seg.id)) }
    }

    static func urlFileName(_ url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let path = rest[slash...].split(separator: "?").first.map(String.init) ?? ""
        let name = Self.baseName(path)
        return name.isEmpty || name == "/" ? nil : name
    }

    // MARK: Interpreters

    func interpreterInvocation(_ seg: Segment) -> ShellInvocation {
        var inv = ShellInvocation()
        let key = seg.key
        let inlineFlags: Set<String>
        var values: Set<String> = []
        if key.hasPrefix("python") || key.hasPrefix("pypy") { inlineFlags = ["c"]; values = ["c", "m", "W", "X", "Q"] }
        else if key.hasPrefix("node") || key == "deno" || key == "bun" || key == "tsx" || key == "ts-node" {
            inlineFlags = ["e", "p", "--eval", "--print"]; values = ["e", "p", "r", "C", "--eval", "--print", "--require", "--import", "--loader", "--input-type"]
        } else if key.hasPrefix("perl") { inlineFlags = ["e", "E"]; values = ["e", "E", "M", "m", "I", "F", "l", "x", "C"] }
        else if key.hasPrefix("ruby") { inlineFlags = ["e"]; values = ["e", "r", "I", "C", "E", "F", "x"] }
        else if key.hasPrefix("php") { inlineFlags = ["r"]; values = ["r", "f", "c", "d", "z", "t", "S", "B", "R", "F", "E"] }
        else if key == "osascript" { inlineFlags = ["e"]; values = ["e", "l", "s", "i"] }
        else { inlineFlags = ["e", "c"]; values = ["e", "c"] }
        let p = parseArgs(seg.args, ArgSpec(Array(values)), stopAtFirstOperand: true)
        if let o = p.options.first(where: { inlineFlags.contains($0.name) }) {
            inv.hasInlineFlag = true
            inv.inline = o.valueWord ?? o.word
            return inv
        }
        if key.hasPrefix("php"), let f = p.option("f") { inv.scriptFile = f.valueWord; return inv }
        if key.hasPrefix("python"), p.has("m") { return inv }
        if let first = p.operands.first {
            if first.text == "-" { inv.readsStandardInput = true } else { inv.scriptFile = first }
        } else if !p.has("-v", "--version", "V", "h", "--help", "v") || key == "osascript" {
            inv.readsStandardInput = p.options.isEmpty || key == "osascript"
        }
        return inv
    }

    // MARK: R11, R16, R18, R19 by program

    func ruleCode(_ seg: Segment) {
        let key = seg.key
        let p = parseArgs(seg.args)
        let sub = p.operands.first?.text?.lowercased()
        let folder = shortFolder(seg.folder)
        func runs(_ what: String, _ range: Range<Int>? = nil) {
            addFlag(.r18, "Runs code from \(what) that is not shown here", in: seg, range: range)
        }
        switch key {
        case "eval":
            addFlag(.r11, CommandPatterns.ruleWords[.r11] ?? "", in: seg)
        case "base64", "gbase64":
            if p.has("d", "D", "--decode") { addFlag(.r11, "Decodes hidden text (base64); what it holds is not shown", in: seg) }
        case "xxd":
            if p.has("r", "-revert") { addFlag(.r11, "Decodes hidden text (xxd -r); what it holds is not shown", in: seg) }
        case "openssl":
            let words = seg.args.compactMap(\.text)
            if words.contains("-d"), words.first == "enc" || words.first == "base64" || words.contains("-base64") {
                addFlag(.r11, "Decodes hidden text (openssl); what it holds is not shown", in: seg)
            }
        case "uudecode":
            addFlag(.r11, "Decodes hidden text (uudecode); what it holds is not shown", in: seg)
        case "source", ".":
            if let f = seg.args.first { runs(describe(f), f.range) }
        case "make", "gmake", "just", "rake", "ninja", "bazel", "pytest", "tox", "nox", "rspec", "jest", "vitest", "mix":
            if !(seg.args.count == 1 && ["--version", "-v", "-V", "--help"].contains(seg.args[0].text ?? "")) {
                runs("\(folder) (\(key == "make" || key == "gmake" ? "Makefile" : key))")
            }
        case "npm", "pnpm", "yarn", "bun":
            rulePackageManager(seg, key: key, folder: folder)
        case "npx", "pnpx", "bunx", "uvx":
            runs("the package \(p.operands.first.map(describe) ?? "it names") (\(key))")
        case "pip", "pip3", "pipx":
            if sub == "install" || (key == "pipx" && (sub == "run" || sub == "inject")) {
                runs("the package \(p.operands.dropFirst().first.map(describe) ?? "it installs") (\(key) \(sub ?? ""))")
                if p.has("--user", "--break-system-packages") || key == "pipx" {
                    addFlag(.r16, "Installs software that runs with your rights (\(key) \(sub ?? "install"))", in: seg)
                }
            }
        case "uv":
            let words = p.operands.compactMap(\.text)
            if ["run", "sync", "add"].contains(sub ?? "") || (words.first == "pip" && words.dropFirst().first == "install")
                || (words.first == "tool" && ["run", "install"].contains(words.dropFirst().first ?? "")) {
                runs("\(folder) (uv \(words.prefix(2).joined(separator: " ")))")
            }
        case "poetry":
            if ["install", "run", "add", "update", "build"].contains(sub ?? "") { runs("\(folder) (poetry \(sub ?? ""))") }
        case "bundle":
            if ["install", "exec", "update"].contains(sub ?? "") { runs("\(folder) (Gemfile)") }
        case "swift":
            if ["build", "test", "run", "package"].contains(sub ?? "") { runs("\(folder) (Package.swift)") }
            else if let first = p.operands.first, (first.text ?? "").hasSuffix(".swift") { runs(describe(first), first.range) }
        case "xcodebuild":
            if !seg.args.allSatisfy({ ["-version", "-showsdks", "-help", "-usage", "-list"].contains($0.text ?? "") }) || seg.args.isEmpty {
                runs("\(folder) (the Xcode project)")
            }
        case "cargo":
            if ["build", "b", "run", "r", "test", "t", "bench", "check", "c", "clippy", "doc"].contains(sub ?? "") {
                runs("\(folder) (Cargo.toml)")
            }
            if sub == "install" { addFlag(.r16, "Installs software that runs with your rights (cargo install)", in: seg) }
        case "go":
            if ["run", "test", "build", "generate"].contains(sub ?? "") { runs("\(folder) (the Go package)") }
            if sub == "install" { addFlag(.r16, "Installs software that runs with your rights (go install)", in: seg) }
        case "gradle", "gradlew", "mvn", "mvnw":
            if !seg.args.allSatisfy({ ["--version", "-v", "-version", "--help", "-h"].contains($0.text ?? "") }) || seg.args.isEmpty {
                runs("\(folder) (\(key.hasPrefix("gradle") ? "the Gradle build" : "pom.xml"))")
            }
        case "docker", "podman":
            if ["build", "run", "compose", "buildx", "exec", "create"].contains(sub ?? "") {
                runs("\(sub == "build" || sub == "buildx" || sub == "compose" ? folder : "the image \(p.operands.dropFirst().last.map(describe) ?? "it names")") (\(key) \(sub ?? ""))")
            }
        case "docker-compose":
            runs("\(folder) (docker-compose)")
        case "gem":
            if sub == "install" { addFlag(.r16, "Installs software that runs with your rights (gem install)", in: seg) }
        case "direnv":
            if sub == "allow" { runs("\(folder) (.envrc)") }
        case "installer":
            if p.has("pkg") || seg.args.contains(where: { $0.text == "-pkg" }) {
                addFlag(.r16, "Installs software that runs with your rights (installer -pkg)", in: seg)
            }
        case "brew":
            ruleBrew(seg)
        case "open":
            ruleOpen(seg)
        case "osascript":
            ruleOsascript(seg)
        case "shortcuts":
            if sub == "run" { addFlag(.r19, CommandPatterns.ruleWords[.r19] ?? "", in: seg) }
        case "automator", "cliclick":
            addFlag(.r19, CommandPatterns.ruleWords[.r19] ?? "", in: seg)
        default:
            if isShell(key) || isInterpreter(key) { ruleInterpreter(seg) }
        }
    }

    func rulePackageManager(_ seg: Segment, key: String, folder: String) {
        let p = parseArgs(seg.args, ArgSpec(["C", "--prefix", "-w", "--workspace", "--filter", "--dir"]))
        let sub = p.operands.first?.text?.lowercased()
        let runsScripts: Set<String> = ["run", "run-script", "rum", "urn", "test", "t", "tst", "start", "stop", "restart",
                                        "exec", "x", "install", "i", "in", "ins", "inst", "insta", "instal", "isnt",
                                        "isntall", "add", "ci", "clean-install", "ic", "install-test", "it",
                                        "install-ci-test", "cit", "rebuild", "rb", "create", "dlx", "up", "update",
                                        "upgrade"]
        let readOnly: Set<String> = ["ls", "list", "ll", "la", "outdated", "view", "info", "show", "v", "why", "help",
                                     "config", "get", "root", "bin", "prefix", "search", "audit", "doctor", "whoami",
                                     "ping", "explain", "licenses", "cache", "pack", "store", "-v", "--version",
                                     "version", "-h", "--help"]
        var runsCode = false
        if let sub {
            if runsScripts.contains(sub) { runsCode = true }
            else if key != "npm", !readOnly.contains(sub) { runsCode = true }   // yarn/pnpm/bun run unknown words as scripts
            if key == "bun", (p.operands.first?.text ?? "").contains(".") { runsCode = true }
        } else if key == "yarn", p.options.isEmpty {
            runsCode = true                     // `yarn` alone installs, running the packages' scripts
        }
        if runsCode {
            addFlag(.r18, "Runs code from \(folder) (package.json and the packages it installs) that is not shown here", in: seg)
        }
        if p.has("g", "--global"), ["install", "i", "add"].contains(sub ?? "") || (key == "yarn" && sub == "global") {
            addFlag(.r16, "Installs software that runs with your rights (\(key) \(sub ?? "") -g)", in: seg)
        }
        if key == "yarn", sub == "global" {
            addFlag(.r16, "Installs software that runs with your rights (yarn global)", in: seg)
        }
    }

    func ruleBrew(_ seg: Segment) {
        let p = parseArgs(seg.args)
        let words = p.operands.compactMap(\.text)
        let sub = words.first
        if sub == "services", let action = words.dropFirst().first,
           ["start", "stop", "restart", "run", "kill"].contains(action) {
            addFlag(.r8, "Starts or changes a background service (brew services \(action))", in: seg)
        }
        if ["install", "reinstall", "upgrade"].contains(sub ?? "") {
            if p.has("--cask") || p.has("--casks") {
                addFlag(.r16, "Installs software that runs with your rights: \(shownList(words.dropFirst().map { shown($0) })) (Homebrew cask)", in: seg)
            } else if sub == "install" {
                addNote(.homebrew, CommandPatterns.NoteWords.homebrew)
            }
        }
        if sub == "bundle" { addFlag(.r16, "Installs software that runs with your rights (brew bundle)", in: seg) }
    }

    func ruleOpen(_ seg: Segment) {
        let p = parseArgs(seg.args, ArgSpec(["a", "b", "s", "u", "--env", "--stdin", "--stdout", "--stderr"]))
        if let a = p.option("a", "b") {
            addFlag(.r18, "Runs code from \(a.value.map(shown) ?? "the app it names") (open -\(a.name)) that is not shown here",
                    in: seg, range: a.word.range)
        }
        for op in p.operands {
            guard let t = op.text else { continue }
            var path = t.lowercased()
            while path.hasSuffix("/") { path.removeLast() }
            let ext = (path as NSString).pathExtension
            if ["pkg", "mpkg", "dmg"].contains(ext) {
                addFlag(.r16, "Installs software that runs with your rights (opens \(shown(Self.baseName(t))))", in: seg, range: op.range)
            } else if ext == "app" {
                addFlag(.r16, "Installs software that runs with your rights (opens \(shown(Self.baseName(path))))", in: seg, range: op.range)
                addFlag(.r18, "Runs code from \(shown(Self.baseName(t))) that is not shown here", in: seg, range: op.range)
            } else if ["command", "terminal", "workflow", "tool", "sh", "scpt", "applescript", "action", "prefpane"].contains(ext) {
                addFlag(.r18, "Runs code from \(shown(Self.baseName(t))) that is not shown here", in: seg, range: op.range)
            } else if t.contains("://") {
                addNote(.opens, "Opens \(urlHost(t).map(shown) ?? shown(t))")
            } else {
                addNote(.opens, "Opens \(shown(Self.baseName(t)))")
            }
        }
    }

    func ruleOsascript(_ seg: Segment) {
        addFlag(.r19, CommandPatterns.ruleWords[.r19] ?? "", in: seg)
        let inv = interpreterInvocation(seg)
        if inv.inline != nil {
            addFlag(.r18, "Runs an inline AppleScript (osascript -e) that \(AppIdentity.displayName) does not read", in: seg)
        } else if let f = inv.scriptFile {
            addFlag(.r18, "Runs code from \(describe(f)) that is not shown here", in: seg, range: f.range)
        }
        let script = seg.args.compactMap(\.text).joined(separator: " ").lowercased()
        if script.contains("with administrator privileges") {
            addFlag(.r1, "Runs with administrator rights (osascript)", in: seg)
        }
        if script.contains("login item") {
            addFlag(.r8, "Starts or changes a background service (a login item through osascript)", in: seg)
        }
        let original = seg.args.compactMap(\.text).joined(separator: " ")
        if script.range(of: "\\bquit\\b", options: .regularExpression) != nil {
            var app = "an app"
            for opener in ["application \"", "app \""] {
                if let r = original.range(of: opener, options: .caseInsensitive) {
                    app = original[r.upperBound...].split(separator: "\"").first.map(String.init) ?? app
                    break
                }
            }
            addFlag(.r13, "Stops \(shown(app))", in: seg)
        }
    }

    func ruleInterpreter(_ seg: Segment) {
        let name = seg.program ?? seg.key
        let inv = isShell(seg.key) ? shellInvocation(seg) : interpreterInvocation(seg)
        if inv.hasInlineFlag {
            let words = isShell(seg.key) ? "Runs an inline shell script (\(shown(name)) -c)" :
                "Runs an inline program (\(shown(name))) that \(AppIdentity.displayName) does not read"
            addFlag(.r18, words, in: seg, range: inv.inline?.range)
        } else if let f = inv.scriptFile {
            addFlag(.r18, "Runs code from \(describe(f)) that is not shown here", in: seg, range: f.range)
        }
    }
}
