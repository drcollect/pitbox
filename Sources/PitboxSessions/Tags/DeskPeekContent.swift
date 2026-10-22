import Foundation
import PitboxKit

/// What the desk peek shows: the monitor peek's content with the run block,
/// warnings, results, dashboard and commands. Session text only through the plain-text renderer; with Hide text only the
/// headline, the state, host words and the buttons. Pure.
struct DeskPeekModel: Equatable {
    /// A clickable row. Only `result` and `dashboard` open something outside the app and are armed.
    enum Action: Hashable {
        case offer(CommandOffer.ID)
        case result(String)
        case dashboard
        case park
        case copyLink
    }

    struct Button: Equatable {
        var action: Action
        var title: String
        /// VoiceOver: host words only (the peek's text is session text and stays out of labels).
        var accessibilityLabel: String

        var needsArming: Bool {
            switch action {
            case .result, .dashboard: return true
            case .offer, .park, .copyLink: return false
            }
        }
    }

    struct Command: Equatable {
        var number: Int
        /// The first command line (B1 escaped), or "hidden".
        var preview: String
        var chip: String
        var risky: Bool
        /// "from an earlier reply (14:02)" for offers of earlier replies.
        var note: String?
        var button: Button
    }

    struct Step: Equatable {
        var words: String
        var ago: String
    }

    struct Todo: Equatable {
        enum Mark: Equatable { case done, current, pending }
        var text: String
        var mark: Mark
    }

    var title: String
    var state: CodeSessionState
    var detailLines: [String] = []
    var textHidden = false
    var now: String?
    var runLine: String?
    var zoneNote: String?
    /// The 3 pt bar: done / total, orange once a stated ETA passed.
    var progress: Double?
    var late = false
    var warnings: [String] = []
    var tldr: String?
    var ask: String?
    var steps: [Step] = []
    var todosTitle: String?
    var todos: [Todo] = []
    var results: [Button] = []
    var resultNotes: [String] = []
    var dashboard: Button?
    var commands: [Command] = []
    var earlierCommands: [Command] = []
    var footer: [Button] = []
}

/// Builds the desk peek's content. Pure.
enum DeskPeekBuilder {
    struct Inputs {
        var session: CodeSessionSnapshot
        var suppressed = DeskTagSuppressed()
        var textHidden = false
        var warningsShown = CodeSettings.Warnings()
        var now: Date
        var clock: DeskTagClock
        var homeDirectory = NSHomeDirectory()
        /// `CodeSettings.commands`: with Run off (`copyOnly`, the default) the command buttons say "Review…".
        var commands: CodeSettings.Commands = .copyOnly
    }

