import Foundation

// One classification run (docs/SHELL_LANGUAGE.md §1): characters (B1), size (B4), the reader (B3), segments and
// machines, patterns on each segment (nested scripts included), then the class. The pieces live in the other files of
// this folder as extensions of `CommandAnalysis`.

/// Where a segment runs: here, or on the host an `ssh` sends it to.
enum SegmentScope: Equatable {
    case local
    case remote(String)
}

/// How a substitution's output is used (R7: a secret printed into an assignment is a note, anywhere else a red line).
enum SubstitutionUse: Equatable {
    case commandWord, argument, redirectTarget, hereDocument, hereString, condition, arithmetic, loopWords
    case assignment(name: String, standalone: Bool)
}

/// Why a segment exists.
enum SegmentOrigin: Equatable {
    case top
    case substitution(parent: Int, use: SubstitutionUse)
    case processSubstitution(parent: Int, writes: Bool)
    case nested(parent: Int, kind: NestedKind)
}

/// A script a segment runs from text: `sh -c '…'`, `eval …`, the words after an `ssh` host, a body fed to a shell.
enum NestedKind: Equatable {
    case shellString, eval, remote, hereDocument, pipeBody, findExec, watch, envSplit, su
}

/// A pipeline a segment belongs to and its place in it.
struct PipeRef: Equatable {
    let id: Int
    let position: Int
}

/// A variable's value as far as the block shows it.
enum VariableValue: Equatable {
    /// Set to literal text (a `for` loop: one of several).
    case literal([String])
    /// Filled from `security find-*-password … -w` (R7's note form, R12's Keychain secret).
    case keychain(item: String)
    /// Set from a substitution, another variable, `read`, or not known.
    case unknown
}

/// One command of the text, after wrappers and assignments were looked through.
final class Segment {
    let id: Int
    var top = -1
    let scope: SegmentScope
    let range: Range<Int>
    let origin: SegmentOrigin
    var simple: ShellSimpleCommand?
    /// `[[` or `((` for conditions (no program).
    var pseudo: String?
    var assignments: [ShellAssignment] = []
    var redirections: [ShellRedirection] = []
    /// The command words after brace expansion.
    var words: [CWord] = []
    var wrappers: [CWord] = []
    var wrapperKeys: [String] = []
    var programIndex: Int?
    /// The program's base name as written; nil without a program.
    var program: String?
    /// The program lowercased (the volumes are case-insensitive), "" without a program.
    var key = ""
    /// The program word holds a variable, a substitution or a glob (R11).
    var programIsBuilt = false
    var args: [CWord] = []
    var pipes: [PipeRef] = []
    var background = false
    /// Variables as they were before this command.
    var variables: [String: VariableValue] = [:]
    /// The working folder when it runs (local scope), nil when unknown.
    var folder: String?
    var depth = 0
    /// Remote hosts of rule 1 (`ssh host cmd`) this segment sends to.
    var sendsTo: String?

    init(id: Int, scope: SegmentScope, range: Range<Int>, origin: SegmentOrigin) {
        self.id = id; self.scope = scope; self.range = range; self.origin = origin
    }

    var isRemote: Bool { if case .remote = scope { return true }; return false }
    var parent: Int? {
        switch origin {
        case .top: return nil
        case .substitution(let p, _), .processSubstitution(let p, _), .nested(let p, _): return p
        }
    }
}

final class CommandAnalysis {
    let text: String
    /// The text's UTF-16 units (ranges point here).
    let units: [UInt16]
    let context: CommandContext
    let facts: CommandSessionFacts
    let options: CommandClassifierOptions
    let home: String
    private(set) var lineStarts: [Int] = [0]

    var flags: [CommandFlag] = []
    private var flagKeys = Set<String>()
    var notes: [CommandNote] = []
    private var noteKeys = Set<String>()
    var placeholder: String?
    var segments: [Segment] = []
    var tops: [Int] = []
    var topIndex: [Int: Int] = [:]
    var comments: [Range<Int>] = []
    var hereDocuments: [ShellHereDocument] = []
    var readable = false
    var lineCount = 1

    var angleRanges: [Range<Int>] = []
    var writeRecords: [WriteRecord] = []
    var localTargets: [String] = []
    /// Top-level list items of the script (`a; b` has two, `a && b` one).
    var topItems = 0

