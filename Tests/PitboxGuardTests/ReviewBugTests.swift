import ApplicationServices
import CoreGraphics
import PitboxKit
import Testing
@testable import PitboxGuard

// Regression tests for the bugs found in an adversarial review. Each one failed
// against the code as first delivered. Fakes only: never the real Accessibility provider (see FakeAX.swift).

@Suite("Review: display changes")
struct ReviewDisplayTests {
    /// What a real Mac once did: the display woke up, reported a ~1920x1080 mode for about
    /// a second, and Shell moved the strip there. A guard that acts on that geometry mangles real windows.
    @Test func transientDisplayModeAfterWakeLeavesWindowsAlone() {
        let window = CGRect(x: 1000, y: 100, width: 2000, height: 800)
        let sim = Simulation([FakeWindow(1, window), FakeWindow(2, CGRect(x: 100, y: 100, width: 300, height: 300))])
        sim.run(for: 5)
        let transient = GuardDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                     visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 1000))
        sim.engine.setDisplays([transient], now: sim.now)
        sim.run(for: 0.12)  // Shell coalesces display changes for 0.12 s before it moves the strip
        sim.engine.setRegions([ReservedRegion(displayID: 1, rect: CGRect(x: 1440, y: 30, width: 480, height: 1000),
                                              edge: .right)], now: sim.now)
        for _ in 0..<5 {  // the mode change nudges other windows; GuardCore ticks after each of their notifications
            sim.run(for: 0.2)
            sim.notify(2)
            sim.pump()
        }
        sim.engine.setDisplays([Fixture.main], now: sim.now)
        sim.run(for: 0.12)
        sim.engine.setRegions([Fixture.rightStrip], now: sim.now)
        sim.run(for: 10)
        #expect(sim.sets.isEmpty, "never corrects against a display mode that lasts a second")
        #expect(sim.frame(1) == window)
    }

    @Test func realDisplayChangeIsCorrectedOnceTheDisplaySettles() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 1000, y: 100, width: 2000, height: 800))])
        sim.run(for: 2)
        let smaller = GuardDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                   visibleFrame: CGRect(x: 0, y: 30, width: 2560, height: 1312))
        sim.engine.setDisplays([smaller], now: sim.now)
        sim.engine.setRegions([ReservedRegion(displayID: 1, rect: CGRect(x: 1920, y: 30, width: 640, height: 1312),
                                              edge: .right)], now: sim.now)
        sim.run(for: 2.9)
        #expect(sim.sets.isEmpty, "held while the new mode settles")
        sim.run(for: 0.5)
        #expect(sim.frame(1) == CGRect(x: 1000, y: 100, width: 920, height: 800))
    }

    /// `GuardCore.wake()` holds too: the display may switch modes a couple of seconds after waking.
    @Test func wakeHoldsCorrectionsUntilTheDisplaySettles() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 100, y: 100, width: 800, height: 600))])
        sim.run(for: 2)
        sim.engine.holdCorrections(now: sim.now)
        sim.appChanges(1, to: Fixture.zoomed)
        sim.pump()
        sim.run(for: 0.5)
        sim.pump()
        #expect(sim.sets.isEmpty)
        sim.run(for: 2.6)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    @Test func dockOnlyChangeIsNotHeld() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 1000, y: 100, width: 2000, height: 800))])
        sim.run(for: 2)
        var dockMoved = Fixture.main
        dockMoved.visibleFrame = CGRect(x: 80, y: 30, width: 5040, height: 1410)
        sim.engine.setDisplays([dockMoved], now: sim.now)
        sim.engine.setRegions([ReservedRegion(displayID: 1, rect: CGRect(x: 2880, y: 30, width: 2240, height: 1410),
                                              edge: .right)], now: sim.now)
        sim.run(for: 0.3)
        #expect(sim.frame(1) == CGRect(x: 1000, y: 100, width: 1880, height: 800))
    }
}

@Suite("Review: transient failures are not verdicts")
struct ReviewFailureTests {
    @Test func capabilityTimeoutIsBackedOffNotJudgedCannotFit() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.provider.hungCapabilityPIDs = [Fixture.textEdit]
        sim.run(for: 3)
        #expect(sim.sets.isEmpty)
        #expect(sim.engine.cannotFitCount == 0, "a timeout says nothing about the window")
        #expect(!sim.logs.contains { $0.contains("cannot fit") })
        sim.provider.hungCapabilityPIDs = []
        sim.run(for: 70)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    @Test func oneFailedWriteIsRetriedLater() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.provider.setFrameScript[1] = [.other(AXError.failure.rawValue)]
        sim.run(for: 40)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    /// An app that answers the frame read but always times out on "is it settable?" must be backed off with growing
    /// delays, not every 2 s (each attempt can block the guard thread for the messaging timeout).
    @Test func halfHungAppBacksOffWithGrowingDelays() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.provider.hungCapabilityPIDs = [Fixture.textEdit]
        sim.run(for: 60)
        #expect((sim.provider.calls["capabilities"] ?? 0) <= 6, "2, 4, 8, 16, 32 s apart")
        #expect(sim.engine.lastError?.contains("does not answer") == true)
    }

    @Test func backoffErrorClearsWhenTheAppAnswersAgain() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.provider.hungPIDs = [Fixture.textEdit]
        sim.run(for: 1.5)
        #expect(sim.engine.lastError?.contains("does not answer") == true)
        sim.provider.hungPIDs = []
        sim.run(for: 70)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
        #expect(sim.engine.lastError == nil, "the problem is over")
    }

    @Test func backoffErrorClearsWhenTheAppQuits() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.provider.hungPIDs = [Fixture.textEdit]
        sim.run(for: 1.5)
        #expect(sim.engine.lastError != nil)
        sim.provider.windows[1] = nil
        sim.engine.removeApp(pid: Fixture.textEdit)
        #expect(sim.engine.lastError == nil)
    }
}

