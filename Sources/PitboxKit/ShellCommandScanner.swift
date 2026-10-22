import Foundation

// The reader of offered shell commands. Pure: it reads text and never runs, expands or looks anything up. It accepts
// exactly the language of docs/SHELL_LANGUAGE.md §2 (the subset of `/bin/zsh -f` Pitbox understands) and reports
// "cannot read" for everything else instead of guessing (B3). Every range is a UTF-16 range of the text it was given
// (NSString offsets), so the sheet can underline it. Never log what it returns (docs/THREAT_MODEL.md).

/// Reads shell text into a syntax tree: words (with their quoting kept apart from their text), operators,
/// redirections, substitutions (recursively, at most `maxSubstitutionDepth` levels, also inside double quotes),
/// here-docs (quoted or unquoted delimiters, `<<-` tab stripping, bodies of unquoted ones read for substitutions),
/// comments and backslash-newline joins. Linear in the text; anything it does not know ends the scan with a problem.
public enum ShellCommandScanner {
    /// Longest text it reads, counted in Unicode scalars.
    public static let maxCharacters = CommandOffer.maxCharacters
    /// Most words, operators and redirections it reads, substitutions included.
    public static let maxTokens = 2_000
    /// `$(…)`, backticks, `$((…))`, `<(…)` and `>(…)` nest at most this deep.
    public static let maxSubstitutionDepth = 8
    /// Compound commands and substitutions together nest at most this deep (keeps the reader's recursion bounded).
    public static let maxNesting = 32

    /// Reads `text`. The result holds either the script or the first problem found.
    public static func scan(_ text: String) -> ShellScan {
        scan(units: Array(text.utf16))
    }

    /// Reads UTF-16 code units (the offer's text as `NSString` sees it).
    public static func scan(units: [UInt16]) -> ShellScan {
        ShellScanRun.scan(ShellSource(units: units))
    }
}

/// What the scanner read.
public struct ShellScan: Sendable, Equatable {
    /// The script; nil when the text cannot be read (then `problem` says why).
    public var script: ShellScript?
    /// Why the text cannot be read (B3, or B4 for the scanner's own size limits).
    public var problem: ShellScanProblem?
    /// Every comment read, `#` included and the line end excluded, in text order (inside substitutions too).
    public var comments: [Range<Int>]
    /// Every here-doc read, in text order (inside substitutions too).
    public var hereDocuments: [ShellHereDocument]
    /// Words, operators and redirections read, substitutions included.
    public var tokenCount: Int

    public init(script: ShellScript?, problem: ShellScanProblem?, comments: [Range<Int>],
                hereDocuments: [ShellHereDocument], tokenCount: Int) {
        self.script = script; self.problem = problem; self.comments = comments
        self.hereDocuments = hereDocuments; self.tokenCount = tokenCount
    }

    /// True when the whole text was read.
    public var isReadable: Bool { script != nil }
}

/// Why the scanner stopped. The words are Pitbox's own, for "Pitbox can't read this shell syntax".
public struct ShellScanProblem: Error, Sendable, Equatable {
    /// What kind of problem stopped the scan.
    public enum Kind: String, Sendable, CaseIterable {
        /// More than `ShellCommandScanner.maxCharacters` characters (B4).
        case tooLong
        /// More than `ShellCommandScanner.maxTokens` tokens (B4).
        case tooManyTokens
        /// Nested deeper than the limits (B3).
        case tooDeep
        /// A quote that is never closed (B3).
        case unclosedQuote
        /// `$(`, a backtick, `${`, `$((`, `(`, `{`, `[[` or a compound command that is never closed (B3).
        case unclosed
        /// A here-doc without its delimiter line (B3).
        case unterminatedHereDocument
        /// A `\` at the very end (B3).
        case trailingBackslash
        /// A construct of the "not accepted" list (docs/SHELL_LANGUAGE.md §2.1, B3).
        case notAccepted
        /// Anything else the grammar does not allow (B3).
        case syntax
    }

    /// The kind of problem.
    public var kind: Kind
    /// What was found, in Pitbox's words: "zsh parameter flags `${(…)…}`", "an unclosed `$(`".
    public var detail: String
    /// Where (UTF-16, into the scanned text).
    public var utf16Range: Range<Int>

    public init(kind: Kind, detail: String, utf16Range: Range<Int>) {
        self.kind = kind; self.detail = detail; self.utf16Range = utf16Range
    }

    /// B4 for the size limits, B3 for everything else.
    public var rule: CommandRule { kind == .tooLong || kind == .tooManyTokens ? .b4 : .b3 }
}

// MARK: The tree

/// A list of commands: `a; b & c` and lines.
public struct ShellScript: Sendable, Equatable {
    /// The and-or lists, in order.
    public var items: [ShellListItem]
    /// Where the list is in the text.
    public var utf16Range: Range<Int>

