import Foundation

/// The window observer's own thread with a run loop: its AXObserver sources,
/// timers and window-server reads run here, never on the main thread and never on the window guard's or the parker's
/// thread, so a slow Claude never stalls the app or the guard. The pattern of the guard's `GuardThread`, copied.
final class DeskTagObserverThread: Thread, DeskTagQueue, @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var started = false

    init(name: String = "pitbox.code-monitors.window-observer") {
        super.init()
        self.name = name
        qualityOfService = .userInitiated
    }

    /// The thread's run loop, starting the thread on first use.
    var runLoop: CFRunLoop? {
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
        let current = CFRunLoopGetCurrent()
        lock.lock()
        loop = current
        lock.unlock()
        // A timer in the far future keeps the run loop alive while nothing else is scheduled.
        let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in }
        CFRunLoopAddTimer(current, keepAlive, .defaultMode)
        ready.signal()
        while !isCancelled {
            _ = CFRunLoopRunInMode(.defaultMode, 1e9, false)
        }
        CFRunLoopTimerInvalidate(keepAlive)
    }

    func async(_ work: @escaping () -> Void) {
        guard let loop = runLoop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(loop)
    }

    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        guard let loop = runLoop else { return }
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
