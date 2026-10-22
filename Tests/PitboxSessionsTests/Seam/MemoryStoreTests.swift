import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

// `code-memory.json`: made-up records in the features' shapes.

private struct Seen: Codable, Equatable { var at: Date }
private struct Finished: Codable, Equatable {
    var reply: String
    var at: Date
    var ranSeconds: Double
    var open: Bool
    var expired: Bool
}
private struct ReadyState: Codable, Equatable { var state: String; var at: Date }
private struct ETARecord: Codable, Equatable { var at: Date; var statedAt: Date; var reply: String }
private struct PendingTask: Codable, Equatable { var task: String; var kind: String; var launchedAt: Date }
private struct Silenced: Codable, Equatable { var rule: String; var until: Date }
private struct Dashboard: Codable, Equatable { var handle: String; var firstSeen: Date; var lastBuilderCallAt: Date? }
private struct Scan: Codable, Equatable { var at: Date; var bytes: Int; var found: Bool }

private let hash = "3f9a0c2b7d1e4f60"

private func readyKey(_ session: String, _ reply: String = "0f3c2a9e-uuid", _ number: Int = 1) -> String {
    "cmd:\(session):\(reply):\(number):\(hash)"
}

/// A store on a fresh folder with a hand-moved clock (writes coalesce over `interval`).
private struct Rig {
    let folder = SeamFolder("memory")
    let clock = ManualClock()
    var url: URL { folder.file("code-memory.json") }

    func store(interval: TimeInterval = 0.05, writeMax: Int = CodeTuning.memoryWriteMax, owner: uid_t = getuid()) -> CodeMemoryStore {
        let clock = self.clock
        return CodeMemoryStore(url: url, owner: owner, clock: { clock.now }, writeInterval: interval, writeMax: writeMax)
    }

    var fileText: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

@Suite("Memory store", .serialized)
struct MemoryStoreTests {
    init() { CodeLog.enabled = false }

    @Test func everyKeyRoundTripsPerSessionAndAcrossARestart() throws {
        let rig = Rig()
        let now = rig.clock.now
        let store = rig.store()
        let later = now.addingTimeInterval(600)
        store.write(.seen, session: sessionA, value: Seen(at: now))
        store.write(.finished, session: sessionA, value: [Finished(reply: "r-1", at: now, ranSeconds: 1260, open: true, expired: false)])
        store.write(.ready, session: sessionA, value: [readyKey(sessionA): ReadyState(state: "later", at: now)])
        store.write(.eta, session: sessionA, value: ETARecord(at: later, statedAt: now, reply: "r-1"))
        store.write(.background, session: sessionA, value: [PendingTask(task: hash, kind: "agent", launchedAt: now)])
        store.write(.silenced, session: sessionA, value: [Silenced(rule: "failed_in_a_row", until: later)])
        store.write(.dashboard, session: sessionA, value: Dashboard(handle: "polar-shore", firstSeen: now, lastBuilderCallAt: nil))
        store.write(.dashboardScan, session: sessionA, value: Scan(at: now, bytes: 104_857_600, found: true))
        store.write(.seen, session: sessionB, value: Seen(at: later))

        func check(_ store: CodeMemoryStore) {
            #expect(store.read(.seen, session: sessionA) == Seen(at: now))
            #expect(store.read(.seen, session: sessionB) == Seen(at: later))
            #expect(store.read(.finished, session: sessionA) == [Finished(reply: "r-1", at: now, ranSeconds: 1260, open: true, expired: false)])
            #expect(store.read(.ready, session: sessionA) == [readyKey(sessionA): ReadyState(state: "later", at: now)])
            #expect(store.read(.eta, session: sessionA) == ETARecord(at: later, statedAt: now, reply: "r-1"))
            #expect(store.read(.background, session: sessionA) == [PendingTask(task: hash, kind: "agent", launchedAt: now)])
            #expect(store.read(.silenced, session: sessionA) == [Silenced(rule: "failed_in_a_row", until: later)])
            #expect(store.read(.dashboard, session: sessionA) == Dashboard(handle: "polar-shore", firstSeen: now, lastBuilderCallAt: nil))
            #expect(store.read(.dashboardScan, session: sessionA) == Scan(at: now, bytes: 104_857_600, found: true))
            #expect((store.read(.seen, session: sessionC) as Seen?) == nil)
            #expect((store.read(.finished, session: sessionA) as Seen?) == nil, "another type reads as nothing")
        }
        check(store)
        store.flush()
        check(rig.store())   // a restart: a new store on the same file
        // Removing a record, then a whole session.
        store.write(.seen, session: sessionB, value: Seen?.none)
        #expect((store.read(.seen, session: sessionB) as Seen?) == nil && !store.sessionIDs.contains(sessionB))
        store.forget(session: sessionA)
        #expect(store.sessionIDs.isEmpty)
        store.flush()
    }