    public init(items: [ShellListItem], utf16Range: Range<Int>) { self.items = items; self.utf16Range = utf16Range }
}

/// One and-or list of a script with what ends it.
public struct ShellListItem: Sendable, Equatable {
    /// What ends an and-or list.
    public enum Terminator: String, Sendable { case none, semicolon, newline, background }
    /// The pipelines joined by `&&` and `||`.
    public var andOr: ShellAndOrList
    /// `;`, a newline, `&` (runs in the background) or nothing (the end of the list).
    public var terminator: Terminator

    public init(andOr: ShellAndOrList, terminator: Terminator) { self.andOr = andOr; self.terminator = terminator }
}

/// Pipelines joined by `&&` and `||`.
public struct ShellAndOrList: Sendable, Equatable {
    /// `&&` or `||`.
    public enum Connector: String, Sendable { case and = "&&", or = "||" }
    /// The pipelines, in order.
    public var pipelines: [ShellPipeline]
    /// `connectors[i]` joins `pipelines[i]` and `pipelines[i + 1]`.
    public var connectors: [Connector]

    public init(pipelines: [ShellPipeline], connectors: [Connector]) {
        self.pipelines = pipelines; self.connectors = connectors
    }
}

/// Commands joined by `|`, optionally negated with `!`.
public struct ShellPipeline: Sendable, Equatable {
    /// Started with `!`.
    public var negated: Bool
    /// The commands joined by `|` (or `|&`).
    public var commands: [ShellCommand]
    /// Where the pipeline is in the text.
    public var utf16Range: Range<Int>

    public init(negated: Bool, commands: [ShellCommand], utf16Range: Range<Int>) {
        self.negated = negated; self.commands = commands; self.utf16Range = utf16Range
    }
}

/// One element of a pipeline.
public enum ShellCommand: Sendable, Equatable {
    case simple(ShellSimpleCommand)
    case compound(ShellCompoundCommand)

    /// Where the command is in the text.
    public var utf16Range: Range<Int> {
        switch self {
        case .simple(let s): return s.utf16Range
        case .compound(let c): return c.utf16Range
        }
    }
}

/// `( … )`, `{ …; }`, `if`, `for`, `while`, `until`, `case`, `[[ … ]]` and `(( … ))`, with redirections after them.
public struct ShellCompoundCommand: Sendable, Equatable {
    /// Which compound command, with its parts.
    public enum Kind: Sendable, Equatable {
        case subshell(ShellScript)
        case group(ShellScript)
        case ifClause(branches: [ShellConditionalBranch], elseBody: ShellScript?)
        /// `for name in words; do …; done`; `items` is nil for `for name; do` (the positional parameters).
        case forLoop(variable: String, items: [ShellWord]?, body: ShellScript)
        case whileLoop(condition: ShellScript, body: ShellScript)
        case untilLoop(condition: ShellScript, body: ShellScript)
        case caseClause(subject: ShellWord, items: [ShellCaseItem])
        /// `[[ … ]]`: its words (operators such as `==` and `&&` are words here).
        case condition(words: [ShellWord])
        /// `(( … ))`.
        case arithmetic(ShellArithmetic)
    }

    /// Which compound command.
    public var kind: Kind
    /// Redirections after its closing word (`done < input`).
    public var redirections: [ShellRedirection]
    /// Where it is in the text.
    public var utf16Range: Range<Int>

    public init(kind: Kind, redirections: [ShellRedirection], utf16Range: Range<Int>) {
        self.kind = kind; self.redirections = redirections; self.utf16Range = utf16Range
    }
}

/// `if`/`elif` condition and the list after `then`.
public struct ShellConditionalBranch: Sendable, Equatable {
    /// The list after `if` or `elif`.
    public var condition: ShellScript
    /// The list after `then`.
    public var body: ShellScript
    public init(condition: ShellScript, body: ShellScript) { self.condition = condition; self.body = body }
}

/// One `pattern) list ;;` of a `case`.
public struct ShellCaseItem: Sendable, Equatable {
    /// The patterns before `)`.
    public var patterns: [ShellWord]
    /// The commands of the clause.
    public var body: ShellScript
    public init(patterns: [ShellWord], body: ShellScript) { self.patterns = patterns; self.body = body }
}

/// Assignments, words and redirections, in the order of the text within each kind.
public struct ShellSimpleCommand: Sendable, Equatable {
    /// `NAME=value` before the first word.
    public var assignments: [ShellAssignment]
    /// The command word and its arguments, as written (nothing expanded).
    public var words: [ShellWord]
    /// Its redirections, in order.
    public var redirections: [ShellRedirection]
    /// From its first to its last word or redirection.
    public var utf16Range: Range<Int>

