import Foundation

/// The one elapsed timeline shared by every part of the app that measures time spans. It keeps counting while the Mac
/// sleeps (unlike `ProcessInfo.systemUptime`, which stops), never goes backwards, and is meaningless as a wall-clock
/// date. Every party that compares these times must use this clock.
public enum MonotonicClock {
    private static let origin = ContinuousClock.now

    /// `ContinuousClock` seconds since this process first read the clock: finite, nonnegative, nondecreasing.
    public static func now() -> TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
}
