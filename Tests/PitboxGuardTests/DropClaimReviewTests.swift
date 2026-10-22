import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxGuard

// Regression tests from an adversarial review of the drop claims, on the same fakes as DropClaimTests. Each failed
// before the fix.

private final class RShared<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

private final class RSimReference: @unchecked Sendable {
    weak var sim: Simulation?
    init(_ sim: Simulation) { self.sim = sim }
}

private struct ReviewRig {
    static let claude: pid_t = 400
    let sim: Simulation
    let claims: WindowDropClaims
    let registryButton: RShared<Bool?>
    let lookAgainCalls: RShared<Int>

    init(_ windows: [FakeWindow], options: GuardOptions = GuardOptions(), wired: Bool = true) {
        var apps = Fixture.apps
        apps[Self.claude] = "Claude"
        let sim = Simulation(windows, options: options, apps: apps)
        let reference = RSimReference(sim)
        let button = RShared<Bool?>(nil)
        let calls = RShared(0)
        let claims = WindowDropClaims(isLeftButtonDown: { button.value ?? reference.sim?.mouseDown ?? false },
                                      now: { reference.sim?.now ?? 0 })
        claims.setClaimablePIDs([Self.claude])
        claims.onReleasedUnparked = {
            calls.value += 1
            guard let sim = reference.sim else { return }
            sim.engine.lookAgain(now: sim.now)
            sim.pump()
        }
        if wired { sim.engine.dropClaims = claims }
        self.sim = sim
        self.claims = claims
        registryButton = button
        lookAgainCalls = calls
    }

    static let desk = CGRect(x: 1000, y: 100, width: 1000, height: 700)
    static let dropped = CGRect(x: 3550, y: 100, width: 1000, height: 700)
    static let slidBack = CGRect(x: 2840, y: 100, width: 1000, height: 700)

    @discardableResult
    func dragIn(_ id: Int, to frame: CGRect = ReviewRig.dropped, claim: (pid: pid_t, number: UInt32)? = nil,
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
        sim.run(for: 0.5)
        return granted
    }

    var claimLines: [String] { sim.logs.filter { $0.contains("left a window for the strip's drop") } }
}

