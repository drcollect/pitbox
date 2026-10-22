import Foundation

/// A clock a statement names: hour and minute, and whether UTC was written
/// with it (`UTC`, `GMT` or `Z` after the value, or in a parenthesis after `ETA`, the value or a table header).
struct ETAClockValue: Equatable, Sendable {
    var hour: Int
    var minute: Int
    var utc: Bool
}

/// What reading a value found.
enum ETAValueOutcome: Equatable, Sendable {
    /// A clock in one of the measured shapes: `HH:MM` or `H:MM`, alone or after `~`, `about` or `around` (or other
    /// words), or the end of a range `HH:MM-HH:MM`.
    case clock(ETAClockValue)
    /// The statement gives nothing: a weekday, a date, `today` or `tomorrow`, a 12-hour time, a duration, a done mark,
    /// a dependency or "soon" word, a clock out of range, or a zone other than UTC.
    case void
    /// No value before the window, the line or the sentence ended.
    case none
}

/// A zone written beside a label or a value.
enum ETAZoneMark: Equatable, Sendable {
    case none, utc, local
    /// Any other zone (`PST`, `CET`, `UTC+1`, `+01:00`, `Lisbon time`): it voids the value (none was measured).
    case foreign
}

/// Reads values after an ETA label, on one line or one table cell whose code spans and quotes are already
/// blanked. Table-driven by the word lists below; pure.
enum ETAValue {
    enum ClockToken: Equatable {
        case valid(hour: Int, minute: Int, end: Int)
        /// Digits and a colon that are no clock of the day (`24:00`, `23:60`, `22:4`).
        case invalid
    }

    /// What a clock's tail decided.
    enum Tail: Equatable {
        case outcome(ETAValueOutcome)
        /// The clock is "it's 22:10 now": never an ETA; scanning goes on from this index.
        case skip(Int)
    }

    // MARK: Word lists

    /// Weekdays and day words: with a clock they name another day, so the statement gives nothing.
    static let dayWords: Set<String> = [
        "mon", "monday", "tue", "tues", "tuesday", "wed", "weds", "wednesday", "thu", "thur", "thurs", "thursday",
        "fri", "friday", "sat", "saturday", "sun", "sunday", "today", "tonight", "tomorrow", "tmrw", "tmr", "yesterday",
    ]
    /// Month names ("may" left out: it is mostly the verb).
    static let monthWords: Set<String> = [
        "jan", "january", "feb", "february", "mar", "march", "apr", "april", "jun", "june", "jul", "july", "aug",
        "august", "sep", "sept", "september", "oct", "october", "nov", "november", "dec", "december",
    ]
    /// Words after which the statement gives nothing: dependencies, "soon", done, unknown, past times.
    static let voidWords: Set<String> = [
        "weekend", "week", "weeks", "month", "months", "after", "once", "waiting", "wait", "waits", "blocked",
        "blocking", "pending", "depends", "dependent", "unknown", "tbd", "tba", "unclear", "none", "yet", "never",
        "soon", "asap", "shortly", "imminent", "imminently", "momentarily", "done", "finished", "complete",
        "completed", "merged", "shipped", "started", "began", "since", "ago", "was", "earlier",
    ]
    /// Duration units after a number.
    static let unitWords: Set<String> = [
        "s", "sec", "secs", "second", "seconds", "m", "min", "mins", "minute", "minutes", "h", "hr", "hrs", "hour",
        "hours", "d", "day", "days", "w", "wk", "wks",
    ]
    /// Done marks (`✅`: "that row is done").
    static let doneMarks: Set<Unicode.Scalar> = ["\u{2705}", "\u{2713}", "\u{2714}", "\u{2611}"]
    /// Zone abbreviations other than UTC, matched exactly (uppercase, so prose words like "est" stay words).
    static let foreignZones: Set<String> = [
        "PST", "PDT", "MST", "MDT", "CST", "CDT", "EST", "EDT", "AKST", "AKDT", "HST", "HDT", "AST", "ADT", "NST",
        "NDT", "BST", "IST", "CET", "CEST", "EET", "EEST", "WET", "WEST", "MET", "MEST", "MSK", "GST", "PKT", "NPT",
        "ICT", "WIB", "SGT", "HKT", "PHT", "JST", "KST", "AEST", "AEDT", "ACST", "ACDT", "AWST", "NZST", "NZDT", "SAST",
        "CAT", "EAT", "WAT", "BRT", "ART", "CLT", "COT", "PET", "VET", "UYT", "ChST", "SST",
    ]
    /// Abbreviations whose full stop ends no sentence.
    static let abbreviations: Set<String> = ["approx", "ca", "est", "eg", "ie", "etc", "vs", "e.g", "i.e"]

