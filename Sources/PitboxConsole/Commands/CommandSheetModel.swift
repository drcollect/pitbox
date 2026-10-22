import Foundation
import PitboxKit

/// What the sheet shows and which buttons it offers, from its state. Pure: the tests drive every class through it.
/// Pitbox's own words are host text; anything from the session (title, nickname, "You asked", caption, replies, paths
/// from the reply) is a `.session` part, drawn in quotes, in regular weight, on its own faint background, after
/// `CommandPlainText` escaped it.
struct CommandSheetModel: Equatable {
    /// One piece of a line.
    enum Part: Equatable {
        /// Pitbox's words.
        case host(String)
        /// Session text, already through the renderer: drawn quoted.
        case session(String)
        /// Pitbox's words, quieter.
        case dim(String)
        /// A path or command in Pitbox's words, monospaced.
        case mono(String)
        /// A warning in Pitbox's words (amber).
        case warning(String)
    }

    struct Row: Equatable {
        var label: String
        var lines: [[Part]]
    }

    /// One red line with its tick box.
    struct RedLine: Equatable {
        var key: String
        var words: String
        /// "(line 2)", or nil for whole-text red lines (R20, R22).
        var lineLabel: String?
        var ticked: Bool
    }

    enum ButtonState: Equatable {
        case hidden
        /// Shown, but off; the reason (shown on the status line or as the button's help).
        case off(String?)
        case on

        var isOn: Bool { self == .on }
        var isShown: Bool { self != .hidden }
    }

    struct Button: Equatable {
        var title: String
        var state: ButtonState
    }

    /// A disclosure below the command area.
    struct Section: Equatable {
        var disclosure: CommandSheetState.Disclosure
        var title: String
        var isOpen: Bool
        /// The label above the content ("session text: treat it as untrusted, like the command").
        var caption: String?
        var lines: [[Part]]
    }

    var title: String
    /// First lines of the body (the Fetch file warning of "Run in terminal instead").
    var warnings: [String]
    var rows: [Row]
    /// The Check row (nil: none, a Fetch file sheet without red lines).
    var checkText: String?
    var redLines: [RedLine]
    /// The line above the command area ("From the reply, command 1 as it was written:" on the Fetch file sheet; "A file
    /// from the session:" above the path of a result fetch).
    var commandCaption: String?
    /// The command area with the exact text: every offer's sheet; never a result fetch, which has no command text.
    var showsCommandArea: Bool
    /// A result fetch's path under `commandCaption`, as session text; empty for an offer's sheet.
    var sourceLines: [[Part]]
    /// The R22 facts in Pitbox's words ("Since then: read web pages · edited 3 files (…)").
    var sinceLine: String?
    var notes: [String]
    var sections: [Section]
    var footer: String?
    /// Unclear machine: "Run on: [This Mac] [The server]".
    var showsMachinePicker: Bool
    var machinePick: CommandSheetState.MachinePick?
    /// Fetch: the "Log in as" choice, the two users and which is picked.
    struct LoginChoice: Equatable {
        var config: String
        var reply: String
        var picked: String
    }
    var loginChoice: LoginChoice?
    var message: CommandSheetState.Message?
    var run: Button
    var type: Button
    var copy: Button
    var copyCleaned: Button
    var server: Button
    var fetch: Button
    var runInstead: Button
    var showInFinder: Button
    /// Open (a document) or Preview (a web document) after a saved fetch; hidden otherwise.
    var openFetched: Button
    var cancel: Button
    /// Run is the risky kind (any red line): 2 s arming after the last tick, and the scroll rule (the bottom of
    /// the command area seen once).
    var isRisky: Bool
    /// The cleaned text and its marks, for Copy cleaned (B1): shown in full before it can be copied.
    struct Cleaned: Equatable {
        var text: String
        /// UTF-16 offsets in `text` where hidden characters were removed.
        var marks: [Int]
        var removed: Int
    }
    var cleaned: Cleaned?

    // MARK: Rules

    /// The words of R22: what followed, never "read its newest reply first".
    static func r22Words(_ supersession: CommandOffer.Supersession?) -> String {
        let tail = "The command text is unchanged; what it runs against may not be."
        guard let s = supersession else { return "The session has moved on since this command. " + tail }
        var parts: [String] = []
        if s.unansweredMessageHead != nil {
            parts.append("You sent the session a new message after this command (\(CommandTimeFormat.clock(s.latestAt))); it has not replied yet.")
        }
        let replies = s.newerReplies + s.newerBackgroundUpdates
        if replies > 0 {
            let noun = replies == 1 ? "1 newer reply" : "\(replies) newer replies"
            let latest = s.replies.last?.at ?? s.latestAt
            parts.append("The session has moved on since this command (\(noun), latest \(CommandTimeFormat.clock(latest))).")
        } else if s.unansweredMessageHead == nil {
            if s.sessionIsWorking {
                // A background or peer turn running, or an SSH mirror that shows nothing newer yet.
                parts.append("The session is working on a newer turn right now (since \(CommandTimeFormat.clock(s.latestAt))); its reply is not in yet.")
            } else {
                parts.append("The session has moved on since this command (latest \(CommandTimeFormat.clock(s.latestAt))).")
            }
        }
        parts.append(tail)
        return parts.joined(separator: " ")
    }

