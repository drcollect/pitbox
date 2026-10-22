import Darwin
import Foundation
import PitboxKit

/// Runs the registered derivers for the engine's worker (the hook of `CodeDerive.swift`): it builds each followed
/// session's digest, marks tool_uses that forks copied, runs the per-session derivers in order (reusing their last
/// output while nothing it came from changed and no deadline passed), then the cross-session ones, and logs passes over
/// `CodeTuning.deriveBudget`. Used on the worker's queue only (a utility-priority background queue, never the main
/// thread): the budget is a soft target, so a slow pass is only logged, at most once per slowest deriver per
/// `budgetLogInterval`, with how many passes (of any session, or cross-session) went over since that deriver's last
/// line.
final class CodeDeriveRunner {
    /// One session as the parse built it in this publication, with its digest when that was read.
    struct Session {
        var id: String
        var snapshot: CodeSessionSnapshot
        var digest: CodeTurnDigest?
        var digestVersion: Int
    }

    /// What one session's fields were derived from.
    private struct Key: Equatable {
        var digestVersion: Int
        var memoryVersion: Int
        var settingsVersion: Int
        var copied: Set<String>
        var snapshot: CodeSessionSnapshot
    }

    private struct Derived {
        var key: Key
        var fields: CodeDerivedFields
        var nextDeadline: Date?
    }

    private(set) var derivers: [any CodeSessionDeriver] = []
    private(set) var crossDerivers: [any CodeCrossSessionDeriver] = []
    private var derived: [String: Derived] = [:]
    /// Built digests, reused while the record's digest version and its copied ids stay the same.
    private var digests: [String: (version: Int, copied: Set<String>, digest: CodeTurnDigest?)] = [:]
    /// Over-budget passes per slowest deriver (its log label) since its last line.
    private struct BudgetNote {
        var loggedAt: TimeInterval
        var passes = 0
        var slowestMS = 0
    }

    /// One budget line per slowest deriver at most this often (seconds).
    static let budgetLogInterval: TimeInterval = 600

    private var budgetNotes: [String: BudgetNote] = [:]
    /// Seconds on a monotonic clock (pass timing and the log interval), and this thread's CPU time in seconds.
    private let clock: () -> TimeInterval
    private let threadCPUTime: () -> TimeInterval

    /// A runner timing passes with `clock` and `threadCPUTime` (tests inject both).
    init(clock: @escaping () -> TimeInterval = MonotonicClock.now,
         threadCPUTime: @escaping () -> TimeInterval = CodeDeriveRunner.currentThreadCPUTime) {
        self.clock = clock
        self.threadCPUTime = threadCPUTime
    }

    var isEmpty: Bool { derivers.isEmpty && crossDerivers.isEmpty }
    var count: Int { derivers.count + crossDerivers.count }

    /// Replaces the derivers; the old ones first forget every session in `sessions`.
    func replace(with set: CodeDeriverSet, leaving sessions: [String]) {
        for id in sessions { leave(id) }
        derivers = set.orderedPerSession
        crossDerivers = set.orderedCrossSession
        forgetCaches()
    }

    /// Everything is derived again at the next publication.
    func forgetCaches() {
        derived = [:]
        digests = [:]
    }

    /// The session is no longer read: its fields and digest go and every deriver drops what it keeps for it.
    func leave(_ id: String) {
        derived[id] = nil
        digests[id] = nil
        for deriver in derivers { deriver.sessionLeft(id) }
        for deriver in crossDerivers { deriver.sessionLeft(id) }
    }

    /// Tool_use ids that more than one of `records` holds (fully read ones only): a fork's copy of its parent's
    /// history, marked `isCopied` in every session that holds them. Keyed by session id.
    func sharedToolUseIDs(_ records: [SessionRecord]) -> [String: Set<String>] {
        var first: [String: String] = [:]
        var shared = Set<String>()
        var idsBySession: [String: Set<String>] = [:]
        for record in records where record.fullyRead && record.transcriptReadable {
            let ids = record.tracker.digest.toolUseIDs
            idsBySession[record.id] = ids
            for toolID in ids {
                if let holder = first[toolID] {
                    if holder != record.id { shared.insert(toolID) }
                } else {
                    first[toolID] = record.id
                }
            }
        }
        guard !shared.isEmpty else { return [:] }
        var out: [String: Set<String>] = [:]
        for (id, ids) in idsBySession {
            let mine = ids.intersection(shared)
            if !mine.isEmpty { out[id] = mine }
        }
        return out
    }

    /// The record's digest, built again only when its version or its copied ids changed.
    func digest(of record: SessionRecord, copied: Set<String>) -> CodeTurnDigest? {
        if let cached = digests[record.id], cached.version == record.digestVersion, cached.copied == copied {
            return cached.digest
        }
        let digest = record.digest(copied: copied)
        digests[record.id] = (record.digestVersion, copied, digest)
        return digest
    }

