import Foundation
import Testing
@testable import PitboxGuard

/// Values written on the guard thread and read by the test after a semaphore.
private final class Observed: @unchecked Sendable {
    var onGuardThread = false
    var timer: GuardTimer?
}

@Suite("Guard thread and timers (no Accessibility involved)")
struct GuardThreadTests {
    @Test func blocksAndTimersRunOnTheGuardThread() {
        let thread = GuardThread(name: "test.pitbox.guard")
        let loop = thread.startAndWait()
        let observed = Observed()
        let ran = DispatchSemaphore(value: 0)
        thread.perform {
            observed.onGuardThread = !Thread.isMainThread && Thread.current.name == "test.pitbox.guard"
            ran.signal()
        }
        #expect(ran.wait(timeout: .now() + 2) == .success)
        #expect(observed.onGuardThread)

        let fired = DispatchSemaphore(value: 0)
        thread.perform {
            observed.timer = GuardTimer(runLoop: loop) { fired.signal() }
            observed.timer?.arm(after: 0.05, leeway: 0)
        }
        #expect(fired.wait(timeout: .now() + 2) == .success, "an armed timer fires")
        #expect(fired.wait(timeout: .now() + 0.2) == .timedOut, "and only once")

        thread.perform {
            observed.timer?.arm(after: 0.05, leeway: 0)
            observed.timer?.disarm()
        }
        #expect(fired.wait(timeout: .now() + 0.3) == .timedOut, "a disarmed timer stays quiet")

        thread.perform { observed.timer?.invalidate() }
        thread.finish()
        let deadline = Date().addingTimeInterval(2)
        while !thread.isFinished && Date() < deadline { usleep(10_000) }
        #expect(thread.isFinished)
    }

    @Test func coreStartsAndShutsDownWithoutStartingTheGuard() {
        // Never call `start()` here: it would create the real Accessibility provider.
        let core = GuardCore(options: GuardOptions(), statusSink: { _ in }, permissionLost: {})
        core.update(regions: [Fixture.rightStrip])
        core.setPaused(true)
        core.stop()
        core.shutdown()
    }
}