    /// Whether R22's own words already say the session is working (then the separate note is left out).
    static func r22SaysWorking(_ s: CommandOffer.Supersession) -> Bool {
        s.sessionIsWorking && s.unansweredMessageHead == nil && s.newerReplies + s.newerBackgroundUpdates == 0
    }

    /// What the user saw of a supersession on the sheet: R22's words, the facts line, the newer replies and their new
    /// message. A click proceeds under R22 only when the session side still finds exactly this.
    static func r22Digest(_ s: CommandOffer.Supersession?) -> String {
        guard let s else { return r22Words(nil) }
        var parts = [r22Words(s), sinceLine(s) ?? "", s.unansweredMessageHead ?? "", s.sessionIsWorking ? "working" : "idle"]
        parts += s.replies.map { "\(CommandTimeFormat.clock($0.at))|\($0.origin.rawValue)|\($0.head)" }
        return parts.joined(separator: "\u{1}")
    }

    /// The host facts since the offer's reply: "Since then: read web pages · edited 3 files (release.sh, …) · 2
    /// background tasks finished". File names are session data: escaped, cut, at most 3 shown.
    static func sinceLine(_ s: CommandOffer.Supersession) -> String? {
        var parts: [String] = []
        if s.readWebSince { parts.append("read web pages") }
        let count = max(s.filesChangedCount, s.filesChangedSince.count)
        if count > 0 {
            let names = s.filesChangedSince.prefix(3).map { CommandPlainText.singleLine($0, maxCharacters: 40) }
            let more = count > names.count ? ", …" : ""
            parts.append("edited \(count == 1 ? "1 file" : "\(count) files") (\(names.joined(separator: ", "))\(more))")
        }
        if s.backgroundTasksFinishedSince > 0 {
            let n = s.backgroundTasksFinishedSince
            parts.append(n == 1 ? "1 background task finished" : "\(n) background tasks finished")
        }
        return parts.isEmpty ? nil : "Since then: " + parts.joined(separator: " · ")
    }

    /// The red line R22, as the sheet adds it (never the classifier).
    static func r22Flag(_ supersession: CommandOffer.Supersession?) -> CommandFlag {
        CommandFlag(rule: .r22, words: r22Words(supersession), line: 0, utf16Range: 0..<0, segment: nil)
    }

    /// A red line's identity, so a tick survives a re-assessment that keeps the same line.
    static func key(of flag: CommandFlag) -> String {
        flag.rule == .r22 ? "R22" : "\(flag.rule.rawValue)|\(flag.line)|\(flag.utf16Range.lowerBound)-\(flag.utf16Range.upperBound)|\(flag.words)"
    }

    /// The red lines needing a tick: the assessment's R1-R21, then R22 when anything followed the reply.
    static func redLines(_ state: CommandSheetState) -> [CommandFlag] {
        var lines = state.assessment.redLines.filter { $0.rule != .r22 }
        if state.supersession != nil || state.supersededWithoutDetails { lines.append(r22Flag(state.supersession)) }
        return lines
    }

    /// Who started the turn, in Pitbox's words, for "You asked" and the newer replies.
    static func originWords(_ origin: CommandTurnOrigin) -> String {
        switch origin {
        case .human: return "started by you"
        case .taskNotification: return "started by a background task"
        case .peer: return "started by another session"
        case .unknown: return "\(AppIdentity.displayName) couldn't tell who started it"
        }
    }

    // MARK: Building

    init(_ state: CommandSheetState, now: TimeInterval, home: String, userName: String) {
        switch state.subject {
        case .offer(let offer):
            self.init(offer: offer, state: state, now: now, home: home, userName: userName)
        case .resultFetch(let subject):
            self.init(resultFetch: subject, state: state, now: now, home: home)
        }
    }

