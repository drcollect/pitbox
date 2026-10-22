import CoreGraphics
import Foundation
import PitboxKit

/// When `WindowGuard` sets Chromium/Electron's `AXManualAccessibility` flag on an app.
///
/// Window move/resize works through AppKit's own window accessibility, so most Chromium and Electron apps need
/// nothing. Turning the flag on makes the app build its full web accessibility tree: more CPU and memory in that app,
/// and some apps change behavior (VS Code, for one, may switch to its screen-reader mode). `AXEnhancedUserInterface`
/// is never touched: it slows down or animates window moves.
public enum ManualAccessibilityPolicy: String, Sendable, CaseIterable {
    /// Never set it.
    case never
    /// Set it once for an app whose windows the window server shows over the block while Accessibility lists no
    /// windows at all for it (the classic Electron symptom), then look again. Default.
    case whenWindowsMissing
    /// Set it for every app that bundles Electron or Chromium as soon as it is observed.
    case electronAndChromium
}

/// Tuning for `WindowGuard`. Times are in seconds, sizes in points.
public struct GuardOptions: Equatable, Sendable {
    /// Apps whose windows are never touched (in addition to Pitbox itself, which is always skipped by process id).
    public var exemptBundleIDs: Set<String>
    /// Log the corrections the guard would make without applying them.
    public var dryRun: Bool
    /// Period of the safety-net pass over all on-screen windows (AX notifications are not reliable).
    public var reconcileInterval: TimeInterval
    /// Quiet time after the last move/resize notification of a window before it is corrected (coalesces bursts
    /// and lets zoom/tiling animations finish, so a zoomed window is shrunk once instead of flickering).
    public var settleDelay: TimeInterval = 0.15
    /// A window that keeps posting notifications is still looked at this long after the first one, even if it never
    /// goes quiet for `settleDelay`.
    public var maxSettleDelay: TimeInterval = 2
    /// After the display arrangement changes (a mode change, a display added or removed) or the system wakes, nothing
    /// is corrected until it has been stable this long: a display waking up can report a temporary mode for a second
    /// or two, and correcting windows against it would shrink them for good.
    public var displayChangeHold: TimeInterval = 3
    /// Delay after a mouse release before correcting what the user dragged.
    public var releaseSettleDelay: TimeInterval = 0.12
    /// How often the mouse button is polled while a correction waits for a release (backs up the mouse-up monitor).
    public var dragPollInterval: TimeInterval = 0.1
    /// A corrected window is looked at again after this long, in case its app put it back.
    public var verifyDelay: TimeInterval = 0.5
    /// Delay before re-checking windows after a Space switch (the switch animation).
    public var spaceChangeDelay: TimeInterval = 0.4
    /// Windows are never shrunk below this width (nor below the width their app refuses to go under). The height is
    /// never changed.
    public var minimumWindowSize = CGSize(width: 320, height: 200)
    /// Shrinking is preferred only if it keeps at least this share of the window's width; otherwise the window is
    /// moved at full size (a window dragged mostly into the strip slides back instead of becoming a sliver).
    /// 0 means "always prefer shrinking".
    public var minimumShrinkFraction: Double = 0.5
    /// Accessibility subroles that are managed. Default: standard windows and dialogs. Left alone: floating panels
    /// (palettes, inspectors, HUDs: placed on purpose), sheets (they follow their parent), popovers and menus, and
    /// system dialogs (security prompts).
    public var managedSubroles: Set<String> = ["AXStandardWindow", "AXDialog"]
    /// Anti-fight: this many corrections of one window within `fightWindow` seconds, without the user causing them,
    /// stop the guard from correcting that window for `fightCooldown` seconds (doubling on each repeat, up to
    /// `maxFightCooldown`).
    public var fightThreshold = 3
    public var fightWindow: TimeInterval = 10
    public var fightCooldown: TimeInterval = 60
    public var maxFightCooldown: TimeInterval = 900
    /// A correction within this long after a mouse release counts as caused by the user (never as a fight).
    public var userActionWindow: TimeInterval = 1.5
    /// A mouse button that reads as held for longer than this no longer delays corrections (stuck-button safety).
    public var maxDragDeferral: TimeInterval = 20
    /// Accessibility messaging timeout, so a hung app cannot block the guard for the 6 s system default.
    public var messagingTimeout: Double = 0.5
    public var manualAccessibility: ManualAccessibilityPolicy = .whenWindowsMissing
    /// Overlaps of at most this many points are ignored.
    public var tolerance: CGFloat = 1

    public init(exemptBundleIDs: Set<String> = GuardOptions.defaultExemptBundleIDs, dryRun: Bool = false,
                reconcileInterval: TimeInterval = 1) {
        self.exemptBundleIDs = exemptBundleIDs
        self.dryRun = dryRun
        self.reconcileInterval = reconcileInterval
    }

    /// Pitbox's own bundle id (`AppIdentity.bundleID`) and system UI that must never be moved. Most of these are not
    /// regular apps (and so are skipped anyway); listing them protects against a policy change in a future macOS.
    public static let defaultExemptBundleIDs: Set<String> = [
        AppIdentity.bundleID, "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.loginwindow", "com.apple.SecurityAgent",
        "com.apple.screencaptureui", "com.apple.PIPAgent",
    ]

    /// `base` adjusted by `PITBOX_GUARD_DRYRUN=1` and `PITBOX_GUARD_EXEMPT=bundle.id,other.id`.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                       base: GuardOptions = GuardOptions()) -> GuardOptions {
        var options = base
        if let value = environment["PITBOX_GUARD_DRYRUN"] {
            options.dryRun = ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
        }
        if let value = environment["PITBOX_GUARD_EXEMPT"] {
            let ids = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            options.exemptBundleIDs.formUnion(ids)
        }
        return options
    }
}
