import CoreGraphics
import Foundation
import PitboxKit

// The window side of Code monitors: where each session's pop-out window is, what
// a click on its monitor does, and the seam the block talks to. Everything here is the app's own words and numbers:
// no window title or other session text is ever part of a status, a result or a log line.

/// Where a session's pop-out window is, as the last window pass saw it.
/// A matched pop-out on the desk: its process and window number (desk tags place and order their panels by it; drag-to-park
/// recognises a dragged pop-out by it). Read-only facts from the window join; nothing acts on the window through it.
public struct CodeDeskWindow: Hashable, Sendable {
    public var pid: pid_t
    public var windowNumber: CGWindowID
    public init(pid: pid_t, windowNumber: CGWindowID) { self.pid = pid; self.windowNumber = windowNumber }
}

public enum CodeWindowPlace: Equatable, Sendable {
    /// On screen in the current Space.
    case onDesk
    /// Minimized by the app at `since` (a record in `code-monitors.json`).
    case parked(since: Date)
    /// Minimized by the user themselves (no record). A click restores it, like a parked one.
    case minimized
    /// A record survived an app restart but its window was not found again yet.
    case parkedNotMatched
    /// A window matched earlier that Accessibility cannot see any more while Claude still lists the pop-out: it is on
    /// another Space. (Windows are never matched by position alone: a hidden window of Claude's looks the
    /// same.)
    case otherSpace
    /// Claude is hidden (⌘H): every window of that copy is off screen. A click shows it.
    case hidden
    /// Off screen and not minimized while Claude still lists the pop-out and is not hidden: Claude hid the window
    /// itself. Accessibility cannot bring it back (`AXMinimized = false` does nothing); Claude's Window menu can.
    case hiddenByClaude
    /// The window was closed while parked. A click opens the session in Claude's main window.
    case closed
    /// The session's Claude copy is not running.
    case profileNotRunning(letter: String)
    /// No window could be told to be this session's (none found, or two equal titles).
    case notMatched
    /// The app has no Accessibility permission, so windows cannot be matched or parked.
    case noAccessibility
}

/// What a click on a monitor's screen does.
public enum CodeWindowClick: String, Equatable, Sendable {
    case park
    case restore
    /// Activate that Claude process (another Space, or Claude hidden); macOS switches the Space.
    case activate
    /// Open the session through `claude://code/continue?session=…` in that copy's main window (window closed).
    case openInMainWindow
    /// Nothing (not matched, profile not running, an operation in flight).
    case none
}

/// An operation in flight for one session (the monitor shows a spinner and ignores clicks).
public enum CodeWindowBusy: String, Equatable, Sendable {
    case parking, restoring, opening, activating
}

/// The window side of one session: where its window is, an operation in flight, and the last failure.
public struct CodeWindowStatus: Equatable, Sendable {
    public var place: CodeWindowPlace
    public var busy: CodeWindowBusy?
    /// The last failure in the app's words ("couldn't park (Claude didn't answer)"), shown for a while.
    public var problem: String?

    public init(place: CodeWindowPlace, busy: CodeWindowBusy? = nil, problem: String? = nil) {
        self.place = place; self.busy = busy; self.problem = problem
    }

    /// What a click on the monitor's screen does now. Nothing while an operation is in flight.
    public var click: CodeWindowClick {
        guard busy == nil else { return .none }
        switch place {
        case .onDesk: return .park
        case .parked, .minimized: return .restore
        case .otherSpace, .hidden: return .activate
        case .closed: return .openInMainWindow
        case .parkedNotMatched, .hiddenByClaude, .profileNotRunning, .notMatched, .noAccessibility: return .none
        }
    }

    /// Whether the window counts as parked for the monitor (parked by the app, minimized, or parked before a
    /// restart and not found again yet).
    public var isParked: Bool {
        switch place {
        case .parked, .minimized, .parkedNotMatched: return true
        default: return false
        }
    }

    /// The chip on the monitor: "on your desk", "parked 12 min", "on another Space", … An operation in flight
    /// and a recent failure win over the place.
    public func chip(now: Date) -> String {
        if let busy {
            switch busy {
            case .parking: return "pitting…"
            case .restoring: return "restoring…"
            case .opening: return "opening…"
            case .activating: return "switching…"
            }
        }
        if let problem { return problem }
        switch place {
        case .onDesk: return "on track"
        case .parked(let since):
            let minutes = Int(now.timeIntervalSince(since) / 60)
            return minutes < 1 ? "in the pit" : "in the pit \(CodeWindowStatus.duration(minutes: minutes))"
        case .minimized: return "minimized"
        case .parkedNotMatched: return "in the pit · window not matched"
        case .otherSpace: return "on another Space"
        case .hidden: return "Claude is hidden"
        case .hiddenByClaude: return "hidden by Claude"
        case .closed: return "closed · opens in main window"
        case .profileNotRunning(let letter): return "Claude \(letter) is not running"
        case .notMatched: return "window not matched"
        case .noAccessibility: return "needs Accessibility"
        }
    }

