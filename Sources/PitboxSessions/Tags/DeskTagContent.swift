import Foundation
import PitboxKit

/// Where the desk peek opens: at its top, or scrolled to the commands or the warnings.
enum DeskPeekFocus: Equatable, Sendable {
    case top, commands, warnings
}

/// One pill of a tag: host words, and session text only through the
/// plain-text renderer.
struct DeskTagPill: Equatable {
    enum Kind: String, Equatable {
        case command, file, warning, running, dashboard, lab
    }

    /// What a click does. Nothing here runs anything.
    enum Action: Equatable {
        /// One offer: its sheet.
        case openOffer(CommandOffer.ID)
        /// Several offers, a warning, a running session: the desk peek.
        case openPeek(DeskPeekFocus)
        /// ▦: the dashboard in the browser, after the arming.
        case openDashboard
    }

    var kind: Kind
    /// The pill's words: "▶ Run…", "⤓ Fetch draft.md…", "⚠ Looks stuck", "ETA 23:24", "▦ Dashboard".
    var text: String
    /// Signs and counts only ("▶ 2", "⚠", "▦", "Running"): with Hide text, and when the window is too narrow. Never
    /// session text.
    var short: String
    var action: Action

    /// Only pills that open something outside the app need arming: ▦.
    var needsArming: Bool { action == .openDashboard }

    /// The log word of `tag shown … kind=`.
    var logKind: String {
        switch kind {
        case .command, .file: return "offer"
        case .warning: return "warning"
        case .running: return "running"
        case .dashboard: return "dashboard"
        case .lab: return "lab"
        }
    }
}

/// What one desk window's tag shows: at most two pills, the main item and ▦ below it.
struct DeskTagContent: Equatable {
    var main: DeskTagPill?
    var dashboard: DeskTagPill?
    /// Hide text (the block's, or `showText` false for the copy): pills draw their short form.
    var textHidden: Bool
    /// The headline through the renderer, for VoiceOver; nil with Hide text.
    var headline: String?

    var pills: [DeskTagPill] { [main, dashboard].compactMap { $0 } }

    /// VoiceOver: "The app for “<headline>”: <tag text>"; with Hide text no headline and the short form.
    func accessibilityLabel(for pill: DeskTagPill) -> String {
        guard !textHidden, let headline else { return "\(AppIdentity.displayName): " + pill.short }
        return "\(AppIdentity.displayName) for “\(headline)”: " + pill.text
    }

    /// `tag shown … kind=` for the log.
    var logKind: String { (main ?? dashboard)?.logKind ?? "none" }
}

/// Builds a tag's content from a session snapshot. Pure.
enum DeskTagContentBuilder {
    struct Inputs {
        var session: CodeSessionSnapshot
        var suppressed = DeskTagSuppressed()
        /// The block's Hide text, or `showText` false for the session's copy.
        var textHidden = false
        var warningsShown = CodeSettings.Warnings()
        /// Lab mode: a lab pill when nothing else applies, so a throwaway pop-out gets a tag.
        var labPill = false
        var now: Date
        var clock: DeskTagClock
        /// `CodeSettings.commands`: with Run off (`copyOnly`, the default) a command pill says "▶ Review…".
        var commands: CodeSettings.Commands = .copyOnly
    }

    static let headlineLimit = 80
    static let nameLimit = 40
    static let otherHeadlineLimit = 36

    /// The content, or nil when no tag applies (none of offer, warning, running, dashboard).
    static func content(_ inputs: Inputs) -> DeskTagContent? {
        let session = inputs.session
        let offers = liveOffers(session, suppressed: inputs.suppressed)
        var main = offerPill(offers, session: session, hidden: inputs.textHidden, commands: inputs.commands)
        if main == nil { main = warningPill(warnings(session, inputs: inputs), hidden: inputs.textHidden) }
        if main == nil, DeskTagRunText.isRunning(session) {
            let words = DeskTagRunText.short(session, now: inputs.now, clock: inputs.clock)
            let hiddenWords = DeskTagRunText.running(session, now: inputs.now)
            main = DeskTagPill(kind: .running, text: inputs.textHidden ? hiddenWords : words, short: "Running",
                            action: .openPeek(.top))
        }
        let dashboard = session.dashboard == nil ? nil
            : DeskTagPill(kind: .dashboard, text: inputs.textHidden ? "▦" : "▦ Dashboard", short: "▦", action: .openDashboard)
        if main == nil, dashboard == nil, inputs.labPill {
            main = DeskTagPill(kind: .lab, text: "\(AppIdentity.displayName) lab tag", short: "Lab", action: .openPeek(.top))
        }
        guard main != nil || dashboard != nil else { return nil }
        return DeskTagContent(main: main, dashboard: dashboard, textHidden: inputs.textHidden,
                           headline: inputs.textHidden ? nil : CodePlainText.line(session.headline, limit: headlineLimit))
    }

