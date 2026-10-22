import Foundation
import PitboxKit

/// The shell blocks of a final reply that become offers. Only fenced or indented code blocks count, never
/// blockquotes, inline code or plain text; tagged blocks by their first info word, prompt-style blocks by their `$ ` and
/// `% ` lines, untagged blocks only when every command line starts with a shell word or a program on the clean PATH.
enum OfferExtraction {
    /// The info words that mark a shell block (first word, lowercased, `{` `}` `.` removed).
    static let shellTags: Set<String> = ["bash", "sh", "zsh", "shell", "console", "shell-session", "sh-session", "terminal"]
    /// Tags whose blocks are always prompt-style (commands after `$ ` or `% `, the rest is output).
    static let promptTags: Set<String> = ["console", "shell-session", "sh-session"]

    /// Shell reserved words and builtins that may start a line of an untagged block.
    static let shellWords: Set<String> = [
        "if", "then", "elif", "else", "fi", "case", "esac", "for", "select", "while", "until", "do", "done", "function",
        "time", "{", "}", "[[", "!", ".", ":", "[", "alias", "bg", "break", "builtin", "cd", "command", "continue",
        "declare", "dirs", "disown", "echo", "eval", "exec", "exit", "export", "false", "fg", "getopts", "hash", "history",
        "jobs", "kill", "let", "local", "popd", "print", "printf", "pushd", "pwd", "read", "readonly", "return", "set",
        "shift", "source", "test", "times", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias", "unset",
        "wait", "whence", "where", "which",
    ]

    /// One block that is offered.
    struct Block: Equatable, Sendable {
        var kind: CommandOffer.BlockKind
        /// The exact text that would run: the block's command lines joined with "\n".
        var text: String
        var displayLines: [CommandOffer.DisplayLine]
        /// The two lines of reply text before the block.
        var caption: String?
    }

    struct Result: Equatable, Sendable {
        /// At most `CommandOffer.maxOffersPerReply`, in reply order, duplicates merged.
        var blocks: [Block]
        /// Blocks beyond the limit ("8 of 12 commands").
        var notShown: Int
    }

    /// The offers of a reply whose text blocks are `texts` (each its own markdown document, as Claude shows them).
    /// `programs` are the program names on the clean PATH; nil means untagged blocks are not offered.
    static func extract(from texts: [String], programs: Set<String>?) -> Result {
        var unique: [Block] = []
        var keys = Set<String>()
        for text in texts {
            for code in MarkdownBlocks.codeBlocks(in: text) where !code.inBlockquote && code.closed {
                guard let block = offer(code, programs: programs) else { continue }
                if keys.insert(duplicateKey(block.text)).inserted { unique.append(block) }
            }
        }
        let shown = Array(unique.prefix(CommandOffer.maxOffersPerReply))
        return Result(blocks: shown, notShown: unique.count - shown.count)
    }

    /// The tag of an info string: its first word, lowercased, with `{`, `}` and `.` removed.
    static func tag(of info: String) -> String {
        let first = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        return first.lowercased().filter { $0 != "{" && $0 != "}" && $0 != "." }
    }

