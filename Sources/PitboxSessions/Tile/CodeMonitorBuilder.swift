import Foundation
import PitboxKit

/// Turns sessions, window statuses and runs into what the block draws. Pure:
/// every rule here is unit-tested without views. Session text passes through `CodePlainText` exactly here.
enum CodeMonitorBuilder {
    struct Inputs {
        /// The monitors, already chosen, filtered and ordered.
        var sessions: [CodeSessionSnapshot]
        var statuses: [String: CodeWindowStatus]
        var runs: CodeOfferRunBook
        var hideText: Bool
        /// `showText` of the settings file: false hides that copy's text for good.
        var showText: [String: Bool]
        var showsProfiles: Bool
        var homeDirectory: String
        var now: Date
        /// `CodeSettings.commands`: with Run off (`copyOnly`, the default) the buttons that open the sheet say "Review…".
        var commands: CodeSettings.Commands = .copyOnly
    }

    // MARK: Which monitors, in which order

    /// A session gets a monitor when Claude has it in a pop-out or the app has a parked record (or a window closed
    /// while parked) for it: only popped-out and parked sessions get monitors.
    static func members(_ sessions: [CodeSessionSnapshot], parked: Set<String>) -> [CodeSessionSnapshot] {
        sessions.filter { $0.popout != nil || parked.contains($0.id) }
    }

    /// The fixed order: by copy (the default copy A, then the others by letter, then unknown) but only
    /// while more than one copy runs, then by when the block first saw the session, then by session id. Attention never
    /// moves a monitor.
    static func ordered(_ sessions: [CodeSessionSnapshot], firstSeen: [String: Int], byCopy: Bool) -> [CodeSessionSnapshot] {
        sessions.sorted { a, b in
            if byCopy {
                let ra = profileRank(a.profile), rb = profileRank(b.profile)
                if ra != rb { return ra < rb }
            }
            let fa = firstSeen[a.id] ?? Int.max, fb = firstSeen[b.id] ?? Int.max
            if fa != fb { return fa < fb }
            return a.id < b.id
        }
    }

    static func profileRank(_ profile: CodeProfile) -> Int { profile.rank }

    /// The block's focus (`MonitorFocus`): only while more than one copy runs, a focus shows the copies it lists, All
    /// every copy; with one copy every focus shows every session.
    static func passes(_ session: CodeSessionSnapshot, focus: MonitorFocus, severalCopies: Bool) -> Bool {
        focus.passes(session, severalCopies: severalCopies)
    }

    // MARK: Items

    static func items(_ inputs: Inputs) -> [CodeMonitorItem] {
        inputs.sessions.enumerated().map { offset, session in
            item(session, position: offset + 1, total: inputs.sessions.count, inputs: inputs)
        }
    }

