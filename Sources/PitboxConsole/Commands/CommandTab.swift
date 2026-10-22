import Foundation
import PitboxKit

/// The tabs Pitbox opens from a command sheet.
enum CommandTabRole: String, Equatable, Sendable {
    /// Runs the approved text once in the clean shell (`.command` kind).
    case run
    /// A clean interactive shell with the text typed as one bracketed paste, not run (`.command` kind).
    case typeIntoTerminal = "type"
    /// `ssh <alias>` for "Open a terminal on <host>": a program tab, nothing typed (`.program` kind).
    case server
}

/// Where a command or Type tab came from, for its bar and tooltip. The headline is session text: the bar shows it in
/// quotes through `CommandPlainText`; everything else is Pitbox's own words.
struct CommandTabOrigin: Equatable {
    /// The session's headline (session text).
    var headline: String
    /// "B Work"; nil when only one Claude copy runs.
    var profileName: String?
    /// "this Mac".
    var machineLabel: String
    /// The folder, short ("~/my project").
    var folderShort: String
    var replyTime: Date?
    var offer: CommandOffer.ID?

    /// The tab's title: "▶ " and the headline, hidden characters removed, cleaned like any tab title, at most 24
    /// characters.
    var tabTitle: String {
        let visible = String(String.UnicodeScalarView(headline.unicodeScalars.filter { !CommandHiddenCharacters.isHidden($0) }))
        return SessionTitle.clean("▶ " + visible, limit: 24)
    }

    /// "Command from Code · B Work · 14:02"
    var tooltip: String {
        var parts = ["Command from Code"]
        if let profileName { parts.append(SessionTitle.clean(profileName, limit: 24)) }
        if let replyTime { parts.append(CommandTimeFormat.clock(replyTime)) }
        return parts.joined(separator: " · ")
    }
}

