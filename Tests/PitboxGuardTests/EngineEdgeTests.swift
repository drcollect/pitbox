import CoreGraphics
import Testing
@testable import PitboxGuard

@Suite("Engine: what it must leave alone, cost and failure handling")
struct EngineEdgeTests {
    @Test func leavesAloneWindowsItMustNotTouch() {
        var minimized = FakeWindow(1, Fixture.zoomed)
        minimized.minimized = true
        var fullScreen = FakeWindow(2, Fixture.main.frame)
        fullScreen.fullScreen = true
        var floating = FakeWindow(3, CGRect(x: 3900, y: 100, width: 300, height: 300))
        floating.subrole = "AXFloatingWindow"
        var sheet = FakeWindow(4, CGRect(x: 3700, y: 100, width: 500, height: 300))
        sheet.role = "AXSheet"
        var popover = FakeWindow(5, CGRect(x: 3700, y: 500, width: 500, height: 300))
        popover.subrole = "AXUnknown"
        var alwaysOnTop = FakeWindow(6, CGRect(x: 3700, y: 900, width: 500, height: 300))
        alwaysOnTop.layer = 3
        let exemptApp = FakeWindow(7, pid: Fixture.unmanaged, Fixture.zoomed)
        let pitboxItself = FakeWindow(8, pid: Fixture.ownPID, Fixture.rightStrip.rect)
        let kiosk = FakeWindow(9, pid: Fixture.chrome, Fixture.main.frame)
        var systemDialog = FakeWindow(10, CGRect(x: 3700, y: 300, width: 500, height: 300))
        systemDialog.subrole = "AXSystemDialog"
        let sim = Simulation([minimized, fullScreen, floating, sheet, popover, alwaysOnTop, exemptApp, pitboxItself,
                              kiosk, systemDialog])
        sim.run(for: 3)
        for id in 1...10 { sim.notify(id) }
        sim.run(for: 3)
        #expect(sim.sets.isEmpty)
    }

