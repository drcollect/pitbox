import Foundation

/// A delayed call that can be cancelled before it runs.
@MainActor
protocol ScheduledCall: AnyObject {
    func cancel()
}

/// Delayed main-thread calls (the live-drag settle, the spring-loaded unfold). Production uses the main queue; tests pass
/// a manual scheduler and advance its clock, so no test depends on how busy the machine is.
@MainActor
protocol ShellScheduler: AnyObject {
    /// Runs `body` on the main thread after `delay` seconds unless the returned call is cancelled first.
    func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> ScheduledCall
}

/// `DispatchQueue.main.asyncAfter` with a cancellable work item.
@MainActor
final class MainQueueScheduler: ShellScheduler {
    static let shared = MainQueueScheduler()

    func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> ScheduledCall {
        let call = WorkItemCall()
        // The item holds the call until it runs or is cancelled (both clear `call.item`, ending the cycle), so a
        // caller that keeps no reference still gets its call.
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard !call.isCancelled else { return }
                call.isCancelled = true
                call.item = nil
                body()
            }
        }
        call.item = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay.isFinite ? delay : 0), execute: item)
        return call
    }
}

/// A main-queue call; cancelling it also cancels the work item.
@MainActor
final class WorkItemCall: ScheduledCall {
    var item: DispatchWorkItem?
    var isCancelled = false

    func cancel() {
        isCancelled = true
        item?.cancel()
        item = nil
    }
}
