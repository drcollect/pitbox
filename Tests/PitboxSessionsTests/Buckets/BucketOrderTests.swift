import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The order inside a bucket is fixed: copy letter, then first seen, then session id.
@MainActor
@Suite("Buckets: fixed order")
struct BucketOrderTests {
    init() { CodeTileLog.enabled = false }

    /// A small deterministic generator (SplitMix64), so a failure can be replayed.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func statesOffersResultsAndWarningsNeverMoveAMonitor() throws {
        let h = BucketHarness()
        let ids = h.makeBuckets(["Acme", "Toy Cube"])
        let base = bucketSessions("s", 12)
        h.set(base)
        for (n, bucket) in [(2, ids[0]), (5, ids[0]), (6, ids[1]), (9, ids[1]), (11, ids[1])] {
            h.model.moveSession("local_s\(n)", toBucket: bucket)
        }
        let expected = h.layout
        var random = Generator(state: 0x5EED_0001)
        let states = CodeSessionState.allCases
        for round in 0..<200 {
            let sessions = base.map { session -> CodeSessionSnapshot in
                var changed = session
                changed.state = states.randomElement(using: &random) ?? .done
                changed.offers = Bool.random(using: &random) ? [tileOffer("make", session: session.index)] : []
                changed.warnings = Bool.random(using: &random)
                    ? [CodeWarning(kind: .silence, since: tileNow)] : []
                changed.unread = Bool.random(using: &random)
                changed.results = Bool.random(using: &random)
                    ? [CodeResult(kind: .artifact, origin: .artifactTool, label: "artifact")] : []
                return changed
            }
            h.set(sessions.shuffled(using: &random))
            #expect(h.layout == expected, "round \(round)")
        }
    }

    @Test func aSecondCopyStartingMovesNothing() {
        let h = BucketHarness()
        h.set(bucketSessions("a", 4))
        let before = h.layout[CodeBucket.unsortedID]
        h.source.runningProfiles = [.a, .b]
        h.set(bucketSessions("a", 4) + [tileSession("local_b1", "B one", index: 9, profile: .b)])
        // Copy letter first, always: A's monitors keep their places, B's go after them.
        #expect(h.layout[CodeBucket.unsortedID] == (before ?? []) + ["local_b1"])
        #expect(h.model.snapshot.showsProfiles)
    }

    @Test func tiesGoByIDAndUnseenSessionsGoLast() {
        let a = tileSession("local_a", "A"), b = tileSession("local_b", "B"), c = tileSession("local_c", "C")
        let same = tileNow
        let ordered = CodeBucketLayout.ordered([c, b, a], firstSeen: { $0 == "local_c" ? nil : same })
        #expect(ordered.map(\.id) == ["local_a", "local_b", "local_c"])
        let byTime = CodeBucketLayout.ordered([a, b, c], firstSeen: { id in
            id == "local_a" ? same.addingTimeInterval(2) : same.addingTimeInterval(id == "local_b" ? 1 : 0)
        })
        #expect(byTime.map(\.id) == ["local_c", "local_b", "local_a"])
        // The copy letter comes before everything (C after B after A, an unknown copy last).
        let other = tileSession("local_0", "Unknown", profile: .unknown(folderName: "Claude-X"))
        let cOne = tileSession("local_1", "C", profile: .c)
        #expect(CodeBucketLayout.ordered([other, cOne, a], firstSeen: { _ in same }).map(\.id) == ["local_a", "local_1", "local_0"])
    }

    @Test func theOrderSurvivesARestartThroughTheFile() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        let first = BucketHarness(store: bucketStore(folder))
        first.set([tileSession("local_z", "Z")])
        first.set([tileSession("local_m", "M"), tileSession("local_z", "Z")])
        first.set([tileSession("local_a", "A"), tileSession("local_m", "M"), tileSession("local_z", "Z")])
        #expect(first.layout[CodeBucket.unsortedID] == ["local_z", "local_m", "local_a"])
        first.model.buckets.flush()
        // A restart: a new store on the same file, the source listing the sessions in another order.
        let second = BucketHarness(store: bucketStore(folder))
        second.set([tileSession("local_a", "A"), tileSession("local_z", "Z"), tileSession("local_m", "M")])
        #expect(second.layout[CodeBucket.unsortedID] == ["local_z", "local_m", "local_a"])
    }
}
