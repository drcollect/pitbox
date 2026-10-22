import AppKit
import PitboxKit

/// Layout, the guard region, the area report and window ordering.
extension BlockPanelController {
    /// Where the block goes now: alone on the chosen display at the chosen edge, or docked beside the host. Nil when
    /// there is no display (alone) or the host's frame is unusable (docked).
    func computeTarget() -> Target? {
        switch effectivePlacement {
        case .alone:
            guard let display = BlockDisplay.choose(remembered: settings.displayUUID, among: displayProvider()) else {
                return nil
            }
            let usable = BlockGeometry.usableFrame(of: display)
            let fit = BlockGeometry.fitAlone(columns: settings.columns, cell: settings.cellWidth, folded: settings.folded,
                                             visibleWidth: usable.width)
            let frame = BlockGeometry.aloneFrame(on: display, edge: settings.edge, width: fit.width,
                                                 topGap: settings.topGap, bottomGap: settings.bottomGap)
            let layout = BlockLayout.make(fit: fit, folded: settings.folded, docked: false, edge: settings.edge)
            return Target(frame: frame, fit: fit, layout: layout, displayID: display.displayID,
                          regionEdge: settings.edge, level: Self.aloneLevel(settings))
        case .docked(let place):
            let fit = BlockGeometry.fitDocked(columns: settings.columns, hostCell: place.cell, folded: settings.folded,
                                              maxWidth: place.maxWidth)
            guard let frame = BlockGeometry.dockedFrame(hostFrame: place.hostFrame, hostEdge: place.edge,
                                                        width: fit.width) else { return nil }
            let layout = BlockLayout.make(fit: fit, folded: settings.folded, docked: true, edge: place.edge)
            return Target(frame: frame, fit: fit, layout: layout, displayID: place.displayID, regionEdge: place.edge,
                          level: Self.dockedLevel(place.level))
        }
    }

    /// Moves the panel to the current target, then reports the area and publishes the region in the order of
    /// docs/DOCK_PROTOCOL.md §7: narrower (a fold) reports the area first and publishes the region after; wider (an
    /// unfold) the other way round. Then orders the window in or out to match `isVisible`.
    ///
    /// The region is held while a live host drag is settling (`liveSettle`), whatever asked for the layout (a fold, a
    /// settings change): the settle publishes it. A change of visibility always publishes (an empty region when the
    /// block leaves the screen). Without a target (no display, unusable host frame) the block is not on screen: no
    /// region, the window out, and the next screen change, watchdog tick or placement tries again.
    func relayout(publishRegion: Bool) {
        let wasVisible = lastVisible
        guard let target = computeTarget() else {
            if !loggedNoTarget {
                Log.warn("block: no display or usable host frame, off screen until one appears", "shell")
                loggedNoTarget = true
            }
            current = nil
            publishRegions()
            reportArea()
            syncVisibility()
            return
        }
        loggedNoTarget = false
        let narrower = target.frame.width < frame.width
        current = target
        if let panel {
            if panel.frame != target.frame { panel.setFrame(target.frame, display: true) }
            if appliedLevel != target.level {
                panel.applyLevel(target.level)
                appliedLevel = target.level
            }
        }
        frame = target.frame
        fit = target.fit
        rail.canUnfold = !target.fit.isRail || settings.folded
        if blockLayout != target.layout {
            blockLayout = target.layout
            root?.blockLayout = target.layout
            onLayoutChanged?(target.layout)
        }
        applyAppearance()
        let publish = isVisible != wasVisible || (publishRegion && liveSettle == nil)
        if narrower {
            reportArea()
            if publish { publishRegions() }
        } else {
            if publish { publishRegions() }
            reportArea()
        }
        syncVisibility()
    }

    /// Publishes one region while on screen, none otherwise; calls `onRegionsChanged` only on a change.
    func publishRegions() {
        let new: [ReservedRegion]
        if isVisible, let current, frame.width > 0 {
            new = [BlockGeometry.region(forPanelFrame: frame, displayID: current.displayID, edge: current.regionEdge,
                                        primaryHeight: primaryHeightProvider())]
        } else {
            new = []
        }
        let changed = regionStore.withLock { stored -> Bool in
            guard stored != new else { return false }
            stored = new
            return true
        }
        guard changed else { return }
        Log.info("block regions: \(new.map { NSStringFromRect($0.rect) })", "shell")
        onRegionsChanged?()
    }

