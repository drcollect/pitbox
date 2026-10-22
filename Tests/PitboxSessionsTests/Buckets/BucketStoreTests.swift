import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Unsorted, making and changing buckets, names, colours, the limit, delete and moves.
@MainActor
@Suite("Buckets: making and changing")
struct BucketStoreTests {
    init() { CodeTileLog.enabled = false }

    private func memoryStore() -> CodeBucketStore { CodeBucketStore(url: nil, owner: getuid(), now: tileNow, writeInterval: 60) }

    @Test func unsortedIsAlwaysThereFirstAndCannotBeRenamedOrDeleted() {
        let store = memoryStore()
        #expect(store.buckets == [CodeBucket.unsorted])
        #expect(!store.rename(CodeBucket.unsortedID, to: "Inbox"))
        #expect(store.delete(CodeBucket.unsortedID) == nil)
        #expect(store.buckets.first?.name == "Unsorted")
        // It can be folded and recoloured.
        store.setFolded(CodeBucket.unsortedID, true)
        store.setColor(CodeBucket.unsortedID, .teal)
        #expect(store.buckets.first == CodeBucket(id: "unsorted", name: "Unsorted", color: .teal, folded: true))
        // A new bucket goes after it, never before.
        store.create()
        #expect(store.buckets.first?.isUnsorted == true && store.buckets.count == 2)
    }

    @Test func newBucketsAreNamedNewBucketAndTakeTheFirstFreeColour() {
        let store = memoryStore()
        let made = (0..<9).compactMap { _ in store.create() }
        #expect(made.allSatisfy { $0.name == "New bucket" && CodeBucket.isValidID($0.id) && !$0.isUnsorted })
        #expect(Set(made.map(\.id)).count == 9)
        // Unsorted holds grey: the free colours in palette order, then the one after the newest bucket's colour.
        #expect(made.map(\.color) == [.violet, .amber, .teal, .red, .green, .blue, .pink, .grey, .violet])
    }

    @Test func namesAreCleanedWhileTypingAndTrimmedWhenKept() {
        // B1 characters, tabs and line breaks are dropped as they are typed; spaces stay until the name is kept.
        #expect(CodeBucketName.typed("  Toy\u{202E} Cu\tbe\n ") == "  Toy Cube ")
        #expect(CodeBucketName.typed("a\u{200B}b\u{2028}c\r") == "abc")
        #expect(CodeBucketName.committed("  Toy Cube  ") == "Toy Cube")
        #expect(CodeBucketName.committed(" \u{202E} \n ") == nil)
        // 32 characters at most (emoji count as one each), and 512 bytes.
        #expect(CodeBucketName.typed(String(repeating: "x", count: 40)).count == 32)
        #expect(CodeBucketName.typed(String(repeating: "🧊", count: 40)).count == 32)
        let marks = "a" + String(repeating: "\u{0301}", count: 2000)
        #expect(CodeBucketName.typed(marks).utf8.count <= 512)
        // Reading holds the same rules.
        #expect(CodeBucketName.validated("  Toy Cube ") == "Toy Cube")
        #expect(CodeBucketName.validated(String(repeating: "y", count: 32)) != nil)
        #expect(CodeBucketName.validated(String(repeating: "y", count: 33)) == nil)
        #expect(CodeBucketName.validated("Toy\u{202E}Cube") == nil)
        #expect(CodeBucketName.validated("Toy\nCube") == nil)
        #expect(CodeBucketName.validated("Toy\tCube") == nil)
        #expect(CodeBucketName.validated("   ") == nil)
    }

    @Test func aNameEmptyAfterTrimmingKeepsTheOldOneAndTwoBucketsMayShareOne() throws {
        let store = memoryStore()
        let a = try #require(store.create()), b = try #require(store.create())
        #expect(store.rename(a.id, to: "  Toy Cube "))
        #expect(!store.rename(a.id, to: "   "))
        #expect(store.bucket(a.id)?.name == "Toy Cube")
        #expect(store.rename(b.id, to: "Toy Cube"))
        #expect(store.buckets.filter { $0.name == "Toy Cube" }.count == 2)
    }

    @Test func twentyBucketsIsTheLimit() {
        let store = memoryStore()
        var made = 0
        while store.create() != nil { made += 1 }
        #expect(made == 19 && store.buckets.count == CodeTuning.maxBuckets)
        #expect(!store.canCreate)
        // A delete makes room again.
        store.delete(store.buckets[1].id)
        #expect(store.canCreate)
    }

    @Test func newSessionsLandInUnsortedAndParkingNeverMovesThem() throws {
        let h = BucketHarness()
        let ids = h.makeBuckets(["Acme"])
        let sideBucket = try #require(ids.first)
        h.set(bucketSessions("a", 3))
        #expect(h.layout[CodeBucket.unsortedID] == ["local_a1", "local_a2", "local_a3"])
        #expect(h.model.moveSession("local_a2", toBucket: sideBucket))
        // Parking, a restore, the window closing and coming back: the session stays where it is.
        h.parker.statuses["local_a2"] = CodeWindowStatus(place: .parked(since: tileNow))
        h.parker.parkedSessionIDs = ["local_a2"]
        h.parker.statuses["local_a2"] = CodeWindowStatus(place: .closed)
        h.set(bucketSessions("a", 3).filter { $0.id != "local_a2" })
        h.parker.parkedSessionIDs = []
        h.set(bucketSessions("a", 3))
        #expect(h.layout[sideBucket] == ["local_a2"])
        #expect(h.layout[CodeBucket.unsortedID] == ["local_a1", "local_a3"])
    }

    @Test func deleteMovesItsSessionsToUnsortedAtTheirFirstSeenPlaceAndTouchesNoWindow() throws {
        let h = BucketHarness()
        let ids = h.makeBuckets(["Toy Cube"])
        let toy = try #require(ids.first)
        h.set(bucketSessions("s", 5))
        h.model.moveSession("local_s2", toBucket: toy)
        h.model.moveSession("local_s4", toBucket: toy)
        #expect(h.layout[CodeBucket.unsortedID] == ["local_s1", "local_s3", "local_s5"])
        h.model.deleteBucket(toy)
        #expect(h.model.snapshot.sections.map(\.id) == [CodeBucket.unsortedID])
        #expect(h.layout[CodeBucket.unsortedID] == ["local_s1", "local_s2", "local_s3", "local_s4", "local_s5"])
        #expect(h.parker.performed.isEmpty)
        #expect(!h.model.snapshot.bucketMode)
    }

    @Test func aMovedSessionTakesItsFirstSeenPlaceThere() throws {
        let h = BucketHarness()
        let ids = h.makeBuckets(["Acme"])
        let sideBucket = try #require(ids.first)
        h.set(bucketSessions("s", 4))
        h.model.moveSession("local_s3", toBucket: sideBucket)
        h.model.moveSession("local_s1", toBucket: sideBucket)
        h.model.moveSession("local_s4", toBucket: sideBucket)
        #expect(h.layout[sideBucket] == ["local_s1", "local_s3", "local_s4"])
        // A move to the bucket it is in changes nothing; an unknown bucket is refused.
        #expect(!h.model.moveSession("local_s1", toBucket: sideBucket))
        #expect(!h.model.moveSession("local_s2", toBucket: "b-zzzzzz"))
    }
}
