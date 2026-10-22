import CoreGraphics
import Foundation

/// Why a tag is not shown. The raw value is the log word.
enum DeskTagHideReason: String, Equatable, Sendable {
    case stripHidden = "block_hidden"
    case settingOff = "setting_off"
    /// The attended check has not passed (or failed) and the lab mode is off.
    case notFeasible = "not_feasible"
    case noContent = "no_content"
    /// The window server no longer lists the window.
    case closed
    case minimized
    case appHidden = "app_hidden"
    /// On another Space or off screen (the window server's on-screen flag is false).
    case offScreen = "off_screen"
    case fullScreen = "full_screen"
    case coversDisplay = "covers_display"
    case tooSmall = "too_small"
    /// On no display, or not even the compact form fits.
    case noRoom = "no_room"
    /// A drag is moving the window (shown again 0.15 s after the last move with the button up).
    case dragging
    /// The fallback cover mode found a window in front of the Claude window over the tag.
    case covered
}

/// What the controller knows about one desk window right now.
struct DeskTagWindowFacts: Equatable {
    /// The window server's latest entry; nil before the first read and once the window is gone.
    var window: DeskTagServerWindow?
    /// The window was read at least once (so a nil `window` means closed, not "not read yet").
    var wasRead = false
    /// The latest notification was a miniaturize and the window is off screen.
    var minimized = false
    /// The app was hidden (⌘H) and not shown again since.
    var appHidden = false
    /// `AXFullScreen`, when read.
    var fullScreen: Bool?
    var dragging = false
    /// Fallback cover mode only.
    var covered = false
}

/// The settings and states every tag shares.
struct DeskTagGlobalState: Equatable {
    var stripVisible = false
    var settingOn = true
    var feasible = false
}

/// The hiding rules, in order. Pure.
enum DeskTagVisibility {
    /// The first reason that hides a tag, nil when it shows. `display` is the window's display (nil: none).
    static func hideReason(global: DeskTagGlobalState, hasContent: Bool, facts: DeskTagWindowFacts,
                           display: DeskTagDisplay?) -> DeskTagHideReason? {
        if !global.stripVisible { return .stripHidden }
        if !global.settingOn { return .settingOff }
        if !global.feasible { return .notFeasible }
        if !hasContent { return .noContent }
        guard let window = facts.window else { return facts.wasRead ? .closed : .offScreen }
        if facts.minimized, !window.isOnScreen { return .minimized }
        if facts.appHidden { return .appHidden }
        if !window.isOnScreen { return .offScreen }
        if facts.fullScreen == true { return .fullScreen }
        guard let display else { return .noRoom }
        if covers(window.bounds, display: display) { return .coversDisplay }
        if window.bounds.width < DeskTagTuning.minimumWindow.width || window.bounds.height < DeskTagTuning.minimumWindow.height {
            return .tooSmall
        }
        if facts.dragging { return .dragging }
        if facts.covered { return .covered }
        return nil
    }

    /// The window reaches every edge of its display (native full screen, or a window made as large as the screen).
    static func covers(_ bounds: CGRect, display: DeskTagDisplay) -> Bool {
        let tolerance = DeskTagTuning.coverTolerance
        return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(display.frame)
    }

    /// The fallback's covered check: some on-screen window of another app at the Claude window's level (layer 0
    /// for an ordinary pop-out) in front of it in the front-to-back list intersects the tag. The app's own windows
    /// (the tags, the block's panel) never count. False when the Claude window is not in the list (other rules hide
    /// it then).
    static func isCovered(tag: CGRect, claude number: CGWindowID, frontToBack: [DeskTagServerWindow], ownPID: pid_t) -> Bool {
        guard let index = frontToBack.firstIndex(where: { $0.number == number }) else { return false }
        let layer = frontToBack[index].layer
        return frontToBack[..<index].contains { covers($0, tag: tag, layer: layer, ownPID: ownPID) }
    }

    private static func covers(_ window: DeskTagServerWindow, tag: CGRect, layer: Int, ownPID: pid_t) -> Bool {
        guard window.layer == layer, window.pid != ownPID, window.alpha > 0.05 else { return false }
        let overlap = window.bounds.intersection(tag)
        return !overlap.isNull && overlap.width >= 1 && overlap.height >= 1
    }

    /// The lab's order check for the first cover mode: the tag panel lies in front of its Claude window, and every
    /// other app's window in front of the Claude window that overlaps the tag also lies in front of the tag. Nil when
    /// either window is missing from the list.
    static func orderHolds(panel: CGWindowID, claude: CGWindowID, tag: CGRect, frontToBack: [DeskTagServerWindow],
                           ownPID: pid_t) -> Bool? {
        guard let panelIndex = frontToBack.firstIndex(where: { $0.number == panel }),
              let claudeIndex = frontToBack.firstIndex(where: { $0.number == claude }) else { return nil }
        guard panelIndex < claudeIndex else { return false }
        let layer = frontToBack[claudeIndex].layer
        return !frontToBack[(panelIndex + 1)..<claudeIndex].contains { covers($0, tag: tag, layer: layer, ownPID: ownPID) }
    }
}
