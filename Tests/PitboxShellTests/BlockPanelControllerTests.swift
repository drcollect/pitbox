import AppKit
import Testing
import PitboxKit
@testable import PitboxShell

/// Records the controller's callbacks in order.
@MainActor
final class BlockRecorder {
    var events: [String] = []
    var areas: [(frame: CGRect, folded: Bool, visible: Bool)] = []
    var settings: [BlockSettings] = []
    var layouts: [BlockLayout] = []
    var visibility: [Bool] = []
    /// The panel's frame at each callback (to check the panel moved first).
    var panelFrameAtArea: [CGRect?] = []
    var panelFrameAtRegions: [CGRect?] = []

    /// The controller's closures keep the recorder alive (tests that ignore it still get callbacks).
    func attach(_ controller: BlockPanelController) {
        controller.onAreaChanged = { [weak controller] frame, folded, visible in
            self.events.append("area")
            self.areas.append((frame, folded, visible))
            self.panelFrameAtArea.append(controller?.window?.frame)
        }
        controller.onRegionsChanged = { [weak controller] in
            MainActor.assumeIsolated {
                self.events.append("regions")
                self.panelFrameAtRegions.append(controller?.window?.frame)
            }
        }
        controller.onSettingsChanged = { self.settings.append($0) }
        controller.onLayoutChanged = { self.layouts.append($0) }
        controller.onVisibilityChanged = { self.visibility.append($0) }
    }
}

/// The panel controller without a screen: headless (layout, regions and callbacks, no window ordered in) on off-screen
/// test displays.
@Suite @MainActor struct BlockPanelControllerTests {
    private func make(_ settings: BlockSettings = BlockSettings(),
                      displays: [BlockDisplay] = [TestDisplays.notebook, TestDisplays.ultrawide])
        -> (BlockPanelController, BlockRecorder) {
        let controller = BlockPanelController(settings: settings)
        controller.isHeadless = true
        controller.displayProvider = { displays }
        controller.primaryHeightProvider = { TestDisplays.primaryHeight }
        let recorder = BlockRecorder()
        recorder.attach(controller)
        return (controller, recorder)
    }

    private let rightHost = DockPlace(hostFrame: CGRect(x: 23533, y: 98, width: 1587, height: 1312), displayID: 12,
                                      edge: .right, level: 2, cell: 301.4, maxWidth: 800)

    @Test func startsHiddenWithNoRegions() {
        let (controller, recorder) = make()
        #expect(!controller.isShown && !controller.isVisible)
        #expect(controller.regions.isEmpty)
        #expect(controller.window == nil)
        controller.hide()
        controller.setNeedsKeyboard(false)
        #expect(controller.regions.isEmpty)
        #expect(recorder.events.isEmpty)
    }

    @Test func showPublishesOneRegionAndHideClearsIt() throws {
        let (controller, recorder) = make()
        controller.show()
        #expect(controller.isShown && controller.isVisible)
        #expect(controller.frame == CGRect(x: 20822, y: 70, width: 690, height: 879))
        let region = try #require(controller.regions.first)
        #expect(controller.regions.count == 1)
        #expect(region == ReservedRegion(displayID: 11, rect: CGRect(x: 20822, y: 491, width: 690, height: 879), edge: .right))
        #expect(controller.window?.frame == controller.frame)
        #expect(controller.window?.isVisible == false, "headless: never ordered in")
        #expect(controller.window?.animationBehavior == NSWindow.AnimationBehavior.none)
        #expect(recorder.visibility == [true])
        #expect(recorder.areas.last?.visible == true)
        controller.hide()
        #expect(controller.regions.isEmpty)
        #expect(recorder.visibility == [true, false])
        #expect(recorder.areas.last?.visible == false)
        #expect(recorder.events.suffix(2) == ["regions", "area"], "the region clears before the area reports hidden")
        controller.toggle()
        #expect(controller.isShown && controller.regions.count == 1)
    }

