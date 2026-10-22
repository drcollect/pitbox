import Foundation

// Hosts and network red lines: B2 on hosts and user names, R12 (uploading or sending), R17 (hosts that look odd), and
// the notes "Connects to <host>", "Uses your ssh-agent" and "Not quarantined". A host is compared with the session's
// own names (alias, HostName, serverNames, the exact `Host` entries of `~/.ssh/config`) and with a short list of
// well-known hosts, never with anything the reply says.

extension CommandAnalysis {
    static let curlSpec = ArgSpec(["o", "d", "F", "T", "H", "X", "u", "A", "e", "b", "c", "K", "m", "w", "x", "U", "E", "r",
                                   "C", "z", "Y", "y", "Q", "t", "--output", "--data", "--data-binary", "--data-raw",
                                   "--data-urlencode", "--data-ascii", "--json", "--form", "--form-string", "--upload-file",
                                   "--header", "--request", "--user", "--url", "--config", "--output-dir", "--proxy",
                                   "--cookie", "--cookie-jar", "--user-agent", "--referer", "--max-time", "--connect-timeout",
                                   "--retry", "--write-out", "--cacert", "--cert", "--key", "--resolve", "--connect-to",
                                   "--oauth2-bearer", "--range", "--limit-rate", "--interface", "--dns-servers"])
    static let wgetSpec = ArgSpec(["O", "o", "P", "i", "e", "U", "a", "t", "T", "w", "Q", "B", "--output-document",
                                   "--output-file", "--directory-prefix", "--input-file", "--post-data", "--post-file",
                                   "--body-file", "--body-data", "--header", "--user-agent", "--user", "--password",
                                   "--method", "--tries", "--timeout"])
    static let scpSpec = ArgSpec(["c", "D", "F", "i", "J", "l", "o", "P", "S", "X"])
    static let rsyncSpec = ArgSpec(["e", "f", "T", "B", "M", "--rsh", "--filter", "--exclude", "--include", "--exclude-from",
                                    "--include-from", "--files-from", "--chmod", "--chown", "--block-size", "--rsync-path",
                                    "--log-file", "--password-file", "--port", "--temp-dir", "--partial-dir", "--backup-dir",
                                    "--suffix", "--max-size", "--min-size", "--timeout", "--contimeout", "--bwlimit",
                                    "--out-format", "--compare-dest", "--copy-dest", "--link-dest", "--remote-option",
                                    "--iconv", "--info", "--debug", "--usermap", "--groupmap", "--sockopts"])

    // MARK: URLs and hosts

    /// The words of a segment that hold a URL (`https://…`, `ssh://…`).
    func urlWords(in seg: Segment) -> [String] {
        seg.args.compactMap { w -> String? in
            let t = w.text ?? w.staticPrefix
            guard let r = t.range(of: "://") else { return nil }
            let scheme = t[..<r.lowerBound]
            guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" })
            else { return nil }
            return t
        }
    }

