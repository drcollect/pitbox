import CoreGraphics
import Foundation

/// Claude pop-outs the Code monitors block is parking by drag-to-park: a small thread-safe registry the block writes
/// and the window guard reads, so the guard leaves a pop-out dropped into the block's reserved region alone while the
/// block minimizes it, instead of sliding it back.
///
/// - A claim exists only for a window of a claimable process (the running readable Claude copies, set by the block), by
///   window number, made while the left button is down; at most `maxClaims` at once.
/// - It holds while `now < min(claimedAt + maxAge, mouseUpAt + maxHoldAfterMouseUp)`. The registry watches the button
///   itself: every `holdRemaining` reads it, and the first time it sees the button up for claims without a mouse-up
///   time, it sets that time to now. A lost mouse-up (a hung block, a missed event) so ends a hold at most about 1 s
///   (the guard's pass) + 3 s after the release, with no call from the block. `maxAge` is the last
///   backstop, for a button that reads as held.
/// - Times come from its own clock (`MonotonicClock` by default) and are answered as seconds left, so no caller ever
///   compares two clocks.
/// - One lock, held for microseconds; the button is read before it is taken; nothing in it waits on another thread.
///   `onReleasedUnparked` and `onChange` are called after the lock is released, on the caller's thread.
/// - `onChange` reports each claim made, each mouse-up that dated a claim and each claim ended by a call (`release`, or
///   its process no longer claimable), so the app can mirror them to a dock host's guard (docs/DOCK_PROTOCOL.md §5.10).
///   It observes only: the registry behaves the same with or without it. Claims that run out (`maxAge`, 3 s after the
///   mouse-up) are not reported; a host's own registry applies the same bounds.
///
/// Only the drag-to-park controller writes claims and only the window guard reads them; `count` is for the guard's status.
public final class WindowDropClaims: @unchecked Sendable {
    /// What changed in the registry (`onChange`).
    public enum Change: Equatable, Sendable {
        /// A new claim: "leave this window alone for a moment" (a repeat during the same press is not reported again).
        case claimed(pid: pid_t, windowNumber: UInt32)
        /// The left button went up and dated at least one claim's mouse-up (once per claim).
        case mouseUp
        /// A claim ended by a call: parked (minimized), or not (look at the window again). A claim dropped because its
        /// process is no longer claimable ends unparked.
        case released(pid: pid_t, windowNumber: UInt32, parked: Bool)
    }

    /// A claim holds at most this long after the mouse-up.
    public static let maxHoldAfterMouseUp: TimeInterval = 3
    /// …and at most this long at all.
    public static let maxAge: TimeInterval = 30
    /// Claims held at once at most.
    public static let maxClaims = 2

    private struct Key: Hashable {
        let pid: pid_t
        let windowNumber: UInt32
    }

    private struct Claim {
        var claimedAt: TimeInterval
        var mouseUpAt: TimeInterval?

        var end: TimeInterval {
            min(claimedAt + WindowDropClaims.maxAge, mouseUpAt.map { $0 + WindowDropClaims.maxHoldAfterMouseUp } ?? .infinity)
        }
    }

    private let isLeftButtonDown: @Sendable () -> Bool
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    // Under `lock`.
    private var claimable: Set<pid_t> = []
    private var claims: [Key: Claim] = [:]
    private var releasedUnparked: Callback?
    private var changed: Observer?

    private typealias Callback = @Sendable () -> Void
    private typealias Observer = @Sendable (Change) -> Void

    /// A registry reading the left button with `isLeftButtonDown` (permission-free, `CGEventSource.buttonState`) and
    /// keeping its times on `now` (`MonotonicClock`); both are injectable for tests.
    public init(isLeftButtonDown: @escaping @Sendable () -> Bool = { CGEventSource.buttonState(.combinedSessionState, button: .left) },
                now: @escaping @Sendable () -> TimeInterval = { MonotonicClock.now() }) {
        self.isLeftButtonDown = isLeftButtonDown
        self.now = now
    }

    /// Called once per claim that ends without a park (released with `parked: false`, or its process no longer
    /// claimable): the guard looks at the window again at once. Called on the releasing caller's thread, outside the
    /// registry's lock.
    public var onReleasedUnparked: (@Sendable () -> Void)? {
        get { lock.withLock { releasedUnparked } }
        set { lock.withLock { releasedUnparked = newValue } }
    }