    /// An offer's sheet: the ordinary sheet or the Fetch file sheet of a `fetchFile` offer.
    private init(offer: CommandOffer, state: CommandSheetState, now: TimeInterval, home: String, userName: String) {
        let assessment = state.assessment
        let facts = offer.context.facts
        let flags = assessment.flags
        let blockRules = Set(flags.filter { $0.rule.blocks }.map(\.rule))
        let blocked = !blockRules.isEmpty || assessment.commandClass == .blocked
        let partly = !offer.replyReadCompletely
        let lines = Self.redLines(state)
        isRisky = assessment.commandClass == .risky || !lines.isEmpty
        let fetchMode = state.mode == .fetch
        let fromFetch = state.mode == .ordinary(fromFetch: true)

        // The machine: Unclear needs the user's pick.
        let unclear = assessment.machine == .unclear
        var machine = assessment.machine
        if unclear, let pick = state.machinePick { machine = pick == .thisMac ? .thisMac : .server }
        machinePick = state.machinePick

        // The class, with the sheet's own facts: partly read is the sheet's to apply.
        var cls = assessment.commandClass
        if blocked { cls = .blocked } else if partly { cls = .partlyRead }
        if cls == .fetchFile, !fetchMode { cls = lines.isEmpty ? .notFlagged : .risky }
        if cls == .unclearMachine, machine == .thisMac { cls = lines.isEmpty ? .notFlagged : .risky }
        if cls == .unclearMachine, machine == .server { cls = .forServer }
        let runnableClass = [.notFlagged, .risky].contains(cls)
        let typableClass = runnableClass || cls == .needsEditing
        // A session working on an external or network volume: none of its commands runs or is typed here, whatever the
        // machine (no pick is offered); Copy stays (docs/THREAT_MODEL.md, T33).
        let onRefusedVolume = !fetchMode && (state.workFolderRefused || Self.worksOnRefusedVolume(facts))
        let refusedVolume = onRefusedVolume && (typableClass || cls == .unclearMachine)
        showsMachinePicker = unclear && !fetchMode && !onRefusedVolume
        // With `commands: copyOnly` there is no Run button at all; Copy and Type into terminal stay.
        let runOff = state.runPolicy == .copyOnly

        // Title, warnings.
        if fetchMode {
            title = Self.fetchTitle(alias: offer.context.facts.sshAlias)
        } else {
            title = "Run a command from Code"
        }
        warnings = fromFetch ? ["This skips Fetch file's protections: it may replace a file, and nothing is quarantined."] : []

        // Rows.
        var rows: [Row] = []
        rows.append(Row(label: "From", lines: [Self.fromLine(offer.source, time: "reply")]))
        rows.append(Row(label: "You asked", lines: [Self.askedLine(offer)]))
        if !fetchMode, let caption = offer.caption, !caption.isEmpty {
            rows.append(Row(label: "Said", lines: [[.session(CommandPlainText.render(caption, maxLines: 2, maxCharacters: 400))]]))
        }
        if fetchMode {
            rows += Self.fetchRows(state, home: home)
        } else {
            rows.append(Row(label: "Session", lines: [[.host(Self.sessionPlace(facts, onRefusedVolume: onRefusedVolume))]]))
            let runsOn: [[Part]] = onRefusedVolume && cls != .otherMachine ? [[.warning(Self.refusedVolumeRunsOnWords)]]
                : Self.runsOnLines(state, machine: machine, cls: cls, userName: userName)
            rows.append(Row(label: "Runs on", lines: runsOn))
            // The folder a run or Type would start in, always named; when it is not the session's own, said why.
            var folderLines: [[Part]] = [[.host(state.folder.shortPath), .dim("   (\(state.folder.path))")]]
            if state.folder.isHomeFallback {
                folderLines.append([.warning("the session's folder doesn't exist here: runs in ~")])
            } else if facts.place == .unknown, !onRefusedVolume {
                folderLines.append([.warning(Self.unknownPlaceFolderWords(state.folder.shortPath))])
            }
            if let problem = state.folder.problem { folderLines.append([.warning(problem)]) }
            rows.append(Row(label: "Folder", lines: folderLines))
            rows.append(Row(label: "Command", lines: [[.host(Self.commandSummary(offer, assessment))]]))
            let connects = assessment.notes.filter { $0.kind == .connects }.map(\.words)
            if !connects.isEmpty { rows.append(Row(label: "Connects to", lines: connects.map { [.host($0)] })) }
        }
        self.rows = rows

        // Check and red lines.
        let blockWords = flags.filter { $0.rule.blocks }.map(\.words)
        switch cls {
        case _ where refusedVolume:
            checkText = Self.refusedVolumeWords
        case .blocked:
            checkText = "Blocked: " + (blockWords.isEmpty ? "\(AppIdentity.displayName) can't read this shell syntax; use Copy" : blockWords.joined(separator: " · "))
        case .partlyRead:
            checkText = "\(AppIdentity.displayName) couldn't read the whole reply. Copy only."
        case .forServer:
            checkText = "For the server: \(AppIdentity.displayName) doesn't run commands there. Copy it, or open a terminal on the server."
        case .otherMachine:
            checkText = "It sends a command to another machine: \(AppIdentity.displayName) doesn't run those. Copy it, or open a terminal there."
        case .needsEditing:
            checkText = "Needs editing: fill in \(assessment.placeholder ?? "the placeholder") first. Type into terminal puts it at a prompt to edit."
        default:
            if lines.isEmpty {
                checkText = fetchMode ? nil
                    : "No known risky pattern. \(AppIdentity.displayName) cannot tell what a program does: this runs with your rights."
            } else {
                let armed = fetchMode ? "Fetch file" : (runOff ? "Type into terminal" : "Run")
                checkText = lines.count == 1 ? "1 red line. Tick it to arm \(armed)."
                    : "\(lines.count) red lines. Tick each one to arm \(armed)."
            }
        }
        let showsTicks = !blocked && !partly && cls != .forServer && cls != .otherMachine && !refusedVolume
        // The words are Pitbox's, but can quote a path or host from the text: escaped like session text.
        redLines = showsTicks ? lines.map { flag in
            RedLine(key: Self.key(of: flag), words: CommandPlainText.singleLine(flag.words, maxCharacters: 600),
                    lineLabel: flag.line > 0 ? "line \(flag.line)" : nil, ticked: state.ticked.contains(Self.key(of: flag)))
        } : []
        commandCaption = fetchMode ? "From the reply, command \(offer.id.number) as it was written:" : nil
        showsCommandArea = true
        sourceLines = []
        sinceLine = state.supersession.flatMap(Self.sinceLine)
        notes = Self.notes(state, offer: offer, setuid: state.setuidPrograms)
        sections = Self.sections(state, replyText: offer.replyText)

        // The footer: what Run does, or that Run is off and how to turn it on.
        if refusedVolume {
            footer = nil
        } else if runOff, !fetchMode, runnableClass || cls == .unclearMachine {
            footer = Self.runOffWords
        } else if runnableClass, !fetchMode {
            let tab = CommandTabOrigin(headline: offer.source.headline, profileName: nil, machineLabel: "", folderShort: "",
                                       replyTime: nil, offer: nil).tabTitle
            footer = "Runs once, in a new tab “\(tab)” of the console. Your keyboard stays where it is; click the terminal to type."
        } else if fetchMode {
            footer = "\(AppIdentity.displayName) copies the file itself; it never replaces a file, and the copy is marked as downloaded."
        } else {
            footer = nil
        }

        // Gates shared by Run, Type and Fetch, in the order their reason is shown.
        let allTicked = lines.allSatisfy { state.ticked.contains(Self.key(of: $0)) }
        var gate: String?
        if state.consumed { gate = "This sheet's approval is used: open the command again to review it." }
        else if state.stale { gate = "The session has moved on: this is from an older reply." }
        else if !state.assessmentReady { gate = "Checking the files this command writes…" }
        else if state.checking { gate = "Checking the session…" }
        else if !allTicked { gate = lines.count == 1 ? "Tick the red line first." : "Tick each red line first." }
        else if isRisky, !state.scrolledToEnd { gate = "Scroll to the end of the command first." }
        let pickGate = unclear && state.machinePick == nil ? "Pick This Mac or The server first." : nil
        let runGate: String? = gate ?? state.folder.problem ?? state.terminalBlocker ?? pickGate
        let typeGateBase: String? = gate ?? state.folder.problem ?? state.typeBlocker ?? pickGate

        // Buttons by class.
        if fetchMode {
            run = Button(title: "Yes, run this", state: .hidden)
            type = Button(title: "Type into terminal (don't run)", state: .hidden)
        } else {
            let runTitle = isRisky ? "Yes, run this risky command" : "Yes, run this"
            if runOff {
                run = Button(title: runTitle, state: .hidden)
            } else if refusedVolume {
                run = Button(title: runTitle, state: .off(Self.refusedVolumeWords))
            } else if runnableClass {
                run = Button(title: runTitle, state: runGate == nil && machine == .thisMac ? .on : .off(runGate))
            } else if cls == .unclearMachine {
                run = Button(title: runTitle, state: .off(runGate))
            } else {
                run = Button(title: runTitle, state: .hidden)
            }
            if refusedVolume {
                type = Button(title: "Type into terminal (don't run)", state: .off(Self.refusedVolumeWords))
            } else if typableClass || cls == .unclearMachine {
                let typeGate = typeGateBase ?? (state.typedText == nil ? "your zsh has interactive comments off: use Copy" : nil)
                type = Button(title: "Type into terminal (don't run)", state: typeGate == nil && machine == .thisMac ? .on : .off(typeGate))
            } else {
                type = Button(title: "Type into terminal (don't run)", state: .hidden)
            }
        }
        // Copy and Copy cleaned follow the classifier's own rule (B1, B2 and B5 forbid copying as it is; B1 offers the
        // cleaned text unless B2 or B5 forbids that too).
        let hasB1 = blockRules.contains(.b1)
        let copiedNow = (state.copiedUntil ?? -1) > now
        copy = Button(title: copiedNow ? "Copied" : (fetchMode ? "Copy command" : "Copy"),
                      state: assessment.copyAllowed ? .on : (hasB1 ? .hidden : .off("This text can't be copied as it is.")))
        if hasB1 {
            copyCleaned = Button(title: (state.copiedCleanedUntil ?? -1) > now ? "Copied" : "Copy cleaned",
                                 state: assessment.offersCopyCleaned ? .on : .off("This text can't be copied, not even cleaned."))
            let result = CommandHiddenCharacters.cleaned(offer.text)
            cleaned = Cleaned(text: result.text, marks: result.marks, removed: result.removed)
        } else {
            copyCleaned = Button(title: "Copy cleaned", state: .hidden)
            cleaned = nil
        }
        // "Open a terminal on <host>" for the server classes, once the alias is an exact Host token.
        if !fetchMode, cls == .forServer || cls == .otherMachine {
            let host: String?
            switch assessment.machine {
            case .remote(let remote): host = remote
            default: host = facts.sshAlias
            }
            let shown = state.serverAlias ?? host ?? "the server"
            let opened = (state.openedServerUntil ?? -1) > now
            server = Button(title: opened ? "Opened" : "Open a terminal on \(shown)",
                            state: state.serverAlias == nil ? .off("That server isn't an exact entry in your SSH config.")
                                : (state.terminalBlocker.map { .off($0) } ?? .on))
        } else {
            server = Button(title: "Open a terminal", state: .hidden)
        }
        // Fetch file.
        if fetchMode, let fetchState = state.fetch {
            // "Run in terminal instead" leads to a Run button: not offered while Run is off (Copy command stays here).
            let controls = Self.fetchControls(fetchState, gate: gate ?? (partly ? "\(AppIdentity.displayName) couldn't read the whole reply." : nil),
                                              offersRunInstead: !runOff)
            fetch = controls.fetch
            runInstead = controls.runInstead
            showInFinder = controls.showInFinder
            openFetched = controls.openFetched
            cancel = controls.cancel
            loginChoice = controls.loginChoice
        } else {
            fetch = Button(title: "Fetch file", state: .hidden)
            runInstead = Button(title: "Run in terminal instead", state: .hidden)
            showInFinder = Button(title: "Show in Finder", state: .hidden)
            openFetched = Button(title: "Open", state: .hidden)
            cancel = Button(title: "Cancel", state: .on)
            loginChoice = nil
        }

        // The status line: the last click's word first, then why things are off.
        if let explicit = state.message {
            message = explicit
        } else if state.stale {
            message = .init(text: "The session has moved on: this is from an older reply.", tone: .warning)
        } else if !fetchMode, !runOff, !refusedVolume, runnableClass || cls == .unclearMachine || cls == .needsEditing,
                  let blocker = state.terminalBlocker {
            message = .init(text: blocker, tone: .info)
        } else if case .off(let reason?) = fetchMode ? fetch.state : (run.state.isShown ? run.state : type.state) {
            message = .init(text: reason, tone: .info)
        } else {
            message = nil
        }
    }

