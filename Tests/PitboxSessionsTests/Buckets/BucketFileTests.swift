import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// `code-buckets.json`: its careful reader, tolerant parsing, the atomic 0600 writer, broken files,
/// pruning and first-seen order across a reload. Every file is made up, in a scratch folder.
@MainActor
@Suite("Buckets: code-buckets.json")
struct BucketFileTests {
    init() { CodeTileLog.enabled = false }

    @Test func aRoundTripKeepsBucketsColoursFoldsAndMembers() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        let store = bucketStore(folder)
        let toy = try #require(store.create())
        store.rename(toy.id, to: "Toy Cube")
        store.setColor(toy.id, .amber)
        store.setFolded(toy.id, true)
        store.setFolded(CodeBucket.unsortedID, true)
        store.noteSeen(["local_a", "local_b"], now: tileNow)
        store.move("local_b", to: toy.id, now: tileNow)
        store.flush()
        let again = bucketStore(folder)
        #expect(again.buckets == store.buckets)
        #expect(again.state.sessions == store.state.sessions)
        #expect(again.bucketID(of: "local_b") == toy.id && again.bucketID(of: "local_a") == CodeBucket.unsortedID)
        #expect(again.note == nil)
        // Only ids and times of sessions are stored: the file holds no headline.
        let json = try folder.json()
        #expect(json["version"] as? Int == 1)
        let sessions = try #require(json["sessions"] as? [String: [String: String]])
        #expect(Set(sessions.keys) == ["local_a", "local_b"])
        #expect(sessions["local_b"]?.keys.sorted() == ["bucket", "firstSeen", "lastSeen"])
    }

    @Test func theWriterUsesA0600TemporaryFileAndAnAtomicRename() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        let store = bucketStore(folder)
        store.create()
        store.flush()
        var first = stat()
        #expect(lstat(folder.file.path, &first) == 0)
        #expect(first.st_mode & 0o777 == 0o600)
        store.create()
        store.flush()
        var second = stat()
        #expect(lstat(folder.file.path, &second) == 0)
        #expect(second.st_mode & 0o777 == 0o600)
        // A new file renamed over the old one, never the old one written in place; no temporary file is left.
        #expect(first.st_ino != second.st_ino)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(names == ["code-buckets.json"])
    }

    @Test func changesCoalesceIntoOneWrite() async throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        let store = bucketStore(folder, interval: 0.3)
        let made = try #require(store.create())
        for index in 0..<20 { store.rename(made.id, to: "Name \(index)") }
        store.setColor(made.id, .blue)
        #expect(store.writeCount == 0)
        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(store.writeCount == 1)
        #expect(bucketStore(folder).bucket(made.id)?.name == "Name 19")
    }

    @Test func unknownKeysAreIgnoredAndBadEntriesAreDroppedAlone() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        let long = String(repeating: "x", count: 33)
        try folder.write("""
        { "version": 1, "theme": "dark",
          "buckets": [
            { "id": "unsorted", "name": "Unsorted", "color": "grey", "folded": false },
            { "id": "b-k3x9q2", "name": "Toy Cube", "color": "amber", "folded": true, "pinned": 3 },
            { "id": "b-ABCDEF", "name": "Upper", "color": "teal" },
            { "id": "b-12345", "name": "Short id", "color": "teal" },
            { "id": "x-abcdef", "name": "Prefix", "color": "teal" },
            { "id": "b-aaaaaa", "name": "\(long)", "color": "teal" },
            { "id": "b-bbbbbb", "name": "Hidden\\u202Eletters", "color": "teal" },
            { "id": "b-cccccc", "name": "Two\\nlines", "color": "teal" },
            { "id": "b-dddddd", "name": "Purple", "color": "purple" },
            { "id": "b-k3x9q2", "name": "Again", "color": "red" },
            { "id": "b-eeeeee", "name": "  Acme  ", "color": "violet" },
            "not an object"
          ],
          "sessions": {
            "local_good": { "bucket": "b-k3x9q2", "firstSeen": "2026-10-19T21:10:04.000Z", "lastSeen": "2026-10-20T08:00:00Z" },
            "local_lost": { "bucket": "b-zzzzzz", "firstSeen": "2026-10-19T21:10:05Z", "lastSeen": "2026-10-20T08:00:00Z" },
            "local_bad-time": { "bucket": "b-k3x9q2", "firstSeen": "yesterday" },
            "remote_x": { "bucket": "b-k3x9q2", "firstSeen": "2026-10-19T21:10:06Z", "lastSeen": "2026-10-20T08:00:00Z" },
            "local_x/y": { "bucket": "b-k3x9q2", "firstSeen": "2026-10-19T21:10:07Z", "lastSeen": "2026-10-20T08:00:00Z" },
            "local_one-time": { "bucket": "b-eeeeee", "lastSeen": "2026-10-20T08:00:00Z", "note": "kept" }
          } }
        """)
        let store = bucketStore(folder, now: Date(timeIntervalSince1970: 1_792_000_000))
        #expect(store.note == nil)
        #expect(store.buckets.map(\.id) == ["unsorted", "b-k3x9q2", "b-eeeeee"])
        #expect(store.buckets.map(\.name) == ["Unsorted", "Toy Cube", "Acme"])
        #expect(store.bucket("b-k3x9q2")?.folded == true && store.bucket("b-k3x9q2")?.color == .amber)
        #expect(Set(store.state.sessions.keys) == ["local_good", "local_lost", "local_one-time"])
        #expect(store.bucketID(of: "local_good") == "b-k3x9q2")
        // A session pointing at an unknown bucket goes to Unsorted; a missing time is taken from the other one.
        #expect(store.state.sessions["local_lost"]?.bucket == CodeBucket.unsortedID)
        #expect(store.state.sessions["local_one-time"]?.firstSeen == store.state.sessions["local_one-time"]?.lastSeen)
        // The cleaned form is written back.
        store.flush()
        let text = try String(contentsOf: folder.file, encoding: .utf8)
        #expect(!text.contains("Purple") && !text.contains("remote_x") && !text.contains("theme") && !text.contains("b-zzzzzz"))
    }

    @Test func aMissingUnsortedIsAddedBackFirstAndPast20BucketsTheFirst20Stay() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        let ids = (0..<21).map { String(format: "b-%06d", $0) }
        let entries = ids.map { "{ \"id\": \"\($0)\", \"name\": \"Bucket \($0)\", \"color\": \"blue\" }" }
        try folder.write("{ \"version\": 1, \"buckets\": [\(entries.joined(separator: ","))], \"sessions\": {} }")
        let store = bucketStore(folder)
        #expect(store.buckets.count == 20)
        #expect(store.buckets.first == CodeBucket.unsorted)
        #expect(store.buckets.dropFirst().map(\.id) == Array(ids.prefix(19)))
        #expect(!store.canCreate)
    }

    @Test(arguments: ["{ oops", "{ \"version\": 1, \"buckets\": [], \"buckets\": [] }", "[1, 2, 3]", "{ \"version\": 2, \"buckets\": [] }",
                      "{ \"buckets\": [] }", String(repeating: "{\"a\":", count: 17) + "1" + String(repeating: "}", count: 17)])
    func aBrokenFileIsSetAsideAndTheTileStartsWithUnsortedAndTheNote(_ text: String) throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        try folder.write(text)
        let store = bucketStore(folder)
        #expect(store.buckets == [CodeBucket.unsorted])
        #expect(store.note == "Your buckets couldn't be read; a copy was kept.")
        #expect(FileManager.default.fileExists(atPath: folder.corrupt.path))
        #expect(try String(contentsOf: folder.corrupt, encoding: .utf8) == text)
        // The note stays until the user's next change.
        store.noteSeen(["local_a"], now: tileNow)
        #expect(store.note != nil)
        store.create()
        #expect(store.note == nil)
    }

    @Test func aTooLargeFileIsSetAside() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        try folder.write("{ \"version\": 1, \"pad\": \"" + String(repeating: "x", count: 300 << 10) + "\" }")
        let store = bucketStore(folder)
        #expect(store.note != nil && FileManager.default.fileExists(atPath: folder.corrupt.path))
    }

    @Test func aLinkAFIFOAndAFileOfAnotherOwnerAreRefused() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        // A link to a valid file elsewhere: refused, the link itself set aside, its target untouched.
        let target = folder.url.appendingPathComponent("elsewhere.json")
        try Data("{ \"version\": 1, \"buckets\": [], \"sessions\": {} }".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.file, withDestinationURL: target)
        let linked = bucketStore(folder)
        #expect(linked.note != nil)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: folder.corrupt.path)) == target.path)
        // A FIFO: refused without blocking.
        try? FileManager.default.removeItem(at: folder.corrupt)
        #expect(mkfifo(folder.file.path, 0o600) == 0)
        let fifo = bucketStore(folder)
        #expect(fifo.note != nil && fifo.buckets == [CodeBucket.unsorted])
        // A file of another owner (an injected owner stands in for one).
        try? FileManager.default.removeItem(at: folder.corrupt)
        try? FileManager.default.removeItem(at: folder.file)
        try folder.write("{ \"version\": 1, \"buckets\": [], \"sessions\": {} }")
        let foreign = bucketStore(folder, owner: getuid() &+ 1)
        #expect(foreign.note != nil && FileManager.default.fileExists(atPath: folder.corrupt.path))
    }

    @Test func entriesGoAfter30DaysAndAtMost500Stay() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        let day: TimeInterval = 86_400
        var sessions: [String] = []
        func entry(_ id: String, _ lastSeen: Date) -> String {
            let time = CodeBucketFile.isoMilliseconds(lastSeen)
            return "\"\(id)\": { \"bucket\": \"unsorted\", \"firstSeen\": \"\(time)\", \"lastSeen\": \"\(time)\" }"
        }
        sessions.append(entry("local_old", tileNow.addingTimeInterval(-31 * day)))
        sessions.append(entry("local_recent", tileNow.addingTimeInterval(-29 * day)))
        for index in 0..<520 { sessions.append(entry("local_n\(index)", tileNow.addingTimeInterval(-Double(index) * 60))) }
        try folder.write("{ \"version\": 1, \"buckets\": [], \"sessions\": { \(sessions.joined(separator: ",")) } }")
        let store = bucketStore(folder)
        #expect(store.state.sessions.count == 500)
        #expect(store.state.sessions["local_old"] == nil)
        // The oldest go first: the 29-day-old one and the 20 oldest of the rest.
        #expect(store.state.sessions["local_recent"] == nil)
        #expect(store.state.sessions["local_n499"] != nil && store.state.sessions["local_n500"] == nil)
        // Seeing new sessions keeps 500, never dropping one being seen.
        store.noteSeen(["local_new1", "local_new2", "local_n0"], now: tileNow)
        #expect(store.state.sessions.count == 500)
        #expect(store.state.sessions["local_new1"] != nil && store.state.sessions["local_new2"] != nil)
        // Archived sessions go at once.
        store.forget(["local_n0"])
        #expect(store.state.sessions["local_n0"] == nil)
    }

    @Test func firstSeenOrderSurvivesAReloadEvenWithinOneMillisecond() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        let store = bucketStore(folder)
        // The clock does not move: each new session still gets a later time.
        store.noteSeen(["local_c", "local_a", "local_b"], now: tileNow)
        store.noteSeen(["local_d"], now: tileNow)
        store.flush()
        let again = bucketStore(folder)
        let order = ["local_a", "local_b", "local_c", "local_d"].sorted {
            (again.firstSeen(of: $0) ?? .distantFuture) < (again.firstSeen(of: $1) ?? .distantFuture)
        }
        #expect(order == ["local_c", "local_a", "local_b", "local_d"])
        // A session seen after the reload goes after all of them, whatever the clock says.
        again.noteSeen(["local_e"], now: tileNow.addingTimeInterval(-3600))
        #expect((again.firstSeen(of: "local_e") ?? .distantPast) > (again.firstSeen(of: "local_d") ?? .distantFuture))
    }

    @Test func aTimeFromTheFutureCountsAsNow() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        try folder.write("""
        { "version": 1, "buckets": [],
          "sessions": { "local_f": { "bucket": "unsorted", "firstSeen": "2030-01-01T00:00:00Z", "lastSeen": "2030-01-01T00:00:00Z" } } }
        """)
        let store = bucketStore(folder)
        #expect(store.firstSeen(of: "local_f") == tileNow)
    }

    @Test func millisecondsAreWrittenRounded() {
        let date = Date(timeIntervalSince1970: 1_792_000_000.0016)
        #expect(CodeBucketFile.isoMilliseconds(date).hasSuffix(".002Z"))
        #expect(CodeDates.parse(CodeBucketFile.isoMilliseconds(date)).map(CodeBucketFile.milliseconds) == 1_792_000_000_002)
    }
}