    @Test func foldShrinksThenReportsTheAreaThenPublishesTheRail() throws {
        let (controller, recorder) = make()
        controller.show()
        recorder.events = []
        recorder.panelFrameAtArea = []
        recorder.panelFrameAtRegions = []
        controller.fold()
        #expect(recorder.events == ["area", "regions"])
        let rail = CGRect(x: 21488, y: 70, width: 24, height: 879)
        #expect(controller.frame == rail)
        #expect(recorder.panelFrameAtArea == [rail], "the panel shrank before the area was reported")
        #expect(recorder.areas.last?.folded == true)
        #expect(controller.regions.first?.rect == CGRect(x: 21488, y: 491, width: 24, height: 879))
        #expect(recorder.settings.last?.folded == true)
        #expect(controller.blockLayout.showsRail)

        recorder.events = []
        recorder.panelFrameAtRegions = []
        controller.unfold()
        #expect(recorder.events == ["regions", "area"], "unfold: the region first, then the area")
        #expect(recorder.panelFrameAtRegions == [CGRect(x: 20822, y: 70, width: 690, height: 879)],
                "the panel widened before the region was published")
        #expect(recorder.areas.last?.folded == false)
        #expect(recorder.settings.last?.folded == false)

        // Folding twice changes nothing.
        controller.fold()
        let count = recorder.events.count
        controller.fold()
        #expect(recorder.events.count == count)
    }

    @Test func toggleFoldWhileHiddenShowsTheBlockUnfolded() {
        let (controller, _) = make(BlockSettings(folded: true))
        controller.toggleFold()
        #expect(controller.isShown && !controller.isFolded)
        #expect(controller.frame.width == 690)
        controller.toggleFold()
        #expect(controller.isFolded && controller.frame.width == 24)
        controller.toggleFold()
        #expect(!controller.isFolded)
    }

    @Test func theRailsPlusAndSpringLoadUnfold() {
        let (controller, _) = make(BlockSettings(folded: true))
        var sprung = 0
        controller.onSpringLoadedUnfold = { sprung += 1 }
        controller.show()
        controller.rail.plusButton.performClick(nil)
        #expect(!controller.isFolded)
        controller.fold()
        controller.rail.onSpringLoadedUnfold?()
        #expect(!controller.isFolded && sprung == 1)
    }

    @Test func columnsFallBackOnANarrowDisplay() {
        let (controller, recorder) = make(BlockSettings(displayUUID: "CCCC-NARROW"),
                                          displays: [TestDisplays.notebook, TestDisplays.narrow, TestDisplays.tiny])
        controller.show()
        #expect(controller.fit == BlockFit(columns: 1, width: 355, cell: 323, reduced: true))
        #expect(controller.frame == CGRect(x: 30925, y: 0, width: 355, height: 775))
        #expect(recorder.layouts.last?.columns == 1)
        controller.setDisplay(uuid: "DDDD-TINY")
        #expect(controller.fit.isRail && controller.fit.reduced)
        #expect(!controller.rail.canUnfold, "nothing wider fits: + is disabled")
        #expect(recorder.areas.last?.folded == true)
        controller.setDisplay(uuid: "main")
        #expect(controller.settings.displayUUID == nil)
        #expect(controller.fit.columns == 2 && controller.rail.canUnfold)
        #expect(controller.regions.first?.displayID == 11)
    }

    @Test func aRememberedDisplayThatIsGoneUsesTheMainDisplay() {
        let (controller, _) = make(BlockSettings(displayUUID: "GONE"))
        controller.show()
        #expect(controller.regions.first?.displayID == 11)
        #expect(controller.settings.displayUUID == "GONE", "the remembered display stays remembered")
    }

    @Test func settingsChangesPersistThroughTheCallbackButFileChangesDoNot() {
        let (controller, recorder) = make()
        controller.show()
        controller.setColumns(1)
        #expect(recorder.settings.last?.columns == 1)
        #expect(controller.frame.width == 355)
        controller.setColumns(1)
        #expect(recorder.settings.count == 1, "no change, no callback")
        controller.setColumns(7)
        #expect(controller.settings.columns == 2)
        controller.setEdge(.left)
        #expect(controller.frame.minX == 20000)
        #expect(controller.regions.first?.edge == .left)
        controller.setGaps(top: 100, bottom: -4)
        #expect(controller.settings.topGap == 100 && controller.settings.bottomGap == 0)
        #expect(controller.frame.maxY == 849)
        controller.setKeepAboveWindows(false)
        #expect(controller.level == .desktop)
        #expect(controller.window?.level == PanelLevel.desktop.windowLevel)
        let before = recorder.settings.count
        controller.apply(BlockSettings(columns: 1, edge: .right, keepAboveWindows: true))
        #expect(recorder.settings.count == before, "apply (from the file) does not call back")
        #expect(controller.frame == CGRect(x: 21157, y: 70, width: 355, height: 879))
        #expect(controller.window?.level.rawValue == 2)
    }

    @Test func dockedSitsOnTheHostsWindowSideWithItsEdgeAndLevel() throws {
        let (controller, recorder) = make()
        controller.show()
        controller.setPlacement(.docked(rightHost))
        #expect(controller.frame == CGRect(x: 22902, y: 98, width: 631, height: 1312))
        let region = try #require(controller.regions.first)
        #expect(region.edge == .right, "docked: the host's edge")
        #expect(region.displayID == 12)
        #expect(region.rect == CGRect(x: 22902, y: 30, width: 631, height: 1312))
        #expect(controller.blockLayout.docked && controller.blockLayout.leftPadding == 16
                && controller.blockLayout.rightPadding == 0)
        #expect(controller.level == .aboveWindows)
        // The host's narrower limit: one column, then the rail.
        var tight = rightHost
        tight.maxWidth = 400
        controller.setPlacement(.docked(tight))
        #expect(controller.frame.width == 317 && controller.frame.maxX == 23533)
        tight.maxWidth = 100
        controller.setPlacement(.docked(tight))
        #expect(controller.fit.isRail)
        // Docked, the alone edge and gaps do not apply.
        controller.setPlacement(.docked(rightHost))
        controller.setEdge(.left)
        controller.setGaps(top: 300)
        #expect(controller.frame == CGRect(x: 22902, y: 98, width: 631, height: 1312))
        // Back alone: the screen edge again.
        controller.setPlacement(.alone)
        #expect(controller.frame == CGRect(x: 20000, y: 70, width: 690, height: 579))
        #expect(recorder.visibility == [true])
    }

    @Test func dockedLevelIsClampedToTheBlocksRange() {
        #expect(BlockPanelController.dockedLevel(2) == .aboveWindows)
        #expect(BlockPanelController.dockedLevel(1000) == .aboveWindows, "a host cannot lift the block over pop-ups")
        #expect(BlockPanelController.dockedLevel(Int.min) == .desktop)
        #expect(BlockPanelController.dockedLevel(PanelLevel.desktop.windowLevel.rawValue) == .desktop)
        #expect(BlockPanelController.dockedLevel(0) == .custom(0))
        let (controller, _) = make()
        controller.show()
        var behind = rightHost
        behind.level = PanelLevel.desktop.windowLevel.rawValue
        controller.setPlacement(.docked(behind))
        #expect(controller.window?.level == PanelLevel.desktop.windowLevel)
    }

    @Test func theBlockHidesAndReturnsWithTheHost() {
        let (controller, recorder) = make()
        controller.show()
        controller.setPlacement(.docked(rightHost))
        var hidden = rightHost
        hidden.visible = false
        controller.setPlacement(.docked(hidden))
        #expect(controller.isShown && !controller.isVisible)
        #expect(controller.regions.isEmpty)
        #expect(recorder.visibility == [true, false])
        #expect(recorder.areas.last?.visible == false)
        controller.setPlacement(.docked(rightHost))
        #expect(controller.isVisible && controller.regions.count == 1)
        #expect(recorder.visibility == [true, false, true])
        // A keyboard request while the host hides the block does not put it on screen.
        controller.setPlacement(.docked(hidden))
        controller.setNeedsKeyboard(true)
        #expect(!controller.isVisible && controller.regions.isEmpty)
    }

    @Test func liveHostDragsMoveThePanelButHoldTheRegion() {
        let (controller, recorder) = make()
        let clock = ManualScheduler()
        controller.scheduler = clock
        #expect(controller.liveSettleDelay == 1)
        controller.show()
        controller.setPlacement(.docked(rightHost))
        let settled = controller.regions
        var drag = rightHost
        drag.live = true
        drag.hostFrame.origin.x -= 50
        drag.hostFrame.size.width += 50
        recorder.events = []
        controller.setPlacement(.docked(drag))
        #expect(controller.frame.minX == 22852, "the panel follows the host at once")
        #expect(controller.regions == settled, "no region mid-drag")
        #expect(recorder.events == ["area"])
        clock.advance(by: 0.6)
        drag.hostFrame.origin.x -= 50
        drag.hostFrame.size.width += 50
        controller.setPlacement(.docked(drag))
        #expect(controller.regions == settled)
        #expect(controller.isHoldingLiveRegion)
        // 1 s after the last live placement (not the first), the region follows.
        clock.advance(by: 0.6)
        #expect(controller.regions == settled, "1.2 s after the first, 0.6 s after the last: still held")
        clock.advance(by: 0.5)
        #expect(!controller.isHoldingLiveRegion)
        #expect(controller.regions.first?.rect.minX == 22802)
        // The first placement without `live` publishes at once.
        drag.hostFrame.origin.x -= 50
        drag.hostFrame.size.width += 50
        controller.setPlacement(.docked(drag))
        #expect(controller.regions.first?.rect.minX == 22802, "still live: held")
        var done = drag
        done.live = false
        controller.setPlacement(.docked(done))
        #expect(!controller.isHoldingLiveRegion)
        #expect(controller.regions.first?.rect.minX == 22752)
    }

    @Test func aFirstLivePlacementFromAlonePublishesAtOnce() {
        let (controller, _) = make()
        controller.show()
        var live = rightHost
        live.live = true
        controller.setPlacement(.docked(live))
        #expect(controller.regions.first?.rect.minX == 22902, "switching to docked is not a drag step")
        #expect(!controller.isHoldingLiveRegion)
    }

    @Test func aKeyboardRequestShowsAHiddenBlock() {
        let (controller, recorder) = make()
        controller.setNeedsKeyboard(true)
        #expect(controller.isShown && controller.regions.count == 1)
        #expect(recorder.visibility == [true])
        #expect(!controller.hasKeyboardFocus, "headless: no window takes the keyboard")
        controller.setNeedsKeyboard(false)
        #expect(controller.isShown)
    }

    @Test func contentViewsAndTheDrawerAreInstalled() throws {
        let (controller, _) = make()
        let block = NSView()
        let drawer = NSView()
        controller.setBlockView(block)
        controller.setDrawerView(drawer)
        controller.setDrawerHeight(200)
        controller.setDrawerHeight(.nan)
        #expect(controller.drawerHeight == 0)
        controller.setDrawerHeight(200)
        controller.show()
        let root = try #require(controller.root)
        #expect(block.superview === root.blockHost)
        #expect(drawer.superview === root.drawerHost)
        root.layoutSubtreeIfNeeded()
        #expect(root.blockHost.frame == CGRect(x: 16, y: 16, width: 658, height: 635))
        #expect(root.drawerHost.frame == CGRect(x: 16, y: 663, width: 658, height: 200))
        #expect(!root.blockHost.isHidden && root.rail.isHidden)
        controller.fold()
        root.layoutSubtreeIfNeeded()
        #expect(root.blockHost.isHidden && root.drawerHost.isHidden && !root.rail.isHidden)
        #expect(root.rail.frame == CGRect(x: 0, y: 0, width: 24, height: 879))
        #expect(root.rail === controller.rail)
        // Replacing the block view swaps it.
        let other = NSView()
        controller.setBlockView(other)
        #expect(block.superview == nil && other.superview === root.blockHost)
    }

    @Test func screenChangesRelayOutOnlyWhenSomethingMoved() {
        var displays = [TestDisplays.notebook]
        let controller = BlockPanelController()
        controller.isHeadless = true
        controller.displayProvider = { displays }
        controller.primaryHeightProvider = { TestDisplays.primaryHeight }
        var regionChanges = 0
        controller.onRegionsChanged = { regionChanges += 1 }
        controller.show()
        #expect(regionChanges == 1)
        controller.displayMayHaveChanged()
        #expect(regionChanges == 1, "the watchdog with nothing changed publishes nothing")
        // The Dock grew.
        displays[0].visibleFrame = CGRect(x: 20000, y: 120, width: 1512, height: 829)
        controller.displayMayHaveChanged()
        #expect(regionChanges == 2)
        #expect(controller.frame == CGRect(x: 20822, y: 120, width: 690, height: 829))
        // No display at all: off screen, no region, until a display comes back (the watchdog's next tick).
        displays = []
        controller.displayMayHaveChanged()
        #expect(!controller.isVisible && controller.isShown)
        #expect(controller.regions.isEmpty && regionChanges == 3)
        controller.displayMayHaveChanged()
        #expect(regionChanges == 3, "nothing to do while there is still no display")
        displays = [TestDisplays.notebook]
        controller.displayMayHaveChanged()
        #expect(controller.isVisible && controller.regions.count == 1 && regionChanges == 4)
    }

    // MARK: Review fixes

    /// No display at `show()`: nothing is ordered in, no region; the next screen change or watchdog tick shows it.
    @Test func showWithoutADisplayStaysOffScreenUntilOneAppears() throws {
        var displays: [BlockDisplay] = []
        let (controller, recorder) = make()
        controller.displayProvider = { displays }
        controller.show()
        #expect(controller.isShown && !controller.isVisible)
        #expect(controller.regions.isEmpty)
        #expect(recorder.visibility.isEmpty && recorder.areas.isEmpty)
        let window = try #require(controller.window)
        #expect(window.frame.minX < -10000, "made off to the side")
        // The ordering code itself, not headless: without a layout it leaves the window out.
        controller.isHeadless = false
        controller.syncWindow()
        controller.isHeadless = true
        #expect(!window.isVisible)
        displays = [TestDisplays.notebook]
        controller.displayMayHaveChanged()
        #expect(controller.isVisible && controller.regions.count == 1)
        #expect(recorder.visibility == [true])
        #expect(window.frame == CGRect(x: 20822, y: 70, width: 690, height: 879))
    }

    /// An unusable host frame: off screen and no region until a usable placement arrives.
    @Test func anUnusableHostFrameKeepsTheBlockOffScreen() {
        let (controller, recorder) = make()
        controller.show()
        var broken = rightHost
        broken.hostFrame = CGRect(x: CGFloat.nan, y: 0, width: 0, height: 0)
        controller.setPlacement(.docked(broken))
        #expect(controller.isShown && !controller.isVisible)
        #expect(controller.regions.isEmpty)
        #expect(recorder.visibility == [true, false])
        #expect(recorder.areas.last?.visible == false)
        controller.displayMayHaveChanged()
        #expect(!controller.isVisible, "the watchdog cannot fix a broken host frame")
        controller.setPlacement(.docked(rightHost))
        #expect(controller.isVisible && controller.regions.first?.rect.minX == 22902)
        #expect(recorder.visibility == [true, false, true])
    }

    /// The menu's Show while the host hides its strip shows the block alone at the screen edge, until the host
    /// shows its strip again or the user hides it.
    @Test func showingAloneWhileTheHostHides() throws {
        let (controller, recorder) = make()
        var overrides: [Bool] = []
        controller.onAloneOverrideChanged = { overrides.append($0) }
        controller.show()
        controller.setPlacement(.docked(rightHost))
        var hidden = rightHost
        hidden.visible = false
        controller.setPlacement(.docked(hidden))
        #expect(controller.isHiddenByHost && !controller.isVisible)
        // The menu's Show.
        controller.toggle()
        #expect(controller.showsAloneOverride && controller.isVisible && !controller.isDockedNow)
        #expect(!controller.isHiddenByHost)
        #expect(controller.frame == CGRect(x: 20822, y: 70, width: 690, height: 879), "alone at the screen edge")
        let region = try #require(controller.regions.first)
        #expect(region.edge == .right && region.displayID == 11)
        #expect(overrides == [true])
        #expect(controller.blockLayout.docked == false)
        // The host keeps its strip hidden: the block stays alone.
        controller.setPlacement(.docked(hidden))
        #expect(controller.showsAloneOverride && controller.frame.minX == 20822)
        // The host shows its strip again: back beside it.
        controller.setPlacement(.docked(rightHost))
        #expect(!controller.showsAloneOverride && controller.isDockedNow)
        #expect(controller.frame.minX == 22902 && controller.regions.first?.edge == .right)
        #expect(overrides == [true, false])
        // Again, then the user hides it: hidden, the override ends, and the host's next show does not bring it back.
        controller.setPlacement(.docked(hidden))
        controller.toggle()
        #expect(controller.isVisible)
        controller.toggle()
        #expect(!controller.isShown && !controller.showsAloneOverride && controller.regions.isEmpty)
        controller.setPlacement(.docked(rightHost))
        #expect(!controller.isVisible)
        #expect(overrides == [true, false, true, false])
        #expect(recorder.visibility.last == false)
        // ⌃⌥C while the host hides it: shown alone, unfolded.
        controller.show()
        controller.fold()
        controller.setPlacement(.docked(hidden))
        controller.toggleFold()
        #expect(controller.isVisible && controller.showsAloneOverride && !controller.isFolded)
        // Without a hiding host, the override is never set.
        controller.setPlacement(.alone)
        #expect(!controller.showsAloneOverride)
        controller.setUserShowsAlone(true)
        #expect(!controller.showsAloneOverride && controller.isVisible)
    }

    /// The watchdog timer and the observers go away with the controller, and `invalidate()` stops them.
    @Test func theWatchdogStopsWithTheController() throws {
        var controller: BlockPanelController? = BlockPanelController()
        controller?.isHeadless = true
        controller?.displayProvider = { [TestDisplays.notebook] }
        controller?.startScreenObserver()
        weak let observer = controller?.screens
        weak let timer = controller?.screens?.watchdog
        #expect(timer?.isValid == true)
        let clock = ManualScheduler()
        controller?.scheduler = clock
        controller?.show()
        controller?.setPlacement(.docked(rightHost))
        var live = rightHost
        live.live = true
        controller?.setPlacement(.docked(live))
        #expect(clock.pendingCount == 1)
        controller = nil
        #expect(observer == nil, "released with the controller")
        #expect(timer?.isValid != true, "the run loop's timer is invalidated")
        #expect(clock.pendingCount == 0, "the pending settle is cancelled")
        clock.advance(by: 5)

        let (kept, _) = make()
        kept.startScreenObserver()
        weak let keptTimer = kept.screens?.watchdog
        kept.show()
        kept.rail.hoverBegan()
        kept.invalidate()
        #expect(!kept.isShown && kept.regions.isEmpty && kept.screens == nil)
        #expect(keptTimer?.isValid != true)
        #expect(!kept.rail.isSpringLoading)
    }

    /// A fold or a settings change during a host's live drag waits for the settle like a placement.
    @Test func changesDuringALiveDragDoNotPublishMidDrag() {
        let (controller, recorder) = make()
        let clock = ManualScheduler()
        controller.scheduler = clock
        controller.show()
        controller.setPlacement(.docked(rightHost))
        let settled = controller.regions
        var drag = rightHost
        drag.live = true
        controller.setPlacement(.docked(drag))
        recorder.events = []
        controller.fold()
        #expect(controller.frame.width == 24, "the panel folds at once")
        #expect(controller.regions == settled, "the region waits")
        #expect(recorder.events == ["area"])
        controller.setColumns(1)
        controller.relayout()
        #expect(controller.regions == settled)
        clock.advance(by: 1)
        #expect(controller.regions.first?.rect.width == 24)
        // Hiding during the hold clears at once.
        controller.setPlacement(.docked(drag))
        controller.hide()
        #expect(controller.regions.isEmpty)
    }

    /// Docked the panel follows the host's look; alone the system's.
    @Test func theHostsAppearanceIsFollowedWhileDocked() throws {
        let (controller, _) = make()
        controller.show()
        let window = try #require(controller.window)
        let root = try #require(controller.root)
        #expect(window.appearance == nil && root.backdrop == .glass)
        controller.apply(appearance: BlockAppearance(scheme: .dark, backdrop: .vibrancy))
        #expect(window.appearance == nil, "alone: the system's look")
        controller.setPlacement(.docked(rightHost))
        #expect(window.appearance?.name == .darkAqua)
        #expect(root.backdrop == .vibrancy)
        #expect(ThemeColor.isDark(controller.rail.effectiveAppearance), "the rail follows")
        controller.apply(appearance: BlockAppearance(scheme: .light, backdrop: .solid))
        #expect(window.appearance?.name == .aqua && root.backdrop == .solid)
        #expect(!ThemeColor.isDark(controller.rail.effectiveAppearance))
        root.layoutSubtreeIfNeeded()
        #expect(root.blockHost.superview === root.contentContainer)
        controller.setPlacement(.alone)
        #expect(window.appearance == nil && root.backdrop == .glass)
        #expect(controller.appearance == .system)
    }

    /// The vertical padding is a parameter (default 16).
    @Test func verticalPaddingIsAParameter() throws {
        let (controller, _) = make()
        #expect(controller.verticalPadding == 16)
        controller.setDrawerHeight(100)
        controller.show()
        let root = try #require(controller.root)
        controller.verticalPadding = 0
        root.layoutSubtreeIfNeeded()
        #expect(root.blockHost.frame == CGRect(x: 16, y: 0, width: 658, height: 879 - 100 - 12))
        #expect(root.drawerHost.frame.maxY == 879)
        controller.verticalPadding = -.infinity
        #expect(controller.verticalPadding == 0)
    }
}
