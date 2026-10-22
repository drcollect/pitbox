import Foundation

/// Cancels a scheduled block.
final class ClockToken {
    private var action: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { action = cancel }
    func cancel() { action?(); action = nil }
    deinit { action?() }
}

/// Time for the session logic (auto-rotation, close confirmation, debounced saves, polling). Injected so tests drive
/// time by hand.
protocol TerminalClock: AnyObject {
    var now: Date { get }
    /// Runs `block` once on the main thread after `delay` seconds.
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> ClockToken
}

/// The real clock: main-thread timers with generous tolerance, so an idle terminal costs almost nothing.
final class SystemClock: TerminalClock {
    var now: Date { Date() }

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> ClockToken {
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in block() }
        timer.tolerance = min(max(delay * 0.1, 0.05), 1.0)
        RunLoop.main.add(timer, forMode: .common)
        return ClockToken { timer.invalidate() }
    }
}