    @Test func windowOnAnotherSpaceWaitsForItsSpace() {
        var elsewhere = FakeWindow(1, Fixture.zoomed)
        elsewhere.onScreen = false  // on another Space
        let sim = Simulation([elsewhere])
        sim.run(for: 1)
        sim.notify(1)  // its app moved it over there
        sim.run(for: 1)
        #expect(sim.sets.isEmpty)
        sim.provider.windows[1]?.onScreen = true  // the user switches to that Space
        sim.run(for: 1.1)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    @Test func idlePassesMakeNoAccessibilityCalls() {
        let sim = Simulation((1...6).map { FakeWindow($0, CGRect(x: 100 * $0, y: 100, width: 800, height: 600)) })
        sim.run(for: 30)
        #expect(sim.provider.accessibilityCalls == 0)
        #expect((sim.provider.calls["onScreenWindows"] ?? 0) >= 30)
    }

    @Test func nothingRunsWhileTheStripIsHiddenOrPaused() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)], regions: [])
        #expect(sim.engine.nextWake(now: 0) == nil)
        sim.run(for: 10)
        #expect(sim.provider.calls.isEmpty)
        sim.engine.setRegions([Fixture.rightStrip], now: sim.now)
        sim.run(for: 1)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
        sim.engine.setPaused(true, now: sim.now)
        sim.appChanges(1, to: Fixture.zoomed)
        #expect(sim.engine.nextWake(now: sim.now) == nil)
        sim.run(for: 10)
        #expect(sim.frame(1) == Fixture.zoomed)
        sim.engine.setPaused(false, now: sim.now)
        sim.run(for: 0.1)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    @Test func unresponsiveAppIsBackedOff() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.provider.hungPIDs = [Fixture.textEdit]
        sim.run(for: 1.5)
        #expect(sim.provider.calls["windows"] == 1)
        sim.run(for: 10)
        #expect((sim.provider.calls["windows"] ?? 0) <= 4)
        #expect(sim.engine.lastError?.contains("does not answer") == true)
        sim.provider.hungPIDs = []
        sim.run(for: 40)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    @Test func revokedPermissionIsReported() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.provider.apiDisabled = true
        sim.run(for: 0.1)
        #expect(sim.engine.apiDisabled)
        #expect(sim.engine.lastError == "Accessibility permission is off")
        sim.engine.reset()  // what the host does when it stops; the error must not outlive a restart
        #expect(!sim.engine.apiDisabled)
        #expect(sim.engine.lastError == nil)
    }

    @Test func secondDisplayWindowsAreJudgedAgainstTheirOwnDisplay() {
        let second = GuardDisplay(id: 2, frame: CGRect(x: 5120, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 5120, y: 25, width: 1920, height: 1055))
        let onSecond = CGRect(x: 5300, y: 100, width: 1200, height: 800)
        let sim = Simulation([FakeWindow(1, onSecond), FakeWindow(2, CGRect(x: 5000, y: 100, width: 1500, height: 800))],
                             displays: [Fixture.main, second])
        sim.run(for: 1)
        #expect(sim.frame(1) == onSecond)
        #expect(sim.frame(2) == CGRect(x: 5120, y: 100, width: 1380, height: 800), "pushed back onto its display")
    }

    @Test func electronWindowsHiddenFromAccessibilityGetManualAccessibilityOnce() {
        var hidden = FakeWindow(1, pid: Fixture.chrome, Fixture.zoomed)
        hidden.listedByAX = false
        let sim = Simulation([hidden])
        sim.provider.manualAccessibilityExposes = true
        sim.run(for: 1)
        #expect(sim.provider.manualAccessibilityRequests == [Fixture.chrome])
        #expect(sim.frame(1) == Fixture.besideRightStrip)
    }

    @Test func manualAccessibilityIsNeverSetWhenPolicyForbidsIt() {
        var hidden = FakeWindow(1, pid: Fixture.chrome, Fixture.zoomed)
        hidden.listedByAX = false
        var options = GuardOptions()
        options.manualAccessibility = .never
        let sim = Simulation([hidden], options: options)
        sim.run(for: 5)
        #expect(sim.provider.manualAccessibilityRequests.isEmpty)
        #expect(sim.frame(1) == Fixture.zoomed)
        #expect(sim.logs.contains { $0.contains("does not list") })
        #expect(sim.provider.calls["windows"] == 1, "remembered for 30 s instead of asked every second")
    }

    @Test func unlistedChildWindowOfAnAppWithWindowsDoesNotTriggerManualAccessibility() {
        let browser = FakeWindow(1, pid: Fixture.chrome, CGRect(x: 100, y: 100, width: 1000, height: 800))
        var popup = FakeWindow(2, pid: Fixture.chrome, CGRect(x: 3700, y: 100, width: 400, height: 300))
        popup.listedByAX = false
        let sim = Simulation([browser, popup])
        sim.run(for: 3)
        #expect(sim.provider.manualAccessibilityRequests.isEmpty)
        #expect(sim.sets.isEmpty)
    }

    @Test func windowsAreMatchedByFrameWithoutWindowNumbers() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed), FakeWindow(2, CGRect(x: 100, y: 100, width: 500, height: 400))])
        sim.provider.exposeWindowIDs = false
        sim.run(for: 0.1)
        #expect(sim.frame(1) == Fixture.besideRightStrip)
        #expect(sim.sets.count == 1)
    }

    @Test func cannotFitIsCountedAndNotRetriedEverySecond() {
        var wide = FakeWindow(1, CGRect(x: 500, y: 100, width: 4000, height: 900))
        wide.resizable = false
        let sim = Simulation([wide])
        sim.run(for: 0.1)
        #expect(sim.frame(1) == CGRect(x: 0, y: 100, width: 4000, height: 900))
        #expect(sim.engine.cannotFitCount == 1)
        sim.run(for: 10)
        #expect(sim.sets.count == 1)
        #expect(sim.provider.calls["info"] == 3, "startup pass, verification, one pass at the new bounds; then remembered")
        sim.provider.windows[1] = nil  // the window is closed
        sim.run(for: 1.1)
        #expect(sim.engine.cannotFitCount == 0)
    }

    @Test func quittingAppIsForgotten() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.run(for: 0.1)
        #expect(sim.engine.windowPIDs[1] == Fixture.textEdit)
        sim.engine.removeApp(pid: Fixture.textEdit)
        #expect(sim.engine.windowPIDs.isEmpty)
        #expect(sim.engine.fights.entries.isEmpty)
        #expect(!sim.engine.isManaged(pid: Fixture.textEdit))
    }

    @Test func vanishedWindowIsForgotten() {
        let sim = Simulation([FakeWindow(1, Fixture.zoomed)])
        sim.run(for: 0.1)
        sim.provider.windows[1] = nil
        sim.notify(1)
        sim.run(for: 0.6)
        #expect(sim.engine.windowPIDs[1] == nil)
        #expect(sim.engine.pending.isEmpty)
    }
}
