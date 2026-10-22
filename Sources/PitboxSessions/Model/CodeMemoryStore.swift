import Darwin
import Foundation
import PitboxKit

/// The kinds of record `code-memory.json` holds per session. Each belongs to one feature; their shapes are
/// `CodeMemorySchema`'s.
public enum CodeMemoryKey: String, Sendable, CaseIterable {
    /// When the user last looked (`seenAt`, the unread dot).
    case seen
    /// Finished records `{reply, at, ranSeconds, open, expired}` (Finished).
    case finished
    /// Ready item states `"later"` or `"dismissed"` with their time, by item key (Ready for you).
    case ready
    /// The stated ETA `{at, statedAt, reply}` (Running and ETA).
    case eta
    /// Pending background tasks `{task: hash16, kind, launchedAt}` (Running and ETA).
    case background
    /// The dashboard `{handle, firstSeen, lastBuilderCallAt}` (Dashboards).
    case dashboard
    /// The one-time scan's mark `{at, bytes, found}` (Dashboards).
    case dashboardScan
    /// Silenced warnings `{rule, until}` (Warnings).
    case silenced
}

/// One store for `code-memory.json`, so the features never write one file several ways. It keeps
/// only session ids, entry uuids, hashes, times, counts and dashboard handles: no titles, headlines, TL;DRs, commands,
/// paths, URLs or file names (`CodeMemorySchema` refuses longer strings).
///
/// - **Writer:** changes coalesce and are written at most once per second on the store's own queue: a temporary file
///   created 0600, `fsync`, rename. A file over 768 KB is refused (`[code] memory write refused size=…`) and the last
///   good file stays.
/// - **Reader:** the careful read of the session files (no link followed, a regular file of the user's, at most 1 MB,
///   nesting at most 16, a duplicated key fails it); records that fail their shape are dropped one by one. A broken
///   file is renamed `code-memory.json.corrupt`, logged with its size and the reason only, and the store starts empty.
/// - **Limits** per session: 64 Ready keys, 16 finished records, 64 pending tasks (the oldest dropped), one ETA, one
///   dashboard, one scan mark, 16 silenced warnings; at most 200 sessions (the least recently written go). Session ids
///   must match `^local_[A-Za-z0-9-]{1,64}$`, uuids `^[0-9A-Za-z-]{1,64}$`.
/// - **Pruning** when loaded and whenever a record is written or read: sessions without a write for 14 days, finished
///   records older than 24 hours, Ready states older than 24 hours (their reply's offers are gone), background tasks
///   older than 6 hours, ETAs 2 hours after their time, silenced warnings past `until`; sessions archived or gone when
///   the engine says so (`pruneSessions`).
///
/// Thread-safe: one lock, held briefly; file work happens outside it. Dates in records are written as ISO 8601 strings
/// with milliseconds; the features' record types use `Date` and plain `Codable`.
public final class CodeMemoryStore: @unchecked Sendable {
    private struct SessionMemory: Equatable {
        var lastActivity: Date
        var records: [CodeMemoryKey: JSONValue]
    }

    private let url: URL
    private let owner: uid_t
    private let clock: @Sendable () -> Date
    private let writeInterval: TimeInterval
    private let writeMax: Int
    private let queue = DispatchQueue(label: "pitbox.code.memory", qos: .utility)
    private let lock = NSLock()

    // Under `lock`.
    private var loaded = false
    private var sessions: [String: SessionMemory] = [:]
    private var dirty = false
    private var writeScheduled = false
    private var observers: [UUID: @Sendable (String) -> Void] = [:]
    private var writes = 0
    private var lastRefusalLogged = -TimeInterval.infinity

    /// A store for `url` (the user's app-support folder by default). Nothing is read before the first use.
    public convenience init(url: URL = Paths.appSupport.appendingPathComponent("code-memory.json")) {
        self.init(url: url, owner: getuid(), clock: { Date() }, writeInterval: CodeTuning.memoryWriteInterval,
                  writeMax: CodeTuning.memoryWriteMax)
    }

    /// Tests: an injected owner (a file of anyone else reads as broken), clock, write interval and size limit.
    init(url: URL, owner: uid_t, clock: @escaping @Sendable () -> Date, writeInterval: TimeInterval, writeMax: Int) {
        self.url = url
        self.owner = owner
        self.clock = clock
        self.writeInterval = writeInterval
        self.writeMax = writeMax
    }

    // MARK: Records

    /// The record of `key` for `session`, decoded as `T`; nil when absent, expired or not of that type.
    public func read<T: Decodable>(_ key: CodeMemoryKey, session: String) -> T? {
        guard CodeIDs.isSessionID(session) else { return nil }
        let now = clock()
        let stored = lock.withLock { () -> JSONValue? in
            ensureLoaded(now: now)
            return sessions[session]?.records[key]
        }
        guard let stored, let value = CodeMemorySchema.clean(key, stored, session: session, now: now),
              let data = try? JSONSerialization.data(withJSONObject: value.foundation, options: [.fragmentsAllowed]) else {
            return nil
        }
        return try? Self.decoder.decode(T.self, from: data)
    }

