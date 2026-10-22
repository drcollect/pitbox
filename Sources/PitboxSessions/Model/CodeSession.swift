import Foundation
import PitboxKit

// The shared model of Code monitors. Data/ produces `CodeSessionSnapshot`s from Claude's session files and transcripts;
// Windows/ joins them with pop-out windows; Tile/ draws them. Every string here that came from a session file or a
// transcript is model-written text: show it only through the block's plain-text renderer, never parse it for commands
// or links, never log it (docs/THREAT_MODEL.md). Many parts read this model: change it only additively.

/// One Claude desktop copy: the default copy (`~/Library/Application Support/Claude`, letter A) is built in;
/// further copies are listed in the settings file's `profiles` (`CodeProfiles`). The block shows profile marks only when
/// more than one copy runs; discovery stays generic, and a folder not listed is "Claude ?" and never read.
public struct CodeProfile: Hashable, Sendable, Identifiable {
    /// "A" for the default copy, "B"..."Z" for listed ones, or "?" for an unknown folder (never read).
    public let letter: String
    /// "A · Claude", "B · Work" (letter and the listed name), "Claude ?".
    public let name: String
    /// The folder name under `~/Library/Application Support`: `Claude`, or a listed copy's folder.
    public let folderName: String
    /// The profile mark's colour (`0xRRGGBB`) from `profiles`; nil uses the palette's own.
    public let colour: UInt32?

    public var id: String { folderName }

    public init(letter: String, name: String, folderName: String, colour: UInt32? = nil) {
        self.letter = letter; self.name = name; self.folderName = folderName; self.colour = colour
    }

    /// The folder of the default copy.
    public static let defaultFolderName = "Claude"
    /// The default copy, the only one built in.
    public static let a = CodeProfile(letter: "A", name: "A · Claude", folderName: defaultFolderName)

    public static func unknown(folderName: String) -> CodeProfile {
        CodeProfile(letter: "?", name: "Claude ?", folderName: folderName)
    }

    /// A listed copy (`profiles` in the settings file, already checked by `CodeSettings`).
    public init(_ listed: CodeSettings.Profile) {
        self.init(letter: listed.letter, name: "\(listed.letter) · \(listed.name)", folderName: listed.folder,
                  colour: listed.colour)
    }

    /// Whether this copy is one the app may read (an unknown folder is shown greyed and never read).
    public var isReadable: Bool { letter != "?" }

    /// The order of copies: A first, then the listed letters alphabetically, then unknown ones.
    var rank: Int {
        guard isReadable, let scalar = letter.unicodeScalars.first, letter.unicodeScalars.count == 1 else { return Int.max }
        return Int(scalar.value)
    }
}

/// The copies the app may read: the default one and the settings file's `profiles`. A running copy whose folder is not
/// among them is "Claude ?" and never read.
public struct CodeProfiles: Sendable, Equatable {
    /// The default copy first, then the listed ones in the file's order.
    public let known: [CodeProfile]

    /// The default copy alone.
    public static let defaultOnly = CodeProfiles(listed: [])

    /// The default copy plus `listed` (entries `CodeSettings` already checked: letters B-Z, unique folders).
    public init(listed: [CodeSettings.Profile]) {
        known = [.a] + listed.map(CodeProfile.init)
    }

    /// The copies `settings` lists.
    public init(_ settings: CodeSettings) { self.init(listed: settings.profiles) }

    /// The known copy for a folder name, nil for anything else.
    public func profile(folderName: String) -> CodeProfile? { known.first { $0.folderName == folderName } }
}

/// One running Claude desktop process and the copy it belongs to. Windows are activated by process id, never by bundle
/// id: all copies share one bundle id.
public struct ClaudeProcessInfo: Sendable, Equatable, Hashable {
    /// The process id (windows are matched and activated by it).
    public var pid: Int32
    /// The copy it belongs to; "Claude ?" (unknown, never read) when its folder is not a known one.
    public var profile: CodeProfile
    /// The `Claude.app` the process runs from (for opening a deep link in that copy).
    public var bundlePath: String?
    /// The app's version, for the "session files changed" banner (`CodeSessionsSource.banner`).
    public var version: String?

