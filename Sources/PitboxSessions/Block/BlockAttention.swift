import Foundation
import PitboxKit

/// The counts behind the fold rail's coloured dots (docs/DOCK_PROTOCOL.md `attention`): sessions that need you (Needs
/// you or Problem), finished work not looked at yet (open Finished items), and running sessions. Counts only, no text.
public struct CodeAttentionCounts: Equatable, Sendable {
    /// Monitors under the current focus that need you (Needs you or Problem).
    public var needsYou: Int
    /// Open Finished items (the summary line's "just finished") under the current focus.
    public var finished: Int
    /// Followed sessions under the current focus that are working (the summary line's "running").
    public var running: Int

    public init(needsYou: Int = 0, finished: Int = 0, running: Int = 0) {
        self.needsYou = needsYou; self.finished = finished; self.running = running
    }

    /// The tuple the block's `onAttentionChanged` hands out.
    public var tuple: (needsYou: Int, finished: Int, running: Int) { (needsYou, finished, running) }
}

/// Hands changed counts on at most once per `interval` (1 s): the first change goes out at once, later ones within the
/// interval are coalesced into one call at its end with the newest counts. Main thread; the clock and the timer are
/// injectable for tests.
@MainActor
final class CodeAttentionThrottle {
    let interval: TimeInterval
    private let clock: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let deliver: (CodeAttentionCounts) -> Void
    private var lastSent: CodeAttentionCounts?
    private var lastSentAt = -TimeInterval.infinity
    private var pending: CodeAttentionCounts?
    private var scheduled = false

    init(interval: TimeInterval = 1, clock: @escaping () -> TimeInterval = { MonotonicClock.now() },
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = CodeAttentionThrottle.mainQueue,
         deliver: @escaping (CodeAttentionCounts) -> Void) {
        self.interval = interval
        self.clock = clock
        self.schedule = schedule
        self.deliver = deliver
    }

    /// The counts now (every rebuild): nothing happens when they equal what was sent last.
    func note(_ counts: CodeAttentionCounts) {
        guard counts != lastSent else {
            pending = nil   // back to what the receiver has: a scheduled call has nothing to send
            return
        }
        pending = counts
        guard !scheduled else { return }
        let wait = lastSentAt + interval - clock()
        if wait <= 0 {
            flush()
        } else {
            scheduled = true
            schedule(wait) { [weak self] in
                self?.scheduled = false
                self?.flush()
            }
        }
    }

    /// Forgets what was sent, so the next counts go out even when unchanged (a new receiver).
    func reset() {
        lastSent = nil
    }

    private func flush() {
        guard let counts = pending else { return }
        pending = nil
        lastSent = counts
        lastSentAt = clock()
        deliver(counts)
    }

    nonisolated static func mainQueue(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }
}