    /// Identical blocks: the same text after trimming trailing whitespace of each line.
    static func duplicateKey(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var end = line.endIndex
                while end > line.startIndex, line[line.index(before: end)] == " " || line[line.index(before: end)] == "\t" {
                    end = line.index(before: end)
                }
                return line[..<end]
            }
            .joined(separator: "\n")
    }

    // MARK: Blocks

    private static func offer(_ code: MarkdownCodeBlock, programs: Set<String>?) -> Block? {
        let caption = caption(code.preceding)
        switch code.kind {
        case .fenced(let info):
            let tag = tag(of: info)
            if tag.isEmpty { return untagged(code.lines, programs: programs, caption: caption) }
            guard shellTags.contains(tag) else { return nil }
            if promptTags.contains(tag) || code.lines.contains(where: isPromptLine) {
                return promptStyle(code.lines, caption: caption)
            }
            return script(code.lines, kind: .tagged(tag), caption: caption)
        case .indented:
            return untagged(code.lines, programs: programs, caption: caption)
        }
    }

    /// A tagged block runs as one script: every line, comments included (they stay comments in the clean shell).
    private static func script(_ raw: [String], kind: CommandOffer.BlockKind, caption: String?) -> Block? {
        let lines = trimmedBlankEdges(raw)
        guard lines.contains(where: { !isBlank($0) && !isComment($0) }) else { return nil }
        let display = lines.map { CommandOffer.DisplayLine(role: isComment($0) ? .comment : .command, text: $0) }
        return Block(kind: kind, text: lines.joined(separator: "\n"), displayLines: display, caption: caption)
    }

    /// Only lines after `$ ` or `% ` are commands (the prompt removed), with their `\` continuation lines; the other
    /// lines are output, shown but never run; `#` lines are comments, never a root prompt.
    private static func promptStyle(_ raw: [String], caption: String?) -> Block? {
        var commands: [String] = []
        var display: [CommandOffer.DisplayLine] = []
        var continuing = false
        for line in trimmedBlankEdges(raw) {
            if continuing {
                commands.append(line)
                display.append(.init(role: .command, text: line))
                continuing = line.hasSuffix("\\")
                continue
            }
            if isPromptLine(line) {
                let command = String(line.dropFirst(2))
                if isBlank(command) {
                    display.append(.init(role: .output, text: line))
                    continue
                }
                commands.append(command)
                display.append(.init(role: isComment(command) ? .comment : .command, text: command))
                continuing = command.hasSuffix("\\")
            } else if isComment(line) {
                display.append(.init(role: .comment, text: line))
            } else {
                display.append(.init(role: .output, text: line))
            }
        }
        guard commands.contains(where: { !isBlank($0) && !isComment($0) }) else { return nil }
        return Block(kind: .promptStyle, text: commands.joined(separator: "\n"), displayLines: display, caption: caption)
    }

    /// Untagged and indented blocks are read as commands only when every command line starts with a known word and
    /// nothing looks like output; never without the clean PATH's program list.
    private static func untagged(_ raw: [String], programs: Set<String>?, caption: String?) -> Block? {
        guard let programs else { return nil }
        let lines = trimmedBlankEdges(raw)
        var continuing = false
        var commands = 0
        for line in lines {
            if continuing {
                continuing = line.hasSuffix("\\")
                continue
            }
            if isBlank(line) || isComment(line) { continue }
            guard startsWithKnownWord(line, programs: programs), !looksLikeOutput(line) else { return nil }
            commands += 1
            continuing = line.hasSuffix("\\")
        }
        guard commands > 0 else { return nil }
        return script(lines, kind: .untagged, caption: caption)
    }

    private static func startsWithKnownWord(_ line: String, programs: Set<String>) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let word = String(trimmed.prefix { !$0.isWhitespace && $0 != ";" && $0 != "|" && $0 != "&" && $0 != "(" && $0 != ")" })
        if shellWords.contains(word) { return true }
        if isAssignment(word) {
            // A line of assignments only (`NAME=value`) is a shell line too.
            return trimmed.dropFirst(word.count).allSatisfy { $0 == " " || $0 == "\t" }
        }
        return !word.contains("/") && programs.contains(word)
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
        return name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    /// Output-looking lines: prompts and arrows, a first word ending in `:` (`error:`, `ls:`), counters such as `[1]`.
    private static func looksLikeOutput(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first else { return false }
        if "$%><=*+|[(".contains(first) && !trimmed.hasPrefix("[[") && !trimmed.hasPrefix("((") { return true }
        let word = trimmed.prefix { !$0.isWhitespace }
        return word.hasSuffix(":") || word.hasSuffix(",")
    }

    private static func isPromptLine(_ line: String) -> Bool { line.hasPrefix("$ ") || line.hasPrefix("% ") }

    private static func isComment(_ line: String) -> Bool { line.drop { $0 == " " || $0 == "\t" }.hasPrefix("#") }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func trimmedBlankEdges(_ lines: [String]) -> [String] {
        guard let first = lines.firstIndex(where: { !isBlank($0) }),
              let last = lines.lastIndex(where: { !isBlank($0) }) else { return [] }
        return Array(lines[first...last])
    }

    private static func caption(_ lines: [String]) -> String? {
        let cleaned = lines.map { CodeText.oneLine($0, limit: 300) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: "\n")
    }
}