    /// A process and its copy.
    public init(pid: Int32, profile: CodeProfile, bundlePath: String? = nil, version: String? = nil) {
        self.pid = pid
        self.profile = profile
        self.bundlePath = bundlePath
        self.version = version
    }
}

/// The state of a session: every state has a word, colour is never the only signal.
public enum CodeSessionState: String, CaseIterable, Sendable {
    case needsYou, problem, working, maybeNeedsYou, quietUnfinished, reviewReady, done, doneNoSummary, unknown

    /// The word on the monitor. `problem` says "failed" or "stopped": see `CodeSessionSnapshot.stateWord`.
    public var word: String {
        switch self {
        case .needsYou: return "needs you"
        case .problem: return "failed"
        case .working: return "working"
        case .maybeNeedsYou: return "maybe needs you"
        case .quietUnfinished: return "quiet · turn not finished"
        case .reviewReady: return "review ready"
        case .done: return "done"
        case .doneNoSummary: return "done · no summary"
        case .unknown: return "status unknown"
        }
    }

    /// Needs you and Problem ask for attention (the block's "need you" counts).
    public var asksForAttention: Bool { self == .needsYou || self == .problem }

    /// Done or Review ready: what "Pit all done" pits.
    public var isDone: Bool { self == .done || self == .doneNoSummary || self == .reviewReady }
}

/// Todos replayed from the tail (`mcp__ccd_turn__update_plan`, TodoWrite as a fallback).
public struct CodeSessionTodos: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public enum Status: String, Sendable { case pending, inProgress, completed }
        public var text: String
        public var status: Status
        public init(text: String, status: Status) { self.text = text; self.status = status }
    }
    public var items: [Item]
    public init(items: [Item]) { self.items = items }

    public var done: Int { items.filter { $0.status == .completed }.count }
    public var total: Int { items.count }
    /// The item in progress, else the first pending one.
    public var current: Item? { items.first { $0.status == .inProgress } ?? items.first { $0.status == .pending } }
}

/// One "Now" line with its time (the peek's last 5 steps).
public struct CodeSessionStep: Sendable, Equatable {
    /// In words, file names only, never paths: "running: swift test", "editing CommandOffer.swift".
    public var words: String
    public var at: Date
    public init(words: String, at: Date) { self.words = words; self.at = at }
}

/// An offer of the latest finished reply with the classifier's result (for the class chips and the offer line).
/// The sheet classifies again on its own; this copy is for display only.
public struct CodeOfferEntry: Sendable, Equatable, Identifiable {
    public var offer: CommandOffer
    public var assessment: CommandAssessment
    public var id: CommandOffer.ID { offer.id }
    public init(offer: CommandOffer, assessment: CommandAssessment) { self.offer = offer; self.assessment = assessment }
}

/// What `session-popouts.json` says about a session's pop-out: only a hint for the window join.
public struct CodePopoutHint: Sendable, Equatable {
    /// The bounds the file holds (top-left origin, points), which may be stale.
    public var bounds: CGRect?
    public init(bounds: CGRect?) { self.bounds = bounds }
}

