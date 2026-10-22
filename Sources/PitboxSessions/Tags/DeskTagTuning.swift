import CoreGraphics
import Foundation
import PitboxKit

/// The numbers of desk tags, in one place. Three of them (`tagRightInset`, `tagPlaceCoalesce`, `tagShowAfterDrag`)
/// come from `CodeTuning`; the rest are the tags' own sizes and limits. The right inset is the one the attended check
/// may change: it grows until the tag covers no control Claude draws at the right end of a pop-out's title bar (the lab
/// mode can try another value without a rebuild).
enum DeskTagTuning {
    /// The mark in a tag's (and the drop label's) dark circle: the app name's first letter, so a fork renames it too.
    static let glyph = String(AppIdentity.displayName.prefix(1))

    // MARK: Placement

    /// The tag's right edge sits this far left of the window's right edge, clear of the resize corner.
    static var rightInset: CGFloat { CodeTuning.tagRightInset }
    /// With less room than this above the window inside its display's visible frame, the tag moves inside the window.
    static let insideBelowRoom: CGFloat = 12
    /// Inside the window, the tag's top sits this far under the window's top edge.
    static let insideTop: CGFloat = 4
    /// A tag's right edge stays at least this far left of the strip (a tag is never inside the strip).
    static let stripGap: CGFloat = 4
    /// A tag is never wider than the window minus this (else only the glyph's circle and a count).
    static let windowMargin: CGFloat = 40

    // MARK: Pills

    static let pillHeight: CGFloat = 22
    static let pillRadius: CGFloat = 11
    static let pillGap: CGFloat = 4
    static let pillMaxWidth: CGFloat = 260
    static let circleSize: CGFloat = 16
    static let circleInset: CGFloat = 3
    static let textGap: CGFloat = 6
    static let textTrailing: CGFloat = 10
    static let fontSize: CGFloat = 12

    // MARK: Visibility

    /// Windows smaller than this get no tag.
    static let minimumWindow = CGSize(width: 320, height: 200)
    /// A window whose bounds reach every edge of its display within this many points covers it.
    static let coverTolerance: CGFloat = 1

    // MARK: Following

    /// A tag is placed at most once per this interval per window (notifications coalesce on the observer thread).
    static var placeCoalesce: TimeInterval { CodeTuning.tagPlaceCoalesce }
    /// After a drag, tags show again this long after the last move with the button up.
    static var showAfterDrag: TimeInterval { CodeTuning.tagShowAfterDrag }
    /// While a drag runs, the left button is read this often (main thread, only during a drag).
    static let dragPoll: TimeInterval = 0.05
    /// The backstop pass for missed notifications, while at least one tag is watched (1 Hz).
    static let backstopInterval: TimeInterval = 1
    /// `AXFullScreen` is read once a resize has been quiet this long.
    static let fullScreenSettle: TimeInterval = 0.3
    /// Registration retries for a Claude copy that is not ready yet (then given up until the interest changes).
    static let observeRetryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]
    /// The Accessibility messaging timeout, set per app element (never the system-wide element: the guard owns it).
    static let messagingTimeout: Float = 1

    // MARK: Desk peek

    static let peekWidth: CGFloat = 360
    static let peekGap: CGFloat = 8
    static let peekMaxHeight: CGFloat = 560
    static let peekMargin: CGFloat = 8
    /// The desk peek closes this long after the pointer left both the tag and the peek.
    static let peekCloseDelay: TimeInterval = 0.25

    // MARK: Arming

    /// ▦ on a tag and ↗ ▤ ▦ in the desk peek count a press only this long after they appeared or moved.
    static var armDelay: TimeInterval { CodeTuning.openButtonArmDelay }

    // MARK: Lab

    /// Lab lines about single notifications, at most this many a minute.
    static let labNoteLinesPerMinute = 240
    static let labCostInterval: TimeInterval = 60
    /// The click check runs this long after a click on a tag.
    static let labClickCheckDelay: TimeInterval = 0.3
}
