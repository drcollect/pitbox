import Foundation
import PitboxKit

public extension CodeDeriverSet {
    /// Finished: the finished mark once per piece of work, and the unread dot across sessions. Register it with the
    /// engine beside the other derivers' sets; it reads the work and progress that `.progress` derives when that runs.
    static var finished: CodeDeriverSet {
        CodeDeriverSet(perSession: [FinishedDeriver()], crossSession: [UnreadDeriver()])
    }
}

/// One finished record in `code-memory.json` (key `finished`): uuids, times and flags only.
struct CodeFinishedRecord: Codable, Equatable, Sendable {
    /// The final reply's uuid.
    var reply: String
    /// When the work finished: the reply's last assistant entry, else when the app saw it (expiry: when the last
    /// task was given up).
    var at: Date
    var ranSeconds: Double
    /// The Finished item stands: not OK'd, no new message of the user's since.
    var open: Bool
    /// Ended because a background task never reported back.
    var expired: Bool
    /// The work made a Finished item (long enough, ended in Review ready, Done or Done · no summary).
    var item: Bool
    /// No chime and no voice for it.
    var silent: Bool
    /// The ETA the work had stated.
    var etaWas: Date?

    init(reply: String, at: Date, ranSeconds: Double, open: Bool, expired: Bool, item: Bool, silent: Bool, etaWas: Date?) {
        self.reply = reply; self.at = at; self.ranSeconds = ranSeconds; self.open = open; self.expired = expired
        self.item = item; self.silent = silent; self.etaWas = etaWas
    }

    /// Tolerant: the optional fields default, so one record of another shape never fails the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = try c.decode(String.self, forKey: .reply)
        at = try c.decode(Date.self, forKey: .at)
        ranSeconds = (try? c.decodeIfPresent(Double.self, forKey: .ranSeconds)) ?? 0
        open = (try? c.decodeIfPresent(Bool.self, forKey: .open)) ?? false
        expired = (try? c.decodeIfPresent(Bool.self, forKey: .expired)) ?? false
        item = (try? c.decodeIfPresent(Bool.self, forKey: .item)) ?? open
        silent = (try? c.decodeIfPresent(Bool.self, forKey: .silent)) ?? true
        etaWas = try? c.decodeIfPresent(Date.self, forKey: .etaWas)
    }
}

/// Finish detection (order 500), once per piece of work. Finished = the latest turn finished by the session-state rule
/// ("the turn is finished": `replyUUID` set) and none of the work's background tasks pending (`ProgressDeriver`'s
/// `progress`, order 100, which also counts the tasks it gave up in `expiredTasks`). A fleet session that
/// launches agents, ends its turn and later runs one turn per notice is finished once, after the last notice's turn: a
/// notice that arrives after a reply (enqueued before its own turn starts) holds the finish for `noticeTurnWait`.
///
/// - Counted once, keyed by the final reply's uuid: a record goes to `CodeMemoryStore` (`finished`), so a restart neither
///   repeats nor loses it. The record waits until the state settles (the 10 s summary grace).
/// - A Finished item (`hasItem`) only for work that ran at least `finishedMinMinutes` and ended in Review ready,
///   Done or Done · no summary; Needs you and Problem have their own signals. Whether the user was looking at it when
///   it ended is decided on the main thread (`CodeFinishAlerts`), which has the window facts.
/// - Silent (no chime, no voice): work that ended by expiry (`ProgressDeriver` dropped a task after `backgroundMaxAge`
///   without its notice, `CodeProgress.expiredTasks`: "a background task never reported back"), work this run never
///   saw running (finished before the app started or before the session was followed; within `finishedSilentAtStart`
///   it still gets its item, older work nothing), and every record from an earlier run.
/// - Closed by a new message of the user's after it; gone after 24 hours (the store prunes the record).
final class FinishedDeriver: CodeSessionDeriver {
    let label = "finished"
    let order = CodeDeriveOrder.finished

    /// How long a notice that came in after the reply holds the finish while its own turn starts (notices are queued,
    /// then delivered as a turn).
    static let noticeTurnWait: TimeInterval = 60
    /// States in which a finished turn has settled (the summary grace is over).
    static let settledStates: Set<CodeSessionState> = [.reviewReady, .done, .doneNoSummary, .needsYou, .problem]
    /// States whose finished work makes an item.
    static let itemStates: Set<CodeSessionState> = [.reviewReady, .done, .doneNoSummary]

    private struct SessionState {
        /// This run saw the work unfinished: a finish after it is live.
        var sawWorking = false
        /// The last stated ETA of the running work.
        var etaWas: Date?
        /// Records this run wrote for live work (only these may chime).
        var created: Set<String> = []
        /// Work counted without a record the store would keep (finished more than 24 hours ago).
        var counted: Set<String> = []
    }

    private var sessions: [String: SessionState] = [:]

    func sessionLeft(_ sessionID: String) { sessions[sessionID] = nil }

