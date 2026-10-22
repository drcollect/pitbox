import Foundation

/// A dedicated thread with its own run loop. Every Accessibility call, AXObserver callback and guard timer runs here,
/// so a slow app never blocks the main thread and the guard state needs no locks.
final class GuardThread: Thread {
    private let ready = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop?

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInitiated
    }

    /// Starts the thread and returns its run loop once it is running.
    func startAndWait() -> CFRunLoop {
        start()
        ready.wait()
        return loop ?? CFRunLoopGetMain()
    }

    override func main() {
        let runLoop = CFRunLoopGetCurrent()
        loop = runLoop
        // A timer in the far future keeps the run loop alive while nothing else is scheduled.
        let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e9, 1e9,
                                                        0, 0) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
        ready.signal()
        while !isCancelled {
            _ = CFRunLoopRunInMode(.defaultMode, 1e9, false)
        }
        CFRunLoopTimerInvalidate(keepAlive)
    }

    /// Runs `block` on this thread, in order with other blocks and callbacks.
    func perform(_ block: @escaping () -> Void) {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    /// Ends the thread after the blocks already queued.
    func finish() {
        perform { [self] in
            cancel()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}

/// A re-armable one-shot timer on a run loop.
final class GuardTimer {
    private let timer: CFRunLoopTimer

    init(runLoop: CFRunLoop, handler: @escaping () -> Void) {
        // A huge interval makes the timer effectively one-shot while keeping it valid for re-arming.
        timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in
            handler()
        }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    /// Fires once, `delay` seconds from now; `leeway` lets the system coalesce wakeups.
    func arm(after delay: TimeInterval, leeway: TimeInterval) {
        CFRunLoopTimerSetTolerance(timer, max(0, leeway))
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + max(0, delay))
    }

    func disarm() {
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + 1e9)
    }

    func invalidate() {
        CFRunLoopTimerInvalidate(timer)
    }
}
