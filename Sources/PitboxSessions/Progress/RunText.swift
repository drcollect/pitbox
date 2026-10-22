import Foundation

/// The running words of a session, from its snapshot's running fields (`ProgressDeriver`'s) and the time now. The
/// block computes them when it draws, so the minutes stay current with its redraw tick; nothing here is session
/// text. Pure.
///
/// | Where | Words |
/// | --- | --- |
/// | Large monitor | "Running 34 min · ETA 23:24 · 4 of 6 agents done"; between turns "Background · 4 of 6 agents …" |
/// | Medium monitor, slim row | "ETA 23:24 · 4/6 agents" or "≈ 9 min left" |
/// | Small monitor | "≈ 9 min" |
/// | desk tag | "ETA 23:24", "ETA 23:24 passed", "≈ 9 min left", "4 of 6 agents done", "Running 12 min" |
/// | Peek | "Started 22:36 · running 34 min · ETA 23:24, as stated in its reply (passed 6 min ago)" and the progress |
enum RunText {
    // MARK: State

    /// Working or maybe needs you, or background tasks pending. "quiet · turn not finished" is not running.
    static func isRunning(_ s: CodeSessionSnapshot) -> Bool {
        ProgressDeriver.isRunning(s.state) || pendingTasks(s) > 0
    }

    /// Background tasks run while the turn itself is not working (it ended, or it went quiet): "Background · …".
    /// The same rule as `CodeProgress.pendingBetweenTurns`.
    static func isBetweenTurns(_ s: CodeSessionSnapshot) -> Bool {
        pendingTasks(s) > 0 && !ProgressDeriver.isRunning(s.state)
    }

    /// Background tasks still running.
    static func pendingTasks(_ s: CodeSessionSnapshot) -> Int {
        guard let progress = s.progress, progress.source == .backgroundTasks else { return 0 }
        return progress.pending
    }

    /// A stated ETA that passed while the session still runs: orange words and bar, "1 past ETA".
    static func isLate(_ s: CodeSessionSnapshot, now: Date) -> Bool {
        guard let eta = s.eta, eta.kind == .stated, isRunning(s) else { return false }
        return now > eta.at
    }

    /// The bar's fill (done of total) while running; nil without a source (no source, no bar).
    static func fraction(_ s: CodeSessionSnapshot) -> Double? {
        guard isRunning(s), let progress = s.progress, progress.total > 0 else { return nil }
        return progress.fraction
    }

    // MARK: Lines