    func derive(_ input: CodeDeriveInput, into fields: inout CodeDerivedFields) {
        let id = input.sessionID
        let snapshot = input.snapshot
        let now = input.now
        var state = sessions[id] ?? SessionState()
        defer { sessions[id] = state }
        var records: [CodeFinishedRecord] = input.memory.read(.finished, session: id) ?? []
        if let eta = fields.eta, eta.kind == .stated { state.etaWas = eta.at }
        let pending = fields.progress.map { $0.source == .backgroundTasks ? $0.pending : 0 } ?? 0

        // A new message of the user's after the finish closes its item.
        if let index = records.indices.last, records[index].open,
           input.digest.turns.contains(where: { $0.origin == .human && ($0.startedAt.map { $0 > records[index].at } ?? false) }) {
            records[index].open = false
            input.memory.write(.finished, session: id, value: records)
        }

        let latest = input.digest.latestTurn
        let reply = snapshot.replyUUID
        let turnFinished = latest?.isFinished == true && reply != nil && latest?.replyUUID == reply
        if !turnFinished || pending > 0 {
            state.sawWorking = true
            output(records, state: state, now: now, into: &fields)
            return
        }
        guard let reply, let latest, !records.contains(where: { $0.reply == reply }), !state.counted.contains(reply) else {
            output(records, state: state, now: now, into: &fields)
            return
        }
        if let noticeAt = Self.noticeAfterReply(latest), now < noticeAt.addingTimeInterval(Self.noticeTurnWait) {
            fields.deadlines.append(noticeAt.addingTimeInterval(Self.noticeTurnWait))
            output(records, state: state, now: now, into: &fields)
            return
        }
        guard Self.settledStates.contains(snapshot.state) else {
            output(records, state: state, now: now, into: &fields)
            return
        }

        // The progress deriver gave up a task of this work whose notice never came: the work ended then, not at its
        // last reply. Its tasks were all launched by that reply, so the drop came at most `backgroundMaxAge` after it
        // (a restart long after it finds the work old, not new).
        let expired = (fields.progress?.expiredTasks ?? 0) > 0
        let replied = latest.finishedAt ?? now
        let at = expired ? min(now, replied.addingTimeInterval(CodeTuning.backgroundMaxAge)) : replied
        let start = fields.workStartedAt ?? Self.workStart(input.digest, now: now) ?? at
        let ran = max(0, at.timeIntervalSince(start))
        let live = state.sawWorking
        let record: CodeFinishedRecord
        if !live, now.timeIntervalSince(at) > CodeTuning.finishedSilentAtStart {
            // Older work seen for the first time: counted, nothing shown.
            record = CodeFinishedRecord(reply: reply, at: at, ranSeconds: ran, open: false, expired: expired, item: false,
                                        silent: true, etaWas: nil)
        } else {
            let minimum = TimeInterval(input.settings.finishedMinMinutes) * 60
            let item = Self.itemStates.contains(snapshot.state) && ran >= minimum
            record = CodeFinishedRecord(reply: reply, at: at, ranSeconds: ran, open: item, expired: expired, item: item,
                                        silent: !live || expired, etaWas: state.etaWas)
            if live, !expired { state.created.insert(reply) }
            CodeLog.info("finished session=#\(snapshot.index) ran_s=\(Int(ran.rounded())) item=\(item ? "yes" : "no") "
                + "silent=\(record.silent ? "yes" : "no")\(expired ? " expired=yes" : "")")
        }
        // The store keeps a record until `finishedRecordLife` after its `at` and drops an older one at once
        // (`CodeMemorySchema`): work that finished longer ago (seen first now, typically at start) is never written,
        // only remembered here so it is never counted again. Writing it anyway was refused as `reason=shape`.
        if at.addingTimeInterval(CodeTuning.finishedRecordLife) >= now {
            records.append(record)
            input.memory.write(.finished, session: id, value: records)
        }
        if now.timeIntervalSince(at) >= CodeTuning.finishedRecordLife { state.counted.insert(reply) }
        state.sawWorking = false
        state.etaWas = nil
        output(records, state: state, now: now, into: &fields)
    }

    /// The newest record as the snapshot's mark, and the moment it expires.
    private func output(_ records: [CodeFinishedRecord], state: SessionState, now: Date, into fields: inout CodeDerivedFields) {
        guard let record = records.last(where: { now.timeIntervalSince($0.at) < CodeTuning.finishedRecordLife }) else {
            fields.finished = nil
            return
        }
        fields.finished = CodeFinishedMark(replyUUID: record.reply, at: record.at, ranSeconds: record.ranSeconds,
                                           isOpen: record.open, hasItem: record.item,
                                           silent: record.silent || !state.created.contains(record.reply),
                                           expired: record.expired, etaWas: record.etaWas)
        fields.deadlines.append(record.at.addingTimeInterval(CodeTuning.finishedRecordLife))
    }

    /// When a notice came in after the turn's final reply (its own turn has not started yet).
    static func noticeAfterReply(_ turn: CodeTurnDigest.Turn) -> Date? {
        var latest: Date?
        for item in turn.items.reversed() {
            switch item {
            case .notice(let notice):
                if let at = notice.at, latest.map({ at > $0 }) ?? true { latest = at }
            case .text, .toolUse, .toolResult:
                return latest
            }
        }
        return latest
    }

    /// The work's start without the progress deriver: the latest turn of the user's or another session's, the current
    /// turn when that is more than `workMaxAge` old or missing.
    static func workStart(_ digest: CodeTurnDigest, now: Date) -> Date? {
        if let start = digest.latestHumanOrPeerTurn?.startedAt, now.timeIntervalSince(start) <= CodeTuning.workMaxAge {
            return start
        }
        return digest.latestTurn?.startedAt
    }
}

/// The finished records from the main thread: OK and Open window close the item.
enum CodeFinishedRecords {
    /// Closes the open item of `reply` (the Finished card's OK, Open window, or a pop-out finishing under the user's eyes).
    static func close(_ reply: String, session: String, memory: CodeMemoryStore) {
        guard var records: [CodeFinishedRecord] = memory.read(.finished, session: session),
              let index = records.lastIndex(where: { $0.reply == reply }), records[index].open else { return }
        records[index].open = false
        memory.write(.finished, session: session, value: records)
    }
}