@Suite("Drop claims: review regressions")
struct DropClaimReviewTests {
    /// A drag held in the strip past the guard's 20 s stuck-button rule, released with the block silent (hung): the
    /// registry's hold ends 3 s after the release, but when does the guard look?
    @Test func aReleaseAfterTheStuckButtonRuleEndsTheHoldWithinThreeSeconds() {
        let rig = ReviewRig([FakeWindow(1, pid: ReviewRig.claude, ReviewRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        let claimedAt = sim.now - 0.5
        // Held for 22 s: the guard's stuck rule (20 s after dragSince) flushes the deferral; the look finds the claim with
        // the button still down, so it re-pends for claimedAt + 30.
        sim.run(until: claimedAt + 22)
        #expect(sim.sets.isEmpty)
        #expect(sim.engine.claimWaits[1] != nil, "the stuck-rule look found it claimed")
        let untilBefore = sim.engine.claimWaits[1]?.until
        #expect(untilBefore != nil && abs((untilBefore ?? 0) - (claimedAt + 30)) < 0.01, "re-pended for claimedAt + 30: \(String(describing: untilBefore))")
        // Released now (the guard's monitor reports it; the block reports nothing and never parks or releases).
        sim.releaseMouse()
        let released = sim.now
        let left = rig.claims.holdRemaining(pid: ReviewRig.claude, windowNumber: 1)
        #expect(left != nil && (left ?? 0) <= 3.001, "the registry's hold ends 3 s after the release: \(String(describing: left))")
        sim.run(until: released + 3.3)
        let correctedBy3s = sim.frame(1) == ReviewRig.slidBack
        sim.run(until: claimedAt + 30.3)
        #expect(correctedBy3s, "at most 3 s after the release")
    }

    /// Claude does not answer Accessibility at the claim's end (busy minimizing): the look backs off, the window loses
    /// its fromDrag wait, and the pass that corrects it later counts the slide-back as a fight hit.
    @Test func aBackoffAtTheClaimsEndStillSlidesBackAsTheUsers() {
        let rig = ReviewRig([FakeWindow(1, pid: ReviewRig.claude, ReviewRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        let released = sim.now
        sim.run(until: released + 2.5)
        #expect(sim.sets.isEmpty)
        sim.provider.hungPIDs.insert(ReviewRig.claude)
        sim.run(until: released + 3.3)
        #expect(sim.sets.isEmpty, "the look at the claim's end got cannotComplete")
        // RG2's fix: the backoff keeps the live claim wait and re-pends the window as a drag's for the backoff's end.
        #expect(sim.engine.pending[1]?.fromDrag == true, "re-pended after the backoff")
        #expect(sim.engine.claimWaits[1] != nil, "the claim wait survives the backoff")
        sim.provider.hungPIDs.remove(ReviewRig.claude)
        sim.run(until: released + 8)
        #expect(sim.frame(1) == ReviewRig.slidBack, "corrected once Claude answers again")
        let hits = sim.engine.fights.entries[1]?.hits ?? []
        #expect(hits.isEmpty, "the slide-back after a park attempt is never a fight")
    }

    /// P2b: the same three times in 10 s (the user retries the drop while Claude is slow): a cooldown?
    @Test func threeSlowDropsDoNotPutThePopOutOnACooldown() {
        let rig = ReviewRig([FakeWindow(1, pid: ReviewRig.claude, ReviewRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        var cooldownLogged = false
        for _ in 1...3 {
            rig.dragIn(1)
            sim.releaseMouse()
            let released = sim.now
            // The block's park fails after ~2.9 s; Claude is unresponsive right at the claim's end.
            sim.run(until: released + 2.9)
            sim.provider.hungPIDs.insert(ReviewRig.claude)
            rig.claims.release(pid: ReviewRig.claude, windowNumber: 1, parked: false)   // failed park, released unparked
            sim.run(until: released + 3.2)
            sim.provider.hungPIDs.remove(ReviewRig.claude)
            sim.run(until: released + 5.6)
            cooldownLogged = sim.logs.contains { $0.contains("keeps ending up over the block") }
        }
        #expect(!cooldownLogged, "three failed drops in ~17 s must not put the pop-out on a cooldown")
    }

    /// Hygiene: `reset()` (stop/start, permission lost) and `forget` keep claim waits.
    @Test func resetForgetsClaimWaits() {
        let rig = ReviewRig([FakeWindow(1, pid: ReviewRig.claude, ReviewRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        sim.run(for: 0.5)
        #expect(sim.engine.claimWaits[1] != nil)
        sim.engine.reset()
        #expect(sim.engine.claimWaits.isEmpty, "reset forgets scheduling state")
    }

    /// Notifications during a claim after `since + maxSettleDelay`: each one costs an `info` round trip, because the
    /// re-pend keeps the claim's first `since` and `windowChanged` caps `due` at `since + 2`.
    @Test func notificationsDuringAClaimCostNoRoundTrips() {
        let rig = ReviewRig([FakeWindow(1, pid: ReviewRig.claude, ReviewRig.desk)])
        let sim = rig.sim
        sim.run(until: 0.5)
        rig.dragIn(1)
        sim.releaseMouse()
        let released = sim.now
        sim.run(until: released + 2.2)
        let before = sim.provider.calls["info"] ?? 0
        var count = 0
        while sim.now < released + 2.9 {
            sim.notify(1)
            sim.pump()
            sim.run(for: 0.01)
            count += 1
        }
        let infoCalls = (sim.provider.calls["info"] ?? 0) - before
        #expect(infoCalls <= 2, "a chattering window is looked at once per maxSettleDelay, as outside a claim")
        sim.run(until: released + 3.3)
        #expect(sim.frame(1) == ReviewRig.slidBack)
    }

    /// P4b: the same storm outside a claim, for comparison.
}
