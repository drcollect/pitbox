import CoreGraphics
import PitboxKit
import Testing
@testable import PitboxGuard

@Suite("Engine: everyday scenarios")
struct EngineScenarioTests {
    @Test func startupPassFixesWindowsAlreadyOverTheStrip() {
        let clear = CGRect(x: 100, y: 100, width: 800, height: 600)
        let sim = Simulation([FakeWindow(1, Fixture.zoomed), FakeWindow(2, clear)])
        sim.run(until: 0.01)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
        #expect(sim.frame(2) == clear)
        #expect(sim.sets.count == 1)
        #expect(sim.provider.calls["info"] == 1, "the window clear of the strip costs no round trip")
        #expect(sim.engine.correctedCount == 1)
    }

    @Test func zoomAnimationIsUndoneOnceWithoutFlicker() {
        let start = CGRect(x: 200, y: 100, width: 1600, height: 900)
        let sim = Simulation([FakeWindow(1, start)])
        sim.run(until: 2.85)
        let infoCalls = sim.provider.calls["info"] ?? 0
        let end = Fixture.zoomed
        // A 12-frame zoom animation, already over the strip and still running when the periodic pass fires at 3.0.
        for step in 1...12 {
            let t = CGFloat(step) / 12
            let frame = CGRect(x: (start.minX + (end.minX - start.minX) * t).rounded(),
                               y: (start.minY + (end.minY - start.minY) * t).rounded(),
                               width: (start.width + (end.width - start.width) * t).rounded(),
                               height: (start.height + (end.height - start.height) * t).rounded())
            sim.appChanges(1, to: frame)
            sim.run(for: 0.016)
            #expect(sim.sets.isEmpty, "never corrects a half-animated frame (step \(step))")
        }
        #expect((sim.provider.calls["info"] ?? 0) == infoCalls, "the pass at t = 3.0 skips the settling window for free")
        sim.run(for: 1)
        #expect(sim.sets.count == 1)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
        sim.run(for: 10)
        #expect(sim.sets.count == 1, "one correction, no flicker loop")
    }

    @Test func dragIsNeverFoughtAndIsCorrectedOnRelease() throws {
        let sim = Simulation([FakeWindow(1, CGRect(x: 1000, y: 100, width: 1000, height: 700))])
        sim.run(until: 0.5)
        let infoCalls = sim.provider.calls["info"] ?? 0
        sim.mouseDown = true
        for step in 1...30 {
            sim.appChanges(1, to: CGRect(x: 1000 + CGFloat(step) * 85, y: 100, width: 1000, height: 700))
            sim.run(for: 0.02)
        }
        sim.run(for: 2)  // the user holds still over the strip, button down
        #expect(sim.sets.isEmpty)
        #expect((sim.provider.calls["info"] ?? 0) == infoCalls, "no round trips to the app while the button is held")
        sim.releaseMouse()
        sim.run(for: 0.5)
        #expect(sim.sets.count == 1)
        #expect(sim.frame(1) == CGRect(x: 2840, y: 100, width: 1000, height: 700), "slid back at full size")
        let hits = sim.engine.fights.entries[1]?.hits ?? []
        #expect(hits.isEmpty, "a user's drag never counts as a fight")
    }