    /// A result fetch: the Fetch file sheet for a file a session handed over or wrote on the
    /// server. No command text, so no command area, no "From the reply" block, no Copy command and no "Run in terminal
    /// instead"; the file, the server, the login user (the config's), the destination and the limits, and the path
    /// under "A file from the session:". The same arming and click-time gates as an offer's Fetch file.
    private init(resultFetch subject: ResultFetchSubject, state: CommandSheetState, now: TimeInterval, home: String) {
        title = Self.fetchTitle(alias: subject.request.alias)
        warnings = []
        rows = [Row(label: "From", lines: [Self.fromLine(subject.source, time: nil)])] + Self.fetchRows(state, home: home)
        checkText = nil
        redLines = []
        isRisky = false
        // Until the request says which tool_use kind it came from (a future `FetchFileRequest.sourceKind`),
        // host words of the sheet's own; never a guess at "handed you" or "wrote".
        commandCaption = "A file from the session:"
        showsCommandArea = false
        sourceLines = [[.session(CommandPlainText.render(subject.request.remotePath, maxLines: 4, maxCharacters: 1_100))]]
        sinceLine = nil
        notes = []
        sections = Self.sections(state, replyText: nil)
        footer = "\(AppIdentity.displayName) copies the file itself; it never replaces a file, and the copy is marked as downloaded."
        showsMachinePicker = false
        machinePick = nil
        cleaned = nil

        var gate: String?
        if state.stale { gate = Self.resultStaleWords }
        else if state.checking { gate = "Checking the session…" }
        run = Button(title: "Yes, run this", state: .hidden)
        type = Button(title: "Type into terminal (don't run)", state: .hidden)
        copy = Button(title: "Copy command", state: .hidden)
        copyCleaned = Button(title: "Copy cleaned", state: .hidden)
        server = Button(title: "Open a terminal", state: .hidden)
        let controls = Self.fetchControls(state.fetch ?? CommandSheetState.Fetch(), gate: gate, offersRunInstead: false)
        fetch = controls.fetch
        runInstead = controls.runInstead
        showInFinder = controls.showInFinder
        openFetched = controls.openFetched
        cancel = controls.cancel
        // The configured login user only: there is no reply to name another one.
        loginChoice = nil

        if let explicit = state.message {
            message = explicit
        } else if state.stale {
            message = .init(text: Self.resultStaleWords, tone: .warning)
        } else if case .off(let reason?) = fetch.state {
            message = .init(text: reason, tone: .info)
        } else {
            message = nil
        }
    }