    /// The large monitor's run line.
    static func large(_ s: CodeSessionSnapshot, now: Date, clock: CodeClockFormat) -> String? {
        guard isRunning(s) else { return nil }
        let eta = etaWords(s, now: now, clock: clock, short: false)
        let progress = shownProgress(s).map(progressWords)
        if isBetweenTurns(s) { return (["Background"] + [progress, eta].compactMap { $0 }).joined(separator: " · ") }
        let parts = [s.workStartedAt.map { WorkClock.runningWords(since: $0, now: now) }, eta, progress].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The medium monitor's short run line, also a slim row's right-hand text.
    static func medium(_ s: CodeSessionSnapshot, now: Date, clock: CodeClockFormat) -> String? {
        guard isRunning(s) else { return nil }
        if let eta = s.eta, eta.kind == .estimate, let left = eta.minutesLeft { return ETAEstimator.words(minutesLeft: left) }
        let parts = [etaWords(s, now: now, clock: clock, short: true), shownProgress(s).map(shortProgressWords)].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return s.workStartedAt.map { WorkClock.runningWords(since: $0, now: now) }
    }

    /// A small monitor's line when no offer, file or warning comes first: the estimate, "≈ 9 min"; otherwise
    /// the small monitor shows its state word.
    static func small(_ s: CodeSessionSnapshot, now: Date, clock: CodeClockFormat) -> String? {
        guard isRunning(s), let eta = s.eta, eta.kind == .estimate, let left = eta.minutesLeft else { return nil }
        return ETAEstimator.shortWords(minutesLeft: left)
    }

    /// A desk tag's running text.
    static func tag(_ s: CodeSessionSnapshot, now: Date, clock: CodeClockFormat) -> String? {
        guard isRunning(s) else { return nil }
        if let eta = etaWords(s, now: now, clock: clock, short: true) { return eta }
        if let progress = shownProgress(s) { return progressWords(progress) }
        return s.workStartedAt.map { WorkClock.runningWords(since: $0, now: now) }
    }

    /// The peek's lines: the start, running time and ETA, then the progress (with a workflow's agents).
    static func peek(_ s: CodeSessionSnapshot, now: Date, clock: CodeClockFormat) -> [String] {
        guard isRunning(s) else { return [] }
        var first: [String] = []
        if let start = s.workStartedAt {
            first.append("Started \(clock.string(start))")
            first.append("running " + CodeDurationText.minutes(CodeDurationText.elapsedMinutes(from: start, to: now)))
        }
        if let eta = s.eta {
            switch eta.kind {
            case .stated:
                var words = "ETA \(clock.string(eta.at))"
                let late = isLate(s, now: now)
                if let estimate = eta.estimateAt {
                    words += " as stated" + (late ? " (\(passedWords(eta.at, now: now)))" : "")
                    words += " · estimate ≈ \(clock.string(estimate))"
                } else {
                    words += ", as stated in its reply" + (late ? " (\(passedWords(eta.at, now: now)))" : "")
                }
                if let other = statedAs(eta, clock: clock) { words += " (stated as \(other))" }
                first.append(words)
            case .estimate:
                if let left = eta.minutesLeft {
                    let source = shownProgress(s).map { " (estimate from \(progressWords($0)))" } ?? ""
                    first.append(ETAEstimator.words(minutesLeft: left) + source)
                }
            }
        }
        var lines: [String] = []
        if !first.isEmpty { lines.append(first.joined(separator: " · ")) }
        if let progress = shownProgress(s) {
            var words = (isBetweenTurns(s) ? "Background · " : "") + progressWords(progress)
            if let done = progress.workflowAgentsDone, let count = progress.workflowAgentCount {
                words += " · workflow agents \(done) of \(count)"
            }
            lines.append(words)
        }
        return lines
    }

    /// "as of 23:12" beside an SSH session's "Now:" when its newest step is over 60 s old (mirrors trail the server by
    /// 20-40 s and up to about 5 minutes).
    static func nowAsOf(_ s: CodeSessionSnapshot, now: Date, clock: CodeClockFormat) -> String? {
        guard s.place == .ssh, ProgressDeriver.isRunning(s.state), let at = s.steps.last?.at,
              now.timeIntervalSince(at) > 60 else { return nil }
        return "as of \(clock.string(at))"
    }

    // MARK: Parts

    /// "ETA 23:24", "ETA 23:24 passed 6 min ago" (long) or "ETA 23:24 passed" (short), "≈ 9 min left".
    static func etaWords(_ s: CodeSessionSnapshot, now: Date, clock: CodeClockFormat, short: Bool) -> String? {
        guard let eta = s.eta else { return nil }
        switch eta.kind {
        case .stated:
            let words = "ETA \(clock.string(eta.at))"
            guard isLate(s, now: now) else { return words }
            return short ? words + " passed" : words + " " + passedWords(eta.at, now: now)
        case .estimate:
            return eta.minutesLeft.map { ETAEstimator.words(minutesLeft: $0) }
        }
    }

    /// "passed 6 min ago", "passed 1 h 5 min ago".
    static func passedWords(_ at: Date, now: Date) -> String {
        "passed " + CodeDurationText.minutes(CodeDurationText.elapsedMinutes(from: at, to: now)) + " ago"
    }

    /// The progress worth words: nil when nothing was counted (only expired background tasks, `total == 0`).
    static func shownProgress(_ s: CodeSessionSnapshot) -> CodeProgress? {
        guard let progress = s.progress, progress.total > 0 else { return nil }
        return progress
    }

    /// "4 of 6 agents done", "1 of 2 workflows done", "4 of 6 tasks done", "4/7 todos".
    static func progressWords(_ p: CodeProgress) -> String {
        if p.unit == .todos { return "\(p.done)/\(p.total) todos" }
        return "\(p.done) of \(p.total) \(noun(p.unit, count: p.total)) done"
    }

    /// "4/6 agents", "1/2 workflows", "4/6 tasks", "4/7 todos".
    static func shortProgressWords(_ p: CodeProgress) -> String {
        "\(p.done)/\(p.total) \(noun(p.unit, count: p.total))"
    }

    static func noun(_ unit: CodeProgress.Unit, count: Int) -> String {
        let singular: String
        switch unit {
        case .agents: singular = "agent"
        case .workflows: singular = "workflow"
        case .tasks: singular = "task"
        case .todos: singular = "todo"
        }
        return count == 1 ? singular : singular + "s"
    }

    /// "22:24 UTC" when the clock was stated in a zone whose wall clock differs from this Mac's at that moment.
    static func statedAs(_ eta: CodeETA, clock: CodeClockFormat) -> String? {
        guard let identifier = eta.statedZone, let zone = TimeZone(identifier: identifier),
              zone.secondsFromGMT(for: eta.at) != clock.timeZone.secondsFromGMT(for: eta.at) else { return nil }
        let label = identifier == "UTC" || identifier == "GMT" ? "UTC" : (zone.abbreviation(for: eta.at) ?? identifier)
        return CodeClockFormat.string(eta.at, statedIn: zone, label: label)
    }
}