    public init(assignments: [ShellAssignment], words: [ShellWord], redirections: [ShellRedirection],
                utf16Range: Range<Int>) {
        self.assignments = assignments; self.words = words; self.redirections = redirections
        self.utf16Range = utf16Range
    }
}

/// `NAME=value` or `NAME+=value` before a command (or alone).
public struct ShellAssignment: Sendable, Equatable {
    /// The variable's name.
    public var name: String
    /// `+=` rather than `=`.
    public var appends: Bool
    /// The value as a word (empty for `NAME=`).
    public var value: ShellWord
    /// Where the assignment is in the text.
    public var utf16Range: Range<Int>

    public init(name: String, appends: Bool, value: ShellWord, utf16Range: Range<Int>) {
        self.name = name; self.appends = appends; self.value = value; self.utf16Range = utf16Range
    }
}

/// One redirection.
public struct ShellRedirection: Sendable, Equatable {
    /// The redirection operator as written.
    public enum Operator: String, Sendable, CaseIterable {
        case input = "<", output = ">", append = ">>", clobber = ">|", outputAndError = "&>"
        case appendOutputAndError = "&>>", duplicateOutput = ">&", duplicateInput = "<&"
        case hereDocument = "<<", hereDocumentStrippingTabs = "<<-", hereString = "<<<"
    }

    /// The descriptor written before the operator (`2>`), nil when none was.
    public var fileDescriptor: Int?
    /// The operator.
    public var op: Operator
    /// The file, descriptor (`2>&1`), here-string or here-doc delimiter word.
    public var target: ShellWord
    /// Set for `<<` and `<<-`.
    public var hereDocument: ShellHereDocument?
    /// From the descriptor to the end of the target.
    public var utf16Range: Range<Int>

    public init(fileDescriptor: Int?, op: Operator, target: ShellWord, hereDocument: ShellHereDocument?,
                utf16Range: Range<Int>) {
        self.fileDescriptor = fileDescriptor; self.op = op; self.target = target; self.hereDocument = hereDocument
        self.utf16Range = utf16Range
    }

    /// True for `>`, `>|`, `&>` and `>&` with a file (not a descriptor): the target is replaced.
    public var replacesTarget: Bool {
        switch op {
        case .output, .clobber, .outputAndError: return true
        case .duplicateOutput: return !target.isDescriptorReference
        default: return false
        }
    }

    /// True for every redirection that writes its target file (`>>` and `&>>` included).
    public var writesTarget: Bool {
        replacesTarget || op == .append || op == .appendOutputAndError
    }
}

/// A here-doc: the text given to a program on its standard input.
public struct ShellHereDocument: Sendable, Equatable {
    /// The delimiter with its quotes removed.
    public var delimiter: String
    /// A quoted delimiter (`<<'EOF'`, `<<"EOF"`, `<<\EOF`) keeps the body literal; an unquoted one expands
    /// `$NAME`, `$(…)` and backticks in it when the shell reads it.
    public var delimiterQuoted: Bool
    /// `<<-`: leading tabs are removed from the body lines and the delimiter line.
    public var stripsTabs: Bool
    /// The body as the program reads it (tabs stripped for `<<-`), without the delimiter line, each line ending in
    /// "\n".
    public var body: String
    /// The body's lines in the text (the delimiter line excluded).
    public var bodyRange: Range<Int>
    /// The body read as a word: literal text, plus the expansions of an unquoted delimiter's body.
    public var content: ShellWord
    /// While scanning: the number of a here-doc whose body comes later (filled in before the scan returns).
    var slot = -1

    public init(delimiter: String, delimiterQuoted: Bool, stripsTabs: Bool, body: String, bodyRange: Range<Int>,
                content: ShellWord) {
        self.delimiter = delimiter; self.delimiterQuoted = delimiterQuoted; self.stripsTabs = stripsTabs
        self.body = body; self.bodyRange = bodyRange; self.content = content
    }
}

/// How a piece of a word was quoted.
public enum ShellQuoting: String, Sendable {
    case none
    /// `'…'`
    case single
    /// `"…"` (also the body of an unquoted here-doc)
    case double
    /// `$'…'`, escapes decoded
    case ansiC
    /// `\x` outside quotes
    case backslash
}

/// One word as written: its pieces, in order. Nothing is expanded; expansions stay pieces of their own.
public struct ShellWord: Sendable, Equatable {
    /// Its pieces, in order.
    public var parts: [ShellWordPart]
    /// Where the word is in the text, quotes included.
    public var utf16Range: Range<Int>

    public init(parts: [ShellWordPart], utf16Range: Range<Int>) { self.parts = parts; self.utf16Range = utf16Range }
}

