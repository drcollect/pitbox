import Foundation

// Checks on the raw text, before and beside the scanner (docs/SHELL_LANGUAGE.md §1): B1 characters, the size
// limits of B4, R20 (who started the turn), R15 secrets anywhere in the text (comments and here-doc bodies included),
// and the placeholders of Needs editing. A `<…>` placeholder is read as one word, so `ssh <server>` is a command
// with a placeholder, not a redirection.

extension CommandAnalysis {
    // MARK: B1

    func checkHiddenCharacters() {
        let hidden = CommandCharacterPolicy.hiddenCharacters(in: text)
        for (n, h) in hidden.enumerated() {
            if n == 64 {
                addFlag(.b1, "And \(hidden.count - 64) more hidden or deceptive characters", h.range, segment: nil)
                break
            }
            addFlag(.b1, "Hidden or deceptive character ⟨\(CommandCharacterPolicy.codePoint(h.scalar))⟩ \(CommandCharacterPolicy.name(h.scalar))",
                    h.range, segment: nil)
        }
    }

    /// B6: the fork bomb `:(){ :|:& };:` in any spacing and with any name (it is also a function definition, B3).
    func checkForkBomb() {
        var squeezed = ""
        var offsets: [Int] = []
        var offset = 0
        for u in units {
            if u != Ch.space, u != Ch.tab, u != Ch.newline { squeezed += Ch.string([u]); offsets.append(offset) }
            offset += 1
        }
        let pattern = "([A-Za-z_:][A-Za-z0-9_:]*)\\(\\)\\{\\1\\|\\1&;?\\};?\\1"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let m = expression.firstMatch(in: squeezed, range: NSRange(location: 0, length: (squeezed as NSString).length)),
              m.range.location < offsets.count else { return }
        let start = offsets[m.range.location]
        let endIndex = min(offsets.count - 1, m.range.location + m.range.length - 1)
        addFlag(.b6, "Known destroyer: a fork bomb (it starts copies of itself until the Mac stops answering)",
                start..<(offsets[endIndex] + 1), segment: nil)
    }

    // MARK: B4

    /// Adds B4 for each size limit the text passes. True when it is longer than the scanner reads at all.
    func checkLimits() -> Bool {
        var scalars = 0
        var lineLength = 0
        var lineNumber = 1
        var longLine: (line: Int, length: Int)?
        for s in text.unicodeScalars {
            if s == "\n" {
                if lineLength > CommandOffer.maxLineCharacters, longLine == nil { longLine = (lineNumber, lineLength) }
                lineNumber += 1
                lineLength = 0
            } else {
                lineLength += 1
            }
            scalars += 1
        }
        if lineLength > CommandOffer.maxLineCharacters, longLine == nil { longLine = (lineNumber, lineLength) }
        let all = 0..<units.count
        if lineCount > CommandOffer.maxLines {
            addFlag(.b4, "Too long to review here: \(lineCount) lines (the limit is \(CommandOffer.maxLines))", all, segment: nil)
        }
        if scalars > CommandOffer.maxCharacters {
            addFlag(.b4, "Too long to review here: \(scalars) characters (the limit is \(CommandOffer.maxCharacters))", all,
                    segment: nil)
        }
        if let l = longLine {
            let start = l.line - 1 < lineStarts.count ? lineStarts[l.line - 1] : 0
            addFlag(.b4, "Too long to review here: line \(l.line) has \(l.length) characters (the limit is \(CommandOffer.maxLineCharacters))",
                    start..<min(units.count, start + l.length), segment: nil)
        }
        return scalars > ShellCommandScanner.maxCharacters
    }

    // MARK: R20

    func checkTurnOrigin() {
        let words: String
        switch facts.turnOrigin {
        case .human: return
        case .taskNotification: words = CommandPatterns.Words.notYourRequestTask
        case .peer: words = CommandPatterns.Words.notYourRequestPeer
        case .unknown: words = "\(AppIdentity.displayName) couldn't tell whether you started this turn"
        }
        addFlag(.r20, words, 0..<0, segment: nil)
    }

    // MARK: R15 in the text

