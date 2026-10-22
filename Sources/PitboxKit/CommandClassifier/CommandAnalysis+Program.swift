import Foundation

// Finding the program (docs/SHELL_LANGUAGE.md §3.2-§3.3): assignments, then wrappers with their options, are
// looked through. A wrapper option outside the tables is B3: skipping it wrongly would make its value look like the
// program and a dangerous command look harmless.

/// One wrapper's options.
struct WrapperSpec {
    var values: Set<String> = []
    var flags: Set<String> = []
    /// Long options without `=`; `--name=value` is accepted for every name in `longValues`.
    var longValues: Set<String> = []
    var longFlags: Set<String> = []
    /// Short options whose value can only be attached (`-d=permanent` of `watch`).
    var attachedOnly: Set<String> = []
    /// `NAME=value` words may follow the options (`env`, `sudo`).
    var assignments = false
    /// Numbers are flags (`nice -10`).
    var numbers = false
}

extension CommandAnalysis {
    static let wrapperSpecs: [String: WrapperSpec] = [
        "sudo": WrapperSpec(values: ["u", "g", "h", "p", "C", "D", "R", "T", "U", "r", "t"],
                            flags: ["A", "B", "b", "E", "e", "H", "i", "K", "k", "l", "n", "P", "S", "s", "V", "v"],
                            longValues: ["--user", "--group", "--host", "--prompt", "--chdir", "--close-from", "--role",
                                         "--type", "--command-timeout", "--other-user", "--preserve-env"],
                            longFlags: ["--askpass", "--bell", "--background", "--preserve-env", "--edit", "--set-home",
                                        "--login", "--remove-timestamp", "--reset-timestamp", "--list",
                                        "--non-interactive", "--preserve-groups", "--stdin", "--shell", "--validate"],
                            assignments: true),
        "doas": WrapperSpec(values: ["u", "C"], flags: ["n", "s", "L"]),
        "env": WrapperSpec(values: ["u", "C", "S", "P"], flags: ["i", "0", "v"],
                           longValues: ["--unset", "--chdir", "--split-string"],
                           longFlags: ["--ignore-environment", "--null", "--debug"], assignments: true),
        "command": WrapperSpec(flags: ["p", "v", "V"]),
        "builtin": WrapperSpec(),
        "exec": WrapperSpec(values: ["a"], flags: ["c", "l"]),
        "nohup": WrapperSpec(),
        "time": WrapperSpec(values: ["o"], flags: ["p", "l", "h", "a"]),
        "nice": WrapperSpec(values: ["n"], longValues: ["--adjustment"], numbers: true),
        "xargs": WrapperSpec(values: ["I", "J", "L", "n", "P", "R", "s", "E", "d", "a", "S"],
                             flags: ["0", "t", "p", "r", "o", "x"],
                             longValues: ["--max-args", "--max-procs", "--delimiter", "--arg-file", "--max-lines",
                                          "--max-chars", "--replace", "--eof"],
                             longFlags: ["--null", "--verbose", "--interactive", "--no-run-if-empty", "--exit",
                                         "--open-tty", "--replace"],
                             attachedOnly: ["i", "l", "e"]),
        "caffeinate": WrapperSpec(values: ["t", "w"], flags: ["d", "i", "m", "s", "u"]),
        "watch": WrapperSpec(values: ["n"], flags: ["t", "b", "e", "c", "g", "x", "p", "w", "q"],
                             longValues: ["--interval", "--differences"],
                             longFlags: ["--no-title", "--beep", "--errexit", "--color", "--chgexit", "--exec",
                                         "--precise", "--no-linewrap", "--differences"],
                             attachedOnly: ["d"]),
        "setsid": WrapperSpec(flags: ["c", "f", "w"], longFlags: ["--ctty", "--fork", "--wait"]),
        "timeout": WrapperSpec(values: ["s", "k"], flags: ["v"], longValues: ["--signal", "--kill-after"],
                               longFlags: ["--verbose", "--foreground", "--preserve-status"]),
        "stdbuf": WrapperSpec(values: ["i", "o", "e"], longValues: ["--input", "--output", "--error"]),
        "chronic": WrapperSpec(flags: ["e", "v"]),
        "unbuffer": WrapperSpec(flags: ["p"]),
        "arch": WrapperSpec(),
        "busybox": WrapperSpec(),
    ]