    static func item(_ s: CodeSessionSnapshot, position: Int, total: Int, inputs: Inputs) -> CodeMonitorItem {
        let windowStatus = inputs.statuses[s.id]
        let hidden = inputs.hideText || inputs.showText[s.profile.letter] == false
        let headline = CodePlainText.line(s.headline, limit: 160) ?? CodePlainText.line(s.title, limit: 160) ?? "Untitled session"
        let quietOverlay = s.quietSince != nil && [.done, .doneNoSummary, .reviewReady].contains(s.state)
        let age = ageText(s, now: inputs.now, quiet: quietOverlay)
        let model = shortModel(s.model)
        let stateWord = CodePlainText.line(s.stateWord, limit: 40) ?? s.state.word
        let statusShort = [stateWord, age].compactMap { $0 }.joined(separator: " · ")
        let statusLine = [stateWord, age, model].compactMap { $0 }.joined(separator: " · ")
        let working = s.state == .working || s.state == .maybeNeedsYou
        let statusCompact = working ? [stateWord, model].compactMap { $0 }.joined(separator: " · ") : statusShort
        let offerLine = hidden ? nil : CodeOfferWords.line(offers: s.offers, run: inputs.runs.latest[s.id], now: inputs.now)
        let compact = compactLine(offers: hidden ? [] : s.offers, offerLine: offerLine, stateWord: stateWord)
        var progress: Double?
        if working, let todos = s.todos, todos.total > 0 { progress = Double(todos.done) / Double(todos.total) }
        var nowLine: String?
        if working {
            var parts: [String] = []
            if let now = CodePlainText.line(s.now, limit: 80) { parts.append(now) }
            if let todos = s.todos, todos.total > 0 { parts.append("\(todos.done)/\(todos.total) todos") }
            if !parts.isEmpty { nowLine = "Now: " + parts.joined(separator: " · ") }
        }
        var item = CodeMonitorItem(
            id: s.id, index: s.index, position: position, total: total, profileLetter: s.profile.letter, profileColour: s.profile.colour,
            profileLabel: inputs.showsProfiles ? s.profile.name : nil,
            headline: headline,
            nickname: hidden ? nil : CodePlainText.line(s.nickname, limit: 48),
            tldr: hidden ? nil : CodePlainText.line(s.tldr, limit: 400),
            now: hidden ? nil : nowLine,
            ask: hidden ? nil : CodePlainText.line(s.askLine, limit: 300),
            offer: offerLine,
            status: statusLine, statusShort: statusShort, statusCompact: statusCompact,
            compactLine: compact.text, compactTone: compact.tone, pip: hidden ? nil : pip(s.offers), progress: progress,
            stateWord: stateWord, state: s.state,
            chip: windowStatus?.chip(now: inputs.now) ?? "",
            chipIsProblem: windowStatus?.problem != nil,
            led: led(s.state), glow: glow(s.state), quiet: quietOverlay,
            busy: windowStatus?.busy != nil, click: windowStatus?.click ?? .none, tooltip: windowStatus?.tooltip,
            textHidden: hidden,
            peek: peek(s, headline: headline, stateLine: [stateWord, age, model, CodePlainText.line(s.effort, limit: 16),
                                                          CodePlainText.line(s.permissionMode, limit: 24)]
                        .compactMap { $0 }.joined(separator: " · "),
                       status: windowStatus, hidden: hidden, inputs: inputs))
        item.hasWarning = !s.warnings.isEmpty
        item.rowAction = hidden ? nil : rowAction(s.offers, line: offerLine, commands: inputs.commands)
        // Results and warnings: the result line only where no offer line stands (an offer and a run's result come
        // first); the warning line, short words and outline.
        item.resultLine = offerLine == nil ? CodeMonitorResultLine.make(s, textHidden: hidden) : nil
        item.warningLine = CodeMonitorWarningLine.make(s, now: inputs.now, textHidden: hidden)
        return item
    }

    /// A slim row's button: the words of the button that opens the one offer's sheet ("▶ Run…",
    /// "⤓ Fetch…", "Review…"), "▶ Run…" or "⤓ Fetch…" for several (they open the peek's list), "Review…" instead of
    /// "▶ Run…" while Run is off (`commands` copyOnly); nil while a command runs or its result shows, and without offers.
    static func rowAction(_ offers: [CodeOfferEntry], line: CodeOfferLine?, commands: CodeSettings.Commands) -> String? {
        guard let line, line.tone == .offer, let first = offers.first else { return nil }
        if offers.count == 1 { return CodeOfferWords.reviewTitle(first.assessment, commands: commands) }
        if offers.allSatisfy({ $0.assessment.commandClass == .fetchFile }) { return "⤓ Fetch…" }
        return commands == .run ? "▶ Run…" : "Review…"
    }

    // MARK: Words

    /// A small monitor's one line: a run's result, else "▶ 2" for commands or "⤓ 1" for files, else
    /// the state word.
    static func compactLine(offers: [CodeOfferEntry], offerLine: CodeOfferLine?, stateWord: String) -> (text: String, tone: CodeOfferLine.Tone?) {
        if let line = offerLine, line.tone != .offer {
            switch line.tone {
            case .running: return ("running…", .running)
            case .ok, .failed, .neutral: return (line.text.components(separatedBy: " · ").first ?? line.text, line.tone)
            case .offer: break
            }
        }
        let fetches = offers.filter { $0.assessment.commandClass == .fetchFile }.count
        let commands = offers.count - fetches
        if commands > 0 { return ("▶ \(commands)", .offer) }
        if fetches > 0 { return ("⤓ \(fetches)", .offer) }
        return (stateWord, nil)
    }

