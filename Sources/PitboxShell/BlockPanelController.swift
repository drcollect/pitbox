import AppKit
import os
import PitboxKit

/// Owns the block's window: alone at a screen edge or docked beside a host, two columns, one, or the fold rail;
/// show, hide and fold; the keyboard on demand; and the region the window guard keeps other windows out of.
///
/// Use from the main thread. `regions` may be read from any thread. Call `invalidate()` when the app terminates.
///
/// Wiring (app):
/// ```swift
/// let block = BlockPanelController(settings: stored.blockSettings)
/// block.setBlockView(monitorsRootView)               // fills the top
/// block.setDrawerView(console.drawerView)            // at the bottom
/// console.onHeightChanged = { block.setDrawerHeight($0) }
/// block.onSettingsChanged = { stored.save($0) }      // columns, fold, edge, display, gaps, level
/// block.onLayoutChanged = { monitors.apply($0) }     // columns, cell, padding, window side
/// block.rail.counts = RailCounts(needsYou: 1, finished: 2, running: 3)
/// let windowGuard = WindowGuard(regions: block, options: .fromEnvironment())
/// block.show()
/// ```
@MainActor
public final class BlockPanelController: ReservedRegionSource {
    // MARK: ReservedRegionSource

    /// One region while the block is on screen (Quartz coordinates; `edge` is the block's edge alone and the host's
    /// edge docked), none otherwise. Thread-safe.
    nonisolated public var regions: [ReservedRegion] { regionStore.withLock { $0 } }

    /// Called on the main thread after `regions` changed. Set it from the main thread.
    nonisolated(unsafe) public var onRegionsChanged: (() -> Void)?

    // MARK: Callbacks

    /// The block's area changed: its frame (AppKit global), whether the rail shows (folded, or nothing wider fits) and
    /// whether it is on screen. Called after the panel moved: on a fold or any narrowing before the new guard region is
    /// published, on an unfold or any widening after it (docs/DOCK_PROTOCOL.md §7). The dock link sends it as `area`
    /// (not while `showsAloneOverride`: the block is then not beside the host).
    public var onAreaChanged: ((_ frame: CGRect, _ folded: Bool, _ visible: Bool) -> Void)?
    /// The block appeared on screen (`true`) or left it (`false`): `show()`/`hide()`, the host's visibility, or a
    /// display or host frame appearing or going away.
    public var onVisibilityChanged: ((Bool) -> Void)?
    /// A setting changed through this controller (fold, columns, edge, display, gaps, level): persist it. Not called
    /// for `apply(_:)`.
    public var onSettingsChanged: ((BlockSettings) -> Void)?
    /// The content layout changed (columns shown, cell, padding, rail, window side): the block's root view follows it.
    public var onLayoutChanged: ((BlockLayout) -> Void)?
    /// A dragged window hovered over the rail long enough: the block unfolded for the drop.
    public var onSpringLoadedUnfold: (() -> Void)?
    /// The user's "show it alone while the host hides it" started (`true`) or ended (`false`). The dock link sends no
    /// `area` while it lasts.
    public var onAloneOverrideChanged: ((Bool) -> Void)?

    // MARK: State