    /// The one line a sheet shows while Run is off: what is off and how to turn it on.
    static let runOffWords = "Run is off. To allow it, set \"commands\": \"run\" in the settings file."

    /// Why Run and Type are off for every command of a session working on an external or network volume (the Check row
    /// and both buttons' reason).
    static let refusedVolumeWords = "This session works on an external or network volume: \(AppIdentity.displayName) does not run its commands. Copy them instead."
    /// The Runs on row of such a session's command.
    static let refusedVolumeRunsOnWords = "nowhere: \(AppIdentity.displayName) does not run this session's commands"
    /// The Folder row's line under such a session's folder (shown, never looked up or bound).
    static let refusedVolumeFolderWords = "an external or network volume: nothing runs here"

    /// The Folder row's line for a session whose place is unknown: the command starts in `shortPath` (the home folder),
    /// not in a folder of the session's.
    static func unknownPlaceFolderWords(_ shortPath: String) -> String {
        "\(AppIdentity.displayName) couldn't tell where this session works: runs in \(shortPath)"
    }

    /// A session that works on this Mac in a folder on an external or network volume (`refusedLocalCwd`): none of its
    /// commands runs or is typed, only copied. Never an SSH session.
    static func worksOnRefusedVolume(_ facts: CommandSessionFacts) -> Bool {
        facts.place != .ssh && facts.refusedLocalCwd != nil
    }

