import CoreGraphics
import Foundation
import PitboxKit

// Desk tags: the app's small label beside a Claude Code pop-out on the desk.
// This file holds the types the composition root sees. Everything a tag shows is the app's own words, numbers and
// session text through the plain-text renderer; a tag never takes the keyboard, never activates the app and never
// acts on a Claude window (it only reads where the window is).

/// One matched desk pop-out as the window join holds it: the session, its Claude process and its
/// window-server number. Only windows on screen of a running readable copy; never the main window, never a parked one.
public struct DeskTagDeskWindow: Hashable, Sendable {
    /// `local_<id>`. Never logged.
    public var sessionID: String
    public var pid: pid_t
    public var windowNumber: CGWindowID

    /// A desk window from the join's numbers.
    public init(sessionID: String, pid: pid_t, windowNumber: CGWindowID) {
        self.sessionID = sessionID; self.pid = pid; self.windowNumber = windowNumber
    }
}

/// Whether desk tags were shown to work on this Mac (an attended check in the lab mode). Until it passes, tags show
/// only in the lab mode (`DeskTagLabOptions`): the desk sessions' commands, files, finished tasks and warnings are in
/// the Ready list either way, so "off" loses nothing but the tags.
public enum DeskTagFeasibility: String, Sendable {
    /// The check has not been run yet: tags only in the lab mode.
    case untested
    /// The check passed: tags follow the `deskTags` setting.
    case passed
    /// The check failed: tags are off whatever the setting says (desk sessions stay in the Ready list only).
    case failed

    /// The value the app ships with; change this one line once the check has run.
    public static let current: DeskTagFeasibility = .untested

    /// Whether tags may show at all, before the setting and the panel's visibility are asked.
    func allowsTags(lab: Bool) -> Bool {
        switch self {
        case .passed: return true
        case .untested: return lab
        case .failed: return false
        }
    }
}

/// How a tag stays under windows that cover its Claude window.
public enum DeskTagCoverMode: String, Sendable {
    /// The first way: the panel at the normal window level, ordered directly above its Claude window and re-ordered
    /// after every activation and focus change of that copy, so the window server's own order covers it.
    case orderedAbove = "above"
    /// The fallback: the panel at the floating level, hidden whenever an on-screen layer-0 window in front of the Claude
    /// window intersects the tag (checked on every notification and in the 1 Hz pass; up to a second of a tag over a
    /// covering window is the known cost).
    case floating

    /// The mode the app ships with; change it if the attended check shows that ordering does not hold.
    public static let current: DeskTagCoverMode = .orderedAbove
}

/// What a click on a tag or on a desk-peek row asks the app to do. Nothing here runs a command: an offer opens
/// its confirmation sheet, whose own rules hold. Implemented by the composition root on top of the
/// block's and the Ready list's paths, so the sheet's events reach the run book and the Ready list as from any other
/// surface. Main thread.
@MainActor
public protocol DeskTagActions: AnyObject {
    /// Opens the confirmation sheet (or the Fetch file sheet) of one offer of `sessionID`, beside the block. `anchor`
    /// is the tag's frame in screen coordinates (y up, like a monitor's frame).
    func openOffer(_ offer: CommandOffer.ID, sessionID: String, anchor: CGRect)
    /// Opens one result (↗ or ▤) after an armed click: the result's own click-time checks still apply.
    func openResult(_ resultID: String, sessionID: String, anchor: CGRect)
    /// Opens the session's dashboard in the browser after an armed click.
    func openDashboard(sessionID: String)
    /// Parks the session's window.
    func park(sessionID: String)
    /// Copies the session's link (the peek's Copy link).
    func copyLink(sessionID: String)
}

/// Offers and warnings the Ready list no longer shows (dismissed, run, typed, fetched; warnings OK'd): their tags go
/// too. Later keeps an item, and so its tag.
public struct DeskTagSuppressed: Equatable, Sendable {
    public var offers: Set<CommandOffer.ID>
    /// Per session id, the ids of its silenced warnings (`CodeWarning.id`).
    public var warnings: [String: Set<String>]

    /// Nothing suppressed, or the given sets.
    public init(offers: Set<CommandOffer.ID> = [], warnings: [String: Set<String>] = [:]) {
        self.offers = offers; self.warnings = warnings
    }
}

/// The lab mode for the attended checks (notifications, order and clicks, the right inset). Read from the
/// app's environment, so it never persists: `open --env PITBOX_DESKTAG_LAB=1 build/Pitbox.app`.
public struct DeskTagLabOptions: Equatable, Sendable {
    /// `PITBOX_DESKTAG_LAB=1`: tags show although the check has not passed, every matched desk pop-out gets a tag (a
    /// lab pill when nothing else applies), and `[code] desktag lab …` lines measure notifications, placement, order
    /// and clicks.
    public var enabled: Bool
    /// `PITBOX_DESKTAG_COVER=above|floating`: try the other cover mode without a rebuild.
    public var coverMode: DeskTagCoverMode?
    /// `PITBOX_DESKTAG_INSET=<points>` (0-200): try another right inset without a rebuild.
    public var rightInset: CGFloat?

    /// Lab off.
    public init(enabled: Bool = false, coverMode: DeskTagCoverMode? = nil, rightInset: CGFloat? = nil) {
        self.enabled = enabled; self.coverMode = coverMode; self.rightInset = rightInset
    }

    /// The options in `environment` (normally `ProcessInfo.processInfo.environment`). Unknown or out-of-range values
    /// are ignored.
    public static func from(environment: [String: String]) -> DeskTagLabOptions {
        var options = DeskTagLabOptions()
        options.enabled = environment["PITBOX_DESKTAG_LAB"] == "1"
        options.coverMode = environment["PITBOX_DESKTAG_COVER"].flatMap(DeskTagCoverMode.init(rawValue:))
        if let raw = environment["PITBOX_DESKTAG_INSET"], let value = Double(raw), value.isFinite, (0...200).contains(value) {
            options.rightInset = CGFloat(value)
        }
        return options
    }
}
