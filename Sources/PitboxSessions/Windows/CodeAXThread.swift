import Foundation

/// The parker's one serial queue: a dedicated thread with its own run loop, like the window
/// guard's. Every Accessibility call of the join and the parker runs here, so a slow Claude never blocks the main thread
/// and never holds a GCD pool thread; waits (the 1.5 s confirmations) are run-loop timers, not sleeps.
final class CodeAXThread: Thread, CodeWorkQueue, @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var started = false

    init(name: String = "pitbox.code-monitors.ax") {
        super.init()
        self.name = name
        qualityOfService = .userInitiated
    }

    /// Starts the thread on first use and returns its run loop.
    private func runLoop() -> CFRunLoop? {
        lock.lock()
        if !started {
            started = true
            lock.unlock()
            start()
            ready.wait()
            lock.lock()
        }
        let value = loop
        lock.unlock()
        return value
    }

    override func main() {
        let runLoop = CFRunLoopGetCurrent()
        lock.lock()
        loop = runLoop
        lock.unlock()
        // A timer in the far future keeps the run loop alive while nothing else is scheduled.
        let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
        ready.signal()
        while !isCancelled {
            _ = CFRunLoopRunInMode(.defaultMode, 1e9, false)
        }
        CFRunLoopTimerInvalidate(keepAlive)
    }

    func async(_ work: @escaping () -> Void) {
        guard let loop = runLoop() else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(loop)
    }

    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        guard let loop = runLoop() else { return }
        // A one-shot timer (interval 0): CF invalidates it after it fired once.
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + max(0, seconds), 0, 0, 0) { _ in
            work()
        }
        CFRunLoopTimerSetTolerance(timer, min(0.05, max(0, seconds) * 0.1))
        CFRunLoopAddTimer(loop, timer, .defaultMode)
        CFRunLoopWakeUp(loop)
    }

    /// Ends the thread after the work already queued.
    func finish() {
        async { [self] in
            cancel()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}
