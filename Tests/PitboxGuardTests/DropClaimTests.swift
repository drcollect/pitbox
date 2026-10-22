import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxGuard

// Drag-to-park in the guard: the fake AX, fake clock and fake button of FakeAX.swift, plus a real `WindowDropClaims`
// reading that same button and clock, wired the way the composition root wires it. No real window, event or
// Accessibility call (see FakeAX.swift).

/// A value the registry's `@Sendable` readers share with the test (the tests run on one thread).
private final class Shared<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// The simulation as the registry's readers see it, weakly (the engine holds the registry).
private final class SimReference: @unchecked Sendable {
    weak var sim: Simulation?
    init(_ sim: Simulation) { self.sim = sim }
}

/// A simulation whose engine holds a claims registry, as `WindowGuard.dropClaims` hands it over.
private struct ClaimRig {
    /// A running readable Claude copy: managed by the guard like any app, and claimable.
    static let claude: pid_t = 400

    let sim: Simulation
    let claims: WindowDropClaims
    /// Overrides what the registry reads as the button (nil: the simulation's own button, as in production, where both
    /// read `CGEventSource.buttonState`).
    let registryButton: Shared<Bool?>
    /// How often `onReleasedUnparked` ran the composition root's `onMainThread { windowGuard.lookAgain() }`.
    let lookAgainCalls: Shared<Int>

    init(_ windows: [FakeWindow], options: GuardOptions = GuardOptions(), wired: Bool = true) {
        var apps = Fixture.apps
        apps[Self.claude] = "Claude"
        let sim = Simulation(windows, options: options, apps: apps)
        let reference = SimReference(sim)
        let button = Shared<Bool?>(nil)
        let calls = Shared(0)
        let claims = WindowDropClaims(isLeftButtonDown: { button.value ?? reference.sim?.mouseDown ?? false },
                                      now: { reference.sim?.now ?? 0 })
        claims.setClaimablePIDs([Self.claude])
        claims.onReleasedUnparked = {
            calls.value += 1
            guard let sim = reference.sim else { return }
            sim.engine.lookAgain(now: sim.now)
            sim.pump()   // GuardCore ticks after every call it hands the engine
        }
        if wired { sim.engine.dropClaims = claims }
        self.sim = sim
        self.claims = claims
        registryButton = button
        lookAgainCalls = calls
    }

    /// The pop-out's frame on the desk, and where the user drops it: mostly inside the right strip (3840...5120).
    static let desk = CGRect(x: 1000, y: 100, width: 1000, height: 700)
    static let dropped = CGRect(x: 3550, y: 100, width: 1000, height: 700)
    /// Where the guard slides a dropped window that was not parked: beside the strip at full size.
    static let slidBack = CGRect(x: 2840, y: 100, width: 1000, height: 700)

    /// Drags window `id` into the strip with the button down, as the block sees it: the block claims it once armed.
    /// Returns whether the claim was granted.
    @discardableResult
    func dragIn(_ id: Int, to frame: CGRect = ClaimRig.dropped, claim: (pid: pid_t, number: UInt32)? = nil,
                notifies: Bool = true) -> Bool {
        sim.mouseDown = true
        let start = sim.frame(id) ?? Self.desk
        for step in 1...10 {
            let t = CGFloat(step) / 10
            let next = CGRect(x: start.minX + (frame.minX - start.minX) * t, y: frame.minY, width: frame.width,
                              height: frame.height)
            if notifies { sim.appChanges(id, to: next) } else { sim.provider.appSets(id, next) }
            sim.run(for: 0.03)
        }
        let target = claim ?? (Self.claude, UInt32(id))
        let granted = claims.claim(pid: target.pid, windowNumber: target.number)
        sim.run(for: 0.5)   // held inside the strip, armed
        return granted
    }

    var claimLines: [String] { sim.logs.filter { $0.contains("left a window for the strip's drop") } }
}

