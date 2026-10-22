import Foundation
import PitboxKit

/// The running-and-ETA deriver, order `CodeDeriveOrder.work` (100, first): it fills `workStartedAt`, `progress` and
/// `eta`.
///
/// - **The work** (`WorkClock`): the latest turn of human or peer origin and every turn after it; the current
///   turn when that one is over 12 hours old or missing. A start the digest lost to its 2 MB / 200-turn bound is
///   remembered in memory while the session stays followed.
/// - **Progress** (`BackgroundTasks`): the work's Agent and Workflow tasks against their notices, "4 of 6 agents
///   done"; tasks still running when the work began count too, so a question typed while agents run keeps their
///   count. Without background work, the turn's todos while it runs. The work's tasks are kept in `code-memory.json`
///   (key `background`: hashes and times) so they survive a restart and outlive the tail; a task without its notice
///   after 6 hours is dropped. `pendingBetweenTurns` says tasks run while the turn is not working, because it ended or
///   went quiet ("Background · …").
/// - **ETA**: the newest statement in the work's assistant texts (`ETAParser`, `ETAClock`), kept in the
///   store (key `eta`) until a newer statement, the end of the work, or 2 hours after it; else the estimate
///   (`ETAEstimator`) while running. A stated ETA is late once passed while the session still runs. After the work
///   ends a stated ETA stays in `eta` (never late) until the next work or `at` + 2 h, so the finish detector can record
///   "ETA was"; the block shows ETAs only through `RunText`, which shows them only while running.
/// - **Deadlines:** the late moment, the drop at `at` + 2 h, once a minute while an estimate applies, the next task
///   expiry, and the moment the work's start turns 12 hours old.
///
/// Logs: `eta stated session=#3 minutes=14 zone=utc` when a new statement is adopted (labels and numbers only).
final class ProgressDeriver: CodeSessionDeriver {
    let label = "progress"
    let order = CodeDeriveOrder.work

    /// This Mac's zone (zone-less clocks of local sessions); injected by tests.
    private let localZone: @Sendable () -> TimeZone
    private var sessions: [String: SessionState] = [:]

    private struct SessionState {
        var anchor: CodeWork.Anchor?
        var texts = ETATextCache()
        var logged: StatedETA?
    }

    /// A deriver reading zone-less local clocks in `localZone()` (this Mac's zone by default).
    init(localZone: @escaping @Sendable () -> TimeZone = { TimeZone.autoupdatingCurrent }) {
        self.localZone = localZone
    }

    func derive(_ input: CodeDeriveInput, into fields: inout CodeDerivedFields) {
        let id = input.sessionID
        var state = sessions[id] ?? SessionState()
        defer { sessions[id] = state }
        let now = input.now
        guard let work = WorkClock.work(in: input.digest, now: now, remembered: state.anchor) else { return }
        if let anchor = work.anchor { state.anchor = anchor }
        fields.workStartedAt = work.startedAt

        // Background tasks.
        let snapshot = input.snapshot
        let stored: [BackgroundTaskRecord] = input.memory.read(.background, session: id) ?? []
        let tasks = BackgroundTasks.merge(BackgroundTasks.fromDigest(input.digest), records: stored, digest: input.digest)
        let tally = BackgroundTasks.tally(tasks, work: work, now: now)
        let turnUnfinished = Self.turnUnfinished(snapshot.state)
        let running = Self.isRunning(snapshot.state) || tally.pending > 0
        let workEnded = tally.pending == 0 && !turnUnfinished && (input.digest.latestTurn?.isFinished ?? true)
        let records = workEnded ? [] : BackgroundTasks.records(tally.counted)
        if records != stored { input.memory.write(.background, session: id, value: records.isEmpty ? nil : records) }

        var progress: CodeProgress?
        if tally.total > 0 {
            // "Between turns": tasks run while the turn is not working (ended, or quiet); the bucket header counts
            // this as running too.
            let between = tally.pending > 0 && !Self.isRunning(snapshot.state)
            progress = CodeProgress(source: .backgroundTasks, unit: tally.unit, done: tally.done, total: tally.total,
                                    since: tally.since, pendingBetweenTurns: between,
                                    workflowAgentsDone: tally.workflowAgentsDone,
                                    workflowAgentCount: tally.workflowAgentCount, expiredTasks: tally.expired)
        } else if tally.expired > 0 {
            // Only tasks whose notice never came are left: no bar, but the finish detector learns of them.
            progress = CodeProgress(source: .backgroundTasks, unit: tally.unit, done: 0, total: 0, since: tally.since,
                                    expiredTasks: tally.expired)
        } else if turnUnfinished, let todos = snapshot.todos, todos.total > 0 {
            progress = CodeProgress(source: .todos, unit: .todos, done: todos.done, total: todos.total,
                                    since: Self.firstPlanCall(in: input.digest) ?? work.startedAt)
        }
        fields.progress = progress

        // The stated ETA, from the work's texts, else what the store kept for this work.
        let (zone, source) = defaultZone(snapshot, settings: input.settings)
        let context = ETAParser.Context(headline: snapshot.headline, nickname: snapshot.nickname)
        let found = StatedETAFinder.newest(in: input.digest, work: work, context: context, defaultZone: zone,
                                           defaultSource: source, cache: &state.texts)
        let storedETA: ETARecord? = input.memory.read(.eta, session: id)
        var stated = found
        if stated == nil, let record = storedETA, Self.belongs(record, to: work) {
            stated = StatedETA(at: record.at, statedAt: record.statedAt ?? record.at, zone: localZone(), source: .local,
                               replyUUID: record.reply)
        }
        if let current = stated, current.at.addingTimeInterval(CodeTuning.etaKeepAfter) < now { stated = nil }
        if workEnded || stated == nil {
            if storedETA != nil { input.memory.write(.eta, session: id, value: nil as ETARecord?) }
        } else if let found, found.at.addingTimeInterval(CodeTuning.etaKeepAfter) >= now {
            let record = ETARecord(at: found.at, statedAt: found.statedAt, reply: found.replyUUID)
            if record != storedETA { input.memory.write(.eta, session: id, value: record) }
        }
        if let found, found != state.logged {
            state.logged = found
            let minutes = Int((found.at.timeIntervalSince(found.statedAt) / 60).rounded())
            CodeLog.info("eta stated session=#\(snapshot.index) minutes=\(minutes) zone=\(found.source.rawValue)")
        }

        // The estimate while running, from background work or todos.
        var estimate: ETAEstimator.Estimate?
        if running, let progress, let since = progress.since {
            estimate = ETAEstimator.estimate(done: progress.done, total: progress.total, since: since, now: now)
        }
        if let stated {
            fields.eta = CodeETA(kind: .stated, at: stated.at, statedZone: Self.zoneName(stated.zone),
                                 statedAt: stated.statedAt, replyUUID: stated.replyUUID, isLate: running && now > stated.at,
                                 estimateAt: estimate?.at)
        } else if let estimate {
            fields.eta = CodeETA(kind: .estimate, at: estimate.at, minutesLeft: estimate.minutesLeft)
        }

        // When these fields change by themselves.
        if let stated {
            if running, stated.at > now { fields.deadlines.append(stated.at.addingTimeInterval(0.5)) }
            fields.deadlines.append(stated.at.addingTimeInterval(CodeTuning.etaKeepAfter + 1))
        }
        if running, progress != nil { fields.deadlines.append(now.addingTimeInterval(60)) }
        if let expiry = tally.nextExpiry { fields.deadlines.append(expiry.addingTimeInterval(1)) }
        if work.basis == .asked, let start = work.startedAt {
            fields.deadlines.append(start.addingTimeInterval(CodeTuning.workMaxAge + 1))
        }
    }

