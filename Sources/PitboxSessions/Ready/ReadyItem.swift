import CryptoKit
import Foundation
import PitboxKit

/// One thing in Ready for you. Built from the snapshots by `CodeReadyList`; every string from a session
/// (headline, command, TL;DR, file name, path) has passed the plain-text renderer (`CodePlainText`) here already.
struct CodeReadyItem: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case warning, command, file, finished
    }

    /// The item key (`cmd:…`, `file:…`, `fin:…`, `warn:…`).
    var id: String
    var kind: Kind
    var sessionID: String
    var sessionIndex: Int
    var follow: CodeFollowedSet.Kind
    /// The quoted headline, "“Toy Cube · checkout”".
    var headline: String
    /// "window on track", "in the pit (Toy Cube)", "in Claude · you opened it 5 h ago", …
    var whereText: String
    /// The order key: the reply, the finish or the warning's start.
    var time: Date
    /// "▶ Command ready", "⤓ File ready", "✓ Finished 23:31", "⚠ Looks stuck", "⚠ Same file in two sessions".
    var title: String
    /// "from an earlier reply (14:02)", "dropped: 3 newer replies since" (host words), nil for none.
    var titleNote: String?
    /// The header line's rest: "from “<headline>” · <where>" or "“<headline>” · ran 21 min · <where>".
    var detail: String
    /// The card's one text line: the first command line, "<file> on buildbox", the TL;DR's first line, the reason.
    var line: String?
    /// The line is a command: monospaced, cut in the middle, never wrapped.
    var lineIsCommand = false
    /// The class chip (Risky, Needs editing, For the server, Other machine, Unclear, Partly read, Blocked).
    var chip: String?
    var buttons: [CodeReadyButton]
    /// The offer behind a command or file item (or the server file result behind a file item).
    var offerID: CommandOffer.ID?
    var result: CodeResult?
    /// A warning item's `CodeWarning.id` (desk tags drop the warnings the user OK'd).
    var warningID: String?
}

/// One button of a card or row.
struct CodeReadyButton: Equatable {
    var action: CodeReadyAction
    var title: String
    /// The button opens something (a link, a file, a dashboard, a fetched file): it counts only once armed.
    var opensSomething: Bool
    /// The card's main button (filled in its kind's colour).
    var primary: Bool

    init(_ action: CodeReadyAction, _ title: String, opens: Bool = false, primary: Bool = false) {
        self.action = action; self.title = title; self.opensSomething = opens; self.primary = primary
    }
}

/// What a press on a Ready button asks for. The list handles its own (Later, Dismiss, OK, Undo, Got it, more); the rest
/// goes to the block (`CodeReadyForYou.onAction`): a sheet, a window, a monitor, a link. Nothing here runs anything:
/// ▶ Run…, Review… and ⤓ Fetch… only open the sheet.
enum CodeReadyAction: Equatable {
    // Handled by the block.
    /// ▶ Run…, Review…, ⤓ Fetch… of an offer (of the latest reply or an earlier one).
    case openSheet(CommandOffer.ID, sessionID: String)
    /// ⤓ Fetch… of a file a session handed over or wrote on the server (`presentFetch`).
    case fetchResult(sessionID: String, result: CodeResult)
    /// Raises and activates the Claude window without moving it.
    case showWindow(sessionID: String)
    /// Unfolds the bucket, turns to the page, scrolls the monitor into view, pulses the bezel.
    case showMonitor(sessionID: String)
    /// Restores a parked window or raises a desk one (the list also clears the item and the unread dot).
    case openWindow(sessionID: String)
    /// Opens the session in Claude's main window (its deep link).
    case openInClaude(sessionID: String)
    /// ↗ or ▤: the first result of a Finished card (armed).
    case openResult(sessionID: String, result: CodeResult)
    /// ▦ Dashboard (armed).
    case openDashboard(sessionID: String)
    /// Show output of a run: selects its command tab and expands the terminal.
    case revealRun(UUID)
    /// Open and Show in Finder of a fetched file (in Downloads, quarantined; armed).
    case openFetched(fileName: String)
    case showFetchedInFinder(fileName: String)

    // Handled by the list.
    case later(String)
    case unfold(String)
    case dismiss(String)
    case undoDismiss
    case ok(String)
    case gotIt
    case showMore
    case showHidden