    @Test func writesCoalesceIntoOneFileWritePerInterval() async throws {
        let rig = Rig()
        let store = rig.store(interval: 0.3)
        for i in 0..<50 { store.write(.seen, session: sessionA, value: Seen(at: rig.clock.now.addingTimeInterval(Double(i)))) }
        #expect(store.writeCount == 0, "nothing is written at once")
        #expect(await eventually { store.writeCount == 1 })
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(store.writeCount == 1)
        #expect(rig.store().read(.seen, session: sessionA) == Seen(at: rig.clock.now.addingTimeInterval(49)), "the last value")
        // An unchanged value writes nothing.
        store.write(.seen, session: sessionA, value: Seen(at: rig.clock.now.addingTimeInterval(49)))
        store.flush()
        #expect(store.writeCount == 1)
    }

    @Test func theFileIsPrivateAndReplacedAtomically() throws {
        let rig = Rig()
        let store = rig.store()
        store.write(.seen, session: sessionA, value: Seen(at: rig.clock.now))
        store.flush()
        var info = stat()
        #expect(lstat(rig.url.path, &info) == 0 && (info.st_mode & 0o777) == 0o600 && (info.st_mode & S_IFMT) == S_IFREG)
        let firstInode = info.st_ino
        store.write(.seen, session: sessionA, value: Seen(at: rig.clock.now.addingTimeInterval(1)))
        store.flush()
        #expect(lstat(rig.url.path, &info) == 0 && info.st_ino != firstInode, "renamed over, never rewritten in place")
        #expect(rig.folder.names == ["code-memory.json"], "no temporary file is left")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: rig.url)) as? [String: Any]
        #expect(root?["version"] as? Int == 1 && (root?["sessions"] as? [String: Any])?[sessionA] != nil)
    }

