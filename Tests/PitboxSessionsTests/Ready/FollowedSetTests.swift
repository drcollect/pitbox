import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// Desk, parked and closed-while-parked first, then recent sessions by the user's own activity, own-activity ones last;
/// 24 at most; the session's writing never pushes a session the user used out.
@Suite("Followed set")
struct FollowedSetTests {
    func id(_ n: Int) -> String { "local_0aaaaaaa-1111-4111-8111-\(String(format: "%012d", n))" }

    func recent(_ n: Int, focused: Double? = nil, message: Double? = nil, own: Double? = nil,
                profile: CodeProfile = .a) -> CodeRecentSession {
        CodeRecentSession(id: id(n), profile: profile, lastFocusedAt: focused.map { readyNow.addingTimeInterval(-$0 * 3600) },
                          latestUserFrameAt: message.map { readyNow.addingTimeInterval(-$0 * 3600) },
                          ownLastActivity: own.map { readyNow.addingTimeInterval(-$0 * 3600) })
    }

    @Test func popOutsFirstThenParkedThenRecentByTheUsersActivity() {
        let desk = readySession(id(1)), parked = readySession(id(2)), closed = readySession(id(3), popout: false)
        let set = CodeFollowedSet(
            monitors: [desk, parked, closed],
            statuses: [id(1): CodeWindowStatus(place: .onDesk),
                       id(2): CodeWindowStatus(place: .parked(since: readyNow)),
                       id(3): CodeWindowStatus(place: .closed)],
            parked: [id(2), id(3)],
            recent: [recent(1, focused: 1), recent(4, own: 0.5), recent(5, focused: 5), recent(6, message: 2)],
            recentHours: 6, now: readyNow)
        #expect(set.entries.map(\.id) == [id(1), id(2), id(3), id(6), id(5), id(4)])
        #expect(set.kind(of: id(1)) == .desk && set.kind(of: id(2)) == .parked && set.kind(of: id(3)) == .parked)
        #expect(set.kind(of: id(6)) == .recentUsed(at: readyNow.addingTimeInterval(-2 * 3600)))
        #expect(set.kind(of: id(4)) == .recentOwn(at: readyNow.addingTimeInterval(-1800)))
        #expect(set.kind(of: id(4))?.getsOffers == false && set.kind(of: id(5))?.getsOffers == true)
        #expect(set.headerNote == nil && set.ids.count == 6)
    }

    @Test func aSessionThatKeepsWritingNeverPushesOneOfTheUsersOut() {
        let used = (1...24).map { recent($0, focused: Double($0) * 0.2) }
        let noisy = recent(99, own: 0.001)
        let set = CodeFollowedSet(monitors: [], statuses: [:], parked: [], recent: [noisy] + used, recentHours: 6, now: readyNow)
        #expect(set.entries.count == 24 && !set.ids.contains(id(99)))
        #expect(set.entries.first?.id == id(1), "The user's most recent first")
        #expect(set.headerNote == "24 of 25 followed")
    }

    @Test func outsideTheHoursUnreadableCopiesAndHoursZeroAreNotFollowed() {
        let list = [recent(1, focused: 7), recent(2, own: 6.5), recent(3, focused: 1, profile: .unknown(folderName: "Claude-X"))]
        #expect(CodeFollowedSet(monitors: [], statuses: [:], parked: [], recent: list, recentHours: 6, now: readyNow).entries.isEmpty)
        let fine = [recent(4, focused: 1)]
        #expect(CodeFollowedSet(monitors: [], statuses: [:], parked: [], recent: fine, recentHours: 0, now: readyNow).entries.isEmpty)
        #expect(CodeFollowedSet(monitors: [], statuses: [:], parked: [], recent: fine, recentHours: 6, now: readyNow).ids == [id(4)])
    }

    @Test func withNoPopOutTheListFillsFromRecentSessions() {
        let set = CodeFollowedSet(monitors: [], statuses: [:], parked: [], recent: [recent(1, message: 1), recent(2, own: 1)],
                                  recentHours: 6, now: readyNow)
        #expect(set.entries.map(\.id) == [id(1), id(2)])
    }

    @Test func ifC22FailsAFieldIsNotUsedAndWithBothGoneEverySessionIsOwnActivityOnly() {
        let list = [recent(1, focused: 1, own: 1), recent(2, message: 1, own: 1)]
        let noFocus = CodeFollowedSet(monitors: [], statuses: [:], parked: [], recent: list, recentHours: 6, now: readyNow,
                                      policy: .init(usesFocusedAt: false))
        #expect(noFocus.kind(of: id(1))?.getsOffers == false && noFocus.kind(of: id(2))?.getsOffers == true)
        let neither = CodeFollowedSet(monitors: [], statuses: [:], parked: [], recent: list, recentHours: 6, now: readyNow,
                                      policy: .init(usesFocusedAt: false, usesUserFrameAt: false))
        #expect(neither.entries.allSatisfy { !$0.kind.getsOffers })
    }

    @Test func aClosedDeskWindowBecomesARecentSessionAndStaysFollowed() {
        // The pop-out is gone from the monitors; the user's focus keeps it in the recent group.
        let set = CodeFollowedSet(monitors: [], statuses: [:], parked: [], recent: [recent(1, focused: 0.01)],
                                  recentHours: 6, now: readyNow)
        #expect(set.kind(of: id(1))?.isRecent == true && set.kind(of: id(1))?.getsOffers == true)
    }

    @Test func theWhereWords() {
        let clock = utcClock
        _ = clock
        #expect(CodeReadyWords.whereText(.recentUsed(at: readyNow.addingTimeInterval(-5 * 3600)), status: nil, bucket: nil,
                                         now: readyNow) == "in Claude · you opened it 5 h ago")
        #expect(CodeReadyWords.whereText(.recentUsed(at: readyNow.addingTimeInterval(-20)), status: nil, bucket: nil,
                                         now: readyNow) == "in Claude · you opened it just now")
        #expect(CodeReadyWords.whereText(.desk, status: CodeWindowStatus(place: .onDesk), bucket: nil, now: readyNow)
                == "window on track")
        #expect(CodeReadyWords.whereText(.parked, status: CodeWindowStatus(place: .parked(since: readyNow)), bucket: "Toy Cube",
                                         now: readyNow) == "in the pit (Toy Cube)")
        #expect(CodeReadyWords.whereText(.desk, status: CodeWindowStatus(place: .otherSpace), bucket: nil, now: readyNow)
                == "on another Space")
        #expect(CodeReadyWords.whereText(.parked, status: CodeWindowStatus(place: .closed), bucket: nil, now: readyNow)
                == "window closed")
        #expect(CodeReadyWords.showButton(.recentUsed(at: readyNow), status: nil, session: id(1)).title == "Open in Claude")
        #expect(CodeReadyWords.showButton(.parked, status: nil, session: id(1)).title == "Show monitor")
        #expect(CodeReadyWords.showButton(.desk, status: CodeWindowStatus(place: .onDesk), session: id(1)).title == "Show window")
    }
}
