import Foundation

/// The summary line under the block header: one line, 12 pt, each part only
/// when above zero, hidden when all are zero: "3 running · next done ≈ 23:24 · 1 past ETA · 2 just finished · 4 ready
/// for you · 1 warning · ▦ 6 dashboards" (the last part is a button that opens the dashboards list).
///
/// - running: followed sessions working or maybe needing you, or with background tasks pending ("quiet · turn not
///   finished" is not running);
/// - next done: the earliest of their stated ETAs not yet passed and their estimates;
/// - past ETA: running sessions whose stated ETA passed;
/// - just finished: open Finished items; ready for you: command and file items, Later ones included (both from the
///   Ready list);
/// - warnings: active warnings; dashboards: followed sessions with one.
///
/// No session text: counts and a clock time only. Pure.
struct CodeSummaryLine: Equatable, Sendable {
    /// A run of words with its look.
    struct Run: Equatable, Sendable {
        enum Tone: Equatable, Sendable {
            /// Ordinary words.
            case plain
            /// A count or the clock (semibold).
            case number
            /// Past ETA and warnings (orange).
            case attention
            /// The dashboards button (pink).
            case dashboard
        }

        var text: String
        var tone: Tone
    }

    /// One part of the line; the dashboards part is the button.
    struct Part: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case running, justFinished, ready, warnings, dashboards }
        var kind: Kind
        var runs: [Run]
        var text: String { runs.map(\.text).joined() }
    }

    /// The counts it was made from.
    var running = 0
    var nextDone: Date?
    var pastETA = 0
    var justFinished = 0
    var ready = 0
    var warnings = 0
    var dashboards = 0
    var parts: [Part] = []

    /// All counts zero: the line is hidden.
    var isEmpty: Bool { parts.isEmpty }
    /// The whole line as plain words (VoiceOver, tests).
    var text: String { parts.map(\.text).joined(separator: " · ") }

    /// The line for the followed sessions. `readyItems` and `justFinished` are the Ready list's counts: command
    /// and file items with Later ones, and open Finished items; `justFinished` nil counts the snapshots' open marks.
    /// `warnings` nil counts the snapshots' warnings.
    static func make(sessions: [CodeSessionSnapshot], readyItems: Int, justFinished: Int? = nil, warnings: Int? = nil,
                     now: Date, clock: CodeClockFormat) -> CodeSummaryLine {
        var line = CodeSummaryLine()
        let running = sessions.filter(RunText.isRunning)
        line.running = running.count
        var candidates: [Date] = []
        for session in running {
            guard let eta = session.eta else { continue }
            let late = RunText.isLate(session, now: now)
            if late { line.pastETA += 1 }
            switch eta.kind {
            case .stated:
                if !late { candidates.append(eta.at) } else if let estimate = eta.estimateAt { candidates.append(estimate) }
            case .estimate:
                candidates.append(eta.at)
            }
        }
        line.nextDone = candidates.filter { $0 >= now }.min()
        let openFinished = sessions.filter { ($0.finished?.isOpen ?? false) && ($0.finished?.hasItem ?? false) }.count
        line.justFinished = max(0, justFinished ?? openFinished)
        line.ready = max(0, readyItems)
        line.warnings = max(0, warnings ?? sessions.reduce(0) { $0 + $1.warnings.count })
        line.dashboards = sessions.filter { $0.dashboard != nil }.count

        if line.running > 0 {
            var runs = [Run(text: "\(line.running)", tone: .number), Run(text: " running", tone: .plain)]
            if let next = line.nextDone {
                runs += [Run(text: " · next done ≈ ", tone: .plain), Run(text: clock.string(next), tone: .number)]
            }
            if line.pastETA > 0 { runs.append(Run(text: " · \(line.pastETA) past ETA", tone: .attention)) }
            line.parts.append(Part(kind: .running, runs: runs))
        }
        if line.justFinished > 0 {
            line.parts.append(Part(kind: .justFinished, runs: [Run(text: "\(line.justFinished)", tone: .number),
                                                               Run(text: " just finished", tone: .plain)]))
        }
        if line.ready > 0 {
            line.parts.append(Part(kind: .ready, runs: [Run(text: "\(line.ready)", tone: .number),
                                                        Run(text: " ready for you", tone: .plain)]))
        }
        if line.warnings > 0 {
            line.parts.append(Part(kind: .warnings, runs: [
                Run(text: "\(line.warnings) warning\(line.warnings == 1 ? "" : "s")", tone: .attention),
            ]))
        }
        if line.dashboards > 0 {
            line.parts.append(Part(kind: .dashboards, runs: [
                Run(text: "▦ \(line.dashboards) dashboard\(line.dashboards == 1 ? "" : "s")", tone: .dashboard),
            ]))
        }
        return line
    }
}