    /// The settings in force.
    public private(set) var settings: BlockSettings
    /// Alone or docked, as the dock link set it.
    public private(set) var placement: BlockPlacement = .alone
    /// True between `show()` and `hide()`.
    public private(set) var isShown = false
    /// True while the user shows the block alone at the screen edge although the host hides its strip (the escape
    /// hatch, `setUserShowsAlone(_:)`). Ends when the host shows its strip again, the placement turns alone, or `hide()`.
    public private(set) var showsAloneOverride = false
    /// The placement the block uses now: `.alone` while `showsAloneOverride`, else `placement`.
    public var effectivePlacement: BlockPlacement { showsAloneOverride ? .alone : placement }
    /// Docked beside the host right now (not alone, not overridden).
    public var isDockedNow: Bool { effectivePlacement.isDocked }
    /// Shown, but off screen because the host hides its strip (the block hides with it).
    public var isHiddenByHost: Bool { isShown && hostHidesBlock }
    /// True while the block is on screen: shown, not hidden by the host, and laid out (a display or a usable host frame).
    public var isVisible: Bool { isShown && !hostHidesBlock && current != nil }
    /// Folded into the rail by the user (the rail may also show because nothing wider fits: `fit.isRail`).
    public var isFolded: Bool { settings.folded }
    /// The panel frame in AppKit space (`.zero` before the first layout; the last one while no target exists).
    public internal(set) var frame: CGRect = .zero
    /// What the block shows at its width.
    public internal(set) var fit: BlockFit
    /// The content layout in force.
    public internal(set) var blockLayout: BlockLayout
    /// The console drawer's height (0 when it has no tabs).
    public private(set) var drawerHeight: CGFloat = 0
    /// Space above the block and below the drawer (default 16). Set 0 when the block view brings its own.
    public var verticalPadding: CGFloat = BlockGeometry.verticalPadding {
        didSet {
            if !verticalPadding.isFinite || verticalPadding < 0 { verticalPadding = 0 }
            root?.verticalPadding = verticalPadding
        }
    }
    /// The fold rail (set its `counts`; the controller handles + and the spring-loaded unfold).
    public let rail = FoldRailView()
    /// The block's window (nil until the first `show()`).
    public var window: NSWindow? { panel }
    /// True while the block holds keyboard focus.
    public var hasKeyboardFocus: Bool { keyboard.hasFocus }
    /// The window level in force: alone from "Keep Above Windows", docked the host's.
    public var level: PanelLevel { current?.level ?? Self.aloneLevel(settings) }
    /// The display the block is laid out on (nil while no target exists).
    public var displayID: UInt32? { current?.displayID }
    /// The look in force: the host's while docked (`apply(appearance:)`), `.system` alone.
    public var appearance: BlockAppearance { isDockedNow ? hostAppearance : .system }

    // MARK: Test seams

    /// The connected displays, main first. Tests inject fixed (off-screen) displays.
    var displayProvider: @MainActor () -> [BlockDisplay] = { BlockDisplay.current() }
    /// The flip reference for the guard region (`ScreenSpace.primaryHeight`).
    var primaryHeightProvider: @MainActor () -> CGFloat = { ScreenSpace.primaryHeight }
    /// Tests only: lay out, publish regions and call back, but never order a window in or watch the screens.
    var isHeadless = false
    /// Seconds after the last live placement before the guard region is published.
    var liveSettleDelay: TimeInterval = 1
    /// Delayed calls (the live settle). Tests use a manual scheduler.
    var scheduler: ShellScheduler = MainQueueScheduler.shared
    /// The screen observer's watchdog period.
    var watchdogInterval: TimeInterval = 4

    // MARK: Private

    struct Target: Equatable {
        var frame: CGRect
        var fit: BlockFit
        var layout: BlockLayout
        var displayID: UInt32
        var regionEdge: Edge
        var level: PanelLevel
    }

    struct Area: Equatable {
        var frame: CGRect
        var folded: Bool
        var visible: Bool
    }

    var panel: PitboxPanel?
    var root: BlockRootView?
    var blockView: NSView?
    var drawerView: NSView?
    var current: Target?
    var appliedLevel: PanelLevel?
    var appliedAppearance: BlockAppearance?
    var hostAppearance = BlockAppearance.system
    var lastArea: Area?
    var lastVisible = false
    var loggedNoTarget = false
    var hideGeneration = 0
    var liveSettle: ScheduledCall?
    var screens: ScreenChangeObserver?
    let regionStore = OSAllocatedUnfairLock<[ReservedRegion]>(initialState: [])
    lazy var keyboard = PanelKeyboard(window: { [weak self] in self?.keyboardWindow },
                                      isShown: { [weak self] in self?.isVisible ?? false },
                                      show: { [weak self] in self?.show() })

    /// The host hides its strip and the user has not asked to see the block alone.
    var hostHidesBlock: Bool { !showsAloneOverride && placement.dockPlace?.visible == false }