    static let wrapperAliases: [String: String] = ["gtimeout": "timeout", "gstdbuf": "stdbuf"]

    private enum WrapperEnd {
        /// The next word (at the index) is the command.
        case command(Int)
        /// No command follows (`command -v x`, `sudo -v`, `env` alone).
        case none
        /// The command is a string run by a shell (`watch 'a | b'`, `env -S '…'`).
        case script(CWord, NestedKind)
        /// An option Pitbox does not know.
        case unknown(CWord)
    }

    func resolveProgram(_ seg: Segment) {
        var k = 0
        let words = seg.words
        while k < words.count {
            let w = words[k]
            guard let t = w.text, !w.hasPattern, !hasDecodedEscapes(w) else { break }
            var key = Self.baseName(t).lowercased()
            key = Self.wrapperAliases[key] ?? key
            guard CommandPatterns.wrappers.contains(Self.baseName(t).lowercased()), let spec = Self.wrapperSpecs[key]
            else { break }
            seg.wrappers.append(w)
            seg.wrapperKeys.append(key)
            switch skipWrapper(key, spec, words, from: k + 1) {
            case .command(let next):
                k = next
                continue
            case .none:
                finishProgram(seg, at: nil)
                return
            case .script(let word, let kind):
                finishProgram(seg, at: nil)
                seg.program = Self.baseName(t)
                seg.key = key
                pendingScripts.append((seg.id, word, kind))
                return
            case .unknown(let word):
                addFlag(.b3, "\(AppIdentity.displayName) can't read this shell syntax (an option of \(shown(Self.baseName(t))) it does not know: \(shown(word.text ?? source(word.range)))); use Copy",
                        word.range, segment: seg.id)
                finishProgram(seg, at: nil)
                return
            }
        }
        finishProgram(seg, at: k < words.count ? k : nil)
    }

    /// Skips one wrapper's options (and assignments); says where its command starts.
    private func skipWrapper(_ key: String, _ spec: WrapperSpec, _ words: [CWord], from start: Int) -> WrapperEnd {
        var k = start
        var noCommand = false
        if key == "arch" { return skipArch(words, from: start) }
        while k < words.count {
            let w = words[k]
            guard let t = w.text else {
                if w.staticPrefix.hasPrefix("-") { return .unknown(w) }
                break
            }
            if t == "--" { k += 1; break }
            if t == "-", key == "env" { k += 1; continue }
            guard t.hasPrefix("-"), t.count > 1 else { break }
            if spec.numbers, t.dropFirst().allSatisfy(\.isNumber) { k += 1; continue }
            if t.hasPrefix("--") {
                let name = t.firstIndex(of: "=").map { String(t[..<$0]) } ?? t
                let attached = t.contains("=")
                if spec.longValues.contains(name) {
                    if key == "env", name == "--split-string" {
                        if attached { return .script(w, .envSplit) }
                        if k + 1 < words.count { return .script(words[k + 1], .envSplit) }
                    }
                    if !attached && !spec.longFlags.contains(name) { k += 1 }
                    k += 1
                    continue
                }
                if spec.longFlags.contains(name) {
                    if ["--list", "--validate", "--remove-timestamp", "--reset-timestamp", "--edit"].contains(name) {
                        noCommand = true
                    }
                    k += 1
                    continue
                }
                return .unknown(w)
            }
            let chars = Array(t.dropFirst()).map(String.init)
            var j = 0
            var consumedNext = false
            while j < chars.count {
                let c = chars[j]
                if spec.values.contains(c) {
                    let rest = chars[(j + 1)...].joined()
                    if key == "env", c == "S" {
                        if !rest.isEmpty { return .script(w, .envSplit) }
                        if k + 1 < words.count { return .script(words[k + 1], .envSplit) }
                    }
                    if rest.isEmpty { consumedNext = true }
                    break
                }
                if spec.attachedOnly.contains(c) { break }
                guard spec.flags.contains(c) else { return .unknown(w) }
                if key == "command", c == "v" || c == "V" { noCommand = true }
                if key == "sudo", ["l", "v", "k", "K", "V", "e"].contains(c) { noCommand = true }
                j += 1
            }
            k += consumedNext ? 2 : 1
        }
        if spec.assignments {
            while k < words.count, let t = words[k].text, Self.isAssignmentWord(t) { k += 1 }
        }
        if key == "timeout", k < words.count { k += 1 }       // the duration
        if noCommand, key == "command" || k >= words.count { return .none }
        if key == "sudo", noCommand, words.count > k, sudoEdits(words, from: start) { return .none }
        guard k < words.count else { return .none }
        if key == "watch", k == words.count - 1, let t = words[k].text,
           t.unicodeScalars.contains(where: { " \t\n;&|<>()$`'\"*?".unicodeScalars.contains($0) }) {
            return .script(words[k], .watch)
        }
        return .command(k)
    }

