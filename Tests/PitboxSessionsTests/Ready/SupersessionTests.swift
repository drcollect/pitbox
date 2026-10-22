import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// One definition of "superseded", what is counted, the host facts since. Invented transcripts only.
@Suite("Supersession facts")
struct SupersessionTests {
    let start = readyNow.addingTimeInterval(-3600)
    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// The user's request and the reply holding the command (reply uuid "a1").
    var offerTurn: [String] {
        [Line.user("Make the checkout work", uuid: "u1", at: at(0)),
         Line.text("Run it:\n\n```bash\necho ok\n```", uuid: "a1", at: at(1))]
    }

    func human(_ n: Int, minute: Double, reply: Bool = true) -> [String] {
        var lines = [Line.user("Message \(n) \(secretWord)", uuid: "uh\(n)", at: at(minute))]
        if reply { lines.append(Line.text("Answer \(n)", uuid: "ah\(n)", at: at(minute + 1))) }
        return lines
    }

    func notice(_ n: Int, minute: Double, reply: Bool = true) -> [String] {
        var lines = [SeamLine.noticeTurn(noticeText(taskID: "task-\(n)"), uuid: "un\(n)", at: at(minute))]
        if reply { lines.append(Line.text("Agent \(n) reported back.", uuid: "an\(n)", at: at(minute + 1))) }
        return lines
    }

    func evaluate(_ lines: [String], midTurn: Bool = false, lastActivityAt: Date? = nil,
                  ssh: Bool = false) -> OfferSupersession.Verdict {
        OfferSupersession.evaluate("a1", in: digestOf(lines, midTurn: midTurn), replyTime: at(1),
                                   session: .init(midTurn: midTurn, lastActivityAt: lastActivityAt, isSSH: ssh))
    }

    func superseded(_ verdict: OfferSupersession.Verdict) -> CommandOffer.Supersession? {
        if case .superseded(let s) = verdict { return s }
        return nil
    }

    @Test func nothingAfterTheReplyIsFreshAndAMissingReplyIsNotFound() {
        #expect(evaluate(offerTurn) == .fresh)
        #expect(OfferSupersession.evaluate("nope", in: digestOf(offerTurn), replyTime: at(1), session: .init()) == .notFound)
    }

    @Test func aNewMessageSupersedesAtOnceWhileTheNewerTurnStillRuns() throws {
        let s = try #require(superseded(evaluate(offerTurn + human(2, minute: 5, reply: false))))
        #expect(s.newerReplies == 0 && s.newerBackgroundUpdates == 0 && s.sessionIsWorking)
        #expect(s.unansweredMessageHead == "Message 2 \(secretWord)")
        #expect(s.latestAt == at(5) && s.replies.isEmpty)
    }

    @Test func noticeTurnsNeverDropTheOffer() throws {
        let three = offerTurn + notice(1, minute: 5) + notice(2, minute: 10) + notice(3, minute: 15)
        let s = try #require(superseded(evaluate(three)))
        #expect(s.newerReplies == 0 && s.newerBackgroundUpdates == 3 && !s.sessionIsWorking)
        #expect(s.unansweredMessageHead == nil && s.backgroundTasksFinishedSince == 3)
        // The 2 latest background replies are listed, oldest first.
        #expect(s.replies.map(\.head) == ["Agent 2 reported back.", "Agent 3 reported back."])
        #expect(s.replies.allSatisfy { $0.origin == .taskNotification })
    }

    @Test func oneHumanReplyAndTwoNoticesKeepItSupersededAndAThirdReplyDropsIt() throws {
        let mixed = offerTurn + human(2, minute: 5) + notice(1, minute: 10) + notice(2, minute: 15)
        let s = try #require(superseded(evaluate(mixed)))
        #expect(s.newerReplies == 1 && s.newerBackgroundUpdates == 2)
        #expect(s.replies.count == 3 && s.replies.first?.origin == .human)
        let two = offerTurn + human(2, minute: 5) + human(3, minute: 10)
        #expect(superseded(evaluate(two))?.newerReplies == 2)
        #expect(evaluate(two + human(4, minute: 15)) == .dropped)
        // A peer's turn counts like the user's.
        let peer = offerTurn + human(2, minute: 5) + human(3, minute: 10)
            + [Line.user("From another session", uuid: "up", at: at(14), origin: "peer"), Line.text("Peer answer", uuid: "ap", at: at(15))]
        #expect(evaluate(peer) == .dropped)
    }