/// Everything the block needs about one session at one moment. Value type: the data side publishes a new array on
/// change.
public struct CodeSessionSnapshot: Sendable, Equatable, Identifiable {
    /// `local_<id>` (checked against `^local_[A-Za-z0-9-]{1,64}$`). Never logged.
    public var id: String
    /// The local index of this session in this run (`#3` in logs).
    public var index: Int
    public var profile: CodeProfile
    /// `title` without a `<sshHost> · ` prefix and without the trailing "(two words)" nickname.
    public var headline: String
    /// The worktree nickname, e.g. "quiet fern".
    public var nickname: String?
    /// The full title and the earlier titles, for the window join by `AXTitle`.
    public var title: String
    public var previousTitles: [String]
    /// Where it runs: local, SSH or unknown, with the SSH host alias and the working folder.
    public var place: CommandSessionFacts.Place
    public var sshHost: String?
    public var cwd: String?
    /// The session's file names no SSH configuration and `cwd` is on an external or network volume (a refused root, never
    /// looked up): the place is unknown, and none of the session's commands runs or is typed (Copy only).
    public var cwdOnRefusedRoot: Bool
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    public var state: CodeSessionState
    /// The word shown, e.g. "failed" or "stopped" for Problem.
    public var stateWord: String
    /// When the session last wrote something (transcript growth or `lastActivityAt`).
    public var lastActivity: Date?
    /// Set when nothing was written for 30 min: the quiet overlay ("quiet 40 min", screen at 50%).
    public var quietSince: Date?
    /// The current summary's `status_detail` and `needs_action`; nil when there is no current summary.
    public var tldr: String?
    public var askLine: String?
    /// While working: the last tool_use in words.
    public var now: String?
    public var todos: CodeSessionTodos?
    /// The last 5 steps, newest last.
    public var steps: [CodeSessionStep]
    /// Transcript bytes written per minute over the last 30 minutes, oldest first (sizes only).
    public var sparkline: [Int]
    /// The fresh offers of the latest finished reply, in reply order, at most 8; empty when stale.
    public var offers: [CodeOfferEntry]
    /// How many shell blocks the reply had beyond the 8 offered ("8 of 12 commands").
    public var offersNotShown: Int
    /// From `session-popouts.json`: present when Claude has this session in a pop-out window.
    public var popout: CodePopoutHint?
    public var isArchived: Bool
    /// When the latest turn finished (its `end_turn`), nil while a turn runs.
    public var turnFinishedAt: Date?

    // MARK: Derived values: filled by the derivers, empty without them

    /// When the work started: the latest turn of the user's or another session's, followed by the turns background
    /// notices started since; the current turn when that is over 12 hours old or missing.
    public var workStartedAt: Date?
    /// The latest turn's final reply while that turn is finished, nil while a turn runs or when its uuid fails
    /// `^[0-9A-Za-z-]{1,64}$`. Finished records and Ready keys use it.
    public var replyUUID: String?
    /// How far the work is, and when it will be done.
    public var progress: CodeProgress?
    public var eta: CodeETA?
    /// What the work produced or handed over, at most `CodeTuning.maxResults` buttons, the first one first.
    public var results: [CodeResult]
    /// Links of the final reply that are no result ("2 other links in the reply").
    public var otherLinkCount: Int
    /// "Looks stuck" and "Same file", and the fleet dashboard.
    public var warnings: [CodeWarning]
    public var dashboard: CodeDashboard?
    /// Offers of earlier replies that stay runnable behind R22 (`offer.supersession` set), oldest reply first.
    public var earlierOffers: [CodeOfferEntry]
    /// The latest finished work.
    public var finished: CodeFinishedMark?
    /// Something new arrived since the user last looked: a finished turn, an offer, a result or a warning.
    public var unread: Bool

    public init(id: String, index: Int, profile: CodeProfile, headline: String, nickname: String? = nil, title: String,
                previousTitles: [String] = [], place: CommandSessionFacts.Place, sshHost: String? = nil,
                cwd: String? = nil, cwdOnRefusedRoot: Bool = false, model: String? = nil, effort: String? = nil,
                permissionMode: String? = nil, state: CodeSessionState, stateWord: String? = nil,
                lastActivity: Date? = nil, quietSince: Date? = nil,
                tldr: String? = nil, askLine: String? = nil, now: String? = nil, todos: CodeSessionTodos? = nil,
                steps: [CodeSessionStep] = [], sparkline: [Int] = [], offers: [CodeOfferEntry] = [],
                offersNotShown: Int = 0, popout: CodePopoutHint? = nil, isArchived: Bool = false,
                turnFinishedAt: Date? = nil, workStartedAt: Date? = nil, replyUUID: String? = nil,
                progress: CodeProgress? = nil, eta: CodeETA? = nil, results: [CodeResult] = [], otherLinkCount: Int = 0,
                warnings: [CodeWarning] = [], dashboard: CodeDashboard? = nil, earlierOffers: [CodeOfferEntry] = [],
                finished: CodeFinishedMark? = nil, unread: Bool = false) {
        self.id = id; self.index = index; self.profile = profile; self.headline = headline; self.nickname = nickname
        self.title = title; self.previousTitles = previousTitles; self.place = place; self.sshHost = sshHost
        self.cwd = cwd; self.cwdOnRefusedRoot = cwdOnRefusedRoot; self.model = model; self.effort = effort
        self.permissionMode = permissionMode
        self.state = state; self.stateWord = stateWord ?? state.word; self.lastActivity = lastActivity
        self.quietSince = quietSince; self.tldr = tldr; self.askLine = askLine; self.now = now; self.todos = todos
        self.steps = steps; self.sparkline = sparkline; self.offers = offers; self.offersNotShown = offersNotShown
        self.popout = popout; self.isArchived = isArchived; self.turnFinishedAt = turnFinishedAt
        self.workStartedAt = workStartedAt; self.replyUUID = replyUUID; self.progress = progress; self.eta = eta
        self.results = results; self.otherLinkCount = otherLinkCount; self.warnings = warnings
        self.dashboard = dashboard; self.earlierOffers = earlierOffers; self.finished = finished; self.unread = unread
    }
}