    // MARK: Scanning

    /// The first value from `start`: words in between are skipped (`ETA for the build ~23:24`), a void word stops it
    /// with nothing, and the value must begin within `window` characters (nil: anywhere on the line). `zone` is a zone
    /// written before `start` (a label line's or a table header's).
    static func scan(_ s: [Unicode.Scalar], from start: Int, window: Int?, zone initial: ETAZoneMark = .none) -> ETAValueOutcome {
        var i = start
        var zone = initial
        var depth = 0
        while i < s.count {
            if let window, i - start > window { return .none }
            let c = s[i]
            if c.properties.isWhitespace {
                i += 1
                continue
            }
            if c == "(" {
                if let (mark, end) = parenthetical(s, at: i) {
                    if mark == .foreign { return .void }
                    if mark == .utc { zone = .utc }
                    i = end
                    continue
                }
                depth += 1
                i += 1
                continue
            }
            if c == ")" {
                depth = max(0, depth - 1)
                i += 1
                continue
            }
            if depth == 0, c == ";" || c == "!" || c == "?" || c == "|" { return .none }
            if c == ".", depth == 0, endsSentence(s, at: i) { return .none }
            if doneMarks.contains(c) { return .void }
            if ETAText.isDigit(c) {
                switch readClock(s, at: i) {
                case .invalid?:
                    return .void
                case .valid(let hour, let minute, let end)?:
                    switch tail(s, hour: hour, minute: minute, end: end, zone: zone) {
                    case .outcome(let outcome): return outcome
                    case .skip(let next):
                        i = next
                        continue
                    }
                case nil:
                    let number = readNumber(s, at: i)
                    if number.isDate || unitFollows(s, at: number.end) { return .void }
                    i = number.end
                    continue
                }
            }
            if c.properties.isAlphabetic {
                let (word, end) = readWord(s, at: i)
                // Before the value only UTC counts as a bare word ("ETA in UTC: 22:24"); other zone names count after
                // the value or in a parenthesis, so a word such as "CAT" or "WEST" here stays a word.
                let (mark, markEnd) = zoneWord(word, s, end: end)
                if mark == .utc {
                    zone = .utc
                    i = markEnd
                    continue
                }
                let lower = word.lowercased()
                if dayWords.contains(lower) || monthWords.contains(lower) || voidWords.contains(lower) { return .void }
                i = end
                continue
            }
            i += 1
        }
        return .none
    }

    /// After a clock: a 12-hour mark voids it, "now" skips it, a range gives its end, then the zone and day words.
    static func tail(_ s: [Unicode.Scalar], hour: Int, minute: Int, end: Int, zone: ETAZoneMark) -> Tail {
        if isTwelveHourMark(s, at: end) { return .outcome(.void) }
        let next = nextWord(s, at: end)
        if next?.word.lowercased() == "now" { return .skip(next?.end ?? end) }
        var value = (hour: hour, minute: minute)
        var k = end
        if let range = rangeEnd(s, at: end) {
            if case .invalid = range { return .outcome(.void) }
            if case .valid(let h, let m, let rangeEnd) = range {
                value = (h, m)
                k = rangeEnd
                if isTwelveHourMark(s, at: k) { return .outcome(.void) }
            }
        }
        let (mark, markEnd) = zoneAfter(s, at: k)
        if mark == .foreign { return .outcome(.void) }
        if dayFollows(s, at: markEnd) { return .outcome(.void) }
        let utc = mark == .utc || (mark == .none && zone == .utc)
        return .outcome(.clock(ETAClockValue(hour: value.hour, minute: value.minute, utc: utc)))
    }

    // MARK: Tokens