    /// The latest reply's offers, then the earlier replies' (still runnable behind R22), without the ones the
    /// Ready list no longer shows.
    static func liveOffers(_ session: CodeSessionSnapshot, suppressed: DeskTagSuppressed) -> [CodeOfferEntry] {
        var seen = Set<CommandOffer.ID>()
        return (session.offers + session.earlierOffers).filter { entry in
            guard !suppressed.offers.contains(entry.id), !seen.contains(entry.id) else { return false }
            seen.insert(entry.id)
            return true
        }
    }

    /// The warnings shown, by the settings and without the silenced ones; "Looks stuck" before "Same file".
    static func warnings(_ session: CodeSessionSnapshot, inputs: Inputs) -> [CodeWarning] {
        let silenced = inputs.suppressed.warnings[session.id] ?? []
        return session.warnings.filter { warning in
            guard !silenced.contains(warning.id) else { return false }
            switch warning.kind {
            case .failedInARow, .silence: return inputs.warningsShown.stuck
            case .sameFile: return inputs.warningsShown.sameFile
            }
        }.sorted { rank($0.kind) < rank($1.kind) }
    }

    private static func rank(_ kind: CodeWarning.Kind) -> Int {
        switch kind {
        case .failedInARow: return 0
        case .silence: return 1
        case .sameFile: return 2
        }
    }

    // MARK: Offers

    /// "▶ Run…", "▶ Run… · risky", "▶ Review… · for buildbox", "▶ 1 command · blocked", "⤓ Fetch draft.md…",
    /// "▶ 2 commands…", "▶ 3 commands… · 1 risky", "⤓ 2 files…"; "▶ Review…" in place of "▶ Run…" while Run is off.
    static func offerPill(_ offers: [CodeOfferEntry], session: CodeSessionSnapshot, hidden: Bool,
                          commands: CodeSettings.Commands) -> DeskTagPill? {
        guard let first = offers.first else { return nil }
        let allFetch = offers.allSatisfy { $0.assessment.commandClass == .fetchFile }
        let kind: DeskTagPill.Kind = allFetch ? .file : .command
        let short = (allFetch ? "⤓ " : "▶ ") + "\(offers.count)"
        guard offers.count == 1 else {
            var text = allFetch ? "⤓ \(offers.count) files…" : "▶ \(offers.count) commands…"
            if !allFetch, let qualifier = severalQualifier(offers) { text += " · " + qualifier }
            return DeskTagPill(kind: kind, text: hidden ? short : text, short: short, action: .openPeek(.commands))
        }
        let text = hidden ? short : oneOfferText(first, session: session, commands: commands)
        return DeskTagPill(kind: kind, text: text, short: short, action: .openOffer(first.id))
    }

    static func oneOfferText(_ entry: CodeOfferEntry, session: CodeSessionSnapshot, commands: CodeSettings.Commands) -> String {
        let assessment = entry.assessment
        // Run itself is only on the sheet, and only while Run is on: otherwise the sheet is for review (Copy, Type).
        let open = commands == .run ? "▶ Run…" : "▶ Review…"
        switch assessment.commandClass {
        case .fetchFile:
            let name = assessment.fetch.map { $0.destinationName ?? ($0.remotePath as NSString).lastPathComponent }
            return "⤓ Fetch " + (CodePlainText.line(name, limit: nameLimit) ?? "file") + "…"
        case .notFlagged: return open
        case .risky: return open + " · risky"
        case .unclearMachine: return open + " · machine unclear"
        case .blocked: return "▶ 1 command · blocked"
        case .needsEditing: return "▶ Review… · needs editing"
        case .partlyRead: return "▶ Review… · partly read"
        case .forServer:
            let alias = CodePlainText.line(session.sshHost, limit: 24)
            return "▶ Review… · " + (alias.map { "for " + $0 } ?? "for the server")
        case .otherMachine:
            return "▶ Review… · " + (CodeOfferWords.qualifier(assessment) ?? "runs on another machine")
        }
    }

    /// The one class word that matters most among several offers: blocked, then risky, then for the server.
    static func severalQualifier(_ offers: [CodeOfferEntry]) -> String? {
        let classes = offers.map(\.assessment.commandClass)
        let blocked = classes.filter { $0 == .blocked }.count
        if blocked > 0 { return "\(blocked) blocked" }
        let risky = classes.filter { $0 == .risky }.count
        if risky > 0 { return "\(risky) risky" }
        let server = classes.filter { $0 == .forServer || $0 == .otherMachine }.count
        if server > 0 { return "\(server) for the server" }
        return nil
    }

    // MARK: Warnings

    /// "⚠ Looks stuck" or "⚠ Same file as “<other headline>”".
    static func warningPill(_ warnings: [CodeWarning], hidden: Bool) -> DeskTagPill? {
        guard let warning = warnings.first else { return nil }
        let text: String
        switch warning.kind {
        case .failedInARow, .silence:
            text = "⚠ Looks stuck"
        case .sameFile:
            let other = CodePlainText.line(warning.otherHeadline, limit: otherHeadlineLimit)
            text = other.map { "⚠ Same file as “\($0)”" } ?? "⚠ Same file"
        }
        return DeskTagPill(kind: .warning, text: hidden ? "⚠" : text, short: "⚠", action: .openPeek(.warnings))
    }
}
