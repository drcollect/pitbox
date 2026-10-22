import Foundation

// Which machine the command is for (docs/SHELL_LANGUAGE.md §4.1). Decided from the command's structure and the session
// facts only; the reply's caption and comments are claims, shown, and only able to make the result Unclear when they
// contradict it.

extension CommandAnalysis {
    func decideMachine() {
        var macReasons: [String] = []
        var serverReasons: [String] = []
        var macPaths: [String] = []
        var serverPaths: [String] = []
        let serverNames = Set(([facts.sshAlias, facts.resolvedHostName].compactMap { $0 } + facts.serverNames)
            .map { $0.lowercased() })
        for seg in segments where !seg.isRemote && seg.pseudo == nil {
            let key = seg.key
            if CommandPatterns.remoteShells.contains(key) {
                if seg.sendsTo == nil, let host = remoteTarget(seg).host {
                    macReasons.append("it opens a shell on \(shown(host))")
                }
                continue
            }
            if CommandPatterns.transfers.contains(key) {
                for w in seg.args {
                    guard let r = remoteOperand(w) else {
                        collectPathHints(w, seg, &macPaths, &serverPaths)
                        continue
                    }
                    if serverNames.contains(r.host.lowercased()) {
                        let isDestination = w.range == seg.args.last?.range
                        macReasons.append(isDestination ? "it copies to \(shown(r.host))" : "it copies from \(shown(r.host))")
                    }
                }
                continue
            }
            for (n, name) in ([key] + seg.wrapperKeys).enumerated() where !name.isEmpty {
                let shownName = n == 0 ? (seg.program ?? name) : name
                if CommandPatterns.macOnlyPrograms.contains(name) {
                    macReasons.append("it uses \(shown(shownName)), which exists only on a Mac")
                }
                if CommandPatterns.linuxOnlyPrograms.contains(name) {
                    serverReasons.append("it uses \(shown(shownName)), a Linux program")
                }
            }
            for w in seg.args where !(w.text ?? w.staticPrefix).contains("://") {
                collectPathHints(w, seg, &macPaths, &serverPaths)
            }
            for r in seg.redirections where r.hereDocument == nil && r.op != .hereString && !r.target.isDescriptorReference {
                for w in expand(r.target) { collectPathHints(w, seg, &macPaths, &serverPaths) }
            }
        }

        var base: CommandMachine
        var reason: String
        switch facts.place {
        case .local:
            base = .thisMac
            reason = "For this Mac: the session runs on this Mac."
        case .unknown:
            base = .unclear
            reason = "Unclear: \(AppIdentity.displayName) couldn't tell where the session runs."
        case .ssh:
            if let mac = macReasons.first {
                if let s = serverReasons.first ?? serverPaths.first.map({ "it names \($0), a server path" }) {
                    base = .unclear
                    reason = "Unclear: \(mac), but \(s)."
                } else {
                    base = .thisMac
                    reason = "For this Mac: \(mac)."
                }
            } else if let s = serverReasons.first {
                if let m = macPaths.first {
                    base = .unclear
                    reason = "Unclear: \(s), but it names \(m), a Mac path."
                } else {
                    base = .server
                    reason = "For the server: \(s)."
                }
            } else if let m = macPaths.first {
                base = .unclear
                reason = "Unclear: it names \(m), so probably this Mac."
            } else if let s = serverPaths.first {
                base = .unclear
                reason = "Unclear: it names \(s), so probably the server."
            } else {
                base = .unclear
                reason = "Unclear: nothing in it says which machine."
            }
        }

        if let claim = findClaim() {
            replyClaim = claim.text
            addNote(.replyClaim, "The reply says: “\(shownRaw(claim.text))”")
            let contradicts = (claim.mac && base == .server) || (claim.server && base == .thisMac)
            if contradicts {
                reason = "Unclear: the reply says “\(shownRaw(claim.text))”, but " + reason.prefix(1).lowercased() + reason.dropFirst()
                base = .unclear
            }
        }
        baseMachine = base
        if let host = tops.compactMap({ segments[$0].sendsTo }).first ?? segments.compactMap(\.sendsTo).first {
            machine = .remote(host: host)
            machineReason = "Runs on \(shown(host)): it sends a command there."
        } else {
            machine = base
            machineReason = reason
        }
    }