    /// `H:MM` or `HH:MM` (optionally `:SS`) at `i`, not followed by a digit; nil when the digits are no clock shape.
    static func readClock(_ s: [Unicode.Scalar], at i: Int) -> ClockToken? {
        var j = i
        while j < s.count, ETAText.isDigit(s[j]) { j += 1 }
        let digits = j - i
        guard digits >= 1, digits <= 2, j < s.count, s[j] == ":" else { return nil }
        var k = j + 1
        while k < s.count, ETAText.isDigit(s[k]) { k += 1 }
        guard k - (j + 1) == 2 else { return k == j + 1 ? nil : .invalid }
        guard let hour = Int(String(String.UnicodeScalarView(s[i..<j]))),
              let minute = Int(String(String.UnicodeScalarView(s[(j + 1)..<k]))), hour <= 23, minute <= 59 else {
            return .invalid
        }
        var end = k
        if end < s.count, s[end] == ":" {
            var seconds = end + 1
            while seconds < s.count, ETAText.isDigit(s[seconds]) { seconds += 1 }
            if seconds - (end + 1) == 2 { end = seconds }
        }
        return .valid(hour: hour, minute: minute, end: end)
    }

    /// A number token: digits with `.`, `/` or `-` between digit groups. Dates are `20/10`, `2026-10-20`, `20.10.`.
    static func readNumber(_ s: [Unicode.Scalar], at i: Int) -> (end: Int, isDate: Bool) {
        var j = i
        var separators: [Unicode.Scalar] = []
        while j < s.count {
            if ETAText.isDigit(s[j]) {
                j += 1
            } else if (s[j] == "." || s[j] == "/" || s[j] == "-"), j + 1 < s.count, ETAText.isDigit(s[j + 1]) {
                separators.append(s[j])
                j += 1
            } else {
                break
            }
        }
        let trailingDot = j < s.count && s[j] == "." && separators.contains(".")
        let isDate = separators.contains("/") || separators.contains("-") || separators.filter { $0 == "." }.count >= 2
            || trailingDot
        return (j, isDate)
    }

    /// A duration unit right after a number (`20 min`, `~20m`, `1.5h`, `20-min`).
    static func unitFollows(_ s: [Unicode.Scalar], at i: Int) -> Bool {
        var j = i
        if j < s.count, s[j] == "-" { j += 1 }
        var spaces = 0
        while j < s.count, s[j] == " ", spaces < 2 {
            j += 1
            spaces += 1
        }
        guard j < s.count, s[j].properties.isAlphabetic else { return false }
        return unitWords.contains(readWord(s, at: j).word.lowercased())
    }

    /// Letters and digits from `i` (apostrophes inside a word kept).
    static func readWord(_ s: [Unicode.Scalar], at i: Int) -> (word: String, end: Int) {
        var j = i
        while j < s.count {
            let c = s[j]
            if c.properties.isAlphabetic || ETAText.isDigit(c) {
                j += 1
            } else if (c == "'" || c == "\u{2019}"), j + 1 < s.count, s[j + 1].properties.isAlphabetic, j > i {
                j += 1
            } else {
                break
            }
        }
        return (String(String.UnicodeScalarView(s[i..<j])), j)
    }

    /// The next word after spaces (nil when something else comes first).
    static func nextWord(_ s: [Unicode.Scalar], at i: Int) -> (word: String, end: Int)? {
        var j = i
        while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
        guard j < s.count, s[j].properties.isAlphabetic else { return nil }
        return readWord(s, at: j)
    }

    /// `am`, `pm`, `a.m.`, `p.m.` after the value (one space at most before it).
    static func isTwelveHourMark(_ s: [Unicode.Scalar], at i: Int) -> Bool {
        var j = i
        if j < s.count, s[j] == " " { j += 1 }
        guard j + 1 < s.count else { return false }
        let a = String(s[j]).lowercased(), b = String(s[j + 1]).lowercased()
        guard a == "a" || a == "p" else { return false }
        if b == "m" { return j + 2 >= s.count || !s[j + 2].properties.isAlphabetic }
        if b == ".", j + 2 < s.count, String(s[j + 2]).lowercased() == "m" { return true }
        return false
    }

    /// `-HH:MM` or `–HH:MM` (spaces and `~` allowed): a range, read as its end.
    static func rangeEnd(_ s: [Unicode.Scalar], at i: Int) -> ClockToken? {
        var j = i
        while j < s.count, s[j] == " " { j += 1 }
        guard j < s.count, s[j] == "-" || s[j] == "\u{2013}" || s[j] == "\u{2014}" else { return nil }
        j += 1
        while j < s.count, s[j] == " " || s[j] == "~" || s[j] == "\u{2248}" { j += 1 }
        guard j < s.count, ETAText.isDigit(s[j]) else { return nil }
        return readClock(s, at: j)
    }

    // MARK: Zones and days