/// A piece of a word.
public enum ShellWordPart: Sendable, Equatable {
    /// Text after quote removal, with how it was quoted. `$'…'` text is decoded (`decodedEscapes` tells whether
    /// `\x…`, `\u…`, `\U…`, octal or `\c` escapes built it).
    case text(String, quoting: ShellQuoting, decodedEscapes: Bool, utf16Range: Range<Int>)
    /// A leading `~` (the home folder).
    case tilde(utf16Range: Range<Int>)
    /// An unquoted `*`, `?` or `[…]`.
    case glob(String, utf16Range: Range<Int>)
    /// An unquoted brace list `{a,b}` or range `{1..3}` (plain text only), with its alternatives as zsh would
    /// produce them (nil when there would be more than 64).
    case braceList(String, alternatives: [String]?, utf16Range: Range<Int>)
    case parameter(ShellParameter)
    /// `$(…)` or backticks.
    case commandSubstitution(ShellScript, backticks: Bool, quoted: Bool, utf16Range: Range<Int>)
    /// `$((…))`.
    case arithmetic(ShellArithmetic)
    /// `<(…)` (the program reads its output as a file) or `>(…)` (writes into it).
    case processSubstitution(ShellScript, writes: Bool, utf16Range: Range<Int>)

    /// Where the piece is in the text.
    public var utf16Range: Range<Int> {
        switch self {
        case .text(_, _, _, let r), .tilde(let r), .glob(_, let r), .braceList(_, _, let r),
             .commandSubstitution(_, _, _, let r), .processSubstitution(_, _, let r): return r
        case .parameter(let p): return p.utf16Range
        case .arithmetic(let a): return a.utf16Range
        }
    }
}

/// `$NAME`, `${NAME}`, `${NAME:-word}`, `${NAME:=word}`, `${NAME:?word}`, `${#NAME}`, `$1`, `$?`, `$$`, `$@`.
public struct ShellParameter: Sendable, Equatable {
    /// Which of the accepted forms.
    public enum Form: String, Sendable {
        case plain, braced
        case useDefault = ":-", assignDefault = ":=", errorIfUnset = ":?"
        case length = "#"
    }

    /// The name (`HOME`, `1`, `?`).
    public var name: String
    /// The form.
    public var form: Form
    /// The word after `:-`, `:=` or `:?`.
    public var word: ShellWord?
    /// Inside double quotes.
    public var quoted: Bool
    /// From `$` to the end of the parameter.
    public var utf16Range: Range<Int>

    public init(name: String, form: Form, word: ShellWord?, quoted: Bool, utf16Range: Range<Int>) {
        self.name = name; self.form = form; self.word = word; self.quoted = quoted; self.utf16Range = utf16Range
    }
}

/// `$((…))` or `((…))`: the expression as written and the expansions inside it.
public struct ShellArithmetic: Sendable, Equatable {
    /// The text between the parentheses.
    public var expression: String
    /// Parameters and substitutions inside the expression.
    public var expansions: [ShellWordPart]
    /// Names used without `$` (`x` in `$((x + 1))`): the shell evaluates their values as arithmetic too.
    public var bareNames: [String]
    /// From `$((` or `((` to `))`.
    public var utf16Range: Range<Int>

    public init(expression: String, expansions: [ShellWordPart], bareNames: [String], utf16Range: Range<Int>) {
        self.expression = expression; self.expansions = expansions; self.bareNames = bareNames
        self.utf16Range = utf16Range
    }
}

// MARK: Reading words

extension ShellWord {
    /// The word's text when nothing in it is expanded at run time (no parameter, substitution or arithmetic):
    /// quotes removed, `~` kept as `~`, globs and brace lists as written. Nil otherwise.
    public var literalText: String? {
        var out = ""
        for part in parts {
            switch part {
            case .text(let s, _, _, _): out += s
            case .tilde: out += "~"
            case .glob(let s, _): out += s
            case .braceList(let s, _, _): out += s
            case .parameter, .commandSubstitution, .arithmetic, .processSubstitution: return nil
            }
        }
        return out
    }

    /// True when some piece is filled in at run time (a parameter, a substitution or arithmetic).
    public var hasExpansion: Bool { literalText == nil }

    /// True for an unquoted `*`, `?`, `[…]` or brace list.
    public var hasPattern: Bool {
        parts.contains { if case .glob = $0 { return true }; if case .braceList = $0 { return true }; return false }
    }

    /// True when some piece was quoted or escaped.
    public var isQuoted: Bool {
        parts.contains { if case .text(_, let q, _, _) = $0 { return q != .none }; return false }
    }

    /// True for `1`, `2`, `-` and the like after `>&` and `<&`.
    var isDescriptorReference: Bool {
        guard let t = literalText, !t.isEmpty, !isQuoted else { return false }
        return t == "-" || t.utf16.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }
}
