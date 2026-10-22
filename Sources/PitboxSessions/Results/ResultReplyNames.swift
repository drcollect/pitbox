import Foundation

/// Which paths a final reply names: a file the work wrote becomes a result only when
/// the reply names it (its absolute path, its path below the session's folder, or its file name as a whole word), and
/// other path-like words of the reply show in the peek as plain text, never as buttons. Strings only.
enum ResultReplyNames {
    /// The reply names `path` (as the tool_use wrote it): the whole path, the part below `cwd`, or the file name (at
    /// least 3 characters with an extension), each as a whole token.
    static func names(_ path: String, in reply: String, cwd: String?) -> Bool {
        guard path.hasPrefix("/"), path.count >= 2, !reply.isEmpty else { return false }
        if containsToken(reply, path) { return true }
        if let cwd {
            let folder = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
            if path.hasPrefix(folder + "/") {
                let below = String(path.dropFirst(folder.count + 1))
                if !below.isEmpty, containsToken(reply, below) { return true }
            }
        }
        if let name = ResultPaths.lastComponent(path), name.count >= 3, name.contains("."), !name.hasPrefix(".") {
            return containsToken(reply, name)
        }
        return false
    }

    /// `token` occurs in `text` with no letter, digit, `_` or `-` right before it (a `/` may come before: a longer
    /// path naming the same file), and none right after (a `.` after it is fine at the end of a sentence).
    static func containsToken(_ text: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var searchStart = text.startIndex
        while let range = text.range(of: token, options: .literal, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            var afterOK = after.map { !isWordCharacter($0) } ?? true
            if after == "." {
                let next = text.index(after: range.upperBound)
                afterOK = next == text.endIndex || !isWordCharacter(text[next])
            }
            if (before.map { !isWordCharacter($0) && $0 != "." } ?? true), afterOK { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    /// Path-like words of `reply` (starting with `/` or `~/`, with at least two parts, no `://`), in order, without
    /// repeats, at most `limit`: code spans whole (paths with spaces), bare words otherwise. For the peek only.
    static func mentionedPaths(in reply: String, limit: Int) -> [String] {
        var out: [String] = []
        func add(_ raw: Substring) {
            var word = raw.trimmingCharacters(in: .whitespaces)
            while let last = word.last, ".,;:!?)]}'\"".contains(last) { word.removeLast() }
            guard out.count < limit, looksLikePath(word), !out.contains(word) else { return }
            out.append(word)
        }
        for line in reply.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "`", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                if index % 2 == 1, index < parts.count - 1 {
                    add(part)
                } else {
                    for word in part.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" || $0 == "<" || $0 == ">" || $0 == "\"" }) {
                        add(word)
                    }
                }
                if out.count >= limit { return out }
            }
        }
        return out
    }

    private static func looksLikePath(_ word: String) -> Bool {
        guard word.hasPrefix("/") || word.hasPrefix("~/"), !word.contains("://"), word.count <= ResultPaths.maxBytes else {
            return false
        }
        return word.split(separator: "/").filter { !$0.isEmpty && $0 != "~" }.count >= 2
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" }
}