    /// Path hints: Mac paths and server paths among a segment's local operands (never remote operands or remote
    /// command text).
    func collectPathHints(_ w: CWord, _ seg: Segment, _ mac: inout [String], _ server: inout [String]) {
        guard let raw = w.text ?? (w.parameterNames == ["HOME"] ? texts(of: w, in: seg)?.first : nil) else { return }
        var t = raw
        if w.tilde || t.hasPrefix(home + "/") || t == home {
            t = "~" + (t.hasPrefix("~") ? String(t.dropFirst()) : String(t.dropFirst(home.count)))
        }
        if t.hasPrefix("-") { return }
        let lower = t.lowercased()
        for hint in CommandPatterns.macPathHints {
            let h = hint.lowercased()
            if lower == h || lower.hasPrefix(h.hasSuffix("/") ? h : h + "/") || (h.hasSuffix("/") && lower.hasPrefix(h)) {
                mac.append(shown(t))
                return
            }
        }
        if lower.hasPrefix("/opt/homebrew") { mac.append(shown(t)); return }
        if let cwd = facts.remoteCwd, !cwd.isEmpty, Self.isInside(t, cwd) { server.append(shown(t)); return }
        for hint in CommandPatterns.serverPathHints {
            let h = hint.lowercased()
            if lower == h || lower == String(h.dropLast()) || lower.hasPrefix(h.hasSuffix("/") ? h : h + "/") {
                server.append(shown(t))
                return
            }
        }
    }

    /// The reply's claim about the machine, from the caption or a comment.
    func findClaim() -> (text: String, mac: Bool, server: Bool)? {
        var texts: [String] = []
        if let c = context.caption { texts.append(c) }
        for r in comments { texts.append(source(r)) }
        var serverPhrases = CommandPatterns.serverClaims
        for name in [facts.sshAlias, facts.resolvedHostName].compactMap({ $0 }) + facts.serverNames {
            serverPhrases.append("on " + name.lowercased())
        }
        serverPhrases.sort { $0.count > $1.count }
        var found: (String, Bool, Bool)?
        for text in texts {
            var mac: String?
            var server: String?
            for p in CommandPatterns.macClaims { if let r = Self.phrase(p, in: text) { mac = String(text[r]); break } }
            for p in serverPhrases { if let r = Self.phrase(p, in: text) { server = String(text[r]); break } }
            if mac == nil, server == nil { continue }
            if let f = found {
                found = (f.0, f.1 || mac != nil, f.2 || server != nil)
            } else {
                found = (mac ?? server ?? "", mac != nil, server != nil)
            }
        }
        return found
    }

    /// `p` in `text` as whole words, ignoring case.
    static func phrase(_ p: String, in text: String) -> Range<String.Index>? {
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: p, options: [.caseInsensitive], range: search) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let afterNext: Character? = {
                guard r.upperBound < text.endIndex else { return nil }
                let n = text.index(after: r.upperBound)
                return n < text.endIndex ? text[n] : nil
            }()
            let boundaryBefore = before.map { !($0.isLetter || $0.isNumber) } ?? true
            let continuesName = after == "." && (afterNext.map { $0.isLetter || $0.isNumber } ?? false)
            let boundaryAfter = !continuesName
                && (after.map { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } ?? true)
            if boundaryBefore, boundaryAfter { return r }
            search = r.upperBound..<text.endIndex
        }
        return nil
    }

    // MARK: R21 and "Writes" (docs/SHELL_LANGUAGE.md §8 A5)

    func finalizeWrites() {
        let facts = context.pathFacts
        for record in writeRecords {
            guard let paths = record.paths, machine != .server else { continue }
            var checked: [String] = []
            for path in paths {
                if !localTargets.contains(path) { localTargets.append(path) }
                let inside = record.intoFolder.map { Self.normalize(path + "/" + $0) }
                for p in inside where !localTargets.contains(p) { localTargets.append(p) }
                if facts[path] == .directory, !inside.isEmpty { checked += inside } else { checked.append(path) }
            }
            for path in checked {
                switch facts[path] {
                case .file?, .directory?:
                    if record.replaces { addFlag(.r21, "Replaces \(shownPath(path))", record.range, segment: record.segment) }
                case .link(let target)?:
                    if record.replaces {
                        addFlag(.r21, "Replaces \(shownPath(path)) (→ \(shownRaw(target)))", record.range, segment: record.segment)
                    }
                case .missing?, nil:
                    addNote(.writes, "Writes \(shownPath(path))")
                }
            }
        }
    }
}