    @Test func brokenFilesStartFreshAndAreKeptAsCorrupt() throws {
        let lines = Shared<[String]>([])
        let token = CodeLog.observe { lines.value.append($0) }
        defer { CodeLog.stopObserving(token) }
        let valid = #"{"version":1,"sessions":{"\#(sessionA)":{"lastActivity":"2026-10-01T14:00:00.000Z","seen":{"at":"2026-10-01T14:00:00.000Z"}}}}"#
        let cases: [(String, (Rig) throws -> Void)] = [
            ("too-large", { rig in try Data(count: CodeTuning.memoryReadMax + 1).write(to: rig.url) }),
            ("link", { rig in
                try valid.write(to: rig.folder.file("elsewhere.json"), atomically: true, encoding: .utf8)
                try FileManager.default.createSymbolicLink(at: rig.url, withDestinationURL: rig.folder.file("elsewhere.json"))
            }),
            ("not-regular", { rig in #expect(mkfifo(rig.url.path, 0o600) == 0) }),
            ("duplicate-key", { rig in try #"{"version":1,"version":1,"sessions":{}}"#.write(to: rig.url, atomically: true, encoding: .utf8) }),
            ("too-deep", { rig in
                let deep = String(repeating: "[", count: 17) + String(repeating: "]", count: 17)
                try #"{"version":1,"sessions":{},"x":\#(deep)}"#.write(to: rig.url, atomically: true, encoding: .utf8)
            }),
            ("shape", { rig in try #"{"version":2,"sessions":{}}"#.write(to: rig.url, atomically: true, encoding: .utf8) }),
            ("syntax", { rig in try "not json at all".write(to: rig.url, atomically: true, encoding: .utf8) }),
        ]
        for (label, make) in cases {
            let rig = Rig()
            try make(rig)
            let store = rig.store()
            #expect(store.sessionIDs.isEmpty, "\(label): starts fresh")
            var info = stat()
            #expect(lstat(rig.url.path + ".corrupt", &info) == 0, "\(label): kept as .corrupt")
            #expect(lstat(rig.url.path, &info) != 0, "\(label): moved away")
            #expect(lines.value.contains { $0.contains("memory file unreadable") && $0.contains("reason=\(label)") }, "\(label)")
            // Writing again makes a good file.
            store.write(.seen, session: sessionA, value: Seen(at: rig.clock.now))
            store.flush()
            #expect(rig.store().read(.seen, session: sessionA) == Seen(at: rig.clock.now), "\(label): a good file again")
        }
        // A file of another owner (the store is told it belongs to someone else).
        let rig = Rig()
        try valid.write(to: rig.url, atomically: true, encoding: .utf8)
        #expect(rig.store(owner: getuid() + 1).sessionIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: rig.url.path + ".corrupt"))
        #expect(lines.value.contains { $0.contains("reason=other-owner") })
        for line in lines.value { #expect(!line.contains(rig.folder.url.path) && !line.contains(sessionA)) }
    }

    @Test func theWriterRefusesAFileOverItsLimitAndKeepsTheLastGoodOne() throws {
        let lines = Shared<[String]>([])
        let token = CodeLog.observe { lines.value.append($0) }
        defer { CodeLog.stopObserving(token) }
        let rig = Rig()
        let store = rig.store(writeMax: 4096)
        store.write(.seen, session: sessionA, value: Seen(at: rig.clock.now))
        store.flush()
        let good = rig.fileText
        var ready: [String: ReadyState] = [:]
        for i in 0..<40 { ready[readyKey(sessionA, "reply-\(i)")] = ReadyState(state: "dismissed", at: rig.clock.now) }
        store.write(.ready, session: sessionA, value: ready)
        store.flush()
        #expect(rig.fileText == good, "refused: the last good file stays")
        #expect(lines.value.contains { $0.hasPrefix("WARN memory write refused size=") })
        #expect((store.read(.ready, session: sessionA) as [String: ReadyState]?)?.count == 40, "still held in memory")
        // The real limit: 200 sessions of 64 Ready keys are far over 768 KB.
        let big = Rig()
        let full = big.store(interval: 60)   // only the flush below writes
        for s in 0..<CodeTuning.memorySessionsMax {
            let id = String(format: "local_0eeeeeee-5555-4555-8555-%012d", s)
            var states: [String: ReadyState] = [:]
            for i in 0..<CodeTuning.memoryReadyKeysMax { states[readyKey(id, "reply-\(i)")] = ReadyState(state: "later", at: big.clock.now) }
            full.write(.ready, session: id, value: states)
        }
        full.flush()
        #expect(!FileManager.default.fileExists(atPath: big.url.path), "over 768 KB: never written")
    }

    @Test func perSessionLimitsKeepTheNewest() throws {
        let rig = Rig()
        let store = rig.store()
        let now = rig.clock.now
        var ready: [String: ReadyState] = [:]
        for i in 0..<65 { ready[readyKey(sessionA, "reply-\(i)")] = ReadyState(state: "later", at: now.addingTimeInterval(Double(i))) }
        store.write(.ready, session: sessionA, value: ready)
        let kept: [String: ReadyState] = try #require(store.read(.ready, session: sessionA))
        #expect(kept.count == 64 && kept[readyKey(sessionA, "reply-0")] == nil, "65 Ready keys keep the newest 64")
        let tasks = (0..<65).map { i in
            PendingTask(task: String(format: "%016x", i), kind: "agent", launchedAt: now.addingTimeInterval(Double(i)))
        }
        store.write(.background, session: sessionA, value: tasks)
        let pending: [PendingTask] = try #require(store.read(.background, session: sessionA))
        #expect(pending.count == 64 && pending.first == tasks[1] && pending.last == tasks[64], "the oldest dropped")
        let finished = (0..<17).map { Finished(reply: "r-\($0)", at: now, ranSeconds: 1, open: true, expired: false) }
        store.write(.finished, session: sessionA, value: finished)
        #expect((store.read(.finished, session: sessionA) as [Finished]?)?.count == 16)
        // A flood keeps its newest records instead of nothing (T30's 20,000 launches).
        let flood = (0..<20_000).map { i in PendingTask(task: String(format: "%016x", i), kind: "bash", launchedAt: now) }
        store.write(.background, session: sessionB, value: flood)
        #expect((store.read(.background, session: sessionB) as [PendingTask]?)?.count == 64)
        // At most 200 sessions: the least recently written go.
        for s in 0..<(CodeTuning.memorySessionsMax + 5) {
            rig.clock.advance(1)
            store.write(.seen, session: String(format: "local_0fffffff-6666-4666-8666-%012d", s), value: Seen(at: rig.clock.now))
        }
        #expect(store.sessionIDs.count == CodeTuning.memorySessionsMax)
        #expect(!store.sessionIDs.contains(sessionA), "written longest ago")
        store.flush()
    }

    @Test func aHostileUUIDOrKeyIsNeverStored() throws {
        let rig = Rig()
        let store = rig.store()
        let huge = String(repeating: "a", count: 600 * 1024)
        let now = rig.clock.now
        store.write(.finished, session: sessionA, value: [Finished(reply: huge, at: now, ranSeconds: 1, open: true, expired: false),
                                                          Finished(reply: "bad_uuid", at: now, ranSeconds: 1, open: true, expired: false),
                                                          Finished(reply: "r-ok", at: now, ranSeconds: 1, open: true, expired: false)])
        store.write(.ready, session: sessionA, value: [readyKey(sessionA, huge): ReadyState(state: "later", at: now),
                                                       readyKey(sessionB): ReadyState(state: "later", at: now),
                                                       readyKey(sessionA, "ok"): ReadyState(state: "maybe", at: now),
                                                       "warn:\(sessionA):failed_in_a_row": ReadyState(state: "dismissed", at: now)])
        store.write(.dashboard, session: sessionA, value: Dashboard(handle: "Polar-Shore", firstSeen: now, lastBuilderCallAt: nil))
        store.write(.background, session: sessionA, value: [PendingTask(task: "not-a-hash", kind: "agent", launchedAt: now)])
        store.write(.seen, session: "not-a-session", value: Seen(at: now))
        store.flush()
        #expect((store.read(.finished, session: sessionA) as [Finished]?)?.map(\.reply) == ["r-ok"])
        #expect((store.read(.ready, session: sessionA) as [String: ReadyState]?)?.keys.sorted() == ["warn:\(sessionA):failed_in_a_row"])
        #expect((store.read(.dashboard, session: sessionA) as Dashboard?) == nil)
        #expect((store.read(.background, session: sessionA) as [PendingTask]?) == nil)
        #expect((store.read(.seen, session: "not-a-session") as Seen?) == nil)
        let size = (try? FileManager.default.attributesOfItem(atPath: rig.url.path)[.size] as? Int) ?? 0
        #expect(size < 4096 && !rig.fileText.contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        #expect(!rig.fileText.contains(sessionB) && !rig.fileText.contains("not-a-session"))
    }

    @Test func recordsExpireAndIdleSessionsArePruned() throws {
        let rig = Rig()
        let store = rig.store()
        let now = rig.clock.now
        store.write(.finished, session: sessionA, value: [Finished(reply: "r-old", at: now, ranSeconds: 1, open: true, expired: false)])
        store.write(.background, session: sessionA, value: [PendingTask(task: hash, kind: "workflow", launchedAt: now)])
        store.write(.ready, session: sessionA, value: [readyKey(sessionA): ReadyState(state: "later", at: now)])
        store.write(.eta, session: sessionA, value: ETARecord(at: now, statedAt: now, reply: "r-old"))
        store.write(.silenced, session: sessionA, value: [Silenced(rule: "silence", until: now.addingTimeInterval(3600))])
        store.write(.seen, session: sessionA, value: Seen(at: now))
        store.flush()
        rig.clock.advance(2 * 3600 + 1)          // the ETA is 2 h past, the silence over
        #expect((store.read(.eta, session: sessionA) as ETARecord?) == nil)
        #expect((store.read(.silenced, session: sessionA) as [Silenced]?) == nil)
        #expect((store.read(.background, session: sessionA) as [PendingTask]?) != nil)
        rig.clock.advance(4 * 3600)              // 6 h after the launch
        #expect((store.read(.background, session: sessionA) as [PendingTask]?) == nil)
        #expect((store.read(.finished, session: sessionA) as [Finished]?) != nil)
        rig.clock.advance(18 * 3600)             // 24 h after the finish and the Ready state
        #expect((store.read(.finished, session: sessionA) as [Finished]?) == nil)
        #expect((store.read(.ready, session: sessionA) as [String: ReadyState]?) == nil)
        #expect(store.read(.seen, session: sessionA) == Seen(at: now), "seen has no life of its own")
        // 13 days without a write: still there at the next load; 15 days: gone.
        rig.clock.set(now.addingTimeInterval(13 * 86_400))
        let after13 = rig.store()
        #expect(after13.sessionIDs == [sessionA])
        after13.flush()
        rig.clock.set(now.addingTimeInterval(15 * 86_400))
        let after15 = rig.store()
        #expect(after15.sessionIDs.isEmpty)
        after15.flush()
        #expect(rig.store().sessionIDs.isEmpty, "the pruned file was written")
    }

    @Test func pruneSessionsDropsGoneAndArchivedOnes() {
        let rig = Rig()
        let store = rig.store()
        for id in [sessionA, sessionB, sessionC] { store.write(.seen, session: id, value: Seen(at: rig.clock.now)) }
        store.pruneSessions(existing: [], archived: [])
        #expect(store.sessionIDs.count == 3, "an empty listing prunes nothing")
        store.pruneSessions(existing: [sessionA, sessionB], archived: [sessionB])
        #expect(store.sessionIDs == [sessionA])
        store.flush()
    }

    @Test func observersHearChangesOutsideTheLock() {
        let rig = Rig()
        let store = rig.store()
        let heard = Shared<[String]>([])
        let reads = Shared<Int>(0)
        let token = store.addObserver { id in
            heard.value.append(id)
            // Reading inside the callback must not deadlock: the lock is not held.
            if (store.read(.seen, session: id) as Seen?) != nil { reads.value += 1 }
        }
        store.write(.seen, session: sessionA, value: Seen(at: rig.clock.now))
        store.write(.seen, session: sessionA, value: Seen(at: rig.clock.now))
        store.forget(session: sessionA)
        store.forget(session: sessionA)
        #expect(heard.value == [sessionA, sessionA] && reads.value == 1, "unchanged writes and empty forgets are silent")
        store.removeObserver(token)
        store.write(.seen, session: sessionB, value: Seen(at: rig.clock.now))
        #expect(heard.value.count == 2)
        store.flush()
    }

    /// The record the finished detector really writes (`CodeFinishedRecord`, every field set, the `etaWas` date too) is
    /// kept and reads back the same, now and after a restart, with no refusal; a malformed one is still refused
    /// (`reason=shape`), and one already past its 24 hours says so (`reason=expired`, the case that was logged as a
    /// shape).
    @Test func theFinishedDetectorsRecordIsSavedAndReadBack() throws {
        let log = ThisThreadLog()
        defer { log.stop() }
        let rig = Rig()
        let store = rig.store()
        let now = rig.clock.now
        let records = [
            CodeFinishedRecord(reply: "0f3c2a9e-aaaa-4bbb-8ccc-dddddddddddd", at: now.addingTimeInterval(-7200),
                               ranSeconds: 1260.25, open: false, expired: true, item: false, silent: true, etaWas: nil),
            CodeFinishedRecord(reply: "5d1e7c40-1111-4222-8333-444455556666", at: now.addingTimeInterval(-60),
                               ranSeconds: 3, open: true, expired: false, item: true, silent: false,
                               etaWas: now.addingTimeInterval(-300)),
        ]
        store.write(.finished, session: sessionA, value: records)
        #expect(store.read(.finished, session: sessionA) == records)
        store.flush()
        #expect(rig.store().read(.finished, session: sessionA) == records, "a restart reads the same records")
        #expect(rig.fileText.contains("\"finished\""))
        #expect(!log.lines.contains { $0.contains("memory write refused") })

        // Malformed: a reply that is no entry uuid, a negative run time. Refused as a shape; nothing is stored.
        var bad = records[1]
        bad.reply = "not an entry uuid!"
        store.write(.finished, session: sessionB, value: [bad])
        bad = records[1]
        bad.ranSeconds = -1
        store.write(.finished, session: sessionB, value: [bad])
        #expect((store.read(.finished, session: sessionB) as [CodeFinishedRecord]?) == nil)
        #expect(log.lines.filter { $0 == "WARN memory write refused key=finished reason=shape" }.count == 2)
        // Well formed but finished over 24 hours ago: the store would drop it at once, and says why.
        var old = records[1]
        old.at = now.addingTimeInterval(-CodeTuning.finishedRecordLife - 60)
        store.write(.finished, session: sessionC, value: [old])
        #expect(log.lines.last == "WARN memory write refused key=finished reason=expired")
        #expect(!store.sessionIDs.contains(sessionB) && !store.sessionIDs.contains(sessionC))
        // A list that mixes an expired element with a malformed one: malformed parts make it a shape, whatever else.
        var malformed = records[1]
        malformed.reply = "not an entry uuid!"
        store.write(.finished, session: sessionC, value: [old, malformed])
        #expect(log.lines.last == "WARN memory write refused key=finished reason=shape")
        store.write(.finished, session: sessionC, value: [malformed, old])
        #expect(log.lines.last == "WARN memory write refused key=finished reason=shape", "in either order")
        store.write(.finished, session: sessionC, value: [old, old])
        #expect(log.lines.last == "WARN memory write refused key=finished reason=expired", "every element only expired")
        // The Ready map judges member by member too.
        let expiredState = ReadyState(state: "later", at: now.addingTimeInterval(-CommandOffer.maxAge - 60))
        store.write(.ready, session: sessionC, value: [readyKey(sessionC): expiredState])
        #expect(log.lines.last == "WARN memory write refused key=ready reason=expired")
        store.write(.ready, session: sessionC, value: [readyKey(sessionC): expiredState,
                                                      readyKey(sessionC, "0f3c2a9e-uuid", 2): ReadyState(state: "maybe", at: now)])
        #expect(log.lines.last == "WARN memory write refused key=ready reason=shape")
        // An empty list has nothing expired in it: a shape.
        store.write(.finished, session: sessionC, value: [CodeFinishedRecord]())
        #expect(log.lines.last == "WARN memory write refused key=finished reason=shape")
        #expect(!store.sessionIDs.contains(sessionC))
        store.flush()
    }

    @Test func noRecordTextReachesTheLog() {
        let lines = Shared<[String]>([])
        let token = CodeLog.observe { lines.value.append($0) }
        defer { CodeLog.stopObserving(token) }
        let rig = Rig()
        let store = rig.store()
        store.write(.finished, session: sessionA, value: [Finished(reply: "\(secretWord)_x", at: rig.clock.now, ranSeconds: 1,
                                                                   open: true, expired: false)])
        store.write(.seen, session: "local_\(secretWord)!", value: Seen(at: rig.clock.now))
        store.flush()
        #expect(lines.value.contains { $0.contains("memory write refused key=finished reason=shape") })
        #expect(lines.value.contains { $0.contains("reason=session-id") })
        for line in lines.value { #expect(!line.contains(secretWord) && !line.contains(sessionA)) }
    }
}
