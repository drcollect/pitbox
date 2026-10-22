import Foundation
import Testing
@testable import PitboxKit

// The registry's change hook (`WindowDropClaims.onChange`), which the app uses to mirror drop claims to a dock host
// (docs/DOCK_PROTOCOL.md §5.10): a fake left button and a fake clock, no real events.

/// A value the tests change while the registry reads it.
private final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A registry over a fake button and clock, with copy A's pid claimable and every change recorded.
private struct ChangeRig {
    let button = Shared(true)
    let clock = Shared<TimeInterval>(100)
    let changes = Shared<[WindowDropClaims.Change]>([])
    let claims: WindowDropClaims

    static let claude: pid_t = 4242
    static let other: pid_t = 777

    init(observed: Bool = true) {
        let button = self.button
        let clock = self.clock
        claims = WindowDropClaims(isLeftButtonDown: { button.value }, now: { clock.value })
        claims.setClaimablePIDs([Self.claude])
        if observed {
            let changes = self.changes
            claims.onChange = { changes.value.append($0) }
        }
    }

    func advance(_ seconds: TimeInterval) { clock.value += seconds }

    /// The changes since the last call.
    func take() -> [WindowDropClaims.Change] {
        let seen = changes.value
        changes.value = []
        return seen
    }
}

@Suite("Window drop claims: the change hook")
struct WindowDropClaimsChangeTests {
    @Test func aNewClaimIsReportedOnceAndARefusedOneNever() {
        let rig = ChangeRig()
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 7))
        #expect(rig.take() == [.claimed(pid: ChangeRig.claude, windowNumber: 7)])
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 7), "a repeat during the same press")
        #expect(rig.take().isEmpty, "a repeat is not a new claim")
        #expect(!rig.claims.claim(pid: ChangeRig.other, windowNumber: 1))
        rig.button.value = false
        #expect(!rig.claims.claim(pid: ChangeRig.claude, windowNumber: 8))
        rig.button.value = true
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 8))
        #expect(!rig.claims.claim(pid: ChangeRig.claude, windowNumber: 9), "two at most")
        #expect(rig.take() == [.claimed(pid: ChangeRig.claude, windowNumber: 8)], "refusals report nothing")
        // Released and pressed again: a new claim, reported again.
        rig.claims.noteMouseUp()
        _ = rig.take()
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 7))
        #expect(rig.take() == [.claimed(pid: ChangeRig.claude, windowNumber: 7)])
    }

    @Test func aMouseUpIsReportedOnlyWhenItDatesAClaim() {
        let rig = ChangeRig()
        rig.claims.noteMouseUp()
        #expect(rig.take().isEmpty, "a click without claims")
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 1))
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 2))
        _ = rig.take()
        rig.claims.noteMouseUp()
        #expect(rig.take() == [.mouseUp], "one report for both claims")
        rig.claims.noteMouseUp()
        #expect(rig.take().isEmpty, "already dated")
    }

    @Test func theRegistrySeeingTheButtonUpReportsTheMouseUpToo() {
        let rig = ChangeRig()
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 5))
        _ = rig.take()
        #expect(rig.claims.holdRemaining(pid: ChangeRig.claude, windowNumber: 5) == 30, "the button is still down")
        #expect(rig.take().isEmpty)
        rig.button.value = false   // nobody calls noteMouseUp: the guard's look sees the button up
        #expect(rig.claims.holdRemaining(pid: ChangeRig.claude, windowNumber: 99) == nil)
        #expect(rig.take() == [.mouseUp], "dated while asked about another window")
        #expect(rig.claims.holdRemaining(pid: ChangeRig.claude, windowNumber: 5) == 3)
        #expect(rig.take().isEmpty)
    }

    @Test func aReleaseIsReportedOnlyWhenItEndsAClaimAfterTheGuardsCallback() {
        let rig = ChangeRig()
        let order = Shared<[String]>([])
        let changes = rig.changes
        rig.claims.onReleasedUnparked = { order.value.append("lookAgain") }
        rig.claims.onChange = { change in
            changes.value.append(change)
            order.value.append("change")
        }
        rig.claims.release(pid: ChangeRig.claude, windowNumber: 1, parked: true)
        #expect(rig.take().isEmpty, "no claim, nothing ended")
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 1))
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 2))
        _ = rig.take()
        order.value = []
        rig.claims.release(pid: ChangeRig.claude, windowNumber: 1, parked: true)
        rig.claims.release(pid: ChangeRig.claude, windowNumber: 2, parked: false)
        rig.claims.release(pid: ChangeRig.claude, windowNumber: 2, parked: false)
        #expect(rig.take() == [.released(pid: ChangeRig.claude, windowNumber: 1, parked: true),
                               .released(pid: ChangeRig.claude, windowNumber: 2, parked: false)])
        #expect(order.value == ["change", "lookAgain", "change"], "the guard's own callback keeps its place")
    }

    @Test func claimsOfAProcessNoLongerClaimableEndUnparked() {
        let rig = ChangeRig()
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 3))
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 1))
        _ = rig.take()
        rig.claims.setClaimablePIDs([ChangeRig.claude, ChangeRig.other])
        #expect(rig.take().isEmpty, "still claimable")
        rig.claims.setClaimablePIDs([ChangeRig.other])
        #expect(rig.take() == [.released(pid: ChangeRig.claude, windowNumber: 1, parked: false),
                               .released(pid: ChangeRig.claude, windowNumber: 3, parked: false)])
        rig.claims.setClaimablePIDs([])
        #expect(rig.take().isEmpty)
    }

    @Test func claimsThatRunOutAreNotReported() {
        let rig = ChangeRig()
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 1))
        rig.claims.noteMouseUp()
        _ = rig.take()
        rig.advance(3)
        #expect(rig.claims.holdRemaining(pid: ChangeRig.claude, windowNumber: 1) == nil)
        #expect(rig.claims.count == 0)
        rig.claims.release(pid: ChangeRig.claude, windowNumber: 1, parked: true)
        #expect(rig.take().isEmpty, "the host's registry applies the same bounds itself")
    }

    /// The hook only observes: the same calls give the same answers with and without it, and calling back into the
    /// registry from the hook does not deadlock (it runs outside the lock).
    @Test func theRegistryBehavesTheSameWithAnObserver() {
        func script(_ rig: ChangeRig) -> [String] {
            var answers: [String] = []
            let c = rig.claims
            answers.append("\(c.claim(pid: ChangeRig.claude, windowNumber: 1))")
            answers.append("\(c.claim(pid: ChangeRig.claude, windowNumber: 2))")
            answers.append("\(c.claim(pid: ChangeRig.claude, windowNumber: 3))")
            rig.advance(5)
            c.noteMouseUp()
            rig.button.value = false
            answers.append("\(String(describing: c.holdRemaining(pid: ChangeRig.claude, windowNumber: 1)))")
            rig.advance(1)
            c.release(pid: ChangeRig.claude, windowNumber: 2, parked: false)
            answers.append("\(c.count)")
            rig.button.value = true
            answers.append("\(c.claim(pid: ChangeRig.claude, windowNumber: 2))")
            c.setClaimablePIDs([])
            answers.append("\(c.count)")
            answers.append("\(String(describing: c.holdRemaining(pid: ChangeRig.claude, windowNumber: 1)))")
            return answers
        }
        let plain = ChangeRig(observed: false)
        let observed = ChangeRig()
        let claims = observed.claims
        let seenCounts = Shared<[Int]>([])
        let changes = observed.changes
        claims.onChange = { change in
            changes.value.append(change)
            seenCounts.value.append(claims.count)   // re-enters the registry: the lock is not held here
        }
        #expect(script(plain) == script(observed))
        #expect(observed.take() == [.claimed(pid: ChangeRig.claude, windowNumber: 1),
                                    .claimed(pid: ChangeRig.claude, windowNumber: 2),
                                    .mouseUp,
                                    .released(pid: ChangeRig.claude, windowNumber: 2, parked: false),
                                    .claimed(pid: ChangeRig.claude, windowNumber: 2),
                                    .released(pid: ChangeRig.claude, windowNumber: 1, parked: false),
                                    .released(pid: ChangeRig.claude, windowNumber: 2, parked: false)])
        #expect(seenCounts.value == [1, 2, 2, 1, 2, 0, 0])
        #expect(plain.take().isEmpty)
    }

    @Test func theHookCanBeRemoved() {
        let rig = ChangeRig()
        rig.claims.onChange = nil
        #expect(rig.claims.onChange == nil)
        #expect(rig.claims.claim(pid: ChangeRig.claude, windowNumber: 1))
        rig.claims.noteMouseUp()
        rig.claims.release(pid: ChangeRig.claude, windowNumber: 1, parked: true)
        #expect(rig.take().isEmpty)
    }
}
