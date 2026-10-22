import Foundation

/// Times and durations as the running words show them: always in this Mac's zone, in the system's 12- or 24-hour
/// form ("23:24", "11:24 PM"). Pure and `Sendable`: the zone and the hour cycle are fixed when it is made (tests pass
/// their own; the app uses `system`).
public struct CodeClockFormat: Sendable, Equatable {
    /// The zone times are shown in (this Mac's).
    public let timeZone: TimeZone
    /// 24-hour clock ("23:24") or 12-hour clock ("11:24 PM").
    public let uses24Hour: Bool
    /// The 12-hour clock's day-half words ("AM", "PM").
    public let amSymbol: String
    public let pmSymbol: String

    /// A clock in `timeZone`, 24- or 12-hour.
    public init(timeZone: TimeZone, uses24Hour: Bool, amSymbol: String = "AM", pmSymbol: String = "PM") {
        self.timeZone = timeZone
        self.uses24Hour = uses24Hour
        self.amSymbol = amSymbol
        self.pmSymbol = pmSymbol
    }

    /// This Mac's zone and hour cycle, read now (`DateFormatter`'s "j" skeleton names the system's choice).
    public static var system: CodeClockFormat {
        let locale = Locale.autoupdatingCurrent
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "HH"
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return CodeClockFormat(timeZone: .autoupdatingCurrent, uses24Hour: !pattern.contains("a"),
                               amSymbol: calendar.amSymbol, pmSymbol: calendar.pmSymbol)
    }

    /// "23:24" or "11:24 PM".
    public func string(_ date: Date) -> String {
        let (hour, minute) = Self.wallClock(date, in: timeZone)
        let mm = minute < 10 ? "0\(minute)" : "\(minute)"
        if uses24Hour { return (hour < 10 ? "0\(hour)" : "\(hour)") + ":" + mm }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve):\(mm) \(hour < 12 ? amSymbol : pmSymbol)"
    }

    /// "22:24 UTC": a clock in another zone, for "(stated as 22:24 UTC)". 24-hour form for UTC (how sessions write it).
    static func string(_ date: Date, statedIn zone: TimeZone, label: String) -> String {
        let (hour, minute) = wallClock(date, in: zone)
        return String(format: "%02d:%02d", hour, minute) + " " + label
    }

    /// The hour and minute a wall clock in `zone` shows at `date`.
    static func wallClock(_ date: Date, in zone: TimeZone) -> (hour: Int, minute: Int) {
        let local = Int(floor(date.timeIntervalSince1970)) + zone.secondsFromGMT(for: date)
        let secondsOfDay = ((local % 86_400) + 86_400) % 86_400
        return (secondsOfDay / 3600, (secondsOfDay % 3600) / 60)
    }
}

/// Durations in the running words: "34 min", "1 h 12 min", "1 h".
enum CodeDurationText {
    /// Whole minutes as "34 min", "1 h 12 min" or "2 h".
    static func minutes(_ minutes: Int) -> String {
        let value = max(0, minutes)
        guard value >= 60 else { return "\(value) min" }
        let hours = value / 60, rest = value % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Whole minutes from `start` to `now`, rounded down, at least `floor` (the words never say "0 min").
    static func elapsedMinutes(from start: Date, to now: Date, atLeast floor: Int = 1) -> Int {
        max(floor, Int((now.timeIntervalSince(start) / 60).rounded(.down)))
    }
}