    func sessionLeft(_ sessionID: String) {
        sessions[sessionID] = nil
    }

    // MARK: Rules

    /// Working or maybe needs you: the turn runs ("quiet · turn not finished" is not running).
    static func isRunning(_ state: CodeSessionState) -> Bool { state == .working || state == .maybeNeedsYou }

    /// The turn itself has not finished (quiet ones included).
    static func turnUnfinished(_ state: CodeSessionState) -> Bool {
        state == .working || state == .maybeNeedsYou || state == .quietUnfinished
    }

    /// A stored ETA belongs to this work when it was stated after the work's start; when the start is only a fallback
    /// (the asking turn is not in the digest), the store's ETA stands until it expires.
    static func belongs(_ record: ETARecord, to work: CodeWork) -> Bool {
        guard work.basis == .asked, let start = work.startedAt else { return true }
        return (record.statedAt ?? record.at) >= start
    }

    /// The zone's name for `CodeETA.statedZone`: "UTC" for UTC under any of its names (Foundation calls it "GMT").
    static func zoneName(_ zone: TimeZone) -> String {
        utcNames.contains(zone.identifier) ? "UTC" : zone.identifier
    }

    private static let utcNames: Set<String> = ["UTC", "GMT", "Etc/UTC", "Etc/GMT", "Etc/Universal", "Universal", "Zulu"]

    /// The latest turn's first plan call (`mcp__ccd_turn__update_plan` or TodoWrite): the todos' start.
    static func firstPlanCall(in digest: CodeTurnDigest) -> Date? {
        guard let turn = digest.latestTurn else { return nil }
        for case .toolUse(let tool) in turn.items
            where tool.name == StepWords.updatePlan || tool.name == StepWords.todoWrite {
            return tool.at
        }
        return nil
    }

    /// The zone zone-less clocks are read in: SSH sessions `serverTimeZones[alias]` (UTC when not listed),
    /// local ones this Mac's.
    private func defaultZone(_ snapshot: CodeSessionSnapshot, settings: CodeSettings) -> (TimeZone, StatedETA.ZoneSource) {
        if snapshot.place == .ssh || (snapshot.place == .unknown && snapshot.sshHost != nil) {
            return (settings.serverTimeZone(for: snapshot.sshHost ?? ""), .server)
        }
        return (localZone(), .local)
    }
}

public extension CodeDeriverSet {
    /// Running and ETA: the work, background progress, the stated ETA and the estimate (`workStartedAt`,
    /// `progress`, `eta`). Register it with the other derivers' sets:
    /// `engine.register(.progress + … , memory: memory)`.
    static var progress: CodeDeriverSet { CodeDeriverSet(perSession: [ProgressDeriver()]) }
}