    /// One session's fields: the last ones while nothing they came from changed and no deadline passed, else every
    /// per-session deriver in order.
    func derive(_ record: SessionRecord, snapshot: CodeSessionSnapshot, digest: CodeTurnDigest, copied: Set<String>,
                memoryVersion: Int, settingsVersion: Int, memory: CodeMemoryStore, settings: CodeSettings, owner: uid_t,
                now: Date) -> CodeDerivedFields {
        guard !derivers.isEmpty else { return CodeDerivedFields() }
        let key = Key(digestVersion: record.digestVersion, memoryVersion: memoryVersion, settingsVersion: settingsVersion,
                      copied: copied, snapshot: snapshot)
        if let cached = derived[record.id], cached.key == key, cached.nextDeadline.map({ $0 > now }) ?? true {
            return cached.fields
        }
        let input = CodeDeriveInput(snapshot: snapshot, digest: digest, digestVersion: record.digestVersion, now: now,
                                    memory: memory, settings: settings, transcript: record.transcript,
                                    sessionFile: record.sessionFile, owner: owner)
        var fields = CodeDerivedFields()
        let started = clock(), startedCPU = threadCPUTime()
        var slowest = (label: "", seconds: 0.0)
        for deriver in derivers {
            let begin = clock()
            deriver.derive(input, into: &fields)
            let spent = clock() - begin
            if spent > slowest.seconds { slowest = (deriver.label, spent) }
        }
        noteBudget(clock() - started, cpu: threadCPUTime() - startedCPU, slowest: slowest.label, pass: "session")
        derived[record.id] = Derived(key: key, fields: fields, nextDeadline: fields.deadlines.filter { $0 > now }.min())
        return fields
    }

    /// The cross-session derivers in order, each over every session with a digest, as the ones before it left them.
    func crossDerive(_ sessions: [Session], fields: inout [String: CodeDerivedFields], context: CodeCrossDeriveContext) {
        guard !crossDerivers.isEmpty else { return }
        let started = clock(), startedCPU = threadCPUTime()
        var slowest = (label: "", seconds: 0.0)
        var count = 0
        for deriver in crossDerivers {
            let inputs = sessions.compactMap { session -> CodeCrossSessionInput? in
                guard let digest = session.digest else { return nil }
                let current = fields[session.id] ?? CodeDerivedFields()
                return CodeCrossSessionInput(snapshot: current.applied(to: session.snapshot), digest: digest,
                                             digestVersion: session.digestVersion)
            }
            guard !inputs.isEmpty else { return }
            count = inputs.count
            let begin = clock()
            deriver.derive(inputs, context: context, into: &fields)
            let spent = clock() - begin
            if spent > slowest.seconds { slowest = (deriver.label, spent) }
        }
        noteBudget(clock() - started, cpu: threadCPUTime() - startedCPU, slowest: slowest.label,
                   pass: "cross sessions=\(count)")
    }

    /// A pass that took longer than `CodeTuning.deriveBudget` (wall time): one line at most once per
    /// `budgetLogInterval` per slowest deriver, `derive over budget slowest=earlier-offers passes=14 max_ms=69
    /// last=session ms=60 cpu_ms=4`. `passes` and `max_ms` count every over-budget pass in which that deriver was the
    /// slowest since its previous line, this one included, whichever session it ran for (so no session is named);
    /// `last` is the kind of the pass that wrote the line (`session`, or `cross sessions=3` for the cross-session pass
    /// over 3 sessions), and `ms` and `cpu_ms` its wall and thread CPU time (a wall time far above the CPU time is
    /// waiting: the utility queue preempted, memory paged in). Nothing else changes.
    private func noteBudget(_ seconds: TimeInterval, cpu: TimeInterval, slowest: String, pass: String) {
        guard seconds > CodeTuning.deriveBudget else { return }
        let label = Self.logLabel(slowest)
        let ms = Self.milliseconds(seconds)
        var note = budgetNotes[label] ?? BudgetNote(loggedAt: -TimeInterval.infinity)
        note.passes += 1
        note.slowestMS = max(note.slowestMS, ms)
        let now = clock()
        guard now - note.loggedAt >= Self.budgetLogInterval else {
            budgetNotes[label] = note
            return
        }
        CodeLog.warn("derive over budget slowest=\(label) passes=\(note.passes) max_ms=\(note.slowestMS) "
            + "last=\(pass) ms=\(ms) cpu_ms=\(Self.milliseconds(cpu))")
        budgetNotes[label] = BudgetNote(loggedAt: now)
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        seconds.isFinite ? Int(max(0, min(seconds * 1000, 1e9)).rounded()) : 0
    }

    /// The calling thread's CPU time (user and system) in seconds.
    static func currentThreadCPUTime() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    /// A deriver's label as log text: lowercase letters, digits and `-` only, at most 32.
    static func logLabel(_ label: String) -> String {
        let kept = label.lowercased().unicodeScalars.filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
        let text = String(String.UnicodeScalarView(kept.prefix(32)))
        return text.isEmpty ? "deriver" : text
    }
}