/// A session of a readable copy that the user used, or that was active, in the last hours, known from its session file
/// alone: no transcript of an unfollowed session is read. The block picks the followed set from these and the pop-outs.
public struct CodeRecentSession: Sendable, Equatable, Identifiable {
    /// `local_<id>`.
    public var id: String
    /// The copy it belongs to (a running readable one).
    public var profile: CodeProfile
    /// The session file's `lastFocusedAt` and `latestUserFrameAt`: the user's own input. Kept apart, so a field found
    /// to move on the session's own writing can be ignored.
    public var lastFocusedAt: Date?
    public var latestUserFrameAt: Date?
    /// The session file's `lastActivityAt`: the session's own activity, any kind.
    public var ownLastActivity: Date?

    /// A recent session from its session file's fields.
    public init(id: String, profile: CodeProfile, lastFocusedAt: Date? = nil, latestUserFrameAt: Date? = nil,
                ownLastActivity: Date? = nil) {
        self.id = id; self.profile = profile; self.lastFocusedAt = lastFocusedAt
        self.latestUserFrameAt = latestUserFrameAt; self.ownLastActivity = ownLastActivity
    }

    /// The later of `lastFocusedAt` and `latestUserFrameAt`: what the followed set's recent sessions are chosen and
    /// ordered by.
    public var usersLastActivity: Date? { [lastFocusedAt, latestUserFrameAt].compactMap { $0 }.max() }
}

/// The data side as the block sees it. Implemented by Data/ (`CodeSessionsEngine`); tests and previews use a fake.
@MainActor
public protocol CodeSessionsSource: AnyObject {
    /// Sessions of every readable copy that have a pop-out, plus the ones the block asked to watch, in stable order.
    var sessions: [CodeSessionSnapshot] { get }
    /// The copies found running now (letter order). The block shows profile marks only when there is more than one.
    var runningProfiles: [CodeProfile] { get }
    /// The running Claude processes with their copy and app path (the window join works per pid; the deep-link fallback
    /// opens the copy's own app).
    var runningProcesses: [ClaudeProcessInfo] { get }
    /// "Claude's session files changed (Claude <version>). Showing titles only." when most files fail.
    var banner: String? { get }
    /// Called on the main thread after `sessions`, `runningProfiles` or `banner` changed.
    var onChange: (() -> Void)? { get set }
    /// Which sessions' transcripts to watch closely: the followed sessions (pop-outs and recent main-window sessions, at
    /// most 24). They appear in `sessions` too, with `popout == nil` when they have none.
    func setWatched(_ sessionIDs: Set<String>)
    /// The block became visible or hidden: hidden means FSEvents only, no timers.
    func setStripVisible(_ visible: Bool)
    func start()
    func stop()
    /// Unarchived sessions of the running readable copies whose session file passes the session-file checks and whose
    /// `usersLastActivity` or `ownLastActivity` lies within the last `hours` (at most
    /// `CodeTuning.readyRecentHoursMax`), the user's most recent first, then the session's own, then by id; pop-out
    /// sessions included. Nothing for `hours` ≤ 0.
    func recentSessions(within hours: Double) -> [CodeRecentSession]
}

public extension CodeSessionsSource {
    /// Default for sources that do not know processes (tests, previews).
    var runningProcesses: [ClaudeProcessInfo] { [] }
    /// Default for sources that do not read session files (tests, previews): no recent sessions.
    func recentSessions(within hours: Double) -> [CodeRecentSession] { [] }
}
