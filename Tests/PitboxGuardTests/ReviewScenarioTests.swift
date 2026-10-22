import CoreGraphics
import PitboxKit
import Testing
@testable import PitboxGuard

// Scenarios from an adversarial review that the original suite did not cover: notification storms, character-cell
// snapping, apps quitting mid-correction, strips changing during a drag, tabbed windows. Fakes only.

@Suite("Review: cost under notification storms")
struct ReviewStormTests {
    @Test func burstOfAThousandNotificationsCostsOneCheck() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 100, y: 100, width: 800, height: 600))])
        sim.run(for: 2)
        let infoCalls = sim.provider.calls["info"] ?? 0
        sim.provider.appSets(1, Fixture.zoomed)
        for _ in 0..<1000 { sim.notify(1) }
        sim.run(for: 0.3)
        #expect(sim.sets.count == 1)
        #expect((sim.provider.calls["info"] ?? 0) - infoCalls == 1)
    }

    @Test func burstAcrossFiftyWindowsCostsOneCheckEach() {
        let sim = Simulation((1...50).map { FakeWindow($0, CGRect(x: 20 * $0, y: 100, width: 800, height: 600)) })
        sim.run(for: 2)
        let infoCalls = sim.provider.calls["info"] ?? 0
        for _ in 0..<20 { for id in 1...50 { sim.notify(id) } }
        sim.run(for: 0.3)
        #expect((sim.provider.calls["info"] ?? 0) - infoCalls == 50)
        #expect(sim.sets.isEmpty)
    }
}

@Suite("Review: real-world app behaviours")
struct ReviewAppBehaviourTests {
    @Test func terminalSnappingDownFitsInOneStep() {
        var terminal = FakeWindow(1, Fixture.zoomed)
        terminal.widthStep = 7
        let sim = Simulation([terminal])
        sim.run(for: 5)
        #expect(sim.frame(1) == CGRect(x: 0, y: 30, width: 3836, height: 1312))
        #expect(sim.sets.count == 1)
    }

    @Test func snappingUpIsLeftAFewPointsOverWithoutALoop() {
        var terminal = FakeWindow(1, Fixture.zoomed)
        terminal.widthStep = 7
        terminal.snapsUp = true
        let sim = Simulation([terminal])
        sim.run(for: 60)
        #expect(sim.frame(1) == CGRect(x: 0, y: 30, width: 3843, height: 1312))
        #expect(sim.sets.count == 1)
        #expect(sim.logs.filter { $0.contains("cannot fit") }.count == 1)
        #expect(sim.engine.fightingCount(now: sim.now) == 0)
    }

    @Test func appQuittingBetweenTheReadAndTheWriteIsForgotten() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.provider.setFrameScript[1] = [.invalidElement]
        sim.run(for: 0.1)
        #expect(sim.engine.lastError == nil)
        #expect(sim.engine.windowPIDs[1] == nil)
        sim.provider.windows[1] = nil
        sim.engine.removeApp(pid: Fixture.textEdit)  // NSWorkspace's terminate notification
        sim.run(for: 5)
        #expect(sim.sets.isEmpty)
        #expect(sim.engine.pending.isEmpty)
    }

    /// The app hangs between the two writes of a two-step correction (learned minimum, then slide). The half-done
    /// window has new bounds, so the pass looks at it again once the app answers.
    @Test func appHangingBetweenTheTwoWritesIsFinishedLater() {
        var stubborn = FakeWindow(1, CGRect(x: 500, y: 100, width: 4000, height: 900))
        stubborn.appMinWidth = 3600
        let sim = Simulation([stubborn])
        sim.provider.setFrameScript[1] = [nil, .cannotComplete]
        sim.run(until: 0.01)
        sim.provider.hungPIDs = [Fixture.textEdit]
        sim.run(until: 1)
        sim.provider.hungPIDs = []
        sim.run(until: 20)
        #expect(sim.frame(1) == CGRect(x: 240, y: 100, width: 3600, height: 900))
        #expect(sim.engine.cannotFitCount == 0)
    }

    @Test func stripWidenedDuringADragIsAppliedOnRelease() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 1000, y: 100, width: 1000, height: 700))])
        sim.run(until: 0.5)
        sim.mouseDown = true
        sim.appChanges(1, to: CGRect(x: 2600, y: 100, width: 1000, height: 700))
        sim.run(for: 0.5)
        let wider = ReservedRegion(displayID: 1, rect: CGRect(x: 3200, y: 30, width: 1920, height: 1312), edge: .right)
        sim.engine.setRegions([wider], now: sim.now)
        sim.run(for: 1)
        #expect(sim.sets.isEmpty, "nothing moves while the button is held")
        sim.releaseMouse()
        sim.run(for: 0.5)
        #expect(sim.frame(1) == CGRect(x: 2600, y: 100, width: 600, height: 700))
    }

    @Test func pausedDuringADragStaysQuietUntilResumed() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 1000, y: 100, width: 1000, height: 700))])
        sim.run(until: 0.5)
        sim.mouseDown = true
        sim.appChanges(1, to: CGRect(x: 3550, y: 100, width: 1000, height: 700))
        sim.run(for: 0.5)
        sim.engine.setPaused(true, now: sim.now)
        sim.releaseMouse()
        sim.run(for: 3)
        #expect(sim.sets.isEmpty)
        sim.engine.setPaused(false, now: sim.now)
        sim.run(for: 0.3)
        #expect(sim.frame(1) == CGRect(x: 2840, y: 100, width: 1000, height: 700))
    }

    /// Native tabs: every tab is a window with the group's frame; only the selected one is on screen.
    @Test func tabbedWindowsOnlyTheVisibleTabIsWritten() {
        var background = FakeWindow(2, Fixture.zoomed)
        background.onScreen = false
        let sim = Simulation([FakeWindow(1, Fixture.zoomed), background])
        sim.run(for: 0.1)
        sim.notify(2)
        sim.run(for: 2)
        #expect(sim.sets.map(\.id) == [1])
    }

    @Test func sizeSettableButNotPositionShrinksInPlaceOrReportsCannotFit() {
        var pinned = FakeWindow(1, CGRect(x: 1000, y: 100, width: 3000, height: 900))
        pinned.movable = false
        let right = Simulation([pinned])
        right.run(for: 1)
        #expect(right.frame(1) == CGRect(x: 1000, y: 100, width: 2840, height: 900))
        pinned.frame = CGRect(x: 500, y: 100, width: 2500, height: 900)
        let left = Simulation([pinned], regions: [Fixture.leftStrip])
        left.run(for: 5)
        #expect(left.sets.isEmpty, "narrowing against a left strip moves the origin, which it cannot")
        #expect(left.engine.cannotFitCount == 1)
    }
}
