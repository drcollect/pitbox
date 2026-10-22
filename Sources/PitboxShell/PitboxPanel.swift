import AppKit

/// Where the panel sits in the window stack. `.desktop` keeps it behind every normal window (so it can never cover
/// one) and above the wallpaper, Finder's desktop icons and Apple's desktop widgets; `.aboveWindows` keeps it above
/// normal windows (level 0) so no app window covers it, but below floating (3), status, modal and pop-up windows,
/// so transient pop-ups (for example a screenshot tool's share pop-up, a floating window at level 3) draw over it and
/// stay readable. Pop-ups that other processes show at level 0 or 1 (AutoFill, input-source indicators, popovers and
/// sheets of normal windows, a writing assistant's overlay at level 1) still sit under the panel where they overlap it.
/// The app default is `.aboveWindows` (the menu's "Keep Above Windows"; docked, the host's level wins).
public enum PanelLevel: Equatable, Sendable {
    /// Desktop-icon level + 3: above the wallpaper (desktop level), Finder's icons (desktop-icon level), the
    /// menu bar backdrop (+1) and Apple's desktop widgets (+2); below every normal window (level 0).
    case desktop
    /// `kCGBackstopMenuLevel` (-20): still below normal windows, above everything desktop-related.
    case backstop
    /// An explicit Quartz window level (experiments only).
    case custom(Int)

    /// Floating level - 1 (level 2): above every normal window (level 0, so an app window never covers the panel) and
    /// below floating windows (3), status, modal and pop-up windows, menus, modal alerts and the Dock, so those draw
    /// over the panel. The default ("Keep Above Windows").
    public static var aboveWindows: PanelLevel { .custom(NSWindow.Level.floating.rawValue - 1) }

    /// The AppKit level for this policy.
    public var windowLevel: NSWindow.Level {
        switch self {
        case .desktop: return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)
        case .backstop: return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)))
        case .custom(let raw): return NSWindow.Level(rawValue: raw)
        }
    }

    /// True when the level is above normal windows (level 0), like `.aboveWindows`; false for the levels behind them
    /// (`.desktop`, `.backstop`).
    public var isAboveNormalWindows: Bool { windowLevel.rawValue > NSWindow.Level.normal.rawValue }

    /// The collection behaviour that goes with this level (all Spaces, out of Cmd-` cycling, plus one full-screen flag).
    ///
    /// Behind windows the panel is `.stationary`: Mission Control and Show Desktop leave it alone, like the desktop
    /// picture it sits on. Above windows it is `.transient` instead (AppKit's own default for windows that are not at
    /// the normal level): it floats in every Space and hides in Mission Control and App Exposé. A stationary panel
    /// above windows would stay drawn over Mission Control's window thumbnails in the right quarter of the screen,
    /// covering some of them and blocking clicks on them.
    func collectionBehavior(hideInFullscreen: Bool) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        behavior.insert(isAboveNormalWindows ? .transient : .stationary)
        behavior.insert(hideInFullscreen ? .fullScreenNone : .fullScreenAuxiliary)
        return behavior
    }
}

/// The block's window: borderless, non-activating, on all Spaces, out of window cycling, and stationary (behind
/// windows) or transient (above windows, hidden in Mission Control) depending on its level, see
/// `PanelLevel.collectionBehavior(hideInFullscreen:)`. It becomes key only when a view that takes typing is clicked (text fields, text views,
/// web views, terminals) or when asked to (`makeKeyForTyping()`), and never activates the app, so other apps'
/// windows keep their order and the menu bar stays with the user's app.
///
/// Key status is gated here rather than left to `becomesKeyOnlyIfNeeded`: `NSHostingView` answers
/// `needsPanelToBecomeKey == true` and SwiftUI buttons are not separate views, so AppKit's own rule would make every
/// click on SwiftUI content (monitor chrome, buttons, empty glass) steal keyboard focus from the user's app.
final class PitboxPanel: NSPanel {
    /// Whether the panel may become key right now. Cleared whenever it resigns key.
    private(set) var keyAllowed = false
    /// The level policy and full-screen preference the collection behaviour is derived from.
    private var levelPolicy: PanelLevel = .desktop
    private var hidesInFullscreen = true

    init(contentRect: NSRect, level: PanelLevel, hideInFullscreen: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: true)
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        tabbingMode = .disallowed
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        displaysWhenScreenProfileChanges = true
        hidesInFullscreen = hideInFullscreen
        applyLevel(level)
    }

    /// Sets the window level and the collection behaviour that belongs to it (stationary behind windows, transient
    /// above them), keeping the full-screen preference.
    func applyLevel(_ level: PanelLevel) {
        levelPolicy = level
        self.level = level.windowLevel
        refreshCollectionBehavior()
    }

    /// All Spaces, not in Cmd-` cycling, stationary or transient by level (see
    /// `PanelLevel.collectionBehavior(hideInFullscreen:)`). In native full-screen Spaces it is absent (no
    /// `fullScreenAuxiliary`; `fullScreenNone` only stops the panel itself from going full screen) unless
    /// `hideInFullscreen` is false: then it joins the full-screen Space, and at `.aboveWindows` it draws over the edge
    /// of the full-screen window (the window guard leaves those alone).
    func applyCollectionBehavior(hideInFullscreen: Bool) {
        hidesInFullscreen = hideInFullscreen
        refreshCollectionBehavior()
    }

    private func refreshCollectionBehavior() {
        let behavior = levelPolicy.collectionBehavior(hideInFullscreen: hidesInFullscreen)
        if collectionBehavior != behavior { collectionBehavior = behavior }
    }

    override var canBecomeKey: Bool { keyAllowed }
    override var canBecomeMain: Bool { false }

    /// Makes the panel key for typing (a bucket name field, the console) without activating the app.
    func makeKeyForTyping() {
        keyAllowed = true
        makeKey()
    }

    override func resignKey() {
        super.resignKey()
        keyAllowed = false
    }

    /// Borderless windows may sit anywhere; never let AppKit push the panel below the menu bar or on-screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// A click on a view that takes typing makes the panel key first. Every other click (buttons, monitors, glass) is
    /// delivered without the panel becoming key, so keyboard focus stays in the app the user is typing in.
    override func sendEvent(_ event: NSEvent) {
        if !isKeyWindow, event.type == .leftMouseDown || event.type == .rightMouseDown,
           let hit = hitView(for: event), Self.wantsKeyboard(hit) {
            makeKeyForTyping()
        }
        super.sendEvent(event)
    }

    private func hitView(for event: NSEvent) -> NSView? {
        guard let content = contentView, let frameView = content.superview else { return nil }
        return frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
    }

    /// True if `view` or an ancestor takes typing: an editable text field (including SwiftUI's `TextField`, which is
    /// an `NSTextField` subclass), an editable or selectable text view, or any other `NSTextInputClient` (WKWebView,
    /// terminal views). Deliberately ignores `needsPanelToBecomeKey`, which `NSHostingView` always answers `true`.
    static func wantsKeyboard(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if let field = v as? NSTextField, field.isEditable { return true }
            if let text = v as? NSTextView { if text.isEditable || text.isSelectable { return true } }
            else if v is NSTextInputClient { return true }
            current = v.superview
        }
        return false
    }
}
