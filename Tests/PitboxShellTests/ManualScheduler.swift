import Foundation
@testable import PitboxShell

/// A scheduler driven by the test: nothing runs until `advance(by:)` moves its clock past a call's time.
@MainActor
final class ManualScheduler: ShellScheduler {
    @MainActor
    final class Call: ScheduledCall {
        let at: TimeInterval
        var body: (@MainActor () -> Void)?
        private(set) var isCancelled = false

        init(at: TimeInterval, body: @escaping @MainActor () -> Void) {
            self.at = at
            self.body = body
        }

        func cancel() {
            isCancelled = true
            body = nil
        }
    }

    private(set) var now: TimeInterval = 0
    private(set) var calls: [Call] = []

    /// Calls that will still run.
    var pendingCount: Int { calls.filter { $0.body != nil }.count }

    func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> ScheduledCall {
        let call = Call(at: now + max(0, delay), body: body)
        calls.append(call)
        return call
    }

    /// Moves the clock forward, running every due call in time order (calls scheduled meanwhile included).
    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = calls.filter({ $0.body != nil && $0.at <= end }).min(by: { $0.at < $1.at }) {
            now = next.at
            let body = next.body
            next.body = nil
            body?()
        }
        now = end
        calls.removeAll { $0.body == nil }
    }
}
