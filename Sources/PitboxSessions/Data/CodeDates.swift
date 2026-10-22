import Foundation

/// Timestamps as Claude writes them: ISO 8601 date-times such as `2026-10-01T09:59:54.819Z` (transcripts, session
/// files), with any number of fractional digits (or none) and `Z`, `+01:00`, `+0100` or `+01` as the zone (a missing zone
/// means UTC), or a number of milliseconds (or seconds) since 1970 (session files). Parsed by hand: this runs for every
/// transcript line, and a formatter per call would be slow. (A copy of a usage reader's parser: modules do not import each
/// other.)
enum CodeDates {
    /// The date for `text`, or nil when it is not such a date-time (or not between 2000 and 2200).
    static func parse(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { parse(UnsafeRawBufferPointer($0)) }
    }

    /// A date from a number: milliseconds since 1970 when it is that large, else seconds; nil outside 2000-2200.
    static func fromNumber(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        guard seconds >= 946_684_800, seconds <= 7_258_118_400 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func parse(_ b: UnsafeRawBufferPointer) -> Date? {
        let n = b.count
        guard n >= 19 else { return nil }
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= n else { return nil }
            var value = 0
            for i in start..<(start + count) {
                let c = b[i]
                guard c >= 0x30, c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            return value
        }
        guard let year = digits(0, 4), b[4] == UInt8(ascii: "-"), let month = digits(5, 2), b[7] == UInt8(ascii: "-"),
              let day = digits(8, 2), b[10] == UInt8(ascii: "T") || b[10] == UInt8(ascii: " "),
              let hour = digits(11, 2), b[13] == UInt8(ascii: ":"), let minute = digits(14, 2), b[16] == UInt8(ascii: ":"),
              let second = digits(17, 2) else { return nil }
        guard (2000...2200).contains(year), (1...12).contains(month), (1...daysIn(month, year)).contains(day),
              hour <= 23, minute <= 59, second <= 60 else { return nil }
        var i = 19
        var fraction = 0.0
        if i < n, b[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            let start = i
            while i < n, b[i] >= 0x30, b[i] <= 0x39 {
                fraction += Double(b[i] - 0x30) * scale
                scale /= 10
                i += 1
            }
            guard i > start else { return nil }
        }
        var offset = 0
        if i < n {
            switch b[i] {
            case UInt8(ascii: "Z"), UInt8(ascii: "z"):
                i += 1
            case UInt8(ascii: "+"), UInt8(ascii: "-"):
                let sign = b[i] == UInt8(ascii: "-") ? -1 : 1
                guard let hours = digits(i + 1, 2), hours <= 23 else { return nil }
                i += 3
                var minutes = 0
                if i < n, b[i] == UInt8(ascii: ":") { i += 1 }
                if i < n {
                    guard let m = digits(i, 2), m <= 59 else { return nil }
                    minutes = m
                    i += 2
                }
                offset = sign * (hours * 3600 + minutes * 60)
            default:
                return nil
            }
        }
        guard i == n else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    private static func daysIn(_ month: Int, _ year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