    /// A short explanation for the monitor's tooltip, in the app's words, or nil.
    public var tooltip: String? {
        switch place {
        case .otherSpace: return "On another Space. A click switches to that Space."
        case .hidden: return "Claude is hidden. A click shows it."
        case .hiddenByClaude: return "Claude hid this window. Bring it back from Claude's Window menu."
        case .closed: return "The window was closed while in the pit. A click opens the session in Claude's main window."
        case .parkedNotMatched:
            return "Pitted before \(AppIdentity.displayName) restarted. The window is found again once it can be told apart."
        case .notMatched:
            return "\(AppIdentity.displayName) can't tell which window is this session's (missing, or two with the same title)."
        case .noAccessibility: return "Pit stops need \(AppIdentity.displayName)'s Accessibility permission."
        default: return nil
        }
    }

    /// "12 min", "2 h", "3 d".
    static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 48 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / (24 * 60)) d"
    }
}

/// How ⌃⌥P ended. The app turns it into the voice HUD's short line (`hudLine`).
public enum CodeParkFrontmostResult: Equatable, Sendable {
    /// The front pop-out was parked.
    case parked
    /// The front window is a pop-out that is already parked or minimized.
    case alreadyParked
    /// The front app is not a Claude copy, or its focused window is not a matched pop-out (the main window included).
    case notAPopout
    /// The pop-out did not minimize; the reason in the app's words.
    case failed(reason: String)
    /// The app has no Accessibility permission.
    case noAccessibility

    /// The HUD line, in the app's words; never a title.
    public var hudLine: String {
        switch self {
        case .parked: return "In the pit"
        case .alreadyParked: return "That pop-out is already in the pit"
        case .notAPopout: return "The front window isn't a Code pop-out"
        case .failed(let reason): return reason.prefix(1).uppercased() + reason.dropFirst()
        case .noAccessibility: return "Pit stops need \(AppIdentity.displayName)'s Accessibility permission"
        }
    }

    public var succeeded: Bool { self == .parked }
}

/// How "Park all done" ended.
public struct CodeParkAllResult: Equatable, Sendable {
    /// Windows parked.
    public var parked: Int
    /// Done monitors whose window is on another Space (never parked by Park all done).
    public var skippedOtherSpace: Int
    /// Windows that did not minimize.
    public var failed: Int

    public init(parked: Int = 0, skippedOtherSpace: Int = 0, failed: Int = 0) {
        self.parked = parked; self.skippedOtherSpace = skippedOtherSpace; self.failed = failed
    }

    /// The header's short note: "Parked 3 · 1 on another Space, not parked", nil when there is nothing to say.
    public var note: String? {
        var parts: [String] = []
        if parked > 0 { parts.append("\(parked) into the pit") }
        if skippedOtherSpace > 0 { parts.append("\(skippedOtherSpace) on another Space, not pitted") }
        if failed > 0 { parts.append("\(failed) didn't answer") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What the block needs from the window side: the statuses, the actions, and the inputs. Implemented by
/// `CodeWindowParker`; tests use a fake. Main thread only; the work itself runs on the parker's own thread.
@MainActor
public protocol CodeWindowParking: AnyObject {
    /// The window side of every session the parker was given, by session id (`local_<id>`).
    var statuses: [String: CodeWindowStatus] { get }
    /// Sessions with a parked record (also from before a restart) or a window closed while parked: the block keeps
    /// their monitors and asks the source to watch them.
    var parkedSessionIDs: Set<String> { get }
    /// Called on the main thread after `statuses`, `parkedSessionIDs` or `deskWindows` changed.
    var onChange: (() -> Void)? { get set }
    /// Every matched pop-out on the desk now, by session id (for desk tags and drag-to-park).
    var deskWindows: [String: CodeDeskWindow] { get }
    /// Loads the parked records and runs a first pass (once).
    func start()
    /// Stops the pass; the records stay on disk.
    func stop()
    /// The sessions the block shows (titles and pop-out hints for the window join) and the running Claude processes
    /// from the data side (`CodeSessionsSource.runningProcesses`: pids for the join, app paths for the deep link).
    func update(sessions: [CodeSessionSnapshot], processes: [ClaudeProcessInfo])
    /// The block is visible (1 Hz window pass) or hidden (no timer at all).
    func setActive(_ active: Bool)
    /// A click on a monitor (or a peek button): park, restore, activate, or open in the main window.
    func perform(_ click: CodeWindowClick, sessionID: String)
    /// Parks every listed session whose window is on the desk, skipping other Spaces.
    func parkAllDone(_ sessionIDs: [String]) async -> CodeParkAllResult
    /// ⌃⌥P: parks the frontmost Claude pop-out.
    func parkFrontmostPopout() async -> CodeParkFrontmostResult
}

public extension CodeWindowParking {
    /// Default for parkers that do not publish desk windows (tests, previews).
    var deskWindows: [String: CodeDeskWindow] { [:] }
}
