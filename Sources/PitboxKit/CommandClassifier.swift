import Foundation

// The command classifier's public entry point (docs/SHELL_LANGUAGE.md). Pure: it reads text, never runs anything and
// never touches the file system (the caller passes what it looked up in `CommandContext`, and optionally a path
// lookup for R21). It reads the text with `ShellCommandScanner`, classifies every segment (nested scripts included),
// decides the machine and returns one class: the most restrictive that applies. Never log the text or anything taken
// from it (docs/THREAT_MODEL.md).

/// Classifies an offered command's text: the class, the red lines and block reasons with
/// their words and ranges, the notes, the segments and the machine.
public enum CommandClassifier {
    /// Version of the pattern tables and the accepted language; shown in "How it runs" and logged as a number.
    public static let policyVersion = 1

    /// Classifies `text` (the exact bytes an offer would run) for the session described by `context`. Partly read is
    /// never returned: the caller applies the offer's `replyReadCompletely`. R21 and the exact R10 need file facts:
    /// assess once, `lstat` the paths in `localTargets`, and assess again with them in `context.pathFacts`
    /// (docs/SHELL_LANGUAGE.md §8 A5, A6).
    public static func assess(text: String, context: CommandContext) -> CommandAssessment {
        assess(text: text, context: context, options: CommandClassifierOptions())
    }

    /// Classifies `text` with settings the context does not carry: the shell (clean or login), the block's kind (the
    /// "untagged block" note) and whether a Fetch file shape is recognised.
    public static func assess(text: String, context: CommandContext, options: CommandClassifierOptions)
        -> CommandAssessment {
        let analysis = CommandAnalysis(text: text, context: context, options: options)
        var assessment = analysis.run()
        guard analysis.neutralized else { return assessment }
        // A `<…>` placeholder was read as a word. Typed unedited, zsh reads it as redirections: keep the red lines and
        // blocks of that reading too, so nothing it would do goes unticked.
        let literal = CommandAnalysis(text: text, context: context, options: options, neutralizesPlaceholders: false).run()
        let found = Set(assessment.flags.map(\.rule))
        for flag in literal.flags where flag.rule != .b3 && !found.contains(flag.rule) {
            assessment.flags.append(flag)
        }
        assessment.flags.sort { $0.utf16Range.lowerBound != $1.utf16Range.lowerBound
            ? $0.utf16Range.lowerBound < $1.utf16Range.lowerBound
            : CommandAnalysis.order($0.rule) < CommandAnalysis.order($1.rule) }
        if assessment.flags.contains(where: { $0.rule.blocks }) { assessment.commandClass = .blocked }
        for target in literal.localTargets where !assessment.localTargets.contains(target) {
            assessment.localTargets.append(target)
        }
        return assessment
    }

    /// The text with every B1 character removed, and what was removed (the sheet's **Copy cleaned**).
    public static func cleanedText(_ text: String) -> CommandCleanedText {
        CommandCharacterPolicy.cleaned(text)
    }

    /// B1's character policy as one predicate (docs/SHELL_LANGUAGE.md §3.4), from the Unicode data of the macOS it
    /// runs on: every character of category Cc or Cf except tab and newline, every Default_Ignorable_Code_Point,
    /// U+2028 and U+2029, and every space other than U+0020. The block and the sheet escape session text with it, so
    /// the characters they show escaped are exactly the ones that block an offer.
    public static func isHiddenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CommandCharacterPolicy.isHidden(scalar)
    }

    /// Whether an untagged block reads as commands. Every line that starts a command must start with a shell
    /// keyword or builtin, an assignment, or a program in `programsOnCleanPath`, and the block must read as shell
    /// (no output lines, nothing the scanner cannot read). Nil `programsOnCleanPath` (not looked up): false.
    public static func untaggedBlockReadsAsCommands(_ text: String, programsOnCleanPath: Set<String>?) -> Bool {
        CommandAnalysis.untaggedBlockReadsAsCommands(text, programsOnCleanPath: programsOnCleanPath)
    }
}

/// Settings for `CommandClassifier.assess(text:context:options:)` that `CommandContext` does not carry.
public struct CommandClassifierOptions: Sendable, Equatable {
    /// The shell that runs the command: the clean shell adds the note "Runs in the clean shell".
    public var shell: CommandExecutionDescriptor.Shell
    /// The block's kind: `.untagged` adds the note "Untagged block, read as a command".
    public var blockKind: CommandOffer.BlockKind?
    /// False for the ordinary sheet of "Run in terminal instead": the Fetch file shape is then an ordinary
    /// command.
    public var recognizesFetchFile: Bool

    public init(shell: CommandExecutionDescriptor.Shell = .clean, blockKind: CommandOffer.BlockKind? = nil,
                recognizesFetchFile: Bool = true) {
        self.shell = shell; self.blockKind = blockKind; self.recognizesFetchFile = recognizesFetchFile
    }
}

/// The text with its B1 characters removed (the sheet's "Copy cleaned").
public struct CommandCleanedText: Sendable, Equatable {
    /// One removed character.
    public struct Removal: Sendable, Equatable {
        /// The removed character.
        public var scalar: Unicode.Scalar
        /// Where it was, in the original text (UTF-16).
        public var utf16Range: Range<Int>
        /// 1-based line of the original text.
        public var line: Int
        /// `⟨U+202E⟩`, as the sheet shows it in place.
        public var escaped: String { "⟨" + CommandCharacterPolicy.codePoint(scalar) + "⟩" }

        public init(scalar: Unicode.Scalar, utf16Range: Range<Int>, line: Int) {
            self.scalar = scalar; self.utf16Range = utf16Range; self.line = line
        }
    }

    /// The cleaned text.
    public var text: String
    /// What was removed, in text order.
    public var removals: [Removal]
    /// "2 hidden characters removed".
    public var summary: String {
        removals.count == 1 ? "1 hidden character removed" : "\(removals.count) hidden characters removed"
    }

    public init(text: String, removals: [Removal]) { self.text = text; self.removals = removals }
}

extension CommandAssessment.Class {
    /// How restrictive the class is (docs/SHELL_LANGUAGE.md §4.3): the higher, the less the sheet allows.
    public var severity: Int {
        switch self {
        case .notFlagged: return 0
        case .risky: return 1
        case .fetchFile: return 2
        case .unclearMachine: return 3
        case .needsEditing: return 4
        case .forServer: return 5
        case .otherMachine: return 6
        case .partlyRead: return 7
        case .blocked: return 8
        }
    }
}

extension CommandAssessment {
    /// Copy works for every class except a block by B1, B2 or B5.
    public var copyAllowed: Bool {
        !flags.contains { $0.rule == .b1 || $0.rule == .b2 || $0.rule == .b5 }
    }

    /// B1 offers **Copy cleaned** (when no B2 or B5 forbids copying as well).
    public var offersCopyCleaned: Bool {
        flags.contains { $0.rule == .b1 } && !flags.contains { $0.rule == .b2 || $0.rule == .b5 }
    }

    /// The block reasons found, in text order.
    public var blockReasons: [CommandRule] {
        var seen: [CommandRule] = []
        for f in flags where f.rule.blocks && !seen.contains(f.rule) { seen.append(f.rule) }
        return seen
    }
}
