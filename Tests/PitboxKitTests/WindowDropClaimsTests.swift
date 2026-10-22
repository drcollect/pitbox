import Foundation
import Testing
@testable import PitboxKit

// Drop claims: a fake left button and a fake clock, no real events.

/// A value the tests change while the registry reads it.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct Rig {
    let button = Box(true)
    let clock = Box<TimeInterval>(100)
    let claims: WindowDropClaims

    /// Copy A's pid is claimable; another copy's pid (unreadable, "Claude ?") is not.
    static let claude: pid_t = 4242
    static let unreadable: pid_t = 4444
    static let other: pid_t = 777

    init() {
        let button = self.button
        let clock = self.clock
        claims = WindowDropClaims(isLeftButtonDown: { button.value }, now: { clock.value })
        claims.setClaimablePIDs([Self.claude])
    }

    func advance(_ seconds: TimeInterval) { clock.value += seconds }
}

@Suite("Window drop claims")
struct WindowDropClaimsTests {
    @Test func theLimitsMatchTheSpec() {
        #expect(WindowDropClaims.maxHoldAfterMouseUp == 3)
        #expect(WindowDropClaims.maxAge == 30)
        #expect(WindowDropClaims.maxClaims == 2)
    }

    @Test func onlyClaimablePIDsWithTheButtonDownAreClaimed() {
        let rig = Rig()
        #expect(!rig.claims.claim(pid: Rig.other, windowNumber: 1), "another app's window")
        #expect(!rig.claims.claim(pid: Rig.unreadable, windowNumber: 1), "a copy the block may not read")
        rig.button.value = false
        #expect(!rig.claims.claim(pid: Rig.claude, windowNumber: 1), "the button is up")
        #expect(rig.claims.count == 0)
        rig.button.value = true
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 1))
        #expect(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 1) != nil)
        // Other numbers and other pids are never claimed by it.
        #expect(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 2) == nil)
        #expect(rig.claims.holdRemaining(pid: Rig.other, windowNumber: 1) == nil)
    }

    @Test func aClaimHoldsUntilTheEarlierOfThirtySecondsAndThreeAfterTheMouseUp() throws {
        let rig = Rig()
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 7))
        rig.advance(10)
        #expect(try #require(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 7)) == 20)
        rig.claims.noteMouseUp()
        rig.button.value = false
        #expect(try #require(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 7)) == 3)
        rig.advance(2.5)
        #expect(try #require(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 7)) == 0.5)
        rig.advance(0.5)
        #expect(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 7) == nil, "ended 3 s after the mouse-up")
        #expect(rig.claims.count == 0)

        // A button that reads as held: the 30 s backstop.
        rig.button.value = true
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 8))
        rig.advance(29.5)
        #expect(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 8) == 0.5)
        rig.advance(0.5)
        #expect(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 8) == nil)

        // A mouse-up late in the claim: 30 s still wins.
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 9))
        rig.advance(28)
        rig.claims.noteMouseUp()
        #expect(try #require(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 9)) == 2)
    }

    /// Nobody reports the release; the guard's own looks see the button up.
    @Test func aLostMouseUpEndsTheHoldThreeSecondsAfterTheFirstLookThatSeesTheButtonUp() throws {
        let rig = Rig()
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 5))
        rig.advance(4)
        rig.button.value = false            // released; no noteMouseUp from anyone
        rig.advance(0.75)                    // the guard's next pass comes a little later
        #expect(try #require(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 5)) == 3)
        rig.advance(2)
        #expect(try #require(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 5)) == 1, "the first sighting counts")
        rig.advance(1)
        #expect(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 5) == nil)
    }

    @Test func seeingTheButtonUpDatesEveryOpenClaim() throws {
        let rig = Rig()
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 1))
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 2))
        rig.button.value = false
        _ = rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 1)
        rig.advance(3)
        #expect(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 2) == nil, "window 2 was never asked about")
    }

    @Test func atMostTwoClaimsAndAReclaimWithinAPressKeepsItsTimes() throws {
        let rig = Rig()
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 1))
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 2))
        #expect(!rig.claims.claim(pid: Rig.claude, windowNumber: 3), "two at most")
        rig.advance(20)
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 1), "already claimed")
        #expect(try #require(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 1)) == 10, "the press does not extend it")
        // Released, then pressed again: a new claim with fresh times.
        rig.claims.noteMouseUp()
        rig.advance(1)
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 1))
        #expect(try #require(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 1)) == 30)
        // Once one ends, a third window may be claimed.
        rig.claims.release(pid: Rig.claude, windowNumber: 2, parked: true)
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 3))
        #expect(rig.claims.count == 2)
    }

    @Test func releaseEndsTheClaimAndOnlyAnUnparkedOneCallsBackOnceOutsideTheLock() {
        let rig = Rig()
        let calls = Box(0)
        let seenInside = Box<Int?>(nil)
        let claims = rig.claims
        claims.onReleasedUnparked = {
            calls.value += 1
            // The lock is not held here: calling back into the registry must not deadlock.
            seenInside.value = claims.count
        }
        #expect(claims.claim(pid: Rig.claude, windowNumber: 1))
        #expect(claims.claim(pid: Rig.claude, windowNumber: 2))
        claims.release(pid: Rig.claude, windowNumber: 1, parked: true)
        #expect(calls.value == 0 && claims.holdRemaining(pid: Rig.claude, windowNumber: 1) == nil)
        claims.release(pid: Rig.claude, windowNumber: 2, parked: false)
        #expect(calls.value == 1 && seenInside.value == 0)
        claims.release(pid: Rig.claude, windowNumber: 2, parked: false)
        #expect(calls.value == 1, "a claim that is gone is not released twice")
    }

    @Test func aProcessNoLongerClaimableLosesItsClaims() {
        let rig = Rig()
        let calls = Box(0)
        rig.claims.onReleasedUnparked = { calls.value += 1 }
        #expect(rig.claims.claim(pid: Rig.claude, windowNumber: 1))
        rig.claims.setClaimablePIDs([Rig.other])
        #expect(rig.claims.holdRemaining(pid: Rig.claude, windowNumber: 1) == nil)
        #expect(calls.value == 1, "the guard looks again")
        rig.claims.setClaimablePIDs([])
        #expect(calls.value == 1)
    }

    @Test func concurrentUseFromSeveralThreadsStaysConsistent() {
        let rig = Rig()
        let claims = rig.claims
        let released = Box(0)
        claims.onReleasedUnparked = { released.value += 1 }
        let granted = Box(0)
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let window = UInt32(i % 4)
            if claims.claim(pid: Rig.claude, windowNumber: window) { granted.value += 1 }
            _ = claims.holdRemaining(pid: Rig.claude, windowNumber: window)
            if i % 3 == 0 { claims.noteMouseUp() }
            if i % 5 == 0 { claims.release(pid: Rig.claude, windowNumber: window, parked: i % 2 == 0) }
            _ = claims.count
        }
        #expect(claims.count <= WindowDropClaims.maxClaims)
        #expect(granted.value >= 1)
        #expect(released.value >= 0)
    }

    @Test func theDefaultsUseTheRealButtonAndTheMonotonicClock() {
        // No claim is made here: the default reader only reads the button state (permission-free).
        let claims = WindowDropClaims()
        claims.setClaimablePIDs([])
        #expect(!claims.claim(pid: Rig.claude, windowNumber: 1))
        #expect(claims.holdRemaining(pid: Rig.claude, windowNumber: 1) == nil)
        #expect(claims.count == 0)
    }
}