    /// The host of a URL, without user, password or port.
    func urlHost(_ url: String) -> String? {
        guard let r = url.range(of: "://") else { return nil }
        var rest = String(url[r.upperBound...])
        if let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = String(rest[..<cut]) }
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        if rest.hasPrefix("[") { return rest.split(separator: "]").first.map { String($0.dropFirst()) } }
        if let colon = rest.firstIndex(of: ":") { rest = String(rest[..<colon]) }
        return rest.isEmpty ? nil : rest
    }

    /// The user part of a URL (`https://user:pass@host/`).
    func urlUser(_ url: String) -> (user: String, password: String?)? {
        guard let r = url.range(of: "://") else { return nil }
        var rest = String(url[r.upperBound...])
        if let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = String(rest[..<cut]) }
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let credentials = rest[..<at]
        if let colon = credentials.firstIndex(of: ":") {
            return (String(credentials[..<colon]), String(credentials[credentials.index(after: colon)...]))
        }
        return (String(credentials), nil)
    }

    func urlHosts(in seg: Segment) -> [String] { urlWords(in: seg).compactMap(urlHost) }

    /// Every host a segment connects to, with the word it came from and the user it names.
    func hosts(of seg: Segment) -> [(host: String, user: String?, word: CWord)] {
        var out: [(String, String?, CWord)] = []
        let key = seg.key
        if CommandPatterns.remoteShells.contains(key) {
            let t = remoteTarget(seg)
            if let h = t.host, let w = t.hostWord { out.append((h, t.user, w)) }
        }
        if CommandPatterns.transfers.contains(key) {
            for w in seg.args { if let r = remoteOperand(w) { out.append((r.host, r.user, w)) } }
        }
        if key == "git" || key == "ssh-copy-id" || key == "ssh-keyscan" {
            for w in seg.args {
                guard let t = w.text, !t.hasPrefix("-"), !t.contains("://") else { continue }
                if key == "git", let r = remoteOperand(w), r.user != nil { out.append((r.host, r.user, w)) }
                if key != "git" {
                    var h = t
                    var user: String?
                    if let at = h.lastIndex(of: "@") { user = String(h[..<at]); h = String(h[h.index(after: at)...]) }
                    out.append((h, user, w))
                }
            }
        }
        if ["nc", "ncat", "netcat", "telnet", "ping", "dig", "nslookup", "whois", "traceroute", "host", "socat"].contains(key) {
            let p = parseArgs(seg.args, ArgSpec(["p", "s", "w", "i", "c", "t", "W", "q", "x", "X", "-port"]))
            if let first = p.operands.first, let t = first.text {
                let h = key == "socat" ? (t.split(separator: ":").dropFirst().first.map(String.init) ?? "") : t
                if !h.isEmpty, !h.hasPrefix("@") { out.append((h, nil, first)) }
            }
        }
        for w in seg.args {
            let t = w.text ?? w.staticPrefix
            guard t.contains("://"), let h = urlHost(t) else { continue }
            out.append((h, urlUser(t)?.user, w))
        }
        return out
    }

    // MARK: Per segment

    func checkHosts(_ seg: Segment) {
        let isNetwork = CommandPatterns.networkPrograms.contains(seg.key) || seg.key == "open"
        guard isNetwork || CommandPatterns.remoteShells.contains(seg.key) else { return }
        for (host, user, word) in hosts(of: seg) {
            if let user, let s = firstNonASCII(user) {
                addFlag(.b2, "Look-alike character \(lookAlike(s)) in the user name \(shownRaw(user))", in: seg, range: word.range)
            }
            if let s = firstNonASCII(host) {
                addFlag(.b2, "Look-alike character \(lookAlike(s)) in the host \(shownRaw(host))", in: seg, range: word.range)
                continue
            }
            if let odd = oddHost(host) {
                addFlag(.r17, odd, in: seg, range: word.range)
            }
            if seg.key != "open", !isPlaceholderText(host) {
                addNote(.connects, "Connects to \(shown(host))")
            }
        }
        if CommandPatterns.sshAgentPrograms.contains(seg.key) {
            addNote(.usesSSHAgent, CommandPatterns.NoteWords.usesSSHAgent)
        }
    }

    /// R17's words for a host that looks odd, nil for an ordinary one.
    func oddHost(_ raw: String) -> String? {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return nil }
        let own = ([facts.sshAlias, facts.resolvedHostName].compactMap { $0 } + facts.serverNames + facts.knownSSHHosts)
            .map { $0.lowercased() }
        if own.contains(host) { return nil }
        if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
            return "Connects to an unusual host: \(shown(raw)) (an encoded international name)"
        }
        if Self.isIPAddress(host) || host.hasPrefix("0x") && host.dropFirst(2).allSatisfy(\.isHexDigit)
            || (!host.isEmpty && host.allSatisfy(\.isNumber)) {
            return "Connects to an unusual host: \(shown(raw)) (a bare address)"
        }
        for name in own where name.count >= 3 {
            let limit = name.count <= 4 ? 1 : 2
            let d = Self.editDistance(host, name, limit: limit)
            if d >= 1, d <= limit { return "Looks like \(shown(name)) but is \(shown(raw))" }
            if let first = host.split(separator: ".").first.map(String.init), first != host, !own.contains(first) {
                let d2 = Self.editDistance(first, name, limit: limit)
                if d2 >= 1, d2 <= limit, name.count >= 5 { return "Looks like \(shown(name)) but is \(shown(raw))" }
            }
        }
        let registrable = host.split(separator: ".").suffix(2).joined(separator: ".")
        if !CommandPatterns.wellKnownHosts.contains(registrable) {
            for known in CommandPatterns.wellKnownHosts {
                let limit = known.count < 9 ? 1 : 2
                let d = Self.editDistance(registrable, known, limit: limit)
                if d >= 1, d <= limit { return "Looks like \(shown(known)) but is \(shown(raw))" }
            }
        }
        return nil
    }

    static func isIPAddress(_ h: String) -> Bool {
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && (Int($0) ?? 999) <= 255 }) {
            return true
        }
        return h.contains(":") && h.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
    }

    /// Damerau-Levenshtein distance (adjacent swaps count once), stopping early above `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev2 = [Int](repeating: 0, count: y.count + 1)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            var best = cur[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { cur[j] = min(cur[j], prev2[j - 2] + 1) }
                best = min(best, cur[j])
            }
            if best > limit { return limit + 1 }
            prev2 = prev
            prev = cur
        }
        return prev[y.count]
    }

    // MARK: R12 and the transfer notes

    func ruleNetwork(_ seg: Segment) {
        let key = seg.key
        let hostsHere = hosts(of: seg).map(\.host)
        let target = hostsHere.first.map(shown) ?? "the network"
        switch key {
        case "curl":
            let p = parseArgs(seg.args, Self.curlSpec)
            for o in p.options {
                let v = o.value ?? ""
                switch o.name {
                case "T", "--upload-file":
                    addFlag(.r12, "Uploads \(o.valueWord.map(describe) ?? shown(v)) to \(target)", in: seg, range: o.word.range)
                case "F", "--form":
                    if let eq = v.firstIndex(of: "="), let next = v[v.index(after: eq)...].first, next == "@" || next == "<" {
                        addFlag(.r12, "Uploads \(shown(String(v[v.index(eq, offsetBy: 2)...]))) to \(target)", in: seg, range: o.word.range)
                    }
                case "d", "--data", "--data-binary", "--data-ascii", "--json":
                    if v.hasPrefix("@") {
                        let file = String(v.dropFirst())
                        addFlag(.r12, "Uploads \(file == "-" ? "what it reads" : shown(file)) to \(target)", in: seg, range: o.word.range)
                    }
                case "--data-urlencode":
                    if let at = v.firstIndex(of: "@"), !v[..<at].contains("=") {
                        addFlag(.r12, "Uploads \(shown(String(v[v.index(after: at)...]))) to \(target)", in: seg, range: o.word.range)
                    }
                default:
                    break
                }
            }
            if p.has("o", "--output", "O", "--remote-name", "--remote-name-all") || seg.redirections.contains(where: { $0.writesTarget }) {
                addNote(.notQuarantined, CommandPatterns.NoteWords.notQuarantined)
            }
        case "wget":
            let p = parseArgs(seg.args, Self.wgetSpec)
            if let o = p.option("--post-file", "--body-file") {
                addFlag(.r12, "Uploads \(o.value.map(shown) ?? "a file") to \(target)", in: seg, range: o.word.range)
            }
            addNote(.notQuarantined, CommandPatterns.NoteWords.notQuarantined)
        case "scp", "rsync", "sftp":
            let p = parseArgs(seg.args, key == "rsync" ? Self.rsyncSpec : Self.scpSpec)
            guard let dest = p.operands.last, p.operands.count >= 2 else { break }
            if let remote = remoteOperand(dest) {
                let sources = p.operands.dropLast().filter { !isRemoteOperand($0) }
                if !sources.isEmpty {
                    addFlag(.r12, "Uploads \(shownList(sources.map { describe($0) })) to \(shown(remote.host))", in: seg)
                }
            } else if p.operands.dropLast().contains(where: isRemoteOperand) {
                addNote(.notQuarantined, CommandPatterns.NoteWords.notQuarantined)
            }
        case "rclone":
            let words = parseArgs(seg.args, ArgSpec(["config", "--config"])).operands
            if let verb = words.first?.text, ["copy", "sync", "move", "copyto", "moveto"].contains(verb), words.count >= 3 {
                let src = words[1], dst = words[2]
                if !(src.text ?? "").contains(":"), let d = dst.text, d.contains(":") {
                    addFlag(.r12, "Uploads \(describe(src)) to \(shown(String(d.split(separator: ":").first ?? "")))", in: seg)
                }
            }
        case "aws":
            let words = seg.args.compactMap(\.text).filter { !$0.hasPrefix("-") }
            if words.first == "s3", let verb = words.dropFirst().first, ["cp", "sync", "mv"].contains(verb), words.count >= 4,
               !words[2].lowercased().hasPrefix("s3://"), words[3].lowercased().hasPrefix("s3://") {
                addFlag(.r12, "Uploads \(shown(words[2])) to \(shown(words[3]))", in: seg)
            }
        case "gsutil":
            let words = seg.args.compactMap(\.text).filter { !$0.hasPrefix("-") }
            if let verb = words.first, ["cp", "rsync", "mv"].contains(verb), words.count >= 3,
               !words[1].lowercased().hasPrefix("gs://"), words[words.count - 1].lowercased().hasPrefix("gs://") {
                addFlag(.r12, "Uploads \(shown(words[1])) to \(shown(words[words.count - 1]))", in: seg)
            }
        case "nc", "ncat", "netcat", "socat":
            let fromFile = seg.redirections.contains { $0.op == .input && ($0.fileDescriptor ?? 0) == 0 }
            let fromCat = upstream(of: seg).contains { $0.key == "cat" && !$0.args.isEmpty }
            if fromFile || fromCat { addFlag(.r12, "Sends a file to \(target) (\(key))", in: seg) }
        default:
            break
        }
        // What the clipboard or the Keychain gives a network program.
        guard CommandPatterns.networkPrograms.contains(key) else { return }
        if upstream(of: seg).contains(where: { $0.key == "pbpaste" }) {
            addFlag(.r12, "Sends the clipboard to \(target)", in: seg)
        }
        for w in seg.args + seg.assignments.map({ CWord(word: $0.value, text: nil, tilde: false) }) {
            for name in w.parameterNames {
                if case .keychain? = seg.variables[name] {
                    addFlag(.r12, "Sends a Keychain secret to \(target)", in: seg, range: w.range)
                }
            }
        }
    }
}