    /// Whether the block handles it (else the list does).
    var isForTile: Bool {
        switch self {
        case .openSheet, .fetchResult, .showWindow, .showMonitor, .openWindow, .openInClaude, .openResult,
             .openDashboard, .revealRun, .openFetched, .showFetchedInFinder:
            return true
        case .later, .unfold, .dismiss, .undoDismiss, .ok, .gotIt, .showMore, .showHidden:
            return false
        }
    }
}

/// A Ready item's stored state (`code-memory.json` key `ready`): "later" or "dismissed" with its time.
struct CodeReadyStateRecord: Codable, Equatable, Sendable {
    var state: String
    var at: Date

    static let later = "later"
    static let dismissed = "dismissed"
}

/// The item keys. Uuids follow the digest's grammar (1-64 letters, digits or `-`); an entry without a valid uuid
/// makes no item.
enum CodeReadyKey {
    /// The first 16 hex characters of the SHA-256 of `text` (as the run records).
    static func hash16(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `cmd:<session id>:<reply uuid>:<number>:<hash16>`.
    static func command(_ offer: CommandOffer, session: String) -> String? {
        guard CodeIDs.isEntryUUID(offer.id.replyUUID), (1...99).contains(offer.id.number) else { return nil }
        return "cmd:\(session):\(offer.id.replyUUID):\(offer.id.number):\(hash16(offer.text))"
    }

    /// `file:<session id>:<reply uuid>:<hash16 of the path>`.
    static func file(path: String, reply: String, session: String) -> String? {
        guard CodeIDs.isEntryUUID(reply) else { return nil }
        return "file:\(session):\(reply):\(hash16(path))"
    }

    /// `fin:<session id>:<reply uuid>`.
    static func finished(reply: String, session: String) -> String? {
        CodeIDs.isEntryUUID(reply) ? "fin:\(session):\(reply)" : nil
    }

    /// `warn:<session id>:<rule>`.
    static func warning(_ kind: CodeWarning.Kind, session: String) -> String { "warn:\(session):\(kind.rawValue)" }
}

/// Clock times and durations in the app's words: this Mac's zone and the system's 12- or 24-hour format.
struct CodeReadyClock {
    private let formatter: DateFormatter

    init(timeZone: TimeZone = .current, locale: Locale = .current) {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "HH:mm"
        self.formatter = formatter
    }

    /// "23:31" (or "11:31 PM").
    func time(_ date: Date) -> String { formatter.string(from: date) }

    /// "21 min", "1 h 12 min" (minutes rounded down; under a minute "1 min").
    static func ran(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "just now", "12 min ago", "5 h ago", "2 d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        return CodeWindowStatus.duration(minutes: minutes) + " ago"
    }
}

/// The host words of the cards. Pure.
enum CodeReadyWords {
    static let listTitle = "Ready for you"
    static let keptNote = "kept until you act or dismiss"
    static let dismissedUndo = "Dismissed · Undo"
    static let hidden = "hidden"
    static let tooFarBack = "too far back to check: use Copy"

    /// The "<where>" words of a session.
    static func whereText(_ follow: CodeFollowedSet.Kind, status: CodeWindowStatus?, bucket: String?, now: Date) -> String {
        switch follow {
        case .recentUsed(let at): return "in Claude · you opened it " + CodeReadyClock.ago(at, now: now)
        case .recentOwn: return "in Claude · not opened recently"
        case .desk, .parked: break
        }
        switch status?.place {
        case .onDesk?: return "window on track"
        case .parked?, .minimized?, .parkedNotMatched?:
            return bucket.flatMap { CodePlainText.line($0, limit: 32) }.map { "in the pit (\($0))" } ?? "in the pit"
        case .otherSpace?: return "on another Space"
        case .closed?: return "window closed"
        case .hidden?: return "Claude is hidden"
        case .hiddenByClaude?: return "hidden by Claude"
        case .profileNotRunning(let letter)?: return "Claude \(letter) is not running"
        case .notMatched?: return "window not matched"
        case .noAccessibility?, nil: return follow == .parked ? "in the pit" : "window on track"
        }
    }