    /// Called after every change worth mirroring (`Change`), on the caller's thread, outside the registry's lock, in
    /// the order the changes happened on that thread. The app hops to its main thread before it uses one.
    public var onChange: (@Sendable (Change) -> Void)? {
        get { lock.withLock { changed } }
        set { lock.withLock { changed = newValue } }
    }

    /// The processes whose windows may be claimed: the running Claude copies the block may read. Claims of any other
    /// process end now (and the guard is told to look again).
    public func setClaimablePIDs(_ pids: Set<pid_t>) {
        let (dropped, callback, observer) = lock.withLock { () -> ([Key], Callback?, Observer?) in
            claimable = pids
            let gone = claims.keys.filter { !pids.contains($0.pid) }
            for key in gone { claims[key] = nil }
            return (gone, releasedUnparked, changed)
        }
        guard !dropped.isEmpty else { return }
        callback?()
        if let observer {
            for key in dropped.sorted(by: { ($0.pid, $0.windowNumber) < ($1.pid, $1.windowNumber) }) {
                observer(.released(pid: key.pid, windowNumber: key.windowNumber, parked: false))
            }
        }
    }

    /// Claims a window for a drop. False unless its process is claimable and the left button is down now, or when
    /// `maxClaims` other windows are claimed. A window claimed again during the same press keeps its claim as it was
    /// (the press does not extend `maxAge`); claimed again after a release, it starts a new claim.
    public func claim(pid: pid_t, windowNumber: UInt32) -> Bool {
        guard isLeftButtonDown() else { return false }
        let at = now()
        let (granted, observer) = lock.withLock { () -> (Bool, Observer?) in
            guard claimable.contains(pid) else { return (false, nil) }
            expire(at: at)
            let key = Key(pid: pid, windowNumber: windowNumber)
            if let existing = claims[key], existing.mouseUpAt == nil { return (true, nil) }
            guard claims[key] != nil || claims.count < Self.maxClaims else { return (false, nil) }
            claims[key] = Claim(claimedAt: at, mouseUpAt: nil)
            return (true, changed)
        }
        observer?(.claimed(pid: pid, windowNumber: windowNumber))
        return granted
    }

    /// The left button went up (the block's and the guard's mouse-up monitors): every claim without a mouse-up time
    /// gets one now.
    public func noteMouseUp() {
        let at = now()
        let observer = lock.withLock { markMouseUp(at: at) ? changed : nil }
        observer?(.mouseUp)
    }

    /// Ends a window's claim: parked (the block minimized it) or not (it failed; the guard should correct it at once).
    public func release(pid: pid_t, windowNumber: UInt32, parked: Bool) {
        let (removed, callback, observer) = lock.withLock { () -> (Bool, Callback?, Observer?) in
            (claims.removeValue(forKey: Key(pid: pid, windowNumber: windowNumber)) != nil, releasedUnparked, changed)
        }
        guard removed else { return }
        if !parked { callback?() }
        observer?(.released(pid: pid, windowNumber: windowNumber, parked: parked))
    }

    /// How long the window's claim still holds, in seconds; nil when it is not claimed (or the claim has ended). Reads
    /// the left button first: seen up, it dates the mouse-up of every claim that has none.
    public func holdRemaining(pid: pid_t, windowNumber: UInt32) -> TimeInterval? {
        let down = isLeftButtonDown()
        let at = now()
        let (remaining, observer) = lock.withLock { () -> (TimeInterval?, Observer?) in
            let dated = !down && markMouseUp(at: at)
            let observer = dated ? changed : nil
            let key = Key(pid: pid, windowNumber: windowNumber)
            guard let claim = claims[key] else { return (nil, observer) }
            let end = claim.end
            guard at < end else {
                claims[key] = nil
                return (nil, observer)
            }
            return (end - at, observer)
        }
        observer?(.mouseUp)
        return remaining
    }

    /// Claims holding now (for the guard's status).
    public var count: Int {
        let at = now()
        return lock.withLock {
            expire(at: at)
            return claims.count
        }
    }

    /// Under `lock`. True when it dated at least one claim.
    @discardableResult
    private func markMouseUp(at time: TimeInterval) -> Bool {
        var dated = false
        for (key, claim) in claims where claim.mouseUpAt == nil {
            claims[key]?.mouseUpAt = time
            dated = true
        }
        return dated
    }

    /// Under `lock`: drops the claims that have ended.
    private func expire(at time: TimeInterval) {
        claims = claims.filter { time < $0.value.end }
    }
}