    /// Creates the controller with the stored settings. No window exists until `show()`.
    public init(settings: BlockSettings = BlockSettings()) {
        self.settings = settings
        let empty = BlockFit(columns: 0, width: 0, cell: BlockGeometry.clampedCell(settings.cellWidth), reduced: false)
        fit = empty
        blockLayout = BlockLayout.make(fit: empty, folded: settings.folded, docked: false, edge: settings.edge)
        rail.onUnfold = { [weak self] in self?.unfold() }
        rail.onSpringLoadedUnfold = { [weak self] in
            self?.unfold()
            self?.onSpringLoadedUnfold?()
        }
    }

    isolated deinit {
        screens?.stop()
        liveSettle?.cancel()
    }

    /// Hides the block and stops everything that could still fire: the screen observer and its watchdog, a pending
    /// settle, a spring-loaded hover. Call it when the app terminates (a later `show()` starts watching again).
    public func invalidate() {
        hide()
        stopWatchingScreens()
        screens = nil
        cancelLiveSettle()
        rail.hoverEnded()
    }

    // MARK: Content

    /// The block's root view (header, buckets, Ready list): fills the panel above the drawer.
    public func setBlockView(_ view: NSView?) {
        blockView = view
        if let root { root.setView(view, in: root.blockHost) }
    }

    /// The console drawer's view, at the bottom of the panel.
    public func setDrawerView(_ view: NSView?) {
        drawerView = view
        if let root { root.setView(view, in: root.drawerHost) }
    }

    /// The drawer's height as the drawer reports it (0 when it has no tabs). Never moves the panel.
    public func setDrawerHeight(_ height: CGFloat) {
        let safe = height.isFinite ? max(0, height) : 0
        guard safe != drawerHeight else { return }
        drawerHeight = safe
        root?.drawerHeight = safe
    }

    // MARK: Visibility

    /// Shows the block (a short fade unless Reduce Motion is on) and publishes its region. It stays off screen while
    /// the host hides its strip, and while there is no display or usable host frame (it appears on the next screen
    /// change, watchdog tick or placement that gives one).
    public func show() {
        guard !isShown else { return }
        isShown = true
        ensurePanel()
        startWatchingScreens()
        relayout(publishRegion: true)
        Log.info("block shown: visible \(isVisible), frame \(NSStringFromRect(frame)), level \(level.windowLevel.rawValue)",
                 "shell")
    }

    /// Clears the region at once (the guard lets windows back in), then fades the block out. Ends the alone override.
    public func hide() {
        guard isShown else { return }
        isShown = false
        cancelLiveSettle()
        stopWatchingScreens()
        endAloneOverride()
        relayout(publishRegion: true)
        Log.info("block hidden", "shell")
    }

    /// The menu's Show/Hide: hides the block when it is on screen; otherwise shows it, alone at the screen edge if the
    /// host hides its strip (`setUserShowsAlone(true)`).
    public func toggle() { isVisible ? hide() : setUserShowsAlone(true) }

    /// The user's escape from hiding with the host. `true`: show the block, and while the host hides its strip, show it
    /// alone at the screen edge (`showsAloneOverride`) until the host shows its strip again, the placement turns alone,
    /// or `hide()`. `false`: back to the host's state (hidden with the host's strip).
    public func setUserShowsAlone(_ on: Bool) {
        let wanted = on && placement.dockPlace?.visible == false
        if wanted != showsAloneOverride {
            showsAloneOverride = wanted
            cancelLiveSettle()
            Log.info("block: shown alone while the host hides: \(wanted)", "shell")
            onAloneOverrideChanged?(wanted)
            if isShown { relayout(publishRegion: true) }
        }
        if on, !isShown { show() }
    }

    private func endAloneOverride() {
        guard showsAloneOverride else { return }
        showsAloneOverride = false
        onAloneOverrideChanged?(false)
    }

    // MARK: Fold

    /// Folds the block into the rail: the panel shrinks, the area is reported, then the rail's region is published.
    public func fold() { change { $0.folded = true } }

    /// Unfolds the block: the panel widens, its region is published, then the area is reported.
    public func unfold() { change { $0.folded = false } }

    /// Folds or unfolds (⌃⌥C, the menu). While the block is off screen it shows it unfolded (alone if the host hides
    /// its strip).
    public func toggleFold() {
        if !isVisible {
            unfold()
            setUserShowsAlone(true)
            return
        }
        settings.folded ? unfold() : fold()
    }