    /// The button that shows the session: Show window (desk), Show monitor (parked, closed), Open in Claude (recent).
    static func showButton(_ follow: CodeFollowedSet.Kind, status: CodeWindowStatus?, session: String) -> CodeReadyButton {
        if follow.isRecent { return CodeReadyButton(.openInClaude(sessionID: session), "Open in Claude") }
        if follow == .parked || status?.isParked == true {
            return CodeReadyButton(.showMonitor(sessionID: session), "Show monitor")
        }
        if case .closed? = status?.place { return CodeReadyButton(.showMonitor(sessionID: session), "Show monitor") }
        return CodeReadyButton(.showWindow(sessionID: session), "Show window")
    }

    /// The window button of Finished and warning cards: Back on track, or Open in Claude for a recent
    /// session.
    static func windowButton(_ follow: CodeFollowedSet.Kind, session: String, primary: Bool) -> CodeReadyButton {
        follow.isRecent ? CodeReadyButton(.openInClaude(sessionID: session), "Open in Claude", primary: primary)
            : CodeReadyButton(.openWindow(sessionID: session), "Back on track", primary: primary)
    }

    /// A warning's reason, one line; paths and headlines through the renderer.
    static func reason(_ warning: CodeWarning, now: Date) -> String {
        switch warning.kind {
        case .failedInARow:
            let count = warning.failures ?? CodeTuning.stuckRunLength
            let exit = warning.lastExitCode.map { " (last exit \($0))" } ?? ""
            return "\(count) commands failed in a row\(exit)"
        case .silence:
            let minutes = max(Int(CodeTuning.stuckSilence / 60), Int(now.timeIntervalSince(warning.since) / 60))
            return "quiet for \(minutes) min, nothing running"
        case .sameFile:
            let other = CodePlainText.line(warning.otherHeadline, limit: 60).map { "“\($0)”" } ?? "another session"
            let path = CodePlainText.line(warning.path, limit: 60).map { ": \($0)" } ?? ""
            return "Also edited by \(other)\(path)"
        }
    }

    /// "⚠ Looks stuck" or "⚠ Same file in two sessions".
    static func warningTitle(_ kind: CodeWarning.Kind) -> String {
        kind == .sameFile ? "⚠ Same file in two sessions" : "⚠ Looks stuck"
    }

    /// The class chip of a command card, nil for Not flagged and Fetch file.
    static func chip(_ assessment: CommandAssessment) -> String? {
        switch assessment.commandClass {
        case .notFlagged, .fetchFile: return nil
        case .risky: return "Risky"
        case .needsEditing: return "Needs editing"
        case .forServer: return "For the server"
        case .otherMachine: return "Other machine"
        case .unclearMachine: return "Unclear"
        case .partlyRead: return "Partly read"
        case .blocked: return "Blocked"
        }
    }

    /// "<file name> on buildbox" for a Fetch file offer or a server file (the name is session text).
    static func fileLine(name: String, alias: String?) -> String {
        let file = CodePlainText.line(name, limit: 64) ?? "a file"
        let server = alias.flatMap { CodePlainText.line($0, limit: 32) } ?? "the server"
        return "\(file) on \(server)"
    }

    /// "Finished 23:31 · ran 21 min" (the card's title and its detail are split by the card).
    static func finishedTitle(_ mark: CodeFinishedMark, clock: CodeReadyClock) -> String {
        "✓ Finished " + clock.time(mark.at)
    }

    /// "“<headline>” · ran 21 min · in the pit (Toy Cube) · ETA was 23:24", or the expiry words.
    static func finishedDetail(_ mark: CodeFinishedMark, headline: String, whereText: String, clock: CodeReadyClock) -> String {
        var parts = [headline]
        parts.append(mark.expired ? "a background task never reported back" : "ran " + CodeReadyClock.ran(mark.ranSeconds))
        parts.append(whereText)
        if let eta = mark.etaWas { parts.append("ETA was " + clock.time(eta)) }
        return parts.joined(separator: " · ")
    }

    /// The monitor's bottom bar while the Finished item is open: "review ready · finished 23:31 · ran 21 min"
    /// (large) or "finished 23:31" (medium); nil when there is no open item.
    static func monitorBar(_ mark: CodeFinishedMark?, stateWord: String, large: Bool, clock: CodeReadyClock) -> String? {
        guard let mark, mark.isOpen, mark.hasItem else { return nil }
        let finished = "finished " + clock.time(mark.at)
        guard large else { return finished }
        return [stateWord, finished, "ran " + CodeReadyClock.ran(mark.ranSeconds)].joined(separator: " · ")
    }
}