    static func model(_ inputs: Inputs) -> DeskPeekModel {
        let session = inputs.session
        let hidden = inputs.textHidden
        var model = DeskPeekModel(title: CodePlainText.line(session.headline, limit: 140) ?? "Code session", state: session.state)
        model.textHidden = hidden
        if !hidden, let place = placeLine(session, home: inputs.homeDirectory) { model.detailLines.append(place) }
        model.detailLines.append(stateLine(session, now: inputs.now))

        // The run block.
        if DeskTagRunText.isRunning(session) {
            if !hidden, let now = CodePlainText.line(session.now, limit: 160) {
                model.now = "Now: " + now + asOf(session, now: inputs.now, clock: inputs.clock)
            }
            model.runLine = hidden ? DeskTagRunText.running(session, now: inputs.now)
                : DeskTagRunText.peekLine(session, now: inputs.now, clock: inputs.clock)
            if !hidden { model.zoneNote = DeskTagRunText.statedZoneNote(session.eta, clock: inputs.clock) }
            if let progress = session.progress, progress.total > 0 { model.progress = progress.fraction }
            if let eta = session.eta { model.late = DeskTagRunText.isLate(eta, now: inputs.now) }
        }

        let content = DeskTagContentBuilder.Inputs(session: session, suppressed: inputs.suppressed, textHidden: hidden,
                                                warningsShown: inputs.warningsShown, now: inputs.now, clock: inputs.clock)
        model.warnings = DeskTagContentBuilder.warnings(session, inputs: content).map { warningLine($0, hidden: hidden, now: inputs.now) }

        if !hidden {
            model.tldr = CodePlainText.block(session.tldr, limit: 600, maxLines: 6)
            model.ask = CodePlainText.block(session.askLine, limit: 400, maxLines: 4)
            model.steps = session.steps.suffix(5).compactMap { step in
                CodePlainText.line(step.words, limit: 100).map { DeskPeekModel.Step(words: $0, ago: ago(step.at, now: inputs.now)) }
            }
            if let todos = session.todos, !todos.items.isEmpty {
                model.todosTitle = "TODOS \(todos.done)/\(todos.total)"
                let current = todos.current
                model.todos = todos.items.prefix(6).compactMap { item in
                    guard let text = CodePlainText.line(item.text, limit: 90) else { return nil }
                    let mark: DeskPeekModel.Todo.Mark = item.status == .completed ? .done : (item == current ? .current : .pending)
                    return DeskPeekModel.Todo(text: text, mark: mark)
                }
            }
        }

        // Results: ↗ and ▤ are armed buttons; the rest are lines.
        for result in session.results.prefix(CodeTuning.maxResults) {
            if let button = resultButton(result, hidden: hidden) {
                model.results.append(button)
            } else if !hidden, let note = resultNote(result, session: session) {
                model.resultNotes.append(note)
            }
        }
        if session.otherLinkCount > 0 {
            let count = session.otherLinkCount
            model.resultNotes.append("\(count) other link\(count == 1 ? "" : "s") in the reply (open them from the session)")
        }
        if let dashboard = session.dashboard {
            var title = "▦ Open dashboard"
            if !hidden {
                title += " · since " + inputs.clock.string(dashboard.firstSeen)
                if let updated = dashboard.lastBuilderCallAt { title += " · updated " + inputs.clock.string(updated) }
            }
            model.dashboard = DeskPeekModel.Button(action: .dashboard, title: title, accessibilityLabel: "Open dashboard")
        }

        // Commands: the latest reply's, then the earlier replies' (behind R22).
        let live = DeskTagContentBuilder.liveOffers(session, suppressed: inputs.suppressed)
        let latest = Set(session.offers.map(\.id))
        for entry in live {
            let isLatest = latest.contains(entry.id)
            let row = command(entry, hidden: hidden, earlier: !isLatest, commands: inputs.commands, clock: inputs.clock)
            if isLatest { model.commands.append(row) } else { model.earlierCommands.append(row) }
        }

        model.footer = [
            DeskPeekModel.Button(action: .park, title: "Pit", accessibilityLabel: "Pit the window"),
            DeskPeekModel.Button(action: .copyLink, title: "Copy link", accessibilityLabel: "Copy link"),
        ]
        return model
    }

    // MARK: Lines