    /// Why a result fetch is off for good: the click-time check no longer finds the file in the session's work.
    static let resultStaleWords = "The session has moved on: this file is not in its latest work any more."

    // MARK: Pieces

    /// "Fetch a file from buildbox": the alias as plain text.
    private static func fetchTitle(alias: String?) -> String {
        "Fetch a file from " + (alias.map { CommandPlainText.singleLine($0, maxCharacters: 64) } ?? "the server")
    }

    /// Fetch file and the buttons around it: Fetch file by phase (`gate` holds it off while
    /// planned), "Run in terminal instead" (an offer's only), Open or Preview and Show in Finder after a save, Cancel,
    /// and the "Log in as" choice when the config's and the reply's users differ.
    private static func fetchControls(_ fetchState: CommandSheetState.Fetch, gate: String?, offersRunInstead: Bool)
        -> (fetch: Button, runInstead: Button, showInFinder: Button, openFetched: Button, cancel: Button, loginChoice: LoginChoice?) {
        let fetch: Button
        switch fetchState.phase {
        case .planning:
            fetch = Button(title: "Fetch file", state: .off("Reading your SSH config…"))
        case .planned:
            fetch = Button(title: "Fetch file", state: gate == nil ? .on : .off(gate))
        case .refused(let reason):
            fetch = Button(title: "Fetch file", state: .off(reason))
        case .fetching:
            fetch = Button(title: "Fetching…", state: .off(nil))
        case .done:
            fetch = Button(title: "Fetch file", state: .hidden)
        }
        let busy: Bool
        switch fetchState.phase {
        case .fetching, .done: busy = true
        default: busy = false
        }
        let runInstead = Button(title: "Run in terminal instead", state: offersRunInstead && !busy ? .on : .hidden)
        let showInFinder: Button
        let openFetched: Button
        if case .done(.saved) = fetchState.phase {
            showInFinder = Button(title: "Show in Finder", state: .on)
            switch fetchState.opening {
            case .open: openFetched = Button(title: "Open", state: .on)
            case .preview: openFetched = Button(title: "Preview", state: .on)
            case .showInFinderOnly: openFetched = Button(title: "Open", state: .hidden)
            }
        } else {
            showInFinder = Button(title: "Show in Finder", state: .hidden)
            openFetched = Button(title: "Open", state: .hidden)
        }
        let cancel: Button
        if case .fetching = fetchState.phase {
            cancel = Button(title: "Cancel fetch", state: .on)
        } else if case .done = fetchState.phase {
            cancel = Button(title: "Close", state: .on)
        } else {
            cancel = Button(title: "Cancel", state: .on)
        }
        var loginChoice: LoginChoice?
        if let config = fetchState.configUser, let reply = fetchState.replyUser, config != reply {
            loginChoice = LoginChoice(config: config, reply: reply, picked: fetchState.chosenUser ?? config)
        }
        return (fetch, runInstead, showInFinder, openFetched, cancel, loginChoice)
    }

    /// The session's "From" line: headline, nickname, the copy, and `time` ("reply 14:02") or just the time.
    private static func fromLine(_ source: CommandOffer.Source, time: String?) -> [Part] {
        var parts: [Part] = [.session(CommandPlainText.singleLine(source.headline, maxCharacters: 80))]
        if let nickname = source.nickname, !nickname.isEmpty {
            parts.append(.host(" "))
            parts.append(.session(CommandPlainText.singleLine(nickname, maxCharacters: 40)))
        }
        if let profile = source.profileName { parts.append(.host(" · " + SessionTitle.clean(profile, limit: 24))) }
        let clock = CommandTimeFormat.clock(source.replyTime)
        parts.append(.host(" · " + (time.map { "\($0) \(clock)" } ?? clock)))
        return parts
    }

    private static func askedLine(_ offer: CommandOffer) -> [Part] {
        switch offer.context.facts.turnOrigin {
        case .taskNotification: return [.warning("No message from you started this turn: a background task did")]
        case .peer: return [.warning("No message from you started this turn: another session did")]
        case .unknown: return [.warning("\(AppIdentity.displayName) couldn't tell whether you started this turn")]
        case .human:
            guard let asked = offer.source.youAsked, !asked.isEmpty else { return [.dim("(no text)")] }
            return [.session(CommandPlainText.render(asked, maxLines: 2, maxCharacters: 400))]
        }
    }

    private static func sessionPlace(_ facts: CommandSessionFacts, onRefusedVolume: Bool) -> String {
        if onRefusedVolume, facts.place != .ssh { return "works on an external or network volume" }
        switch facts.place {
        case .local: return "runs on this Mac"
        case .ssh: return "runs on \(facts.sshAlias ?? "a server") (SSH)"
        case .unknown: return "\(AppIdentity.displayName) couldn't tell where it runs"
        }
    }