@Suite("Drop claims in the guard")
struct DropClaimTests {
    /// The release while claimed is no correction and no fight; the look at the claim's end slides the window back
    /// as after any drag ("after user action"), never as a fight.
    @Test func aDroppedWindowIsLeftAloneWhileClaimedAndSlidBackAtTheClaimsEndWithoutAFight() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        #expect(rig.dragIn(1))
        sim.releaseMouse()
        let released = sim.now
        sim.run(for: 2.9)
        #expect(sim.sets.isEmpty, "left alone while the claim holds")
        #expect(sim.frame(1) == ClaimRig.dropped)
        #expect(sim.engine.fights.entries[1] == nil, "a claimed look records nothing")
        #expect(sim.engine.cannotFitCount == 0)
        #expect(sim.engine.correctedCount == 0)
        sim.run(until: released + 3.05)
        #expect(sim.frame(1) == ClaimRig.slidBack, "slid back when the claim ended, 3 s after the release")
        #expect(sim.engine.fights.entries[1]?.hits.isEmpty == true, "the slide-back is the user's, never a fight")
        #expect(sim.engine.fightingCount(now: sim.now) == 0)
        #expect(sim.logs.contains { $0.contains("-> 2840,100 1000x700 (after user action)") })
        #expect(rig.claimLines == ["left a window for the strip's drop app=Claude"], "one line per claim, no title")
        sim.run(for: 10)
        #expect(sim.sets.count == 1)
    }

    /// The block could not park: it releases the claim unparked, the registry calls back, `lookAgain` makes the wait
    /// due and the window slides back at once, still as the user's.
    @Test func releasedUnparkedItIsCorrectedAtOnce() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        sim.run(for: 0.6)
        #expect(sim.sets.isEmpty)
        rig.claims.release(pid: ClaimRig.claude, windowNumber: 1, parked: false)
        #expect(rig.lookAgainCalls.value == 1)
        #expect(sim.frame(1) == ClaimRig.slidBack, "corrected at once, not at the claim's end")
        #expect(sim.engine.fights.entries[1]?.hits.isEmpty == true)
        #expect(sim.sets.count == 1)
    }

    /// `lookAgain` also runs a pass: a released window whose wait was lost (here dropped by hand; a guard restart clears
    /// every wait) is still corrected at once, not at the next 1 Hz pass.
    @Test func lookAgainAlsoRunsAPassForAReleasedWindowThatWasNotWaiting() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        sim.run(for: 0.2)
        sim.engine.pending[1] = nil
        rig.claims.release(pid: ClaimRig.claude, windowNumber: 1, parked: false)
        #expect(sim.frame(1) == ClaimRig.slidBack)
    }

    /// The block parked it: minimized windows are never corrected, claim or not.
    @Test func claimedThenMinimizedItIsNeverCorrected() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        sim.run(for: 0.17)   // the block waits 0.05 s, then minimizes
        sim.provider.windows[1]?.minimized = true
        sim.engine.windowMinimized(1)   // kAXWindowMiniaturizedNotification
        rig.claims.release(pid: ClaimRig.claude, windowNumber: 1, parked: true)
        #expect(rig.lookAgainCalls.value == 0, "a park needs no second look")
        sim.run(for: 20)
        #expect(sim.sets.isEmpty)
        #expect(sim.engine.fights.entries[1] == nil)
        // Restored at its frame from before the drag: nothing to correct.
        sim.provider.windows[1]?.minimized = false
        sim.appChanges(1, to: ClaimRig.desk)
        sim.run(for: 2)
        #expect(sim.sets.isEmpty)
        #expect(sim.engine.claimWaits.isEmpty, "the wait ended with the next look")
    }

    /// Where the claim check sits: after the button-down deferral, so nothing changes while the user still holds the
    /// window, and the claimed look makes no capabilities round trip.
    @Test func aClaimedWindowUnderAHeldButtonStillDefersAndTheCheckCostsNoCapabilitiesCall() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        while sim.now < 4.4 {   // still held: Claude keeps posting moves
            sim.notify(1)
            sim.run(for: 0.1)
        }
        // Released at a whole 4.5 s: the passes that follow (4.62, 5.62, …) then add up exactly. (With some sums the
        // engine's pass wake, `lastReconcile + interval`, and its test, `now - lastReconcile >= interval`, disagree by one
        // ulp; the fake clock then spins on that wake until the simulation's step limit. A real clock moves on.)
        sim.run(until: 4.5)
        #expect(sim.engine.deferred.contains(1))
        #expect(sim.engine.claimWaits.isEmpty, "no claimed look under a held button")
        #expect(rig.claimLines.isEmpty)
        // A look that starts while the button is down (pressed again during the round trip) defers too: claimed first,
        // it would wait for the 30 s backstop, since the registry has no release to count 3 s from.
        #expect(sim.engine.evaluate(1, now: sim.now, userInitiated: false) == .deferred)
        sim.releaseMouse()
        let released = sim.now
        sim.run(for: 1)
        #expect(sim.engine.claimWaits[1] != nil)
        #expect((sim.provider.calls["capabilities"] ?? 0) == 0, "no capabilities round trip for a claimed window")
        #expect(sim.sets.isEmpty)
        sim.run(until: released + 3.1)
        #expect(sim.frame(1) == ClaimRig.slidBack, "3 s after the release")
    }

    /// The 1 Hz pass: a window claimed while not pending (Claude posted no move) is found claimed by the pass after the
    /// release, re-pended, never memoized, and skipped by later passes; once the claim is over a pass corrects it.
    @Test func aPassDuringAClaimLeavesItAndAPassAfterCorrectsIt() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1, notifies: false)
        #expect(sim.engine.pending[1] == nil, "no notification: only the pass knows about it")
        sim.releaseMouse()
        let released = sim.now
        sim.run(for: 0.3)
        #expect(sim.engine.claimWaits[1] != nil, "the pass right after the release found it claimed")
        #expect(sim.engine.pending[1]?.fromDrag == true)
        #expect(sim.engine.settled.isEmpty, "a claimed outcome is never remembered by bounds")
        // A pass that reaches it while the claim still holds (its wait dropped by hand) leaves it too.
        sim.engine.pending[1] = nil
        sim.engine.requestReconcile(at: sim.now)
        sim.run(for: 0.01)
        #expect(sim.sets.isEmpty)
        #expect(sim.engine.pending[1] != nil, "re-pended by the pass for the claim's end")
        sim.run(until: released + 2.9)
        #expect(sim.sets.isEmpty)
        // After the claim, with no wait left (dropped by hand), the next pass corrects it like any window over the strip.
        sim.engine.pending[1] = nil
        sim.run(until: released + 3.05)
        #expect(sim.sets.isEmpty, "no pass ran between the claim's end and now")
        sim.run(until: released + 4.2)
        #expect(sim.frame(1) == ClaimRig.slidBack)
    }

    /// Without `_AXUIElementGetWindow` the guard cannot tell windows by number: no claim matches, today's correction.
    @Test func noWindowNumberNoClaim() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.provider.exposeWindowIDs = false
        sim.run(until: 0.5)
        #expect(rig.dragIn(1), "the block's claim itself is granted")
        sim.releaseMouse()
        sim.run(for: 0.3)
        #expect(sim.frame(1) == ClaimRig.slidBack, "corrected 0.12 s after the release, as today")
        #expect(rig.claimLines.isEmpty)
    }

    @Test func aClaimForAnotherNumberHasNoEffect() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk),
                            FakeWindow(2, pid: ClaimRig.claude, CGRect(x: 100, y: 900, width: 600, height: 400))])
        let sim = rig.sim
        sim.run(until: 0.5)
        #expect(rig.dragIn(1, claim: (ClaimRig.claude, 2)))
        sim.releaseMouse()
        sim.run(for: 0.3)
        #expect(sim.frame(1) == ClaimRig.slidBack)
        #expect(sim.frame(2) == CGRect(x: 100, y: 900, width: 600, height: 400))
        #expect(rig.claimLines.isEmpty)
    }

    /// The guard's own release reaches the registry: even a registry whose button reader still says "down" (a missed
    /// event) ends the hold 3 s after the release, through the monitor path and through the 100 ms poll.
    @Test func theGuardsMouseUpNotesTheReleaseInTheClaims() throws {
        for viaPoll in [false, true] {
            let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
            let sim = rig.sim
            rig.registryButton.value = true
            sim.run(until: 0.5)
            rig.dragIn(1)
            let released = sim.now
            if viaPoll {
                sim.mouseDown = false   // no monitor event: the guard's poll notices
                sim.run(for: 0.11)
            } else {
                sim.releaseMouse()
            }
            let left = try #require(rig.claims.holdRemaining(pid: ClaimRig.claude, windowNumber: 1))
            #expect(left < 3.001 && left > 2.8, "dated at the release, not held for 30 s (poll: \(viaPoll))")
            sim.run(until: released + 3.2)
            #expect(sim.frame(1) == ClaimRig.slidBack, "poll: \(viaPoll)")
        }
    }

    /// Nobody reports the release (no monitor, no poll running): the first look that sees the button
    /// up dates it, and the window is corrected about 3 s later, well within 4 s of the release.
    @Test func aLostMouseUpEndsTheHoldWithinAboutFourSeconds() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 1.05)   // the 1 Hz pass ran at 0 and 1: the next one is at 2
        #expect(abs(sim.engine.lastReconcile - 1) < 0.001)
        sim.mouseDown = true
        sim.provider.appSets(1, ClaimRig.dropped)   // Claude posts no move: nothing is pending or deferred
        sim.run(until: 1.3)
        #expect(rig.claims.claim(pid: ClaimRig.claude, windowNumber: 1))
        sim.run(until: 1.4)
        sim.mouseDown = false   // released; the event is lost, and no deferral polls the button
        let released = sim.now
        sim.run(until: released + 3.4)
        #expect(sim.frame(1) == ClaimRig.dropped, "still held: the pass at 2 s saw the button up and dated it then")
        #expect(sim.engine.claimWaits[1] != nil)
        sim.run(until: released + 4)
        #expect(sim.frame(1) == ClaimRig.slidBack, "corrected within about 4 s of a release nobody reported")
    }

    /// T28's left-over: a button that reads as held keeps a claim until `maxAge`, then the window is corrected, even
    /// though the guard's own stuck-button rule (20 s) would have corrected it earlier.
    @Test func aButtonThatReadsAsHeldKeepsTheClaimForThirtySecondsAtMost() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        let claimedAt = sim.now - 0.5
        sim.run(until: claimedAt + 25)
        #expect(sim.sets.isEmpty, "past the 20 s stuck-button rule, the claim still holds")
        #expect(sim.engine.claimWaits[1] != nil)
        sim.run(until: claimedAt + 30.2)
        #expect(sim.frame(1) == ClaimRig.slidBack, "maxAge is the last backstop")
    }

    /// Only the claimed Claude window is left alone; another app's window dropped at the same time is corrected as
    /// before, and a claim for another app's window is refused by the registry.
    @Test func anotherAppsWindowsAreCorrectedAsBefore() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk),
                            FakeWindow(2, pid: Fixture.textEdit, CGRect(x: 1000, y: 900, width: 1000, height: 400))])
        let sim = rig.sim
        sim.run(until: 0.5)
        sim.mouseDown = true
        sim.appChanges(2, to: CGRect(x: 3550, y: 900, width: 1000, height: 400))
        #expect(!rig.claims.claim(pid: Fixture.textEdit, windowNumber: 2), "TextEdit is not claimable")
        rig.dragIn(1)
        sim.releaseMouse()
        sim.run(for: 0.3)
        #expect(sim.frame(2) == CGRect(x: 2840, y: 900, width: 1000, height: 400), "TextEdit slides back as today")
        #expect(sim.frame(1) == ClaimRig.dropped, "the claimed pop-out waits")
        #expect(sim.sets.map(\.id) == [2])
    }

    /// Dry run: nothing is written either way, and a claimed window gets no "would move" line while claimed.
    @Test func dryRunLogsNoWouldMoveForAClaimedWindow() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)], options: GuardOptions(dryRun: true))
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        let released = sim.now
        sim.run(for: 2.9)
        #expect(!sim.logs.contains { $0.hasPrefix("dry run: would") }, "no dry-run line while claimed")
        #expect(sim.engine.correctedCount == 0)
        sim.run(until: released + 3.1)
        #expect(sim.logs.filter { $0.hasPrefix("dry run: would move") }.count == 1, "as today once the claim ended")
        #expect(sim.sets.isEmpty)
    }

    /// Paused, the guard does nothing at all (the block still parks); resumed while the claim holds, the window is
    /// still left alone, and corrected when it ends.
    @Test func pausedDoesNothingAndResumingRespectsAHoldingClaim() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.engine.setPaused(true, now: sim.now)
        sim.releaseMouse()
        let released = sim.now
        sim.engine.lookAgain(now: sim.now)
        sim.run(for: 1)
        #expect(sim.sets.isEmpty)
        sim.engine.setPaused(false, now: sim.now)
        sim.run(for: 0.5)
        #expect(sim.sets.isEmpty, "resumed during the claim: still left alone")
        sim.run(until: released + 3.1)
        #expect(sim.frame(1) == ClaimRig.slidBack)
    }

    /// Notifications during the claim (a minimize animation, focus changes) never correct the window and never add a log
    /// line; the claim's end still corrects it on time.
    @Test func notificationsDuringAClaimKeepItClaimedWithOneLogLine() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        let released = sim.now
        sim.run(for: 0.2)
        let since = sim.engine.claimWaits[1]?.since
        #expect(since != nil)
        while sim.now < released + 2.8 {
            sim.notify(1)
            sim.pump()
            sim.run(for: 0.2)
        }
        #expect(sim.sets.isEmpty)
        #expect(rig.claimLines.count == 1)
        #expect(sim.engine.claimWaits[1]?.since == since, "every re-pend keeps the claim's since")
        #expect(sim.engine.pending[1]?.fromDrag == true)
        sim.run(until: released + 3.2)
        #expect(sim.frame(1) == ClaimRig.slidBack)
        #expect(sim.engine.fights.entries[1]?.hits.isEmpty == true)
    }

    /// Two pop-outs claimed (two at most): a failed park of one makes both waits due; the one still claimed is left
    /// alone again, the released one slides back.
    @Test func lookAgainLooksAtEveryWaitAndOnlyTheReleasedOneMoves() {
        let other = CGRect(x: 1000, y: 900, width: 1000, height: 400)
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk), FakeWindow(2, pid: ClaimRig.claude, other)])
        let sim = rig.sim
        sim.run(until: 0.5)
        sim.mouseDown = true
        sim.appChanges(2, to: CGRect(x: 3550, y: 900, width: 1000, height: 400))
        #expect(rig.claims.claim(pid: ClaimRig.claude, windowNumber: 2))
        rig.dragIn(1)
        sim.releaseMouse()
        sim.run(for: 0.5)
        #expect(Set(sim.engine.claimWaits.keys) == [1, 2])
        let infoBefore = sim.provider.calls["info"] ?? 0
        rig.claims.release(pid: ClaimRig.claude, windowNumber: 1, parked: false)
        #expect((sim.provider.calls["info"] ?? 0) - infoBefore == 2, "both waits were looked at")
        #expect(sim.frame(1) == ClaimRig.slidBack)
        #expect(sim.frame(2) == CGRect(x: 3550, y: 900, width: 1000, height: 400), "still claimed")
        #expect(sim.engine.claimWaits[2] != nil)
        #expect(rig.claimLines.count == 2, "one line per claim, not per look")
    }

    /// The copy quits or becomes unreadable mid-claim: the registry drops its claims and calls back; the window is
    /// corrected at once.
    @Test func aCopyThatStopsBeingClaimableLosesItsHoldAtOnce() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        sim.run(for: 0.5)
        #expect(sim.sets.isEmpty)
        rig.claims.setClaimablePIDs([])
        #expect(rig.lookAgainCalls.value == 1)
        #expect(sim.frame(1) == ClaimRig.slidBack)
    }

    /// A second drop of the same window after the first claim ended is a new claim with a log line of its own.
    @Test func aLaterClaimOfTheSameWindowIsANewClaim() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        sim.run(for: 3.5)
        #expect(sim.frame(1) == ClaimRig.slidBack)
        rig.dragIn(1)
        sim.releaseMouse()
        sim.run(for: 0.5)
        #expect(rig.claimLines.count == 2)
        #expect(sim.frame(1) == ClaimRig.dropped)
    }

    /// Without a registry (`dropClaims` nil, the default) the guard is exactly today's.
    @Test func withoutClaimsTheGuardIsUnchanged() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)], wired: false)
        let sim = rig.sim
        sim.run(until: 0.5)
        #expect(rig.dragIn(1), "the registry grants it, but the guard never asks")
        sim.releaseMouse()
        sim.run(for: 0.3)
        #expect(sim.frame(1) == ClaimRig.slidBack)
        #expect(sim.engine.claimWaits.isEmpty)
    }

    @Test func aClaimedOutcomeIsNeverRememberedByBounds() {
        let sim = Simulation([])
        #expect(sim.engine.settleUntil(.claimed(until: 5), now: 1) == nil)
    }

    /// A look a few milliseconds before the claim's end treats it as ended: the guard never re-pends for an instant that
    /// rounding makes equal to now (with the fake clock that spun on one moment until the step limit).
    @Test func aClaimWithMillisecondsLeftCountsAsEnded() {
        let rig = ClaimRig([FakeWindow(1, pid: ClaimRig.claude, ClaimRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        let released = sim.now
        sim.run(until: released + 2.997)
        #expect(sim.frame(1) == ClaimRig.dropped)
        #expect(sim.engine.evaluate(1, now: sim.now, userInitiated: true) == .corrected(ClaimRig.slidBack))
    }
}

// The facade and the core are tested without `start()`: starting would use the real Accessibility API (FakeAX.swift).
@Suite("Drop claims: facade and core (never started)")
@MainActor
struct DropClaimFacadeTests {
    @Test func claimsAndLookAgainBeforeStartAreHarmless() {
        let guardian = WindowGuard(regions: FakeRegionSource())
        let claims = WindowDropClaims(isLeftButtonDown: { false }, now: { 0 })
        guardian.dropClaims = claims
        #expect(guardian.dropClaims === claims)
        guardian.lookAgain()
        guardian.dropClaims = nil
        guardian.lookAgain()
        #expect(!guardian.status.running)
    }

    @Test func coreTakesClaimsAndLooksAgainWithoutStarting() {
        let core = GuardCore(options: GuardOptions(), statusSink: { _ in }, permissionLost: {})
        core.setDropClaims(WindowDropClaims(isLeftButtonDown: { false }, now: { 0 }))
        core.lookAgain()
        core.setDropClaims(nil)
        core.stop()
        core.shutdown()
    }
}