    /// "this Mac · ~/my project", "buildbox · ~/projects/x".
    static func placeLine(_ session: CodeSessionSnapshot, home: String) -> String? {
        var folder = session.cwd
        if let cwd = folder, session.place == .local, cwd == home || cwd.hasPrefix(home + "/") {
            folder = "~" + cwd.dropFirst(home.count)
        }
        let machine: String?
        switch session.place {
        case .local: machine = "this Mac"
        case .ssh: machine = CodePlainText.line(session.sshHost, limit: 32) ?? "server"
        case .unknown: machine = nil
        }
        let parts = [machine, CodePlainText.line(folder, limit: 80)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "working · 2 min ago · claude-opus-5-5".
    static func stateLine(_ session: CodeSessionSnapshot, now: Date) -> String {
        var parts = [session.stateWord]
        if let activity = session.lastActivity { parts.append(ago(activity, now: now)) }
        if let model = CodePlainText.line(session.model, limit: 40) { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    /// " (as of 23:12)" for an SSH session whose newest entry is over 60 s old (mirrors arrive in batches).
    static func asOf(_ session: CodeSessionSnapshot, now: Date, clock: DeskTagClock) -> String {
        guard session.place == .ssh, let activity = session.lastActivity, now.timeIntervalSince(activity) > 60 else { return "" }
        return " (as of " + clock.string(activity) + ")"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        return CodeWindowStatus.duration(minutes: minutes) + " ago"
    }

    static func warningLine(_ warning: CodeWarning, hidden: Bool, now: Date) -> String {
        switch warning.kind {
        case .failedInARow:
            let count = warning.failures ?? CodeTuning.stuckRunLength
            var line = "Looks stuck: \(count) commands failed in a row"
            if let code = warning.lastExitCode { line += " · last exit \(code)" }
            return line
        case .silence:
            let minutes = max(Int(CodeTuning.stuckSilence / 60), Int(now.timeIntervalSince(warning.since) / 60))
            return "Looks stuck: quiet for \(CodeWindowStatus.duration(minutes: minutes)), nothing running"
        case .sameFile:
            guard !hidden else { return "Same file in two sessions" }
            let other = CodePlainText.line(warning.otherHeadline, limit: 60) ?? "another session"
            let path = CodePlainText.line(warning.path, limit: 60)
            return "Also edited by “\(other)”" + (path.map { ": " + $0 } ?? "")
        }
    }

    /// "↗ Open preview · localhost:5173", "↗ Open artifact", "▤ Open notes.md", "▤ Preview index.html",
    /// "▤ Show script.sh in Finder"; with Hide text without the names.
    static func resultButton(_ result: CodeResult, hidden: Bool) -> DeskPeekModel.Button? {
        let label = hidden ? nil : CodePlainText.line(result.label, limit: 48)
        let title: String
        let voice: String
        switch result.kind {
        case .preview:
            title = "↗ Open preview" + (label.map { " · " + $0 } ?? "")
            voice = "Open preview"
        case .artifact:
            title = "↗ Open artifact"
            voice = "Open artifact"
        case .document:
            title = "▤ Open " + (label ?? "file")
            voice = "Open file"
        case .webDocument:
            title = "▤ Preview " + (label ?? "file")
            voice = "Preview file"
        case .otherFile:
            title = "▤ Show " + (label ?? "file") + " in Finder"
            voice = "Show file in Finder"
        case .serverPreview, .serverFile, .mentionedPath, .earlierArtifact:
            return nil
        }
        return DeskPeekModel.Button(action: .result(result.id), title: title, accessibilityLabel: voice)
    }

    /// The lines for results without a button here.
    static func resultNote(_ result: CodeResult, session: CodeSessionSnapshot) -> String? {
        let label = CodePlainText.line(result.label, limit: 60)
        let alias = CodePlainText.line(session.sshHost, limit: 24) ?? "the server"
        switch result.kind {
        case .serverPreview: return label.map { "Preview on \(alias): \($0)" }
        case .serverFile: return label.map { "⤓ \($0) on \(alias) (Fetch it from Ready for you)" }
        case .mentionedPath: return CodePlainText.line(result.path ?? result.label, limit: 80).map { "Named in the reply: " + $0 }
        default: return nil
        }
    }

    static func command(_ entry: CodeOfferEntry, hidden: Bool, earlier: Bool, commands: CodeSettings.Commands,
                        clock: DeskTagClock) -> DeskPeekModel.Command {
        let (chip, tone) = CodeOfferWords.classChip(entry.assessment)
        let title = CodeOfferWords.reviewTitle(entry.assessment, commands: commands)
        let preview = hidden ? "hidden" : (CodeOfferWords.firstLine(of: entry.offer) ?? "")
        let note = earlier ? "from an earlier reply (" + clock.string(entry.offer.source.replyTime) + ")" : nil
        return DeskPeekModel.Command(number: entry.id.number, preview: preview, chip: chip, risky: tone == .failed,
                                     note: note,
                                     button: DeskPeekModel.Button(action: .offer(entry.id), title: title,
                                                                  accessibilityLabel: "\(title) command \(entry.id.number)"))
    }
}