/// Clock and duration words used on the sheet and the bar.
enum CommandTimeFormat {
    /// "14:02", local time, 24 hours.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "0:12" while running.
    static func running(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        if whole >= 3600 { return String(format: "%d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// "12 s", "2 min 5 s", "1 h 3 min" when finished.
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 60 { return "\(whole) s" }
        if whole < 3600 { return whole % 60 == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(whole % 60) s" }
        return "\(whole / 3600) h \((whole % 3600) / 60) min"
    }
}

/// The command-specific state of one command or Type tab. Owned by its `TerminalSession`; it reports the run's
/// outcome to the sheet's `events` (started, finished or stopped, typed, refused) exactly once each.
@MainActor
final class CommandTab {
    enum Phase: Equatable {
        /// Created; the shell is not spawned yet.
        case waiting
        /// Spawned; the helper has not confirmed the exec yet.
        case starting
        case running
        case ended(ProcessExit)
        /// Nothing ran: why, in Pitbox's words.
        case didNotStart(String)
    }

    /// Type into terminal: waiting for bracketed paste, then typed once.
    enum Typing: Equatable {
        case notApplicable
        case waitingForShell
        case typed
        case notTyped
        /// The user typed into the tab after the paste (the bar stops saying "Typed, not run").
        case userTyped
    }

    let role: CommandTabRole
    let runID: UUID
    let origin: CommandTabOrigin
    /// Run: the approved text (echoed dimly before the start, never sent). Type: the text to paste.
    let text: String
    private(set) var phase: Phase = .waiting
    private(set) var typing: Typing
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    /// How often Stop was pressed: the first sends SIGINT, the next ones SIGKILL.
    private(set) var stopPresses = 0
    /// The selected terminal view has the keyboard (kept up to date by the console view).
    var keyboardHere = false
    /// The pty asks for hidden input (echo off in canonical mode), polled while running.
    var asksForHiddenInput = false

    private var launch: (spec: CommandLaunchSpec, folder: FolderBinding)?
    /// The sheet's events; dropped after the last one (Run: finished, stopped or refused; Type: typed or refused).
    private var events: (@MainActor (CommandOfferEvent) -> Void)?
    /// The user's input is being sent by Pitbox's own paste, not typed by them.
    private(set) var isPastingOffer = false

    /// How long Type waits for the shell to switch bracketed paste on.
    static let typeReadyTimeout: TimeInterval = 5

    init(role: CommandTabRole, runID: UUID = UUID(), origin: CommandTabOrigin, text: String, spec: CommandLaunchSpec,
         folder: FolderBinding, events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        self.role = role
        self.runID = runID
        self.origin = origin
        self.text = text
        self.launch = (spec, folder)
        self.events = events
        typing = role == .typeIntoTerminal ? .waitingForShell : .notApplicable
    }

    /// The spec and folder, handed out once: a command tab never starts twice (no restart).
    func takeLaunch() -> (spec: CommandLaunchSpec, folder: FolderBinding)? {
        defer { launch = nil }
        return launch
    }

    var isRunning: Bool { phase == .running || phase == .starting }
    var hasEnded: Bool {
        switch phase {
        case .ended, .didNotStart: return true
        default: return false
        }
    }

    // MARK: Lifecycle (called by the session)

    func spawned() {
        if phase == .waiting { phase = .starting }
    }

    /// The helper confirmed the exec of the shell: Run reports `started`.
    func started(at date: Date) {
        guard phase == .starting || phase == .waiting else { return }
        phase = .running
        startedAt = date
        if role == .run { send(.started(runID: runID), last: false) }
        CommandLog.terminal("command tab started", ["kind": .label(role)])
    }

    /// Nothing ran: Run and Type report `refused` with the reason.
    func didNotStart(_ reason: String, at date: Date) {
        guard !hasEnded else { return }
        phase = .didNotStart(reason)
        endedAt = date
        if role == .typeIntoTerminal { typing = .notTyped }
        send(.refused(reason: reason), last: true)
        CommandLog.terminal("command tab did not start", ["kind": .label(role)])
    }

    /// The shell ended: Run reports `finished` (an exit status) or `stopped` (a signal) with the duration; Type reports
    /// `refused` only when the text was never typed.
    func ended(_ exit: ProcessExit, at date: Date) {
        guard !hasEnded else { return }
        phase = .ended(exit)
        endedAt = date
        let seconds = startedAt.map { date.timeIntervalSince($0) } ?? 0
        switch role {
        case .run:
            switch exit {
            case .exited(let code): send(.finished(runID: runID, exitStatus: code, seconds: seconds), last: true)
            case .signaled(let signal): send(.stopped(runID: runID, signal: signal, seconds: seconds), last: true)
            case .unknown: send(.finished(runID: runID, exitStatus: -1, seconds: seconds), last: true)
            }
        case .typeIntoTerminal:
            if typing == .waitingForShell {
                typing = .notTyped
                send(.refused(reason: "the shell ended before the text was typed"), last: true)
            }
        case .server:
            break
        }
        CommandLog.terminal("command tab finished", ["kind": .label(role), "status": .number(exit.logStatus),
                                                     "seconds": .number(Int(seconds.rounded()))])
    }

    /// Counts a press of the bar's Stop: 1 means SIGINT to the job, more means SIGKILL to the groups.
    func pressedStop() -> Int {
        stopPresses += 1
        return stopPresses
    }

    // MARK: Type into terminal

    func beginPaste() { isPastingOffer = true }
    func endPaste() { isPastingOffer = false }

    /// The text went in as one bracketed paste: Type reports `typed`.
    func typed() {
        guard typing == .waitingForShell else { return }
        typing = .typed
        send(.typed, last: true)
        CommandLog.terminal("typed into terminal", ["lines": .number(text.split(separator: "\n", omittingEmptySubsequences: false).count)])
    }

    /// The shell never switched bracketed paste on: nothing typed, Type reports `refused`.
    func notTyped(_ reason: String) {
        guard typing == .waitingForShell else { return }
        typing = .notTyped
        send(.refused(reason: reason), last: true)
        CommandLog.terminal("not typed", ["reason": .label(CommandLogWord.shellNotReady)])
    }

    /// The user typed into the tab after the paste.
    func userTyped() {
        if typing == .typed { typing = .userTyped }
    }

    private func send(_ event: CommandOfferEvent, last: Bool) {
        guard let events else { return }
        if last { self.events = nil }
        events(event)
    }
}

extension ProcessExit {
    /// A number for the log: the exit status, minus the signal, or -1000 when unknown.
    var logStatus: Int {
        switch self {
        case .exited(let code): return Int(code)
        case .signaled(let signal): return -Int(signal)
        case .unknown: return -1000
        }
    }
}
