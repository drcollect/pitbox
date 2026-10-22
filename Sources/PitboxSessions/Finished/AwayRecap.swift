import Foundation
import PitboxKit

/// What the recap is made from at the moment the user comes back.
struct CodeAwayRecapContents {
    /// The followed sessions with how they are followed, in the block's fixed order (the recap's sections use it).
    var sessions: [(snapshot: CodeSessionSnapshot, follow: CodeFollowedSet.Kind)]
    /// The Ready list's items now (cards and Later rows; dismissed ones are not there).
    var items: [CodeReadyItem]
    var hideText: Bool
    /// "Still running" words of a session, nil when it is not running: the desk tag text (`RunText.tag`) when the
    /// composition wires it (`CodeReadyForYou.runWords`), else `CodeAwayRecapBuilder.runningWords`.
    var runWords: ((CodeSessionSnapshot, Date) -> String?)?
}

/// "While you were away". **Away** = no HID input for `recapAfterMinutes` (default 15), the screen locked, or the Mac
/// asleep (a gap of that length between two polls). While the block is shown it asks every 30 s, and every 2 s once
/// away, so a return (input again, idle under 2 s) is seen within 2 s. While the block is hidden nothing polls, so an
/// absence then makes no recap: hiding the block ends the away period without one.
/// On return, when anything finished or arrived while away, the card opens the Ready list; Got it removes it, and so do
/// the next away period and 30 minutes shown. Main thread; the clock, presence and timers are injected.
@MainActor
final class CodeAwayRecap {
    /// One line of a section: the quoted headline and the app's own words (and session text unless Hide text is on).
    struct Line: Equatable {
        var headline: String
        var detail: String?
    }

    /// "Finished · 2", "Waiting for you · 3", "Still running · 1" with up to 8 lines ("and 3 more").
    struct Section: Equatable {
        enum Kind: Equatable { case finished, waiting, running }
        var kind: Kind
        var count: Int
        var lines: [Line]
        var more: Int

        var title: String {
            switch kind {
            case .finished: return "Finished · \(count)"
            case .waiting: return "Waiting for you · \(count)"
            case .running: return "Still running · \(count)"
            }
        }
    }

    /// The recap card.
    struct Recap: Equatable {
        var from: Date
        var until: Date
        var sections: [Section]
        var shownAt: Date

        func count(_ kind: Section.Kind) -> Int { sections.first { $0.kind == kind }?.count ?? 0 }
    }

    enum Phase: Equatable {
        case present
        case away(since: Date)
    }

    /// Lines per section at most.
    nonisolated static let linesShown = 8
    /// Input within this many seconds means the user is back.
    nonisolated static let backWithin: TimeInterval = 2

    private(set) var recap: Recap?
    private(set) var phase: Phase = .present
    /// Called after `recap` changed.
    var onChange: (() -> Void)?
    /// A new recap appeared (the read-out with Say it).
    var onRecap: ((Recap) -> Void)?
    /// What the recap is made of at the return.
    var contents: (() -> CodeAwayRecapContents?)?
    var clockWords = CodeReadyClock()

    private let environment: CodeReadyEnvironment
    private var settings: CodeSettings
    private var visible = false
    private var generation = 0
    private var lastPollAt: Date?

    init(environment: CodeReadyEnvironment, settings: CodeSettings) {
        self.environment = environment
        self.settings = settings
    }

    // MARK: Inputs

    /// The block was shown or hidden: polling runs only while it is shown (and the recap is on).
    func setStripVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        if visible {
            phase = .present
            lastPollAt = environment.clock()
            poll()
        } else {
            if case .away = phase { CodeTileLog.info("recap skipped reason=block-hidden") }
            phase = .present
            lastPollAt = nil
            generation += 1
        }
    }

    func update(settings: CodeSettings) {
        let wasOn = self.settings.awayRecap
        self.settings = settings
        if !settings.awayRecap {
            phase = .present
            generation += 1
            if recap != nil { set(nil) }
        } else if !wasOn, visible {
            lastPollAt = environment.clock()
            poll()
        }
    }

    /// Got it.
    func gotIt() {
        guard recap != nil else { return }
        set(nil)
    }

    // MARK: Polling

    /// One look at presence (tests call it directly with the scheduler replaced).
    func poll() {
        guard visible, settings.awayRecap else { return }
        let now = environment.clock()
        let threshold = TimeInterval(settings.recapAfterMinutes) * 60
        if let recap, now.timeIntervalSince(recap.shownAt) >= CodeTuning.recapLife { set(nil) }
        let idle = environment.idleSeconds()
        let locked = environment.screenLocked()
        let gap = lastPollAt.map { now.timeIntervalSince($0) } ?? 0
        switch phase {
        case .present:
            if gap >= threshold, let last = lastPollAt {
                // The Mac slept (or the app was held) longer than the threshold: that was an absence.
                phase = .away(since: last)
            } else if locked || (idle.map { $0 >= threshold } ?? false) {
                phase = .away(since: now.addingTimeInterval(-(idle ?? 0)))
            }
            if case .away = phase, recap != nil { set(nil) }
            if case .away = phase { returnIfBack(now: now, idle: idle, locked: locked) }
        case .away:
            returnIfBack(now: now, idle: idle, locked: locked)
        }
        lastPollAt = now
        scheduleNext()
    }

    private func returnIfBack(now: Date, idle: TimeInterval?, locked: Bool) {
        guard case .away(let since) = phase, !locked, let idle, idle < Self.backWithin else { return }
        phase = .present
        guard let contents = contents?(),
              let built = CodeAwayRecapBuilder.build(from: since, until: now, contents: contents, clock: clockWords, now: now)
        else {
            CodeTileLog.info("recap none away_min=\(Int(now.timeIntervalSince(since) / 60))")
            return
        }
        set(built)
        CodeTileLog.info("recap shown away_min=\(Int(now.timeIntervalSince(since) / 60)) finished=\(built.count(.finished)) "
            + "waiting=\(built.count(.waiting)) running=\(built.count(.running))")
        onRecap?(built)
    }

    private func scheduleNext() {
        generation += 1
        let token = generation
        let interval: TimeInterval
        if case .away = phase { interval = CodeTuning.recapPollAway } else { interval = CodeTuning.recapPollPresent }
        environment.schedule(interval) { [weak self] in
            guard let self, self.generation == token else { return }
            self.poll()
        }
    }

    private func set(_ next: Recap?) {
        guard next != recap else { return }
        recap = next
        onChange?()
    }
}