    /// Calls `onAreaChanged` when the frame, the rail or the visibility changed since the last report.
    func reportArea() {
        guard frame.width > 0 else { return }
        let area = Area(frame: frame, folded: fit.isRail, visible: isVisible)
        guard area != lastArea else { return }
        lastArea = area
        onAreaChanged?(area.frame, area.folded, area.visible)
    }

    /// Orders the window in or out and calls `onVisibilityChanged` when `isVisible` changed since the last time.
    func syncVisibility() {
        let visible = isVisible
        guard visible != lastVisible else { return }
        lastVisible = visible
        syncWindow()
        onVisibilityChanged?(visible)
    }

    /// The panel follows the look in force (the host's while docked, the system's alone).
    func applyAppearance() {
        let look = appearance
        guard let panel, let root, look != appliedAppearance else { return }
        appliedAppearance = look
        panel.appearance = look.scheme.nsAppearance
        root.setBackdrop(look.backdrop)
    }

    // MARK: Live placements

    func scheduleLiveSettle() {
        liveSettle?.cancel()
        liveSettle = scheduler.after(liveSettleDelay) { [weak self] in
            guard let self, self.liveSettle != nil else { return }
            self.liveSettle = nil
            self.publishRegions()
        }
    }

    func cancelLiveSettle() {
        liveSettle?.cancel()
        liveSettle = nil
    }

    /// True while a live placement's region is held back.
    var isHoldingLiveRegion: Bool { liveSettle != nil }

    // MARK: Screens

    func startWatchingScreens() {
        guard !isHeadless else { return }
        startScreenObserver()
    }

    /// Starts the observer (also for tests, which never call it through `show()` while headless).
    func startScreenObserver() {
        if screens == nil {
            screens = ScreenChangeObserver(watchdogInterval: watchdogInterval) { [weak self] in
                self?.displayMayHaveChanged()
            }
        }
        screens?.start()
    }

    func stopWatchingScreens() { screens?.stop() }

    /// A screen, Space, wake or Dock change, or the watchdog: lay out again if anything moved, or if a target appeared
    /// or went away. During a host's live drag the host drives the frame.
    func displayMayHaveChanged() {
        guard isShown, liveSettle == nil else { return }
        let target = computeTarget()
        if target != current {
            relayout(publishRegion: true)
        } else {
            publishRegions()   // the primary display's height (the Quartz flip) may have changed alone
        }
    }

    // MARK: Window

    @discardableResult
    func ensurePanel() -> BlockRootView {
        if let root { return root }
        if !isHeadless { BackgroundCursor.enable() }
        let target = computeTarget()
        // Without a target the window is made off to the side and stays ordered out until a layout succeeds.
        let initial = target?.frame ?? CGRect(x: -20000, y: -20000, width: 400, height: 600)
        let level = target?.level ?? Self.aloneLevel(settings)
        let panel = PitboxPanel(contentRect: initial, level: level, hideInFullscreen: settings.hideInFullscreen)
        let root = BlockRootView(frame: CGRect(origin: .zero, size: initial.size), layout: blockLayout, rail: rail,
                                 backdrop: appearance.backdrop)
        root.autoresizingMask = [.width, .height]
        root.drawerHeight = drawerHeight
        root.verticalPadding = verticalPadding
        panel.contentView = root
        root.setView(blockView, in: root.blockHost)
        root.setView(drawerView, in: root.drawerHost)
        self.panel = panel
        self.root = root
        appliedLevel = level
        appliedAppearance = nil
        applyAppearance()
        return root
    }

    /// The window the keyboard handoff may use: only while the block is on screen.
    var keyboardWindow: KeyboardHandoffWindow? {
        guard isVisible, !isHeadless else { return nil }
        return panel
    }

    /// Orders the panel in or out to match `isVisible` (fades unless Reduce Motion is on). Never orders in without a
    /// layout (`isVisible` needs one). Headless: nothing.
    func syncWindow() {
        guard let panel, !isHeadless else { return }
        hideGeneration += 1
        if isVisible {
            if reduceMotion {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            } else {
                if !panel.isVisible { panel.alphaValue = 0 }
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    panel.animator().alphaValue = 1
                }
            }
            return
        }
        guard panel.isVisible else { return }
        let generation = hideGeneration
        let finish: () -> Void = { [weak self] in
            guard let self, self.hideGeneration == generation, !self.isVisible else { return }
            self.panel?.orderOut(nil)
            self.panel?.alphaValue = 1
        }
        if reduceMotion {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: {
                DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
            })
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