    /// `sudo -e`: the words are files to edit, not a command.
    private func sudoEdits(_ words: [CWord], from start: Int) -> Bool {
        for w in words[start...] {
            guard let t = w.text, t.hasPrefix("-"), !t.hasPrefix("--") else {
                if w.text == "--edit" { return true }
                break
            }
            if t.dropFirst().contains("e") { return true }
        }
        return false
    }

    /// `arch -arm64 cmd`, `arch -arch x86_64 -e A=1 cmd`.
    private func skipArch(_ words: [CWord], from start: Int) -> WrapperEnd {
        var k = start
        let flags: Set<String> = ["-arm64", "-arm64e", "-x86_64", "-x86_64h", "-i386", "-32", "-64", "-c", "-h"]
        while k < words.count, let t = words[k].text, t.hasPrefix("-") {
            if t == "-arch" || t == "-e" || t == "-d" { k += 2; continue }
            guard flags.contains(t) else { return .unknown(words[k]) }
            k += 1
        }
        return k < words.count ? .command(k) : .none
    }

    static func isAssignmentWord(_ t: String) -> Bool {
        guard let eq = t.firstIndex(of: "="), eq != t.startIndex else { return false }
        let name = t[..<eq]
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
        else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }

    func hasDecodedEscapes(_ w: CWord) -> Bool {
        w.word.parts.contains { if case .text(_, _, let decoded, _) = $0 { return decoded }; return false }
    }

    /// Sets the program from the word at `k` (nil: no program).
    func finishProgram(_ seg: Segment, at k: Int?) {
        guard let k else {
            seg.programIndex = nil
            seg.program = nil
            seg.key = ""
            seg.args = []
            return
        }
        seg.programIndex = k
        let w = seg.words[k]
        seg.args = Array(seg.words[(k + 1)...])
        if let t = w.text, !w.hasPattern {
            let base = Self.baseName(t)
            seg.program = base
            seg.key = base.lowercased()
            if hasDecodedEscapes(w) { seg.programIsBuilt = true }
        } else if !w.hasPattern, let values = texts(of: w, in: seg), values.count == 1 {
            // `"$HOME/bin/tool"`: a known folder. Any other variable still builds the program (R11).
            let base = Self.baseName(values[0])
            seg.program = base
            seg.key = base.lowercased()
            seg.programIsBuilt = w.parameterNames.contains { $0 != "HOME" }
        } else {
            seg.program = source(w.range)
            seg.key = ""
            seg.programIsBuilt = true
        }
        if !seg.wrapperKeys.isEmpty, ShellParser.notAcceptedCommands.contains(seg.key) {
            addFlag(.b3, "\(AppIdentity.displayName) can't read this shell syntax (`\(seg.key)`); use Copy", w.range, segment: seg.id)
        }
    }
}
