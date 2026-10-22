import Foundation

/// Clock times in this Mac's local time, in the system's 12- or 24-hour format ("23:24", or "11:24 PM"). Tests pass a
/// fixed zone and locale.
struct DeskTagClock {
    let timeZone: TimeZone
    private let formatter: DateFormatter

    /// The Mac's own zone and regional format.
    static var system: DeskTagClock { DeskTagClock(timeZone: .autoupdatingCurrent, locale: .autoupdatingCurrent) }

    init(timeZone: TimeZone, locale: Locale) {
        self.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        self.formatter = formatter
    }

    func string(_ date: Date) -> String { formatter.string(from: date) }

    /// The clock in another zone (for "(stated as 22:24 UTC)"), same format.
    func string(_ date: Date, in zone: TimeZone) -> String {
        let other = formatter.copy() as? DateFormatter ?? formatter
        other.timeZone = zone
        return other.string(from: date)
    }
}

/// The short run text of a tag and the peek's run line: host words built from the snapshot's progress, ETA and work
/// start. Pure. (`CodeRunDecoration` builds the monitor's run words; these follow the same wording.)
enum DeskTagRunText {
    /// Running: working or maybe needs you, or background tasks pending between turns. "Quiet · turn
    /// not finished" is not running.
    static func isRunning(_ session: CodeSessionSnapshot) -> Bool {
        switch session.state {
        case .working, .maybeNeedsYou: return true
        default: return session.progress?.pendingBetweenTurns == true
        }
    }

    /// The tag's text while running, the first that applies: "ETA 23:24 passed", "ETA 23:24", "≈ 9 min left", "4 of 6
    /// agents done", "Running 12 min", "Running".
    static func short(_ session: CodeSessionSnapshot, now: Date, clock: DeskTagClock) -> String {
        if let eta = session.eta {
            switch eta.kind {
            case .stated:
                let time = clock.string(eta.at)
                return isLate(eta, now: now) ? "ETA \(time) passed" : "ETA \(time)"
            case .estimate:
                if let minutes = eta.minutesLeft, let words = estimateWords(minutes: minutes) { return words }
            }
        }
        if let progress = session.progress, let words = progressWords(progress) { return words }
        return running(session, now: now)
    }

    /// "Running 12 min", "Running 1 h 12 min" (minutes rounded down); "Running" without a start or under a minute.
    static func running(_ session: CodeSessionSnapshot, now: Date) -> String {
        guard let start = session.workStartedAt else { return "Running" }
        let minutes = Int(now.timeIntervalSince(start) / 60)
        return minutes < 1 ? "Running" : "Running " + duration(minutes: minutes)
    }

    /// A stated ETA that has passed (the data side's mark, or the clock by now): orange "passed".
    static func isLate(_ eta: CodeETA, now: Date) -> Bool {
        eta.kind == .stated && (eta.isLate || now >= eta.at)
    }

    /// "≈ 9 min left"; 10-59 minutes rounded to 5, 60 and more to 10 ("≈ 1 h 20 min left"); nothing over 240 minutes
    /// or under 1.
    static func estimateWords(minutes: Int) -> String? {
        guard minutes >= 1, Double(minutes) * 60 <= CodeTuning.estimateMax else { return nil }
        let rounded: Int
        switch minutes {
        case ..<10: rounded = minutes
        case ..<60: rounded = Int((Double(minutes) / 5).rounded()) * 5
        default: rounded = Int((Double(minutes) / 10).rounded()) * 10
        }
        return "≈ " + duration(minutes: rounded) + " left"
    }

    /// "4 of 6 agents done", "1 of 2 workflows done", "4 of 6 tasks done", "4/7 todos"; nil without a total.
    static func progressWords(_ progress: CodeProgress) -> String? {
        guard progress.total > 0 else { return nil }
        let done = min(progress.done, progress.total)
        switch progress.unit {
        case .agents: return "\(done) of \(progress.total) agents done"
        case .workflows: return "\(done) of \(progress.total) workflows done"
        case .tasks: return "\(done) of \(progress.total) tasks done"
        case .todos: return "\(done)/\(progress.total) todos"
        }
    }

    /// "12 min", "1 h", "1 h 12 min".
    static func duration(minutes: Int) -> String {
        let value = max(0, minutes)
        if value < 60 { return "\(value) min" }
        let rest = value % 60
        return rest == 0 ? "\(value / 60) h" : "\(value / 60) h \(rest) min"
    }

    /// The desk peek's run line: "Started 22:36 · running 34 min · ETA 23:24, as stated in its reply (passed 6
    /// min ago)", or "… · ≈ 9 min left (estimate from 4 of 6 agents done)", or "… · ETA 23:24 as stated · estimate ≈
    /// 23:31". Nil when the session is not running.
    static func peekLine(_ session: CodeSessionSnapshot, now: Date, clock: DeskTagClock) -> String? {
        guard isRunning(session) else { return nil }
        var parts: [String] = []
        if let start = session.workStartedAt {
            let minutes = Int(now.timeIntervalSince(start) / 60)
            parts.append("Started " + clock.string(start))
            if minutes >= 1 { parts.append("running " + duration(minutes: minutes)) }
        } else if session.progress?.pendingBetweenTurns == true {
            parts.append("Background")
        }
        if let eta = session.eta {
            switch eta.kind {
            case .stated:
                var words = "ETA " + clock.string(eta.at)
                if let estimate = eta.estimateAt {
                    words += " as stated · estimate ≈ " + clock.string(estimate)
                } else {
                    words += ", as stated in its reply"
                }
                if isLate(eta, now: now) {
                    let late = Int(now.timeIntervalSince(eta.at) / 60)
                    words += late >= 1 ? " (passed \(duration(minutes: late)) ago)" : " (passed)"
                }
                parts.append(words)
            case .estimate:
                if let minutes = eta.minutesLeft, var words = estimateWords(minutes: minutes) {
                    if let progress = session.progress, let source = progressWords(progress) {
                        words += " (estimate from \(source))"
                    }
                    parts.append(words)
                }
            }
        }
        if session.eta?.kind != .estimate, let progress = session.progress, let words = progressWords(progress) {
            parts.append(words)
        }
        return parts.isEmpty ? "Running" : parts.joined(separator: " · ")
    }

    /// "(stated as 22:24 UTC)" when a stated ETA was read in a zone other than this Mac's.
    static func statedZoneNote(_ eta: CodeETA?, clock: DeskTagClock) -> String? {
        guard let eta, eta.kind == .stated, let name = eta.statedZone, let zone = TimeZone(identifier: name),
              zone.secondsFromGMT(for: eta.at) != clock.timeZone.secondsFromGMT(for: eta.at) else { return nil }
        let label = zone.identifier == "UTC" || zone.identifier == "GMT" ? "UTC" : (zone.abbreviation(for: eta.at) ?? zone.identifier)
        return "(stated as \(clock.string(eta.at, in: zone)) \(label))"
    }
}
