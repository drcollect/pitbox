import AppKit
import Testing
import PitboxKit
@testable import PitboxShell

@Suite @MainActor struct FoldRailViewTests {
    @Test func dotsShowOnlyWhatIsThereInThePitStopWords() {
        let rail = FoldRailView(frame: CGRect(x: 0, y: 0, width: 24, height: 600))
        #expect(rail.needsYouRow.isHidden && rail.finishedRow.isHidden && rail.runningRow.isHidden)
        rail.counts = RailCounts(needsYou: 1, finished: 3, running: 2)
        #expect(!rail.needsYouRow.isHidden && !rail.finishedRow.isHidden && !rail.runningRow.isHidden)
        #expect(rail.needsYouRow.accessibilityLabel() == "1 needs you")
        #expect(rail.finishedRow.accessibilityLabel() == "3 finished")
        #expect(rail.runningRow.accessibilityLabel() == "2 running")
        #expect(rail.needsYouRow.label.stringValue == "1")
        #expect(rail.needsYouRow.toolTip == "1 needs you")
        rail.counts = RailCounts(needsYou: 2, finished: 0, running: 0)
        #expect(rail.needsYouRow.accessibilityLabel() == "2 need you")
        #expect(rail.finishedRow.isHidden && rail.runningRow.isHidden)
        rail.counts = RailCounts(needsYou: 250)
        #expect(rail.needsYouRow.label.stringValue == "99+")
        #expect(rail.needsYouRow.accessibilityLabel() == "250 need you", "VoiceOver gets the real number")
        rail.layoutSubtreeIfNeeded()
        #expect(rail.plusButton.frame.minY < rail.needsYouRow.frame.minY, "+ is at the top")
        #expect(rail.isAccessibilityElement() && rail.accessibilityLabel() == "Pitbox, folded")
        #expect(rail.plusButton.accessibilityLabel() == "Unfold Pitbox")
    }

    @Test func aRunningCommandPulsesTheBlueDot() {
        let rail = FoldRailView(frame: CGRect(x: 0, y: 0, width: 24, height: 600))
        rail.counts = RailCounts(commandRunning: true)
        #expect(!rail.runningRow.isHidden)
        #expect(rail.runningRow.wantsPulse)
        #expect(rail.runningRow.label.isHidden, "no session count: the dot alone")
        #expect(rail.runningRow.accessibilityLabel() == "a command is running")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(rail.runningRow.isPulsing) }
        rail.counts = RailCounts(running: 4, commandRunning: true)
        #expect(rail.runningRow.accessibilityLabel() == "4 running, a command is running")
        #expect(rail.runningRow.label.stringValue == "4")
        rail.counts = RailCounts(running: 4)
        #expect(!rail.runningRow.wantsPulse && !rail.runningRow.isPulsing)
        rail.counts = RailCounts()
        #expect(rail.runningRow.isHidden)
    }

    @Test func plusUnfoldsUnlessThereIsNoRoom() {
        let rail = FoldRailView(frame: CGRect(x: 0, y: 0, width: 24, height: 600))
        var unfolds = 0
        rail.onUnfold = { unfolds += 1 }
        rail.plusButton.performClick(nil)
        #expect(unfolds == 1)
        rail.canUnfold = false
        #expect(!rail.plusButton.isEnabled)
        #expect(rail.plusButton.accessibilityLabel() == "Unfold Pitbox: not enough room")
        rail.plusButton.performClick(nil)
        #expect(unfolds == 1)
    }

    @Test func springLoadedUnfoldAfterTheDelay() {
        let rail = FoldRailView(frame: CGRect(x: 0, y: 0, width: 24, height: 600))
        let clock = ManualScheduler()
        rail.scheduler = clock
        #expect(rail.springLoadDelay == 0.6)
        var fired = 0
        rail.onSpringLoadedUnfold = { fired += 1 }
        // A hover that ends early does nothing.
        rail.hoverBegan()
        #expect(rail.isSpringLoading)
        clock.advance(by: 0.5)
        rail.hoverEnded()
        #expect(!rail.isSpringLoading)
        clock.advance(by: 5)
        #expect(fired == 0)
        // A hover that lasts 0.6 s fires once, even when hoverBegan repeats.
        rail.hoverBegan()
        clock.advance(by: 0.3)
        rail.hoverBegan()
        clock.advance(by: 0.29)
        #expect(fired == 0)
        clock.advance(by: 0.02)
        #expect(fired == 1)
        #expect(!rail.isSpringLoading)
        rail.hoverEnded()
        clock.advance(by: 5)
        #expect(fired == 1)
        // A rail that cannot unfold (no room) does not spring-load; losing the room cancels a running hover.
        rail.canUnfold = false
        rail.hoverBegan()
        #expect(!rail.isSpringLoading && clock.pendingCount == 0)
        rail.canUnfold = true
        rail.hoverBegan()
        rail.canUnfold = false
        #expect(!rail.isSpringLoading && clock.pendingCount == 0)
        clock.advance(by: 5)
        #expect(fired == 1)
    }

