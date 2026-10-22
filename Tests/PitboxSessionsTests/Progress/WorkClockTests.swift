import Foundation
import Testing
@testable import PitboxSessions

/// The work and its running time.
@Suite("The work")
struct WorkClockTests {
    let t0 = fixtureNow.addingTimeInterval(-3600)

    @Test func theWorkStartsAtTheLatestTurnOfTheUsersOrAPeersAndTakesInTheNoticeTurns() throws {
        let digest = digestOf([
            Line.user("Earlier \(secretWord) question", uuid: "u0", at: t0.addingTimeInterval(-600)),
            Line.text("Answer", uuid: "a0", at: t0.addingTimeInterval(-590)),
            Line.user("Build it", uuid: "u1", at: t0),
        ] + TaskLine.agentLaunch(1, at: t0.addingTimeInterval(30)) + [
            Line.text("Launched", uuid: "a1", at: t0.addingTimeInterval(40)),
            SeamLine.noticeTurn(noticeText(taskID: "agent1x"), uuid: "n1", at: t0.addingTimeInterval(900)),
            Line.text("Agent done", uuid: "a2", at: t0.addingTimeInterval(910)),
            SeamLine.noticeTurn(noticeText(taskID: "other"), uuid: "n2", at: t0.addingTimeInterval(1200), origin: "system"),
            Line.text("Still going", uuid: "a3", at: t0.addingTimeInterval(1210)),
        ])
        let work = try #require(WorkClock.work(in: digest, now: fixtureNow))
        #expect(work.basis == .asked && work.startUUID == "u1" && work.startedAt == t0)
        #expect(work.contains(turn: digest.turns.count - 1), "notice and unknown-origin turns belong to the work")
        #expect(!work.contains(turn: work.firstTurn - 1))
        #expect(WorkClock.runningWords(since: t0, now: t0.addingTimeInterval(34 * 60 + 59)) == "Running 34 min")
        #expect(WorkClock.runningWords(since: t0, now: t0.addingTimeInterval(72 * 60)) == "Running 1 h 12 min")
        #expect(WorkClock.runningWords(since: t0, now: t0.addingTimeInterval(20)) == "Running 1 min")
    }

    @Test func aPeerTurnStartsWorkToo() throws {
        let digest = digestOf([
            Line.user("The user's ask", uuid: "u1", at: t0),
            Line.text("ok", uuid: "a1", at: t0.addingTimeInterval(10)),
            Line.user("Another session asks", uuid: "p1", at: t0.addingTimeInterval(600), origin: "peer"),
        ])
        #expect(WorkClock.work(in: digest, now: fixtureNow)?.startUUID == "p1")
    }

    @Test func overTwelveHoursOldOrMissingTheWorkIsTheCurrentTurn() throws {
        let old = fixtureNow.addingTimeInterval(-13 * 3600)
        let digest = digestOf([
            Line.user("Long ago", uuid: "u1", at: old),
            Line.text("ok", uuid: "a1", at: old.addingTimeInterval(10)),
            SeamLine.noticeTurn(noticeText(taskID: "x1"), uuid: "n1", at: fixtureNow.addingTimeInterval(-600)),
        ])
        let work = try #require(WorkClock.work(in: digest, now: fixtureNow))
        #expect(work.basis == .currentTurn && work.startUUID == "n1" && work.firstTurn == digest.turns.count - 1)
        let none = digestOf([SeamLine.noticeTurn(noticeText(taskID: "x1"), uuid: "n1", at: t0)])
        #expect(WorkClock.work(in: none, now: fixtureNow)?.basis == .currentTurn)
        #expect(WorkClock.work(in: .empty, now: fixtureNow) == nil)
    }

    @Test func aStartLostToATruncatedDigestIsRemembered() throws {
        var digest = digestOf([
            SeamLine.noticeTurn(noticeText(taskID: "x1"), uuid: "n1", at: t0.addingTimeInterval(1800)),
            Line.text("ok", uuid: "a1", at: t0.addingTimeInterval(1810)),
        ])
        let anchor = CodeWork.Anchor(startUUID: "u1", startedAt: t0)
        #expect(WorkClock.work(in: digest, now: fixtureNow, remembered: anchor)?.basis == .currentTurn,
                "a whole digest has no lost start")
        digest.truncated = true
        let work = try #require(WorkClock.work(in: digest, now: fixtureNow, remembered: anchor))
        #expect(work.basis == .remembered && work.startedAt == t0 && work.firstTurn == 0)
        let stale = CodeWork.Anchor(startUUID: "u1", startedAt: fixtureNow.addingTimeInterval(-13 * 3600))
        #expect(WorkClock.work(in: digest, now: fixtureNow, remembered: stale)?.basis == .currentTurn)
    }
}