    @Test func aReplyToATurnOfUnknownOriginCountsAsTheUsers() throws {
        let unknown = offerTurn + [Line.user("No origin", uuid: "ux", at: at(5), origin: nil), Line.text("Hm.", uuid: "ax", at: at(6))]
        let s = try #require(superseded(evaluate(unknown)))
        #expect(s.newerReplies == 1 && s.replies.first?.origin == .unknown)
    }

    @Test func theHostFactsSince() throws {
        var lines = offerTurn + [Line.user("Fix the docs", uuid: "u2", at: at(5))]
        lines.append(Line.toolUse("WebFetch", id: "toolu_web", uuid: "w1", at: at(6), input: ["url": "https://example.com"]))
        lines.append(SeamLine.result("toolu_web", uuid: "wr", at: at(6), content: "page"))
        for n in 1...9 {
            lines.append(SeamLine.edit("/home/someone/project/file\(n).md", id: "toolu_e\(n)", uuid: "e\(n)", at: at(7)))
            lines.append(SeamLine.result("toolu_e\(n)", uuid: "er\(n)", at: at(7), content: "ok"))
        }
        lines.append(SeamLine.queuedCommand(noticeText(taskID: "bg-1"), uuid: "q1", at: at(8)))
        lines.append(SeamLine.queuedCommand(noticeText(taskID: "bg-2", status: "failed"), uuid: "q2", at: at(8)))
        lines.append(SeamLine.queuedCommand(noticeText(taskID: "bg-3", status: "running"), uuid: "q3", at: at(8)))
        lines.append(Line.text("Docs updated.", uuid: "a2", at: at(9)))
        let s = try #require(superseded(evaluate(lines)))
        #expect(s.readWebSince && s.newerReplies == 1)
        #expect(s.filesChangedSince == (1...8).map { "file\($0).md" } && s.filesChangedCount == 9)
        #expect(s.backgroundTasksFinishedSince == 2, "a running status is not a finished task")
    }

    @Test func aBackgroundTurnStillRunningSaysWorkingWithItsStart() throws {
        let s = try #require(superseded(evaluate(offerTurn + notice(1, minute: 5, reply: false))))
        #expect(s.sessionIsWorking && s.unansweredMessageHead == nil && s.newerReplies == 0)
        #expect(s.latestAt == at(5))
    }

    @Test func sevenNoticeTurnsKeepCompleteFacts() throws {
        var lines = offerTurn
        for n in 1...7 { lines += notice(n, minute: Double(n * 5)) }
        let digest = digestOf(lines)
        #expect(digest.turns.first?.replyUUID == "a1", "the offer's turn stays in the digest")
        let s = try #require(superseded(evaluate(lines)))
        #expect(s.newerBackgroundUpdates == 7 && s.backgroundTasksFinishedSince == 7 && s.replies.count == 2)
    }

    @Test func anSSHSessionWhoseFileSaysMidTurnIsWorkingThoughItsMirrorShowsNothing() throws {
        let activity = at(3)
        let s = try #require(superseded(evaluate(offerTurn, midTurn: true, lastActivityAt: activity, ssh: true)))
        #expect(s.newerReplies == 0 && s.sessionIsWorking && s.latestAt == activity && s.unansweredMessageHead == nil)
        // lastActivityAt more than 10 s past what the mirror shows: working too; 9 s: fresh.
        let late = try #require(superseded(evaluate(offerTurn, lastActivityAt: at(1).addingTimeInterval(11), ssh: true)))
        #expect(late.sessionIsWorking && late.latestAt == at(1).addingTimeInterval(11))
        #expect(evaluate(offerTurn, lastActivityAt: at(1).addingTimeInterval(9), ssh: true) == .fresh)
        #expect(evaluate(offerTurn, lastActivityAt: at(1).addingTimeInterval(60), ssh: false) == .fresh, "local sessions write at once")
    }
}