    // Walk state.
    var pendingScripts: [(segment: Int, word: CWord, kind: NestedKind)] = []
    var pipeMembers: [Int: [(Int, Int)]] = [:]
    /// Files a decoder wrote in this block (B5 through a file).
    var decodedFiles: [(path: String, segment: Int)] = []
    /// How many segments the rules pass has visited.
    var rulesApplied = 0
    var upstreamCache: [Int: [Int]] = [:]
    var walkDone = false
    var variables: [String: VariableValue] = [:]
    var folder: String?
    var pipeCounter = 0
    /// Files a downloader wrote in this block (R3's "download, chmod +x and run").
    var downloads: [(path: String, segment: Int)] = []
    /// Placeholders `<…>` are read as if their brackets were these (so `<server>` reads as one word).
    static let placeholderOpen: UInt16 = 0xE000
    static let placeholderClose: UInt16 = 0xE001
    var neutralized = false

    // Machine.
    var machine: CommandMachine = .unclear
    var machineReason = ""
    var replyClaim: String?
    var fetch: FetchFileRequest?

    /// False for the second reading of a text with `<…>` placeholders: as zsh would read it if typed unedited.
    let neutralizesPlaceholders: Bool

    init(text: String, context: CommandContext, options: CommandClassifierOptions, neutralizesPlaceholders: Bool = true) {
        self.neutralizesPlaceholders = neutralizesPlaceholders
        self.text = text
        self.units = Array(text.utf16)
        self.context = context
        self.facts = context.facts
        self.options = options
        self.home = Self.normalize(context.facts.homeDirectory.isEmpty ? "/" : context.facts.homeDirectory)
        for (k, u) in units.enumerated() where u == Ch.newline { lineStarts.append(k + 1) }
    }

    // MARK: The run

    func run() -> CommandAssessment {
        lineCount = Self.lines(of: text)
        checkHiddenCharacters()
        if checkLimits() { return finish() }
        checkTurnOrigin()
        checkSecretsInText()
        checkForkBomb()
        let scanUnits = findPlaceholders()
        let scan = ShellCommandScanner.scan(units: scanUnits)
        comments = scan.comments
        hereDocuments = scan.hereDocuments
        guard let script = scan.script, scan.problem == nil else {
            if let p = scan.problem { addProblem(p, segment: nil) }
            decidePlaceholder()
            machine = .unclear
            machineReason = "Unclear: \(AppIdentity.displayName) couldn't read the command."
            return finish()
        }
        readable = true
        topItems = script.items.count
        startWalk()
        walk(script, WalkContext())
        walkDone = true
        decidePlaceholder()
        rulesApplied = 0
        applyRulesToNewSegments()
        applyBlockRules()
        decideMachine()
        recognizeFetch()
        collectNotes()
        return finish()
    }

    /// Lines of the text: a trailing newline does not start another line.
    static func lines(of text: String) -> Int {
        var n = 1
        var last: Unicode.Scalar?
        for s in text.unicodeScalars { if s == "\n" { n += 1 }; last = s }
        if last == "\n" { n -= 1 }
        return max(1, n)
    }

    // MARK: Flags and notes