    private static func runsOnLines(_ state: CommandSheetState, machine: CommandMachine, cls: CommandAssessment.Class,
                                    userName: String) -> [[Part]] {
        var lines: [[Part]] = []
        switch machine {
        case .thisMac:
            let shell = state.shell == .clean ? "in a clean /bin/zsh (no startup files)" : "in your usual zsh (your startup files run first)"
            lines.append([.host("this Mac, as \(userName), \(shell)")])
        case .server:
            lines.append([.host("the server: \(AppIdentity.displayName) doesn't run it there")])
        case .remote(let host):
            lines.append([.host("it sends a command to "), .mono(CommandPlainText.singleLine(host, maxCharacters: 64)),
                          .host(": not run from here")])
        case .unclear:
            lines.append([.warning("unclear: pick This Mac or The server below")])
        }
        if !state.assessment.machineReason.isEmpty { lines.append([.dim(state.assessment.machineReason)]) }
        if let claim = state.assessment.replyClaim, !claim.isEmpty {
            lines.append([.dim("The reply says: "), .session(CommandPlainText.singleLine(claim, maxCharacters: 80))])
        }
        return lines
    }

    private static func commandSummary(_ offer: CommandOffer, _ assessment: CommandAssessment) -> String {
        let lineWord = assessment.lineCount == 1 ? "1 line" : "\(assessment.lineCount) lines"
        let commandWord = assessment.commandCount == 1 ? "1 command" : "\(assessment.commandCount) commands"
        var text = "\(offer.id.number) of \(offer.total) · \(lineWord) · \(commandWord)"
        if offer.blockKind == .untagged { text += " · untagged block, read as a command" }
        return text
    }

