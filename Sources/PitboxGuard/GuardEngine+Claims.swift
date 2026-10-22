import CoreGraphics
import Foundation
import PitboxKit

/// A window the guard leaves alone for the block's drop, waiting for the claim's end. One entry per window whose latest
/// look found it claimed; every other look of that window removes it.
struct ClaimWait: Equatable {
    /// The first claimed look of this claim, kept for every re-pend (as a drag's own wait keeps its `since`).
    var since: TimeInterval
    /// When the claim ends, on the guard's clock, as last read: the window's next look is due then.
    var until: TimeInterval

    /// A claimed look more than this after the previous one's `until` belongs to a new claim. A look comes at `until`
    /// or before it (a notification), late only by the guard thread's own work, never by this much.
    static let lateness: TimeInterval = 1

    /// A claim with less than this left counts as ended: the look happens now instead of a few microseconds later, so
    /// the guard never re-pends for an instant that rounding makes equal to now (it would spin on the same moment).
    static let minimumLeft: TimeInterval = 0.005

    /// Whether this wait can still be the one a look at `now` continues.
    func isLive(at now: TimeInterval) -> Bool { now <= until + Self.lateness }
}

/// Drag-to-park in the window guard. The block claims a Claude pop-out in `WindowDropClaims` while the user drags it
/// into the strip with the button down. A window whose number holds a claim is left alone (no write, no fight record,
/// no "cannot fit" mark, no dry-run line) and looked at again when the claim ends, as caused by the user, so a
/// slide-back after a failed park is never a fight.
///
/// Where the check sits in `evaluate`: after eligibility, overlap, cooldown and the button-down deferral (a claimed
/// window under a held button still defers, as every window does), before the window-server state and the
/// capabilities round trip, so it costs no Accessibility call of its own. It holds on every path that
/// evaluates (the release, a notification, the 1 Hz pass). The registry keeps its own clock and answers in seconds left,
/// so no two clocks are ever compared; its lock is held for microseconds and nothing here waits on another thread.
extension GuardEngine {
    /// When the claim on `window` ends, on the guard's clock; nil when it is not claimed (or has less than
    /// `ClaimWait.minimumLeft` left). Matched by window number only: a window without one never matches a claim
    /// (failing toward today's correction). Asking also lets the registry see the button up, which dates a release
    /// nobody reported.
    func claimEnd(of window: Window, pid: pid_t, now: TimeInterval) -> TimeInterval? {
        guard let claims = dropClaims, let number = provider.windowID(of: window),
              let left = claims.holdRemaining(pid: pid, windowNumber: number), left >= ClaimWait.minimumLeft else {
            return nil
        }
        return now + left
    }

    /// Leaves a claimed window alone and re-pends it for the claim's end with `fromDrag` set, so that look counts as
    /// caused by the user. Logs one line per claim, with the app's name and no title.
    func holdForClaim(_ window: Window, pid: pid_t, until: TimeInterval, previous: ClaimWait?,
                      now: TimeInterval) -> EvalOutcome {
        let continuing = previous.flatMap { $0.isLive(at: now) ? $0 : nil }
        let since = continuing?.since ?? now
        // Entries of windows that went away mid-claim (minimized, closed: never looked at again) end here.
        claimWaits = claimWaits.filter { $0.value.isLive(at: now) }
        claimWaits[window] = ClaimWait(since: since, until: until)
        pending[window] = Pending(due: until, fromDrag: true, since: since)
        if continuing == nil { log(.info, "left a window for the strip's drop app=\(appName(pid))") }
        return .claimed(until: until)
    }

    /// A claim ended without a park (`WindowDropClaims.onReleasedUnparked`, through `WindowGuard.lookAgain()`): every
    /// window still waiting on a claim is due at once (its wait keeps `fromDrag`), and a pass runs.
    /// A window the claim's end no longer concerns (minimized, re-pended by something else) is left as it is.
    func lookAgain(now: TimeInterval) {
        guard isActive else { return }
        for (window, wait) in claimWaits where wait.isLive(at: now) {
            guard let item = pending[window], item.fromDrag else { continue }
            pending[window]?.due = min(item.due, now)
        }
        requestReconcile(at: now)
    }
}
