import PitboxKit

/// What `WindowGuard` is doing right now (for the menu's guard line and the log).
public struct GuardStatus: Equatable, Sendable {
    /// Pitbox holds the Accessibility permission.
    public var trusted: Bool
    /// Started, trusted and watching windows (true even while the strip is hidden and there is nothing to do).
    public var running: Bool
    /// Corrections suspended by `setPaused(true)`.
    public var paused: Bool
    /// Corrections are only logged.
    public var dryRun: Bool
    /// Strips currently reserved.
    public var regionCount: Int
    /// Corrections applied since launch (in dry-run mode: corrections that would have been applied).
    public var correctedCount: Int
    /// Windows the guard stopped correcting for a while because their app kept putting them back.
    public var fightingWindows: Int
    /// Windows that still overlap a strip because they cannot get small enough or cannot move far enough.
    public var cannotFitWindows: Int
    /// Apps with a live Accessibility observer.
    public var observedApps: Int
    /// The most recent problem, in plain words.
    public var lastError: String?

    public init(trusted: Bool = false, running: Bool = false, paused: Bool = false, dryRun: Bool = false,
                regionCount: Int = 0, correctedCount: Int = 0, fightingWindows: Int = 0, cannotFitWindows: Int = 0,
                observedApps: Int = 0, lastError: String? = nil) {
        self.trusted = trusted; self.running = running; self.paused = paused; self.dryRun = dryRun
        self.regionCount = regionCount; self.correctedCount = correctedCount; self.fightingWindows = fightingWindows
        self.cannotFitWindows = cannotFitWindows; self.observedApps = observedApps; self.lastError = lastError
    }

    /// The status as JSON: `{trusted, running, paused, regions, corrected, fighting, dryRun, cannotFit, observedApps,
    /// lastError}` (labels and numbers only, never a window title).
    public var json: JSONValue {
        [
            "trusted": .bool(trusted), "running": .bool(running), "paused": .bool(paused),
            "regions": .number(Double(regionCount)), "corrected": .number(Double(correctedCount)),
            "fighting": .number(Double(fightingWindows)), "dryRun": .bool(dryRun),
            "cannotFit": .number(Double(cannotFitWindows)), "observedApps": .number(Double(observedApps)),
            "lastError": lastError.map { .string($0) } ?? .null,
        ]
    }
}