    static let secretExpressions: [NSRegularExpression] = {
        let prefixes = CommandPatterns.secretPrefixes
            .map { "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: $0.prefix) + "[A-Za-z0-9_-]{\($0.minimum),}" }
        let patterns = prefixes + [
            "(?<![A-Za-z0-9])(?:" + CommandPatterns.awsKeyPrefixes.joined(separator: "|") + ")[A-Z0-9]{16}(?![A-Za-z0-9])",
            "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----",
            "(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}",
            "(?i)\\bbearer[ \\t]+(?![$`\"'<])[A-Za-z0-9._~+/=-]{40,}",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    func checkSecretsInText() {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for expression in Self.secretExpressions {
            for m in expression.matches(in: text, range: whole) {
                let found = ns.substring(with: m.range)
                if isPlaceholderText(found) { continue }
                addFlag(.r15, CommandPatterns.ruleWords[.r15] ?? "", m.range.location..<(m.range.location + m.range.length),
                        segment: nil)
            }
        }
    }

    /// Text that is a stand-in rather than a value: `xxxx…`, `YOUR_…`, `<…>`, `CHANGEME`, `…`.
    func isPlaceholderText(_ s: String) -> Bool {
        let upper = s.uppercased()
        if upper.contains("YOUR") || upper.contains("CHANGEME") || upper.contains("CHANGE_ME") || upper.contains("REPLACE")
            || upper.contains("EXAMPLE.COM") || s.contains("<") || s.contains("…") || s.contains("...") { return true }
        if let last = s.split(whereSeparator: { $0 == "-" || $0 == "_" }).last, last.count >= 8,
           Set(last.lowercased()).count <= 2 { return true }
        return false
    }

    // MARK: Placeholders

    /// Finds the `<…>` placeholders and returns the units to scan, with their brackets turned into word characters.
    func findPlaceholders() -> [UInt16] {
        var out = units
        guard neutralizesPlaceholders, !units.contains(Self.placeholderOpen), !units.contains(Self.placeholderClose)
        else { return out }
        var k = 0
        while k < units.count {
            guard units[k] == Ch.less, k + 1 < units.count, Ch.isLetter(units[k + 1]), k == 0 || units[k - 1] != Ch.less
            else { k += 1; continue }
            var j = k + 1
            while j < units.count, Ch.isNameChar(units[j]) || units[j] == Ch.minus { j += 1 }
            guard j < units.count, units[j] == Ch.greater else { k += 1; continue }
            let name = Ch.string(units[(k + 1)..<j])
            if CommandPatterns.markupTags.contains(name.lowercased()) || text.contains("</" + name + ">") {
                k = j + 1
                continue
            }
            angleRanges.append(k..<(j + 1))
            out[k] = Self.placeholderOpen
            out[j] = Self.placeholderClose
            neutralized = true
            k = j + 1
        }
        return out
    }

    /// After the scan: the first placeholder outside comments, as written.
    func decidePlaceholder() {
        var found: [(Int, String)] = []
        func outsideComments(_ r: Range<Int>) -> Bool { !comments.contains { $0.contains(r.lowerBound) } }
        for r in angleRanges where outsideComments(r) { found.append((r.lowerBound, source(r))) }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for (expression, outsideQuotesOnly) in Self.placeholderExpressions {
            for m in expression.matches(in: text, range: whole) {
                let r = m.range.location..<(m.range.location + m.range.length)
                guard outsideComments(r) else { continue }
                if outsideQuotesOnly, insideQuotes(r.lowerBound) { continue }
                let match = ns.substring(with: m.range)
                if sessionHostNames.contains(match.lowercased()) { continue }
                found.append((r.lowerBound, match))
            }
        }
        placeholder = found.min { $0.0 < $1.0 }?.1
    }

    static let placeholderExpressions: [(NSRegularExpression, Bool)] = {
        let quoted: [String] = [
            "YOUR[_-][A-Z0-9_-]+",
            "(?i)\\byour[-_][a-z0-9_-]*[-_]here\\b",
            "/path/to(?:/|\\b)",
            "(?i)(?<![A-Za-z0-9._-])(?:user|username)@(?:host|hostname|server|yourserver|your-server)(?![A-Za-z0-9-])",
            "(?i)(?<![A-Za-z0-9-])(?:[A-Za-z0-9-]+\\.)*example\\.com(?![A-Za-z0-9-])",
            "(?<![A-Za-z0-9_])(?:CHANGEME|CHANGE_ME|REPLACE_ME|REPLACEME)(?![A-Za-z0-9_])",
            "\\[(?:\\.\\.\\.|…)\\]",
            "(?i)\\[your[^\\]\\n]*\\]",
            "(?<=/)…|…(?=/)",
            "(?<![^\\s=\"'])\\[[A-Za-z][A-Za-z0-9 _-]{2,}\\](?![^\\s\"'])",
        ]
        let unquoted: [String] = ["(?<![A-Za-z0-9_])TODO(?![A-Za-z0-9_])"]
        return quoted.compactMap { (try? NSRegularExpression(pattern: $0)).map { ($0, false) } }
            + unquoted.compactMap { (try? NSRegularExpression(pattern: $0)).map { ($0, true) } }
    }()

    /// The session's own host names: never placeholders, whatever they look like.
    var sessionHostNames: Set<String> {
        Set(([facts.sshAlias, facts.resolvedHostName].compactMap { $0 } + facts.serverNames + facts.knownSSHHosts)
            .map { $0.lowercased() })
    }

    /// True when `offset` is inside quotes of the scanned script (an approximation from the words' quoted parts).
    func insideQuotes(_ offset: Int) -> Bool {
        for seg in segments {
            for w in seg.words + seg.args {
                for part in w.word.parts {
                    if case .text(_, let q, _, let r) = part, q == .single || q == .double, r.contains(offset) { return true }
                }
            }
        }
        return false
    }
}