    /// The production scheduler: a call runs on the main queue; a cancelled one never does. Generous margins: it waits
    /// for the call that runs, then checks the cancelled one (due earlier) did not.
    @Test func theMainQueueSchedulerRunsAndCancels() async throws {
        var ran: [String] = []
        let cancelled = MainQueueScheduler.shared.after(0.01) { ran.append("cancelled") }
        cancelled.cancel()
        _ = MainQueueScheduler.shared.after(0.02) { ran.append("kept") }
        for _ in 0..<300 where ran.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ran == ["kept"])
    }

    /// Dots keep 3:1 against the glass stand-ins the monitors' palette is checked on (#C0B8E2 light, #413A77 dark).
    @Test func amberAndGreenDotsKeepTheirContrast() {
        let lightGlass: UInt32 = 0xC0B8E2, darkGlass: UInt32 = 0x413A77
        for color in [RailPalette.needsYou, RailPalette.finished] {
            #expect(Self.contrast(color.light, lightGlass) >= 3, "\(String(color.light, radix: 16)) on light glass")
            #expect(Self.contrast(color.dark, darkGlass) >= 3, "\(String(color.dark, radix: 16)) on dark glass")
        }
        #expect(RailPalette.running == PitboxTheme.blue, "running keeps the theme's blue")
    }

    @Test func wordsForEveryCount() {
        #expect(FoldRailView.needsYouWords(1) == "1 needs you")
        #expect(FoldRailView.needsYouWords(0) == "0 need you")
        #expect(FoldRailView.finishedWords(1) == "1 finished")
        #expect(FoldRailView.runningWords(1, commandRunning: false) == "1 running")
        #expect(FoldRailView.shortCount(99) == "99" && FoldRailView.shortCount(100) == "99+")
        #expect(FoldRailView.shortCount(-3) == "0")
    }

    @Test func drawsInLightAndDark() {
        let rail = FoldRailView(frame: CGRect(x: 0, y: 0, width: 24, height: 300))
        rail.counts = RailCounts(needsYou: 1, finished: 1, running: 1)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            rail.appearance = NSAppearance(named: name)
            rail.layoutSubtreeIfNeeded()
            rail.updateLayer()
            rail.needsYouRow.updateLayer()
            #expect(rail.needsYouRow.dot.backgroundColor == RailPalette.needsYou.color(dark: name == .darkAqua).cgColor)
        }
    }

    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((rgb >> 16) & 0xFF) + 0.7152 * channel((rgb >> 8) & 0xFF) + 0.0722 * channel(rgb & 0xFF)
    }
}

@Suite @MainActor struct BlockRootViewTests {
    private let alone = BlockLayout.make(fit: BlockFit(columns: 2, width: 690, cell: 323, reduced: false), folded: false,
                                         docked: false, edge: .right)

    @Test func blockOnTopDrawerAtTheBottom() {
        let size = CGSize(width: 690, height: 879)
        let none = BlockRootView.contentFrames(size: size, layout: alone, drawerHeight: 0)
        #expect(none.block == CGRect(x: 16, y: 16, width: 658, height: 847))
        #expect(none.drawer == CGRect(x: 16, y: 863, width: 658, height: 0))
        #expect(none.rail == .zero)
        let tall = BlockRootView.contentFrames(size: size, layout: alone, drawerHeight: 5000)
        #expect(tall.drawer.height == 847 && tall.block.height == 0, "the drawer never leaves the panel")
        let docked = BlockLayout.make(fit: BlockFit(columns: 2, width: 631, cell: 301.4, reduced: false), folded: false,
                                      docked: true, edge: .right)
        let d = BlockRootView.contentFrames(size: CGSize(width: 631, height: 1312), layout: docked, drawerHeight: 100)
        #expect(d.block.minX == 16 && d.block.maxX == 631, "no padding on the host's side")
        let rail = BlockLayout.make(fit: BlockFit(columns: 0, width: 24, cell: 323, reduced: false), folded: true,
                                    docked: false, edge: .right)
        let r = BlockRootView.contentFrames(size: CGSize(width: 24, height: 879), layout: rail, drawerHeight: 100)
        #expect(r.rail == CGRect(x: 0, y: 0, width: 24, height: 879) && r.block == .zero && r.drawer == .zero)
    }
}