/// The recap's sections. Pure.
enum CodeAwayRecapBuilder {
    /// The recap for an absence from `from` to `until`, nil when nothing finished or arrived meanwhile.
    static func build(from: Date, until: Date, contents: CodeAwayRecapContents, clock: CodeReadyClock,
                      now: Date) -> CodeAwayRecap.Recap? {
        let period = from...max(from, until)
        var finished: [CodeAwayRecap.Line] = []
        var waiting: [CodeAwayRecap.Line] = []
        var running: [CodeAwayRecap.Line] = []
        var arrived = false
        let itemsBySession = Dictionary(grouping: contents.items, by: \.sessionID)
        for (session, _) in contents.sessions {
            let headline = "“" + (CodePlainText.line(session.headline, limit: 80) ?? "Untitled session") + "”"
            let items = itemsBySession[session.id] ?? []
            if items.contains(where: { $0.kind != .finished && period.contains($0.time) }) { arrived = true }
            if let mark = session.finished, mark.isOpen, mark.hasItem, period.contains(mark.at) {
                var detail = "at " + clock.time(mark.at)
                if !contents.hideText, let tldr = session.tldr.flatMap({ CodePlainText.line($0, limit: 120) }) {
                    detail += " · " + tldr
                }
                finished.append(.init(headline: headline, detail: detail))
            }
            if let detail = waitingWords(session, items: items, hideText: contents.hideText) {
                waiting.append(.init(headline: headline, detail: detail))
                if session.state == .needsYou, session.lastActivity.map(period.contains) ?? false { arrived = true }
            }
            let words = contents.runWords.map { $0(session, now) } ?? runningWords(session, clock: clock, now: now)
            if let detail = words {
                running.append(.init(headline: headline, detail: detail))
            }
        }
        guard !finished.isEmpty || arrived else { return nil }
        let sections = [section(.finished, finished), section(.waiting, waiting), section(.running, running)].compactMap { $0 }
        return CodeAwayRecap.Recap(from: from, until: until, sections: sections, shownAt: now)
    }

    private static func section(_ kind: CodeAwayRecap.Section.Kind, _ lines: [CodeAwayRecap.Line]) -> CodeAwayRecap.Section? {
        guard !lines.isEmpty else { return nil }
        let shown = Array(lines.prefix(CodeAwayRecap.linesShown))
        return CodeAwayRecap.Section(kind: kind, count: lines.count, lines: shown, more: lines.count - shown.count)
    }

    /// "command ready", "2 commands ready", "file ready: draft.md", "Looks stuck", "Same file", "needs you".
    static func waitingWords(_ session: CodeSessionSnapshot, items: [CodeReadyItem], hideText: Bool) -> String? {
        let commands = items.filter { $0.kind == .command }.count
        if commands > 0 { return commands == 1 ? "command ready" : "\(commands) commands ready" }
        if let file = items.first(where: { $0.kind == .file }) {
            guard !hideText, let line = file.line else { return "file ready" }
            let name = line.components(separatedBy: " on ").first ?? line
            return "file ready: " + name
        }
        if let warning = items.first(where: { $0.kind == .warning }) {
            return warning.title.replacingOccurrences(of: "⚠ ", with: "")
        }
        return session.state == .needsYou ? "needs you" : nil
    }

    /// The run text (the short form): "ETA 23:24", "ETA 23:24 passed", "≈ 9 min left", "4 of 6 agents done",
    /// "Running 12 min"; nil when the session is not running.
    static func runningWords(_ session: CodeSessionSnapshot, clock: CodeReadyClock, now: Date) -> String? {
        let pending = session.progress?.pendingBetweenTurns == true && (session.progress?.pending ?? 0) > 0
        guard session.state == .working || session.state == .maybeNeedsYou || pending else { return nil }
        if let eta = session.eta {
            switch eta.kind {
            case .stated: return "ETA " + clock.time(eta.at) + (eta.isLate ? " passed" : "")
            case .estimate:
                if let minutes = eta.minutesLeft { return "≈ \(minutes) min left" }
            }
        }
        if let progress = session.progress, progress.total > 0, progress.unit != .todos {
            return "\(progress.done) of \(progress.total) \(progress.unit.rawValue) done"
        }
        if let start = session.workStartedAt { return "Running " + CodeReadyClock.ran(now.timeIntervalSince(start)) }
        return "working"
    }
}
