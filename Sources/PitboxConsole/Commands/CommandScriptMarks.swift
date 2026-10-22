import PitboxKit

/// What the scanner (PitboxKit, `ShellCommandScanner`) knows about the text the sheet shows, for the command area:
/// the shell's comments, shown dimmed, and the here-doc bodies, shown on a faint panel labelled
/// "text given to <program>".
///
/// Only a text the scanner can read gets marks. For an unreadable text (B3, blocked anyway) nothing is dimmed and no
/// panel is drawn, so nothing that would run can look inert. A `#` inside quotes or inside a here-doc body is not a
/// comment, and the scanner knows it.
struct CommandScriptMarks: Equatable {
    /// One here-doc body.
    struct HereDocument: Equatable {
        /// The body's lines in the text (UTF-16 offsets), the delimiter line excluded.
        var body: Range<Int>
        /// Who reads it: the command's first word as written (plain text, hidden characters escaped), or the keyword
        /// of a compound command (`while`, `{ … }`).
        var program: String
    }

    /// The comments, from `#` to the end of the line (UTF-16 offsets), in order.
    var comments: [Range<Int>]
    /// The here-doc bodies with text, in order.
    var hereDocuments: [HereDocument]

    /// No marks.
    static let empty = CommandScriptMarks(comments: [], hereDocuments: [])

    init(comments: [Range<Int>], hereDocuments: [HereDocument]) {
        self.comments = comments
        self.hereDocuments = hereDocuments
    }

    /// The marks of `text`, from one scan.
    init(text: String) {
        let scan = ShellCommandScanner.scan(text)
        guard let script = scan.script else {
            self = .empty
            return
        }
        var walker = Walker(units: Array(text.utf16))
        walker.walk(script)
        var found = walker.found
        // A body the walk did not reach still gets its panel.
        for document in scan.hereDocuments where !found.contains(where: { $0.body == document.bodyRange }) {
            found.append(HereDocument(body: document.bodyRange, program: "a command"))
        }
        comments = scan.comments.sorted { $0.lowerBound < $1.lowerBound }
        hereDocuments = found.filter { !$0.body.isEmpty }.sorted { $0.body.lowerBound < $1.body.lowerBound }
    }

    /// Whether the character at `offset` is inside a comment.
    func isComment(at offset: Int) -> Bool {
        comments.contains { $0.contains(offset) }
    }

    /// Walks the scanned script for every here-doc and the command that reads it. Depth is bounded by the scanner's
    /// own limits (`ShellCommandScanner.maxNesting`, `maxSubstitutionDepth`).
    private struct Walker {
        let units: [UInt16]
        var found: [HereDocument] = []

        mutating func walk(_ script: ShellScript) {
            for item in script.items {
                for pipeline in item.andOr.pipelines {
                    for command in pipeline.commands { walk(command) }
                }
            }
        }

        private mutating func walk(_ command: ShellCommand) {
            switch command {
            case .simple(let simple):
                let program = simple.words.first.map { shown($0) } ?? "no program"
                for assignment in simple.assignments { walk(assignment.value) }
                for word in simple.words { walk(word) }
                add(simple.redirections, program: program)
            case .compound(let compound):
                switch compound.kind {
                case .subshell(let body), .group(let body):
                    walk(body)
                case .ifClause(let branches, let elseBody):
                    for branch in branches {
                        walk(branch.condition)
                        walk(branch.body)
                    }
                    if let elseBody { walk(elseBody) }
                case .forLoop(_, let items, let body):
                    for word in items ?? [] { walk(word) }
                    walk(body)
                case .whileLoop(let condition, let body), .untilLoop(let condition, let body):
                    walk(condition)
                    walk(body)
                case .caseClause(let subject, let items):
                    walk(subject)
                    for item in items {
                        for pattern in item.patterns { walk(pattern) }
                        walk(item.body)
                    }
                case .condition(let words):
                    for word in words { walk(word) }
                case .arithmetic(let arithmetic):
                    for part in arithmetic.expansions { walk(part) }
                }
                add(compound.redirections, program: Self.keyword(compound.kind))
            }
        }

        private mutating func add(_ redirections: [ShellRedirection], program: String) {
            for redirection in redirections {
                walk(redirection.target)
                if let document = redirection.hereDocument {
                    found.append(HereDocument(body: document.bodyRange, program: program))
                    walk(document.content)
                }
            }
        }

        private mutating func walk(_ word: ShellWord) {
            for part in word.parts { walk(part) }
        }

        private mutating func walk(_ part: ShellWordPart) {
            switch part {
            case .commandSubstitution(let script, _, _, _), .processSubstitution(let script, _, _):
                walk(script)
            case .parameter(let parameter):
                if let word = parameter.word { walk(word) }
            case .arithmetic(let arithmetic):
                for inner in arithmetic.expansions { walk(inner) }
            case .text, .tilde, .glob, .braceList:
                break
            }
        }

        /// The word exactly as written, as plain text on one line (at most 32 characters).
        private func shown(_ word: ShellWord) -> String {
            let lower = max(0, min(word.utf16Range.lowerBound, units.count))
            let upper = max(lower, min(word.utf16Range.upperBound, units.count))
            let written = String(decoding: units[lower..<upper], as: UTF16.self)
            return CommandPlainText.singleLine(written, maxCharacters: 32)
        }

        private static func keyword(_ kind: ShellCompoundCommand.Kind) -> String {
            switch kind {
            case .subshell: return "( … )"
            case .group: return "{ … }"
            case .ifClause: return "if"
            case .forLoop: return "for"
            case .whileLoop: return "while"
            case .untilLoop: return "until"
            case .caseClause: return "case"
            case .condition: return "[[ … ]]"
            case .arithmetic: return "(( … ))"
            }
        }
    }
}