    // MARK: Settings

    /// Applies settings read from the file (no `onSettingsChanged`). A change that moves the block re-lays it out and
    /// publishes the new region once (held during a host's live drag, like a placement).
    public func apply(_ newSettings: BlockSettings) {
        let old = settings
        settings = newSettings
        if old.hideInFullscreen != newSettings.hideInFullscreen {
            panel?.applyCollectionBehavior(hideInFullscreen: newSettings.hideInFullscreen)
        }
        if old != newSettings { relayout(publishRegion: true) }
    }

    /// Two columns or one (other values count as two).
    public func setColumns(_ columns: Int) { change { $0.columns = BlockGeometry.sanitizedColumns(columns) } }

    /// The screen edge alone.
    public func setEdge(_ edge: Edge) { change { $0.edge = edge } }

    /// The display alone, by UUID; nil or "main" for the main display.
    public func setDisplay(uuid: String?) {
        change { $0.displayUUID = BlockDisplay.meansMain(uuid) ? nil : uuid }
    }

    /// The top and bottom gaps alone (each made safe: 0...600). Nil leaves one as it is.
    public func setGaps(top: Double? = nil, bottom: Double? = nil) {
        change {
            if let top { $0.topGap = BlockGeometry.clampedGap(top) }
            if let bottom { $0.bottomGap = BlockGeometry.clampedGap(bottom) }
        }
    }

    /// "Keep Above Windows": above normal windows (floating − 1) or behind them. Docked, the host's level wins.
    public func setKeepAboveWindows(_ above: Bool) { change { $0.keepAboveWindows = above } }

    private func change(_ body: (inout BlockSettings) -> Void) {
        var new = settings
        body(&new)
        guard new != settings else { return }
        apply(new)
        onSettingsChanged?(settings)
    }

    // MARK: Placement

    /// Alone, or docked beside a host (the dock link sets it). Docked, the block takes the host's display, edge, top,
    /// bottom, level and visibility. While `place.live` (the host's width drag) the panel follows at once but the guard
    /// region is published only at the first placement without `live`, or `liveSettleDelay` (1 s) after the last one.
    /// A placement in which the host shows its strip (or `.alone`) ends `showsAloneOverride`.
    public func setPlacement(_ newPlacement: BlockPlacement) {
        let wasDockedNow = isDockedNow
        let wasHostHiding = hostHidesBlock
        placement = newPlacement
        if showsAloneOverride, newPlacement.dockPlace?.visible != false { endAloneOverride() }
        let live = newPlacement.dockPlace?.live ?? false
        if live, wasDockedNow, isDockedNow, hostHidesBlock == wasHostHiding {
            relayout(publishRegion: false)
            scheduleLiveSettle()
        } else {
            cancelLiveSettle()
            relayout(publishRegion: true)
        }
    }

    /// The host's look (`appearance` in the dock link): followed while docked; alone the block follows the system.
    public func apply(appearance: BlockAppearance) {
        hostAppearance = appearance
        applyAppearance()
    }

    /// Re-reads the display geometry now (normally automatic: screen, Space, wake and Dock changes, a 4 s watchdog).
    public func relayout() { relayout(publishRegion: true) }

    // MARK: Keyboard

    /// `true`: take keyboard focus now (a bucket name field, the console, Escape during a drag), showing the block
    /// first if it is hidden; never activates the app. `false`: hand it back to the app that had it.
    public func setNeedsKeyboard(_ needs: Bool) { keyboard.setNeeds(needs) }

    // MARK: Levels

    /// The level alone: floating − 1 above windows, or behind them.
    static func aloneLevel(_ settings: BlockSettings) -> PanelLevel { settings.keepAboveWindows ? .aboveWindows : .desktop }

    /// The host's level, kept between "behind windows" and floating − 1, so a host can never lift the block over
    /// floating windows, menus or alerts.
    public static func dockedLevel(_ raw: Int) -> PanelLevel {
        let low = PanelLevel.desktop.windowLevel.rawValue
        let high = PanelLevel.aboveWindows.windowLevel.rawValue
        if raw <= low { return .desktop }
        if raw >= high { return .aboveWindows }
        return .custom(raw)
    }
}
