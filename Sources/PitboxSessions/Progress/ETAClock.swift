import Foundation
import PitboxKit

/// Places a stated clock time on the timeline: in its zone, at the first moment
/// with that clock time at or after the statement time minus `CodeTuning.etaBeforeStatement` (30 min). Stated at 23:50,
/// "ETA: 00:20" is 00:20 the next day; stated at 14:00, "ETA: 13:50" is today and already passed. An ETA more than
/// `CodeTuning.etaMaxAhead` (12 h) after its statement is ignored. Daylight-saving changes are exact: a clock time that
/// occurs twice (the hour after the clocks go back) is placed at its first occurrence not before that bound, and a
/// clock time that does not occur that day (the hour the clocks skip) falls to the next day, which is then over 12 h
/// away and so ignored. Pure.
enum ETAClock {
    /// The moment, or nil when it lies more than 12 hours after `statedAt`.
    static func place(hour: Int, minute: Int, in zone: TimeZone, statedAt: Date) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let bound = statedAt.addingTimeInterval(-CodeTuning.etaBeforeStatement)
        let boundSeconds = Int(floor(bound.timeIntervalSince1970))
        let localDay = floorDivide(boundSeconds + zone.secondsFromGMT(for: bound), 86_400)
        var best: Date?
        for day in (localDay - 1)...(localDay + 2) {
            // The wall time as if it were UTC, then every offset the zone has around it.
            let naive = day * 86_400 + hour * 3600 + minute * 60
            var offsets = Set<Int>()
            for probe in [naive - 86_400, naive, naive + 86_400] {
                offsets.insert(zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(probe))))
            }
            for offset in offsets {
                let candidate = Date(timeIntervalSince1970: TimeInterval(naive - offset))
                guard zone.secondsFromGMT(for: candidate) == offset, candidate >= bound else { continue }
                if best.map({ candidate < $0 }) ?? true { best = candidate }
            }
        }
        guard let best, best.timeIntervalSince(statedAt) <= CodeTuning.etaMaxAhead else { return nil }
        return best
    }

    private static func floorDivide(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }
}

/// The app's own estimate (a straight-line rate with guards): only while running, only from background work
/// or todos. elapsed = whole minutes since the counted work started (at least 1); none unless done ≥ 1, total ≥ 3,
/// elapsed ≥ 3 min and done < total; left = max(1, round(elapsed × (1 − p) / p)) with p = done / total; nothing over
/// 240 minutes. Pure.
enum ETAEstimator {
    /// An estimate: minutes left and the moment they give.
    struct Estimate: Equatable, Sendable {
        var minutesLeft: Int
        var at: Date
    }

    static func estimate(done: Int, total: Int, since: Date, now: Date) -> Estimate? {
        let elapsed = CodeDurationText.elapsedMinutes(from: since, to: now)
        guard done >= CodeTuning.estimateMinDone, total >= CodeTuning.estimateMinTotal, done < total,
              Double(elapsed) * 60 >= CodeTuning.estimateMinElapsed else { return nil }
        let p = Double(done) / Double(total)
        let left = max(1, Int((Double(elapsed) * (1 - p) / p).rounded()))
        guard Double(left) * 60 <= CodeTuning.estimateMax else { return nil }
        return Estimate(minutesLeft: left, at: now.addingTimeInterval(Double(left) * 60))
    }

    /// The minutes the words show: under 10 as they are, 10-59 to the nearest 5, 60 and more to the nearest 10.
    static func shownMinutes(_ left: Int) -> Int {
        if left < 10 { return max(1, left) }
        if left < 60 { return Int((Double(left) / 5).rounded()) * 5 }
        return Int((Double(left) / 10).rounded()) * 10
    }

    /// "≈ 9 min left", "≈ 25 min left", "≈ 1 h 20 min left".
    static func words(minutesLeft: Int) -> String {
        "≈ " + CodeDurationText.minutes(shownMinutes(minutesLeft)) + " left"
    }

    /// "≈ 9 min" (small monitors).
    static func shortWords(minutesLeft: Int) -> String {
        "≈ " + CodeDurationText.minutes(shownMinutes(minutesLeft))
    }
}