@Suite("Review: learning and refusals")
struct ReviewLearningTests {
    /// An app that applies frames a moment after the write (Wine, XQuartz, some iPad apps) must not leave behind a
    /// "minimum width" that stops the guard from ever narrowing that window again.
    @Test func minimumLearnedFromALateApplyIsForgottenOnceTheAppCatchesUp() {
        var late = FakeWindow(1, Fixture.zoomed)
        late.appliesLate = true
        let sim = Simulation([late])
        sim.run(for: 2)
        #expect(sim.frame(1) == Fixture.besideRightStrip, "the late write lands")
        sim.run(until: 5)
        sim.appChanges(1, to: Fixture.zoomed)  // the user zooms again
        sim.run(for: 2)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    /// Auto layout or SwiftUI may grow a window back to its minimum after the read-back: learn it and slide the
    /// window, instead of shrinking it again until the fight detector gives up with the window over the strip.
    @Test func minimumEnforcedAfterTheFactIsLearnedInsteadOfFought() {
        var clamped = FakeWindow(1, CGRect(x: 100, y: 100, width: 800, height: 600))
        clamped.growsBackToWidth = 1100
        let sim = Simulation([clamped])
        sim.run(for: 2)
        sim.appChanges(1, to: CGRect(x: 2800, y: 100, width: 1500, height: 900))
        sim.run(for: 5)
        #expect(sim.frame(1) == CGRect(x: 2740, y: 100, width: 1100, height: 900))
        #expect(sim.sets.count == 2, "shrink, learn, slide")
        #expect(sim.engine.fightingCount(now: sim.now) == 0)
    }

    @Test func appThatIgnoresMovesIsTriedOnceAndLeftAloneQuietly() {
        var pinned = FakeWindow(1, CGRect(x: 4000, y: 200, width: 600, height: 400))
        pinned.ignoresMoves = true
        let sim = Simulation([pinned])
        sim.run(for: 200)
        #expect(sim.sets.count == 1, "one try; the refusal is remembered at these bounds")
        #expect(sim.engine.correctedCount == 0, "nothing was corrected")
        #expect(sim.engine.cannotFitCount == 1)
        #expect(sim.engine.fightingCount(now: sim.now) == 0)
        #expect(sim.logs.filter { $0.contains("refused") }.count == 1)
    }
}

@Suite("Review: fights, storms and dry run")
struct ReviewLoopTests {
    /// Any click anywhere used to make every correction "user-caused" for 1.5 s, so an app that reverts its window
    /// could flicker forever while the user kept clicking in other apps.
    @Test func appThatRevertsIsLeftAloneEvenWhileTheUserKeepsClicking() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 100, y: 100, width: 800, height: 600))])
        sim.run(for: 2)
        sim.provider.windows[1]?.revertsTo = Fixture.zoomed
        sim.releaseMouse()  // the user clicks the zoom button
        sim.appChanges(1, to: Fixture.zoomed)
        for _ in 0..<100 {  // and keeps clicking in other apps for a minute
            sim.run(for: 0.6)
            sim.releaseMouse()
        }
        #expect(sim.sets.count <= 8, "an app that always reverts ends up cooling down (\(sim.sets.count) corrections)")
        #expect(sim.engine.fightingCount(now: sim.now) == 1)
    }

    /// A window that never goes quiet for 150 ms was never checked, and the periodic pass skipped it too.
    @Test func windowThatNeverStopsPostingNotificationsIsStillChecked() {
        let sim = Simulation([FakeWindow(1, CGRect(x: 100, y: 100, width: 800, height: 600))])
        sim.run(for: 2)
        sim.provider.appSets(1, Fixture.zoomed)
        for _ in 0..<50 {  // five seconds of chatter, never 150 ms of quiet
            sim.notify(1)
            sim.run(for: 0.1)
        }
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    @Test func dryRunNeverSetsManualAccessibility() {
        var hidden = FakeWindow(1, pid: Fixture.chrome, Fixture.zoomed)
        hidden.listedByAX = false
        let sim = Simulation([hidden], options: GuardOptions(dryRun: true))
        sim.provider.manualAccessibilityExposes = true
        sim.run(for: 5)
        #expect(sim.provider.manualAccessibilityRequests.isEmpty, "a dry run changes nothing in other apps")
        #expect(sim.sets.isEmpty)
        #expect(sim.logs.contains { $0.contains("dry run: would set AXManualAccessibility") })
    }

    /// `_AXUIElementGetWindow` missing or failing: the notification path must still leave always-on-top windows and
    /// windows on other Spaces alone (it used to skip both checks).
    @Test func withoutWindowNumbersFloatingAndOtherSpaceWindowsAreStillLeftAlone() {
        var floating = FakeWindow(1, CGRect(x: 3700, y: 100, width: 600, height: 400))
        floating.layer = 3
        var elsewhere = FakeWindow(2, Fixture.zoomed)
        elsewhere.onScreen = false
        let normal = FakeWindow(3, pid: Fixture.chrome, Fixture.zoomed)
        let sim = Simulation([floating, elsewhere, normal])
        sim.provider.exposeWindowIDs = false
        sim.run(for: 1)
        sim.notify(1)
        sim.notify(2)
        sim.run(for: 2)
        #expect(sim.frame(1) == floating.frame)
        #expect(sim.frame(2) == Fixture.zoomed)
        #expect(sim.frame(3) == Fixture.besideRightStrip, "normal windows are still found by frame")
    }
}
