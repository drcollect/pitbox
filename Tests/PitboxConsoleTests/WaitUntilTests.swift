import Foundation
import Testing
@testable import PitboxConsole

/// A flag set through the main queue from another thread, the way `PTYProcess` delivers output and exits.
final class MainQueueFlag: @unchecked Sendable { var value = false }

/// `waitUntil` must see an event whose delivery sits in the main queue behind a late check. About 200 main-actor tests
/// share that queue with the pty's output delivery; on a loaded Mac it falls seconds behind.
@MainActor
struct WaitUntilStarvationTests {
    @Test(.timeLimit(.minutes(1))) func aDeliveryQueuedBehindALateCheckIsStillSeen() async {
        let flag = MainQueueFlag()
        // Another test's long synchronous body occupies the main queue past the budget (it starts after the first check).
        DispatchQueue.main.async { let start = Date(); while Date().timeIntervalSince(start) < 1.2 {} }
        // The awaited event arrives meanwhile; its delivery is queued behind the next poll, like the pty's output.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { DispatchQueue.main.async { flag.value = true } }
        #expect(await waitUntil(1) { flag.value }, "the event arrived after 0.2 s; only the busy main queue delayed its delivery")
    }

    @Test(.timeLimit(.minutes(1))) func aConditionThatNeverHoldsStillGivesUpAfterItsBudget() async {
        let start = Date()
        #expect(await waitUntil(0.2) { false } == false)
        #expect(Date().timeIntervalSince(start) >= 0.2, "at least the budget's worth of polls, 10 ms apart")
    }
}