    private static func fetchRows(_ state: CommandSheetState, home: String) -> [Row] {
        guard let fetch = state.fetch else { return [] }
        var rows: [Row] = []
        let plan: FetchPlan?
        switch fetch.phase {
        case .planned(let p), .fetching(let p, _): plan = p
        default: plan = nil
        }
        if let plan {
            let ext = (plan.fileName as NSString).pathExtension
            rows.append(Row(label: "File", lines: [[.session(CommandPlainText.singleLine(plan.fileName, maxCharacters: 120)),
                                                    .dim(ext.isEmpty ? "   (no extension)" : "   (ends in .\(ext))")]]))
            var server: [[Part]] = [[.host("\(plan.alias) (your ~/.ssh/config); its host key must be known")]]
            if let proxy = plan.proxyNote { server.append([.warning(proxy)]) }
            rows.append(Row(label: "Server", lines: server))
            if !(fetch.configUser != nil && fetch.replyUser != nil && fetch.configUser != fetch.replyUser) {
                rows.append(Row(label: "Log in as", lines: [[.host("\(plan.loginUser) (your config)")]]))
            }
            rows.append(Row(label: "Path", lines: [[.session(CommandPlainText.render(plan.remotePath, maxLines: 4, maxCharacters: 1_100))]]))
            rows.append(Row(label: "Into", lines: [[.mono("~/Downloads/" + CommandPlainText.singleLine(plan.previewName, maxCharacters: 120)),
                                                    .dim("   (a free name; nothing is replaced)")]]))
            rows.append(Row(label: "Limits", lines: [[.host("up to 500 MB and 10 minutes")]]))
            rows.append(Row(label: "Note", lines: [[.host("the bytes come from the server: open them only if you trust it")]]))
            let shown = Self.scpShown(plan.arguments, open: state.open.contains(.moreOptions))
            rows.append(Row(label: "Runs", lines: shown.map { [.mono($0)] }))
        } else if case .refused(let reason) = fetch.phase {
            rows.append(Row(label: "Fetch", lines: [[.warning(reason)]]))
        } else if case .planning = fetch.phase {
            rows.append(Row(label: "Fetch", lines: [[.dim("Reading your SSH config…")]]))
        }
        if case .fetching(_, let bytes) = fetch.phase {
            rows.append(Row(label: "Progress", lines: [[.host("copying… \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")]]))
        }
        if case .done(let outcome) = fetch.phase {
            switch outcome {
            case .saved(let name, let bytes):
                rows.append(Row(label: "Fetched", lines: [[.mono(CommandPlainText.singleLine(name, maxCharacters: 120)),
                                                          .host(" · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))]]))
            case .failed(let reason):
                rows.append(Row(label: "Not fetched", lines: [[.warning(reason)]]))
            case .cancelled:
                rows.append(Row(label: "Not fetched", lines: [[.host("cancelled: nothing was saved")]]))
            }
        }
        return rows
    }

    /// scp's options that take a value (scp(1)): `-o BatchMode=yes` is one option, shown and counted together.
    static let scpOptionsWithValue: Set<String> = ["-c", "-D", "-F", "-i", "-J", "-l", "-o", "-P", "-S", "-X"]

    /// The scp command as the sheet shows it: the program and its first three options, the count of the rest
    /// (shown when "▸ The whole scp command" is open, which also lists every argument), then `--` and the operands.
    /// The operands always quoted, an option only when it holds more than letters, digits and `_-./:@%+=,`; all of it
    /// as plain text.
    static func scpShown(_ arguments: [String], open: Bool) -> [String] {
        let quoted = { (argument: String) in ShellQuote.quote(CommandPlainText.singleLine(argument, maxCharacters: 1_100)) }
        let shown = { (argument: String) -> String in
            let plain = !argument.isEmpty && argument.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-./:@%+=,".unicodeScalars.contains($0))
            }
            return plain ? argument : quoted(argument)
        }
        guard let separator = arguments.firstIndex(of: "--"), separator > 0 else { return [arguments.map(quoted).joined(separator: " ")] }
        var options: [String] = []
        var index = 1
        while index < separator {
            if scpOptionsWithValue.contains(arguments[index]), index + 1 < separator {
                options.append(shown(arguments[index]) + " " + shown(arguments[index + 1]))
                index += 2
            } else {
                options.append(shown(arguments[index]))
                index += 1
            }
        }
        let operands = arguments[(separator + 1)...].map(quoted)
        let rest = options.dropFirst(3)
        var lines = [([shown(arguments[0])] + options.prefix(3)).joined(separator: " ")]
        if !rest.isEmpty {
            lines.append(open ? "  " + rest.joined(separator: " ")
                              : "  (\(rest.count) more option\(rest.count == 1 ? "" : "s"), ▸ The whole scp command)")
        }
        lines.append("  -- " + operands.joined(separator: " "))
        return lines
    }

    private static func notes(_ state: CommandSheetState, offer: CommandOffer, setuid: [String]) -> [String] {
        var first: [String] = []
        var rest: [String] = []
        for note in state.assessment.notes where note.kind != .connects {
            if note.kind == .readWeb { first.append(note.words) } else { rest.append(note.words) }
        }
        if let s = state.supersession {
            if s.readWebSince { first.append("The session read web pages since this command's reply") }
            if s.sessionIsWorking, !r22SaysWorking(s) { rest.insert("The session is working on a newer turn right now.", at: 0) }
        }
        if offer.blockKind == .untagged, !rest.contains(where: { $0.lowercased().contains("untagged") }) {
            rest.append("Untagged block, read as a command")
        }
        if !offer.replyReadCompletely, state.assessment.commandClass == .blocked || state.assessment.flags.contains(where: { $0.rule.blocks }) {
            rest.insert("\(AppIdentity.displayName) couldn't read the whole reply either.", at: 0)
        }
        for program in setuid {
            rest.append("\(program) can't start inside the command sandbox (macOS refuses setuid programs there): it will fail with “operation not permitted”. Use Copy and run it in your own terminal.")
        }
        if state.mode != .fetch {
            switch state.shell {
            case .clean:
                if !state.assessment.notes.contains(where: { $0.kind == .cleanShell }) {
                    rest.append("Runs in the clean shell: your aliases and ~/.zshrc are not used")
                }
            case .login:
                rest.append("Your startup files run first and can change what this command does.")
                if state.typedText != nil, state.typedText != offer.text {
                    rest.append("Type into terminal leaves out the full-line comments: your zsh has interactive comments off")
                }
            }
        }
        return first + rest
    }

    /// The disclosures: R22's newer replies and new message, "How it runs" (ordinary) or "The whole scp command"
    /// (Fetch file), and "The whole reply" when there is one (`replyText` nil for a result fetch).
    private static func sections(_ state: CommandSheetState, replyText: String?) -> [Section] {
        var sections: [Section] = []
        if let s = state.supersession {
            if let message = s.unansweredMessageHead {
                sections.append(Section(disclosure: .newMessage, title: "Your new message", isOpen: state.open.contains(.newMessage),
                                        caption: "your own text, as the session has it",
                                        lines: [[.session(CommandPlainText.render(message, maxLines: 2, maxCharacters: 400))]]))
            }
            if !s.replies.isEmpty {
                let lines = s.replies.map { reply -> [Part] in
                    [.dim("\(CommandTimeFormat.clock(reply.at)) · \(originWords(reply.origin)): "),
                     .session(CommandPlainText.render(reply.head, maxLines: 6, maxCharacters: 1_200))]
                }
                sections.append(Section(disclosure: .newerReplies, title: "Newer replies", isOpen: state.open.contains(.newerReplies),
                                        caption: "session text: it does not vouch for the command", lines: lines))
            }
        }
        if state.mode != .fetch {
            sections.append(Section(disclosure: .howItRuns, title: "How it runs", isOpen: state.open.contains(.howItRuns),
                                    caption: nil, lines: state.howItRuns))
        } else if let phase = state.fetch?.phase {
            let plan: FetchPlan?
            switch phase {
            case .planned(let p), .fetching(let p, _): plan = p
            default: plan = nil
            }
            if let plan {
                sections.append(Section(disclosure: .moreOptions, title: "The whole scp command", isOpen: state.open.contains(.moreOptions),
                                        caption: "exactly what \(AppIdentity.displayName) runs, one argument a line (no shell)",
                                        lines: plan.arguments.map { [.mono(ShellQuote.quote(CommandPlainText.singleLine($0, maxCharacters: 1_100)))] }))
            }
        }
        if let replyText {
            sections.append(Section(disclosure: .wholeReply, title: "The whole reply", isOpen: state.open.contains(.wholeReply),
                                    caption: "session text: treat it as untrusted, like the command",
                                    lines: [[.session(CommandPlainText.render(replyText, maxLines: 400, maxCharacters: 40_000))]]))
        }
        return sections
    }
}