    @Test func missedMouseUpIsCaughtByPolling() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 1000, y: 100, width: 1000, height: 700))])
        sim.run(until: 0.5)
        sim.mouseDown = true
        sim.appChanges(1, to: CGRect(x: 3550, y: 100, width: 1000, height: 700))
        sim.run(for: 1)
        #expect(sim.sets.isEmpty)
        sim.mouseDown = false  // released, but the monitor event never arrived
        sim.run(for: 0.4)
        #expect(sim.frame(1) == CGRect(x: 2840, y: 100, width: 1000, height: 700))
    }

    @Test func passWaitsForTheButtonAndRunsRightAfterTheRelease() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 100, y: 100, width: 800, height: 600))])
        sim.run(until: 0.5)
        sim.mouseDown = true  // the user is busy dragging something else
        sim.provider.appSets(1, Fixture.zoomed)  // an app zooms a window without telling Accessibility
        let infoCalls = sim.provider.calls["info"] ?? 0
        sim.run(for: 3)
        #expect(sim.sets.isEmpty)
        #expect((sim.provider.calls["info"] ?? 0) == infoCalls, "no round trips to apps while the button is held")
        sim.releaseMouse()
        sim.run(for: 0.2)
        #expect(sim.frame(1) == Fixture.besideRightStrip, "a pass runs right after the release")
    }

    @Test func stuckMouseButtonStopsDelayingCorrections() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 1000, y: 100, width: 1000, height: 700))])
        sim.run(until: 0.5)
        sim.mouseDown = true
        sim.appChanges(1, to: CGRect(x: 3550, y: 100, width: 1000, height: 700))
        sim.run(for: 10)
        #expect(sim.sets.isEmpty)
        sim.run(for: 15)  // past maxDragDeferral (20 s)
        #expect(sim.sets.count == 1)
    }

    @Test func newWindowIsCorrectedOnceItSettles() {
        let sim = Simulation([])
        sim.run(for: 1)
        sim.provider.add(FakeWindow(5, Fixture.zoomed))
        sim.notify(5)  // AXWindowCreated
        sim.run(for: 0.1)
        #expect(sim.sets.isEmpty, "waits for the settle delay")
        sim.run(for: 0.2)
        #expect(sim.frame(5) == Fixture.besideRightStrip)
    }

    @Test func appMinimumWidthIsLearnedAndTheWindowSlidesInstead() {
        var stubborn = FakeWindow(1, CGRect(x: 500, y: 100, width: 4000, height: 900))
        stubborn.appMinWidth = 3600
        let sim = Simulation([stubborn])
        sim.run(until: 0.01)
        #expect(sim.frame(1) == CGRect(x: 240, y: 100, width: 3600, height: 900))
        #expect(sim.sets.count == 2)
        #expect(sim.engine.learnedMinWidth[1] == 3600)
        sim.run(until: 1.5)
        sim.appChanges(1, to: Fixture.zoomed)
        sim.run(for: 1)
        #expect(sim.sets.count == 3, "the learned minimum makes the next correction a single step")
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    @Test func appThatSilentlyPutsTheWindowBackIsCaughtByTheVerification() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.run(for: 0.1)
        sim.provider.appSets(1, Fixture.zoomed)  // no notification
        sim.run(for: 0.45)
        #expect(sim.sets.count == 2)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    @Test func fightingAppIsLeftAloneForACooldownThatDoubles() throws {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.run(until: 0.01)
        sim.run(until: 1.2)
        sim.appChanges(1, to: Fixture.zoomed); sim.run(for: 0.5)
        sim.appChanges(1, to: Fixture.zoomed); sim.run(for: 0.5)
        #expect(sim.sets.count == 3)
        #expect(sim.engine.fightingCount(now: sim.now) == 1)
        #expect(sim.logs.contains { $0.contains("keeps ending up over the block") })
        sim.appChanges(1, to: Fixture.zoomed)
        sim.run(for: 30)
        #expect(sim.sets.count == 3, "left alone while cooling down")
        #expect(sim.frame(1) == Fixture.zoomed)
        sim.run(for: 35)  // the 60 s cooldown ends and the guard tries again
        #expect(sim.sets.count == 4)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
        #expect(sim.engine.fightingCount(now: sim.now) == 0)
        sim.appChanges(1, to: Fixture.zoomed); sim.run(for: 0.5)
        sim.appChanges(1, to: Fixture.zoomed); sim.run(for: 0.5)
        #expect(sim.sets.count == 6)
        let end = try #require(sim.engine.fights.cooldownEnd(1, now: sim.now))
        #expect(abs(end - sim.now - 120) < 1, "second cooldown is twice as long")
    }

    @Test func dryRunLogsOnceAndNeverMovesAnything() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)], options: GuardOptions(dryRun: true))
        sim.run(for: 5)
        #expect(sim.sets.isEmpty)
        #expect(sim.engine.correctedCount == 1)
        #expect(sim.logs.filter { $0.hasPrefix("dry run: would shrink") }.count == 1)
        #expect(sim.provider.calls["info"] == 1, "not asked again every second")
        sim.appChanges(1, to: CGRect(x: 500, y: 30, width: 4500, height: 1312))
        sim.run(for: 1)
        #expect(sim.logs.filter { $0.hasPrefix("dry run") }.count == 2, "a new frame is logged again")
        #expect(sim.sets.isEmpty)
    }

    @Test func leftStripPushesWindowsRight() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)], regions: [Fixture.leftStrip])
        sim.run(for: 0.1)
        #expect(sim.frame(1) == CGRect(x: 1280, y: 30, width: 3840, height: 1312))
    }

    @Test func widerStripTriggersAPass() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 2000, y: 100, width: 1500, height: 800))])
        sim.run(for: 2)
        #expect(sim.sets.isEmpty)
        let wider = ReservedRegion(displayID: 1, rect: CGRect(x: 3200, y: 30, width: 1920, height: 1312), edge: .right)
        sim.engine.setRegions([wider], now: sim.now)
        sim.run(for: 0.3)
        #expect(sim.frame(1) == CGRect(x: 2000, y: 100, width: 1200, height: 800))
    }
}