    /// The 18 pt badge on a small monitor's corner: ▶ for commands, ⤓ for files only; it opens what the offer line opens.
    static func pip(_ offers: [CodeOfferEntry]) -> CodeMonitorPip? {
        guard !offers.isEmpty else { return nil }
        let fetchOnly = offers.allSatisfy { $0.assessment.commandClass == .fetchFile }
        return CodeMonitorPip(symbol: fetchOnly ? "⤓" : "▶", count: offers.count, action: CodeOfferWords.summary(offers).action)
    }

    /// The bottom bar's age: since the last write while a turn runs, since the turn ended once finished;
    /// "quiet 40 min" under the quiet overlay.
    static func ageText(_ s: CodeSessionSnapshot, now: Date, quiet: Bool) -> String? {
        let finished: Bool = {
            switch s.state {
            case .working, .maybeNeedsYou, .quietUnfinished, .unknown: return false
            default: return true
            }
        }()
        let reference = quiet ? s.lastActivity : (finished ? (s.turnFinishedAt ?? s.lastActivity) : s.lastActivity)
        guard let reference else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(reference) / 60))
        let text = minutes < 1 ? "just now" : CodeWindowStatus.duration(minutes: minutes)
        return quiet ? (minutes < 1 ? "quiet" : "quiet \(text)") : text
    }

    /// "opus", "sonnet", "haiku", "fable", else the model as written (cut).
    static func shortModel(_ model: String?) -> String? {
        guard let model = CodePlainText.line(model, limit: 40) else { return nil }
        let lower = model.lowercased()
        for name in ["opus", "sonnet", "haiku", "fable"] where lower.contains(name) { return name }
        return String(model.prefix(16))
    }

    static func led(_ state: CodeSessionState) -> CodeMonitorLED {
        switch state {
        case .needsYou: return CodeMonitorLED(color: CodeMonitorPalette.amber, form: .filled, pulses: false)
        case .problem: return CodeMonitorLED(color: CodeMonitorPalette.red, form: .filled, pulses: false)
        case .working: return CodeMonitorLED(color: CodeMonitorPalette.working, form: .filled, pulses: true)
        case .maybeNeedsYou: return CodeMonitorLED(color: CodeMonitorPalette.amber, form: .filled, pulses: false)
        case .quietUnfinished: return CodeMonitorLED(color: CodeMonitorPalette.working, form: .filled, pulses: false)
        case .reviewReady: return CodeMonitorLED(color: CodeMonitorPalette.green, form: .filled, pulses: false)
        case .done: return CodeMonitorLED(color: CodeMonitorPalette.white, form: .filled, pulses: false)
        case .doneNoSummary: return CodeMonitorLED(color: CodeMonitorPalette.white, form: .ring, pulses: false)
        case .unknown: return CodeMonitorLED(color: CodeMonitorPalette.grey, form: .hollow, pulses: false)
        }
    }

    static func glow(_ state: CodeSessionState) -> UInt32? {
        switch state {
        case .needsYou: return CodeMonitorPalette.amber
        case .problem: return CodeMonitorPalette.red
        default: return nil
        }
    }

    /// "buildbox · ~/projects/x" (SSH, the server's folder), "this Mac · ~/my project", or "where it runs is unknown".
    static func placeLine(_ s: CodeSessionSnapshot, home: String) -> String {
        switch s.place {
        case .ssh:
            let host = CodePlainText.line(s.sshHost, limit: 40) ?? "the server"
            guard let cwd = s.cwd else { return host }
            return host + " · " + (CodePlainText.line(serverShort(cwd), limit: 120) ?? "")
        case .local:
            guard let cwd = s.cwd else { return "this Mac" }
            return "this Mac · " + (CodePlainText.line(localShort(cwd, home: home), limit: 120) ?? "")
        case .unknown:
            return "where it runs is unknown"
        }
    }

    static func localShort(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    /// A server path with its home folder written as `~` (`/home/<user>/x` or `/root/x`).
    static func serverShort(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "home" { return "~/" + parts.dropFirst(2).joined(separator: "/") }
        if parts.first == "root" { return "~/" + parts.dropFirst().joined(separator: "/") }
        return path
    }

    // MARK: Peek

    static func peek(_ s: CodeSessionSnapshot, headline: String, stateLine: String, status: CodeWindowStatus?,
                     hidden: Bool, inputs: Inputs) -> CodeMonitorPeekContent {
        let (button, click): (String?, CodeWindowClick) = {
            guard let status, status.busy == nil else { return (nil, .none) }
            switch status.place {
            case .onDesk: return ("Pit", .park)
            case .parked, .minimized, .hidden: return ("Back on track", .restore)
            case .otherSpace: return ("Switch to its Space", .activate)
            case .closed: return ("Open in main window", .openInMainWindow)
            default: return (nil, .none)
            }
        }()
        var content = CodeMonitorPeekContent(
            title: hidden ? headline : (CodePlainText.line(s.title, limit: 512) ?? headline),
            profile: inputs.showsProfiles ? s.profile.name : nil, place: nil, stateLine: stateLine, tldr: nil, ask: nil,
            steps: [], todosTitle: nil, todos: [], offers: [], offersNote: nil, windowButton: button, windowClick: click,
            link: CodeDeepLink.shareLink(sessionID: s.id), textHidden: hidden)
        guard !hidden else { return content }
        content.place = placeLine(s, home: inputs.homeDirectory)
        content.tldr = CodePlainText.block(s.tldr, limit: 1_024, maxLines: 8)
        content.ask = CodePlainText.block(s.askLine, limit: 1_024, maxLines: 6)
        content.steps = s.steps.suffix(5).compactMap { step in
            guard let words = CodePlainText.line(step.words, limit: 90) else { return nil }
            let minutes = max(0, Int(inputs.now.timeIntervalSince(step.at) / 60))
            return CodePeekStep(words: words, ago: minutes < 1 ? "just now" : CodeWindowStatus.duration(minutes: minutes) + " ago")
        }
        if let todos = s.todos, todos.total > 0 {
            content.todosTitle = "\(todos.done) of \(todos.total) todos"
            let current = todos.current.flatMap { item in todos.items.firstIndex(of: item) }
            let start = max(0, min((current ?? 0) - 2, todos.total - 6))
            content.todos = todos.items.enumerated().dropFirst(start).prefix(6).compactMap { index, item in
                guard let text = CodePlainText.line(item.text, limit: 120) else { return nil }
                let mark: CodePeekTodo.Mark = index == current ? .current : (item.status == .completed ? .done : .pending)
                return CodePeekTodo(text: text, mark: mark)
            }
        }
        content.offers = s.offers.map { entry in
            let (chip, tone) = CodeOfferWords.classChip(entry.assessment)
            return CodePeekOfferRow(id: entry.id, number: entry.offer.id.number,
                                    reviewTitle: CodeOfferWords.reviewTitle(entry.assessment, commands: inputs.commands),
                                    firstLine: CodeOfferWords.firstLine(of: entry.offer) ?? "(empty)",
                                    classChip: chip, classTone: tone,
                                    machineChip: CodeOfferWords.machineChip(entry.assessment, alias: s.sshHost),
                                    canCopy: CodeOfferWords.canCopy(entry.assessment),
                                    ranNote: inputs.runs.ran(sessionID: s.id, text: entry.offer.text)
                                        .map { CodeOfferWords.ranNote($0, now: inputs.now) })
        }
        if s.offersNotShown > 0 {
            content.offersNote = "\(s.offers.count) of \(s.offers.count + s.offersNotShown) commands; the rest are in the session"
        }
        content.warnings = s.warnings.map { CodeWarningWords.peekLines($0, now: inputs.now) }
        content.results = CodeResultPeekRows.rows(results: s.results, otherLinkCount: s.otherLinkCount, alias: s.sshHost, hidden: false,
                                                  time: CodeResultPeekRows.defaultTime)
        return content
    }
}