    func line(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// Adds a flag once; `segment` is a segment id (its top-level segment is what the flag points at).
    func addFlag(_ rule: CommandRule, _ words: String, _ range: Range<Int>, segment: Int?) {
        var words = words
        if let s = segment, case .remote(let host) = segments[s].scope, !words.contains("(on ") {
            words += " (on \(shown(host)))"
        }
        let top = segment.flatMap { topIndex[segments[$0].top] }
        let key = "\(rule.rawValue)|\(range.lowerBound)|\(range.upperBound)|\(words)"
        guard !flagKeys.contains(key) else { return }
        flagKeys.insert(key)
        let lo = max(0, min(range.lowerBound, units.count))
        let hi = max(lo, min(range.upperBound, units.count))
        flags.append(CommandFlag(rule: rule, words: words, line: line(at: lo), utf16Range: lo..<hi, segment: top))
    }

    func addFlag(_ rule: CommandRule, _ words: String, in segment: Segment, range: Range<Int>? = nil) {
        addFlag(rule, words, range ?? segment.range, segment: segment.id)
    }

    func addProblem(_ p: ShellScanProblem, segment: Int?, inside: String? = nil) {
        if p.rule == .b4 {
            addFlag(.b4, "Too long to review here: \(p.detail)", p.utf16Range, segment: segment)
        } else {
            let what = inside.map { "\(p.detail) \($0)" } ?? p.detail
            addFlag(.b3, "\(AppIdentity.displayName) can't read this shell syntax (\(what)); use Copy", p.utf16Range, segment: segment)
        }
    }

    func addNote(_ kind: CommandNote.Kind, _ words: String) {
        let key = "\(kind.rawValue)|\(words)"
        guard !noteKeys.contains(key) else { return }
        noteKeys.insert(key)
        notes.append(CommandNote(kind: kind, words: words))
    }

    func has(_ rule: CommandRule) -> Bool { flags.contains { $0.rule == rule } }

    // MARK: Text helpers

    func source(_ r: Range<Int>) -> String {
        let lo = max(0, min(r.lowerBound, units.count)), hi = max(lo, min(r.upperBound, units.count))
        return Ch.string(units[lo..<hi])
    }

    /// Text from the command shown inside Pitbox's words: plain paths and names as they are, anything else in
    /// quotes, long text cut in the middle, B1 characters escaped (T11: session text never reads as Pitbox's).
    func shown(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            if CommandCharacterPolicy.isHidden(scalar) { out += "⟨" + CommandCharacterPolicy.codePoint(scalar) + "⟩" }
            else { out.unicodeScalars.append(scalar) }
        }
        let limit = 60
        if out.count > limit {
            out = String(out.prefix(limit / 2 - 1)) + "…" + String(out.suffix(limit / 2 - 1))
        }
        let plain = !out.isEmpty && out.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._/~+-@:%,=$#{}*?…".unicodeScalars.contains($0))
        }
        return plain ? out : "“" + out + "”"
    }

    /// Several targets, at most three named.
    func shownList(_ items: [String]) -> String {
        var seen: [String] = []
        for i in items where !seen.contains(i) { seen.append(i) }
        if seen.count <= 3 { return seen.joined(separator: ", ") }
        return seen.prefix(3).joined(separator: ", ") + " and \(seen.count - 3) more"
    }

    /// The folder in the sheet's short form (`~/my project`).
    func shortFolder(_ path: String?) -> String {
        guard let path else { return "the folder it runs in" }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: The class

    func finish() -> CommandAssessment {
        // One R15 per secret: overlapping R15 ranges keep the smallest, the value itself.
        let secrets = flags.filter { $0.rule == .r15 }.sorted { $0.utf16Range.count < $1.utf16Range.count }
        var keptSecrets: [CommandFlag] = []
        for f in secrets where !keptSecrets.contains(where: { $0.utf16Range.overlaps(f.utf16Range) }) { keptSecrets.append(f) }
        flags = flags.filter { $0.rule != .r15 } + keptSecrets
        let ordered = flags.sorted { a, b in
            if a.utf16Range.lowerBound != b.utf16Range.lowerBound { return a.utf16Range.lowerBound < b.utf16Range.lowerBound }
            return Self.order(a.rule) < Self.order(b.rule)
        }
        let cls = decideClass()
        if !readable, machineReason.isEmpty {
            machine = .unclear
            baseMachine = .unclear
            machineReason = "Unclear: \(AppIdentity.displayName) didn't read the command."
        }
        let out = tops.map { id -> CommandSegment in
            let s = segments[id]
            let m: CommandMachine = s.sendsTo.map { .remote(host: $0) } ?? baseMachine
            return CommandSegment(program: s.program, line: line(at: s.range.lowerBound), utf16Range: s.range, machine: m)
        }
        var assessment = CommandAssessment(commandClass: cls, flags: ordered, notes: orderedNotes(), segments: out,
                                           machine: machine, machineReason: machineReason, replyClaim: replyClaim,
                                           fetch: cls == .fetchFile ? fetch : nil, placeholder: placeholder,
                                           lineCount: lineCount, commandCount: out.count)
        var seen = Set<String>()
        assessment.localTargets = localTargets.filter { seen.insert($0).inserted }
        return assessment
    }

    /// The machine of the offer without rule 1 (what a segment that sends nothing elsewhere is for).
    var baseMachine: CommandMachine = .unclear

    func decideClass() -> CommandAssessment.Class {
        if flags.contains(where: { $0.rule.blocks }) { return .blocked }
        if case .remote = machine { return .otherMachine }
        if machine == .server { return .forServer }
        if placeholder != nil { return .needsEditing }
        if machine == .unclear { return .unclearMachine }
        if fetch != nil { return .fetchFile }
        if flags.contains(where: { !$0.rule.blocks }) { return .risky }
        return .notFlagged
    }

    static func order(_ rule: CommandRule) -> Int {
        switch rule {
        case .b1: return 0
        case .b2: return 1
        case .b5: return 2
        case .b6: return 3
        case .b3: return 4
        case .b4: return 5
        default: return 10 + (CommandRule.allCases.firstIndex(of: rule) ?? 0)
        }
    }

    private func orderedNotes() -> [CommandNote] {
        let order = CommandNote.Kind.allCases
        return notes.enumerated().sorted { a, b in
            let ia = a.element.kind == .readWeb ? -1 : (order.firstIndex(of: a.element.kind) ?? 0)
            let ib = b.element.kind == .readWeb ? -1 : (order.firstIndex(of: b.element.kind) ?? 0)
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)
    }
}
