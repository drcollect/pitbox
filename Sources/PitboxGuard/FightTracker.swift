import Foundation

/// Anti-fight bookkeeping. When an app keeps putting a window back over the strip (`threshold` corrections within
/// `window` seconds that the user did not cause), the guard stops correcting that window for a cooldown that doubles
/// on every repeat (up to `maxCooldown`) and is forgotten after a long quiet period.
///
/// `hardLimit` corrections within `window` seconds start a cooldown whatever caused them: "caused by the user" only
/// means "soon after a click anywhere", so without it an app that reverts its window while the user keeps clicking
/// in other apps would be corrected forever.
struct FightTracker<Key: Hashable> {
    struct Entry {
        var hits: [TimeInterval] = []
        /// Every correction, user-caused or not.
        var all: [TimeInterval] = []
        var cooldownUntil: TimeInterval = -.infinity
        var level = 0
        var lastEvent: TimeInterval = -.infinity
    }

    var threshold: Int
    var window: TimeInterval
    var cooldown: TimeInterval
    var maxCooldown: TimeInterval
    private(set) var entries: [Key: Entry] = [:]

    /// Corrections of one window within `window` seconds, for any reason, that start a cooldown.
    var hardLimit: Int { threshold * 2 }

    init(threshold: Int, window: TimeInterval, cooldown: TimeInterval, maxCooldown: TimeInterval) {
        self.threshold = max(1, threshold); self.window = window
        self.cooldown = cooldown; self.maxCooldown = max(cooldown, maxCooldown)
    }

    init(options: GuardOptions) {
        self.init(threshold: options.fightThreshold, window: options.fightWindow, cooldown: options.fightCooldown,
                  maxCooldown: options.maxFightCooldown)
    }

    /// Records one correction. Returns the end of the cooldown this correction started, if any.
    mutating func record(_ key: Key, now: TimeInterval, countsAsFight: Bool) -> TimeInterval? {
        var entry = entries[key] ?? Entry()
        if now - entry.lastEvent > maxCooldown * 2 { entry.level = 0 }
        entry.lastEvent = now
        entry.hits.removeAll { now - $0 > window }
        entry.all.removeAll { now - $0 > window }
        entry.all.append(now)
        if countsAsFight { entry.hits.append(now) }
        var started: TimeInterval?
        if entry.hits.count >= threshold || entry.all.count >= hardLimit {
            let length = min(cooldown * pow(2, Double(min(entry.level, 20))), maxCooldown)
            entry.cooldownUntil = now + length
            entry.level += 1
            entry.hits.removeAll()
            entry.all.removeAll()
            started = entry.cooldownUntil
        }
        entries[key] = entry
        return started
    }

    /// When the window's cooldown ends, if it is cooling down.
    func cooldownEnd(_ key: Key, now: TimeInterval) -> TimeInterval? {
        guard let until = entries[key]?.cooldownUntil, until > now else { return nil }
        return until
    }

    func coolingDownCount(now: TimeInterval) -> Int {
        entries.values.reduce(0) { $0 + ($1.cooldownUntil > now ? 1 : 0) }
    }

    func nextCooldownEnd(after now: TimeInterval) -> TimeInterval? {
        entries.values.lazy.map(\.cooldownUntil).filter { $0 > now }.min()
    }

    mutating func forget(_ key: Key) { entries[key] = nil }

    mutating func forget(where shouldForget: (Key) -> Bool) {
        entries = entries.filter { !shouldForget($0.key) }
    }

    /// Drops windows that have been quiet for long enough that their history no longer matters.
    mutating func prune(now: TimeInterval) {
        entries = entries.filter { $0.value.cooldownUntil > now || now - $0.value.lastEvent < maxCooldown * 2 }
    }
}