    /// The zone written right after a value: `Z` attached, `UTC`/`GMT`, a parenthesis, a foreign abbreviation, an
    /// offset (`+01:00`), "local", or "<Place> time".
    static func zoneAfter(_ s: [Unicode.Scalar], at i: Int) -> (ETAZoneMark, Int) {
        if i < s.count, s[i] == "Z", i + 1 >= s.count || !s[i + 1].properties.isAlphabetic { return (.utc, i + 1) }
        var j = i
        while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
        guard j < s.count else { return (.none, i) }
        if s[j] == "(" {
            if let (mark, end) = parenthetical(s, at: j) { return (mark, end) }
            return (.none, i)
        }
        if s[j] == "+" || s[j] == "-" || s[j] == "\u{2212}", j + 1 < s.count, ETAText.isDigit(s[j + 1]), j == i + 1 || j == i {
            return (.foreign, j + 1)
        }
        guard s[j].properties.isAlphabetic else { return (.none, i) }
        let (word, end) = readWord(s, at: j)
        let (mark, markEnd) = zoneWord(word, s, end: end)
        if mark != .none { return (mark, markEnd) }
        if word.lowercased() == "local" {
            if let next = nextWord(s, at: end), next.word.lowercased() == "time" { return (.local, next.end) }
            return (.local, end)
        }
        if let first = word.unicodeScalars.first, first.properties.isUppercase, let next = nextWord(s, at: end),
           next.word.lowercased() == "time" {
            return (word.lowercased() == "server" ? .none : .foreign, next.end)
        }
        return (.none, i)
    }

    /// `UTC`, `GMT` (any case; with an offset such as `UTC+1` foreign), `Z`, or a foreign abbreviation.
    static func zoneWord(_ word: String, _ s: [Unicode.Scalar], end: Int) -> (ETAZoneMark, Int) {
        let upper = word.uppercased()
        if upper == "UTC" || upper == "GMT" {
            if end + 1 < s.count, s[end] == "+" || s[end] == "-" || s[end] == "\u{2212}", ETAText.isDigit(s[end + 1]) {
                return (.foreign, end + 2)
            }
            return (.utc, end)
        }
        if word == "Z" { return (.utc, end) }
        if foreignZones.contains(word) { return (.foreign, end) }
        return (.none, end)
    }

    /// A parenthesis whose first word is a zone ("(UTC; it's 22:10 now)", "(local)", "(PST)"): its mark and the index
    /// after its closing parenthesis; nil when it starts with anything else.
    static func parenthetical(_ s: [Unicode.Scalar], at i: Int) -> (ETAZoneMark, Int)? {
        var close = i + 1
        var depth = 1
        while close < s.count {
            if s[close] == "(" { depth += 1 }
            if s[close] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            close += 1
        }
        let end = min(close + 1, s.count)
        var j = i + 1
        while j < close, s[j] == " " || s[j] == "*" || s[j] == "_" { j += 1 }
        guard j < close, s[j].properties.isAlphabetic else { return nil }
        let (word, wordEnd) = readWord(s, at: j)
        let (mark, _) = zoneWord(word, s, end: wordEnd)
        if mark != .none { return (mark, end) }
        if word.lowercased() == "local" { return (.local, end) }
        return nil
    }

    /// A weekday, a day word or a date right after a value (`09:00 tomorrow`, `09:00 Mon`, `09:00 20/10`).
    static func dayFollows(_ s: [Unicode.Scalar], at i: Int) -> Bool {
        var j = i
        while j < s.count, s[j] == " " || s[j] == "," || s[j] == "(" || s[j] == "\t" { j += 1 }
        guard j < s.count else { return false }
        if ETAText.isDigit(s[j]) { return readClock(s, at: j) == nil && readNumber(s, at: j).isDate }
        guard s[j].properties.isAlphabetic else { return false }
        let word = readWord(s, at: j).word.lowercased()
        return dayWords.contains(word) || monthWords.contains(word)
    }

    /// A full stop that ends a sentence: followed by a space and a capital letter (or the end), not after an
    /// abbreviation such as "approx.".
    static func endsSentence(_ s: [Unicode.Scalar], at i: Int) -> Bool {
        var start = i
        while start > 0, s[start - 1].properties.isAlphabetic || s[start - 1] == "." { start -= 1 }
        let before = String(String.UnicodeScalarView(s[start..<i])).lowercased()
        if abbreviations.contains(before) { return false }
        var j = i + 1
        guard j < s.count else { return true }
        guard s[j] == " " || s[j] == "\t" else { return false }
        while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
        return j >= s.count || s[j].properties.isUppercase
    }
}