    /// Sets the record of `key` for `session` (nil removes it). The value must fit `CodeMemorySchema`'s shape for
    /// `key`; what does not fit is dropped (a list or map keeps its valid parts), and a write that leaves nothing valid
    /// removes the record and logs `memory write refused key=… reason=shape` (`reason=expired` when every part has the
    /// right shape and is only past its life; one malformed element of a list or map makes it `shape`). Unchanged
    /// values write nothing.
    public func write<T: Encodable>(_ key: CodeMemoryKey, session: String, value: T?) {
        guard CodeIDs.isSessionID(session) else {
            CodeLog.warn("memory write refused key=\(key.rawValue) reason=session-id")
            return
        }
        let now = clock()
        var cleaned: JSONValue?
        if let value {
            guard let data = try? Self.encoder.encode(value),
                  let tree = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                CodeLog.warn("memory write refused key=\(key.rawValue) reason=encoding")
                return
            }
            let encoded = JSONValue(foundation: tree)
            cleaned = CodeMemorySchema.clean(key, encoded, session: session, now: now)
            if cleaned == nil {
                CodeLog.warn("memory write refused key=\(key.rawValue) reason=\(Self.refusal(key, encoded, session: session))")
            }
        }
        let changed = lock.withLock { () -> Bool in
            ensureLoaded(now: now)
            var memory = sessions[session] ?? SessionMemory(lastActivity: now, records: [:])
            guard memory.records[key] != cleaned else { return false }
            memory.records[key] = cleaned
            memory.lastActivity = now
            sessions[session] = memory.records.isEmpty ? nil : memory
            enforceSessionLimit(keeping: session)
            dirty = true
            return true
        }
        if changed { didChange([session]) }
    }

    /// Why a write of `value` left nothing valid: `expired` when it has parts and every one of them (each element of a
    /// list, each member of the Ready map, or the one record) has the right shape and is only past its life (it passes
    /// at the earliest time); `shape` otherwise, also for a list that mixes expired and malformed elements.
    static func refusal(_ key: CodeMemoryKey, _ value: JSONValue, session: String) -> String {
        let parts: [JSONValue]
        switch (key, value) {
        case (.finished, .array(let elements)), (.background, .array(let elements)), (.silenced, .array(let elements)):
            parts = elements.map { JSONValue.array([$0]) }
        case (.ready, .object(let members)):
            parts = members.map { JSONValue.object([$0.key: $0.value]) }
        default:
            parts = [value]
        }
        let fits = { (part: JSONValue) in CodeMemorySchema.clean(key, part, session: session, now: .distantPast) != nil }
        return !parts.isEmpty && parts.allSatisfy(fits) ? "expired" : "shape"
    }

    /// Removes everything kept for `session`.
    public func forget(session: String) {
        let removed = lock.withLock { () -> Bool in
            ensureLoaded(now: clock())
            guard sessions.removeValue(forKey: session) != nil else { return false }
            dirty = true
            return true
        }
        if removed { didChange([session]) }
    }

    /// Removes the sessions that are not in `existing` (gone from every copy's index) or are in `archived`. The engine
    /// calls it after a complete index build; an empty `existing` removes nothing (a failed listing).
    public func pruneSessions(existing: Set<String>, archived: Set<String>) {
        guard !existing.isEmpty else { return }
        let removed = lock.withLock { () -> [String] in
            ensureLoaded(now: clock())
            let gone = sessions.keys.filter { !existing.contains($0) || archived.contains($0) }
            for id in gone { sessions[id] = nil }
            if !gone.isEmpty { dirty = true }
            return gone
        }
        if !removed.isEmpty { didChange(removed) }
    }

    /// Writes pending changes now, on the caller's thread (tests, and app quit).
    public func flush() {
        queue.sync { writeNow() }
    }

    // MARK: For the engine and tests

    /// Calls `handler` (on the thread that made the change, outside the lock) with each session whose records changed.
    func addObserver(_ handler: @escaping @Sendable (String) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = handler }
        return token
    }

    func removeObserver(_ token: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: token) }
    }

    /// Tests: how many times the file was written.
    var writeCount: Int { lock.withLock { writes } }

    /// Tests: the sessions held now.
    var sessionIDs: Set<String> {
        lock.withLock {
            ensureLoaded(now: clock())
            return Set(sessions.keys)
        }
    }

    // MARK: Loading

    /// Under `lock`.
    private func ensureLoaded(now: Date) {
        guard !loaded else { return }
        loaded = true
        switch CodeStateFiles.readObject(at: url, owner: owner, maxBytes: CodeTuning.memoryReadMax) {
        case .failure(.missing):
            sessions = [:]
        case .failure(let failure):
            setAside(reason: failure.label)
        case .success(let root):
            guard root["version"]?.intValue == 1, case .object(let all)? = root["sessions"] else {
                setAside(reason: "shape")
                return
            }
            let cutoff = now.addingTimeInterval(-Double(CodeTuning.memoryPruneDays) * 86_400)
            var cleanedSomething = false
            for (id, value) in all {
                guard CodeIDs.isSessionID(id), case .object(let fields) = value else {
                    cleanedSomething = true
                    continue
                }
                let lastActivity = CodeMemorySchema.date(fields["lastActivity"]) ?? now
                guard lastActivity >= cutoff else {
                    cleanedSomething = true
                    continue
                }
                var records: [CodeMemoryKey: JSONValue] = [:]
                for key in CodeMemoryKey.allCases {
                    guard let raw = fields[key.rawValue] else { continue }
                    if let valid = CodeMemorySchema.clean(key, raw, session: id, now: now) { records[key] = valid }
                    if records[key] != raw { cleanedSomething = true }
                }
                if !records.isEmpty { sessions[id] = SessionMemory(lastActivity: min(lastActivity, now), records: records) }
            }
            enforceSessionLimit(keeping: nil)
            if cleanedSomething { markDirtyWhileLocked() }
        }
    }

    /// A broken file is renamed `.corrupt` and logged with its size and reason; the store starts empty. Under `lock`.
    private func setAside(reason: String) {
        let size = CodeStateFiles.entrySize(url)
        let moved = CodeStateFiles.setAside(url)
        sessions = [:]
        CodeLog.warn("memory file unreadable size=\(size) reason=\(reason) kept=\(moved ? "corrupt" : "no")")
    }

    /// At most `memorySessionsMax` sessions: the least recently written go (never `keeping`). Under `lock`.
    private func enforceSessionLimit(keeping: String?) {
        let over = sessions.count - CodeTuning.memorySessionsMax
        guard over > 0 else { return }
        let oldest = sessions.filter { $0.key != keeping }.sorted {
            $0.value.lastActivity != $1.value.lastActivity ? $0.value.lastActivity < $1.value.lastActivity : $0.key < $1.key
        }.prefix(over)
        for (id, _) in oldest { sessions[id] = nil }
    }

    // MARK: Writing

    private func didChange(_ ids: [String]) {
        scheduleWrite()
        let handlers = lock.withLock { Array(observers.values) }
        for id in ids { for handler in handlers { handler(id) } }
    }

    /// Under `lock`: a write is due (cleaning at load).
    private func markDirtyWhileLocked() {
        dirty = true
        guard !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + writeInterval) { [self] in writeNow() }
    }

    private func scheduleWrite() {
        let schedule = lock.withLock { () -> Bool in
            guard !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        guard schedule else { return }
        // The first change of a burst opens the window; everything until then goes into one write.
        queue.asyncAfter(deadline: .now() + writeInterval) { [self] in writeNow() }
    }

    /// On `queue`.
    private func writeNow() {
        let snapshot = lock.withLock { () -> [String: SessionMemory]? in
            writeScheduled = false
            guard dirty else { return nil }
            dirty = false
            return sessions
        }
        guard let snapshot else { return }
        guard let data = Self.serialize(snapshot) else {
            CodeLog.warn("memory write failed reason=encoding")
            return
        }
        guard data.count <= writeMax else {
            let now = MonotonicClock.now()
            let log = lock.withLock { () -> Bool in
                guard now - lastRefusalLogged >= 60 else { return false }
                lastRefusalLogged = now
                return true
            }
            if log { CodeLog.warn("memory write refused size=\(data.count)") }
            return
        }
        do {
            try CodeStateFiles.writeAtomically(data, to: url)
            lock.withLock { writes += 1 }
        } catch {
            lock.withLock { dirty = true }
            CodeLog.warn("memory write failed reason=\((error as? CodeStateFiles.WriteFailure)?.label ?? "error")")
        }
    }

    private static func serialize(_ sessions: [String: SessionMemory]) -> Data? {
        var all: [String: JSONValue] = [:]
        for (id, memory) in sessions {
            var fields: [String: JSONValue] = ["lastActivity": .string(isoString(memory.lastActivity))]
            for (key, value) in memory.records { fields[key.rawValue] = value }
            all[id] = .object(fields)
        }
        return CodeStateFiles.serialize(["version": .number(1), "sessions": .object(all)])
    }

    // MARK: Coding

    /// ISO 8601 with milliseconds, UTC (`CodeDates.parse` reads it back).
    static func isoString(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    /// A fresh encoder per use (records are small; nothing is shared between threads).
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, coder in
            var container = coder.singleValueContainer()
            try container.encode(isoString(date))
        }
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { coder in
            let container = try coder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = CodeDates.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a date")
            }
            return date
        }
        return decoder
    }
}
