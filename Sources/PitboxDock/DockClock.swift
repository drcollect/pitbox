import Foundation
import PitboxKit

/// A pending timer; `cancel()` makes sure it never runs.
protocol DockTimer: AnyObject, Sendable {
    func cancel()
}

/// Time for the dock link: the elapsed clock and one-shot timers on a given queue. Production uses `SystemDockClock`;
/// the tests drive a manual clock so the 1 s, 2 s, 5 s and 15 s rules are checked without waiting for them.
protocol DockClock: AnyObject, Sendable {
    /// Seconds on one elapsed timeline (never backwards).
    func now() -> TimeInterval
    /// Runs `work` on `queue` after `delay` seconds, unless cancelled first.
    func after(_ delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> DockTimer
}

/// `MonotonicClock` and `DispatchQueue.asyncAfter`.
final class SystemDockClock: DockClock {
    static let shared = SystemDockClock()

    func now() -> TimeInterval { MonotonicClock.now() }

    func after(_ delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> DockTimer {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + POSIX.clamp(delay), execute: item)
        return WorkItemTimer(item: item)
    }

    private final class WorkItemTimer: DockTimer, @unchecked Sendable {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}
