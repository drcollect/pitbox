import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The earlier-offers deriver: offers of earlier replies stay behind R22 with the engine's facts, are rebuilt only with
/// facts the engine used, drop at a third newer reply, 24 hours, a replaced transcript or a duplicated uuid, and turn
/// Copy only when their turn is not read completely or left the digest.
@Suite("Earlier offers")
struct EarlierOffersTests {
    let files = ReadyFiles("earlier")
    let folder = SeamFolder("earlier-memory")
    let clock = ManualClock(readyNow)
    let start = readyNow.addingTimeInterval(-3600)
    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    var offerTurn: [String] {
        [Line.user("Make the checkout work", uuid: "u1", at: at(0)),
         Line.text("Run it:\n\n```bash\necho ok\n```", uuid: "a1", at: at(1))]
    }

    var entry: CodeOfferEntry { readyOffer("echo ok", reply: "a1", replyTime: at(1)) }

    func derive(_ deriver: EarlierOffersDeriver, _ snapshot: CodeSessionSnapshot, _ digest: CodeTurnDigest,
                now: Date = readyNow, files: ReadyFiles? = nil) -> CodeDerivedFields {
        var fields = CodeDerivedFields()
        deriver.derive(deriveInput(snapshot, digest: digest, now: now, memory: readyStore(folder, clock: clock),
                                   files: files ?? self.files), into: &fields)
        return fields
    }

    /// The latest reply's offers as the engine shows them, then a new message of the user's.
    func carriedOver(_ deriver: EarlierOffersDeriver, after newer: [String]) -> CodeDerivedFields {
        let first = derive(deriver, readySession(sessionA, offers: [entry], replyUUID: "a1"), digestOf(offerTurn))
        #expect(first.earlierOffers.isEmpty)
        return derive(deriver, readySession(sessionA, state: .working), digestOf(offerTurn + newer))
    }

    @Test func theLatestRepliesOffersCarryOverWithPhaseOnesFacts() throws {
        let deriver = EarlierOffersDeriver()
        let first = derive(deriver, readySession(sessionA, offers: [entry], replyUUID: "a1"), digestOf(offerTurn))
        // A marker for the latest reply: the click-time check answers superseded instead of stale.
        #expect(first.earlierRegistrations.map(\.replyUUID) == ["a1"])
        #expect(first.earlierRegistrations.first?.keepsOffersWhenSuperseded == true)
        #expect(first.earlierRegistrations.first?.programs == ["ls", "git", "echo", "scp"])

        let fields = derive(deriver, readySession(sessionA, state: .working),
                            digestOf(offerTurn + [Line.user("wait", uuid: "u2", at: at(5))]))
        let earlier = try #require(fields.earlierOffers.first)
        #expect(fields.earlierOffers.count == 1 && earlier.id == entry.id && earlier.offer.text == "echo ok")
        #expect(earlier.offer.context == entry.offer.context && earlier.assessment == entry.assessment)
        let s = try #require(earlier.offer.supersession)
        #expect(s.newerReplies == 0 && s.unansweredMessageHead == "wait" && s.sessionIsWorking)
        let registration = try #require(fields.earlierRegistrations.first)
        #expect(registration.replyUUID == "a1" && registration.texts == [1: "echo ok"] && registration.keepsOffersWhenSuperseded)
        #expect(registration.cliSessionID == files.cli && registration.replyText == entry.offer.replyText)
        #expect(fields.deadlines.contains(at(1).addingTimeInterval(CommandOffer.maxAge)))
    }

    @Test func aReplyNeverSeenAsTheLatestIsRebuiltWithFactsPhaseOneUsed() throws {
        let deriver = EarlierOffersDeriver()
        // Without any offer seen yet, nothing is rebuilt (fail toward fewer offers).
        let lines = offerTurn + [Line.user("thanks", uuid: "u2", at: at(5)), Line.text("You're welcome.", uuid: "a2", at: at(6))]
        #expect(derive(deriver, readySession(sessionA, replyUUID: "a2"), digestOf(lines)).earlierOffers.isEmpty)
        // Another session's offers teach the facts every session shares.
        let other = readyOffer("ls", session: sessionB, index: 4, reply: "b1", replyTime: at(2))
        _ = derive(deriver, readySession(sessionB, index: 4, offers: [other], replyUUID: "b1"),
                   digestOf([Line.user("List", uuid: "ub", at: at(1)), Line.text("```bash\nls\n```", uuid: "b1", at: at(2))]))
        let fields = derive(deriver, readySession(sessionA, replyUUID: "a2"), digestOf(lines))
        let rebuilt = try #require(fields.earlierOffers.first)
        #expect(rebuilt.offer.text == "echo ok" && rebuilt.id == CommandOffer.ID(sessionIndex: 3, replyUUID: "a1", number: 1))
        let facts = rebuilt.offer.context.facts
        #expect(facts.sshAlias == "buildbox" && facts.resolvedHostName == "192.0.2.10" && facts.knownSSHHosts == ["buildbox"])
        #expect(facts.turnOrigin == .human && facts.homeDirectory == "/Users/someone" && facts.remoteCwd == "/home/someone/project")
        #expect(rebuilt.offer.source.youAsked == "Make the checkout work" && rebuilt.offer.replyReadCompletely)
        #expect(rebuilt.offer.supersession?.newerReplies == 1 && rebuilt.offer.context.programsOnCleanPath?.contains("ls") == true)
    }

    /// A session working on an external or network volume: an offer rebuilt from what its snapshot says keeps the
    /// folder as refused, so the sheet runs and types none of it; elsewhere nothing is refused.
    @Test func aRebuiltOfferOfASessionOnAnExternalVolumeKeepsItsFolderRefused() throws {
        let lines = offerTurn + [Line.user("thanks", uuid: "u2", at: at(5)), Line.text("You're welcome.", uuid: "a2", at: at(6))]
        let other = readyOffer("ls", session: sessionB, index: 4, reply: "b1", replyTime: at(2))
        let otherTurn = digestOf([Line.user("List", uuid: "ub", at: at(1)), Line.text("```bash\nls\n```", uuid: "b1", at: at(2))])
        for refused in [true, false] {
            let deriver = EarlierOffersDeriver()
            _ = derive(deriver, readySession(sessionB, index: 4, offers: [other], replyUUID: "b1"), otherTurn)
            var snapshot = readySession(sessionA, place: .unknown, sshHost: nil, replyUUID: "a2")
            snapshot.cwd = "/Volumes/pitbox-test-volume/project"
            snapshot.cwdOnRefusedRoot = refused
            let rebuilt = try #require(derive(deriver, snapshot, digestOf(lines)).earlierOffers.first)
            let facts = rebuilt.offer.context.facts
            #expect(facts.place == .unknown && facts.localCwd == nil)
            #expect(facts.refusedLocalCwd == (refused ? "/Volumes/pitbox-test-volume/project" : nil), "\(refused)")
        }
    }

    /// L2 of the p8 review: an offer kept from before the session's folder became a refused root (a mount-table point
    /// appeared there) carries the mark from then on; an SSH session's offer never does.
    @Test func keptOffersGainTheRefusedMarkWhenTheFolderBecomesARefusedRoot() throws {
        for ssh in [false, true] {
            let deriver = EarlierOffersDeriver()
            var local = entry
            if !ssh {
                local.offer.context.facts = CommandSessionFacts(place: .unknown, localWorkFolder: "/Users/someone/nfs/project",
                                                                homeDirectory: "/Users/someone", userName: "someone",
                                                                turnOrigin: .human)
            }
            let place: CommandSessionFacts.Place = ssh ? .ssh : .unknown
            var before = readySession(sessionA, place: place, sshHost: ssh ? "buildbox" : nil, offers: [local], replyUUID: "a1")
            before.cwd = "/Users/someone/nfs/project"
            _ = derive(deriver, before, digestOf(offerTurn))
            var after = readySession(sessionA, state: .working, place: place, sshHost: ssh ? "buildbox" : nil)
            after.cwd = "/Users/someone/nfs/project"
            after.cwdOnRefusedRoot = !ssh
            let kept = try #require(derive(deriver, after, digestOf(offerTurn + [Line.user("wait", uuid: "u2", at: at(5))]))
                .earlierOffers.first)
            #expect(kept.id == entry.id)
            #expect(kept.offer.context.facts.refusedLocalCwd == (ssh ? nil : "/Users/someone/nfs/project"), "ssh: \(ssh)")
        }
    }

    @Test func aThirdNewerReplyAgeAReplacedTranscriptAndADuplicateDropTheOffer() {
        let two = [Line.user("one", uuid: "u2", at: at(5)), Line.text("1", uuid: "a2", at: at(6)),
                   Line.user("two", uuid: "u3", at: at(7)), Line.text("2", uuid: "a3", at: at(8))]
        let deriver = EarlierOffersDeriver()
        #expect(carriedOver(deriver, after: two).earlierOffers.count == 1)
        let three = two + [Line.user("three", uuid: "u4", at: at(9)), Line.text("3", uuid: "a4", at: at(10))]
        #expect(derive(deriver, readySession(sessionA, replyUUID: "a4"), digestOf(offerTurn + three)).earlierOffers.isEmpty)

        let aged = EarlierOffersDeriver()
        _ = carriedOver(aged, after: [Line.user("wait", uuid: "u2", at: at(5))])
        let later = derive(aged, readySession(sessionA, state: .working), digestOf(offerTurn + [Line.user("wait", uuid: "u2", at: at(5))]),
                           now: at(1).addingTimeInterval(CommandOffer.maxAge + 1))
        #expect(later.earlierOffers.isEmpty)

        let replaced = EarlierOffersDeriver()
        _ = derive(replaced, readySession(sessionA, offers: [entry], replyUUID: "a1"), digestOf(offerTurn))
        files.replace()
        let after = derive(replaced, readySession(sessionA, state: .working),
                           digestOf(offerTurn + [Line.user("wait", uuid: "u2", at: at(5))]))
        #expect(after.earlierOffers.isEmpty, "the transcript was replaced: its replies are burned")

        let twice = EarlierOffersDeriver()
        let duplicated = offerTurn + [Line.text("Run it:\n\n```bash\necho ok\n```", uuid: "a1", at: at(1))]
        _ = derive(twice, readySession(sessionA, offers: [entry], replyUUID: "a1"), digestOf(duplicated))
        #expect(derive(twice, readySession(sessionA, state: .working),
                       digestOf(duplicated + [Line.user("wait", uuid: "u2", at: at(5))])).earlierOffers.isEmpty)
    }

    @Test func aTurnNotReadCompletelyOrOutOfReachIsCopyOnly() throws {
        // An unreadable line inside the offer's turn.
        let broken = [Line.user("Make the checkout work", uuid: "u1", at: at(0)), "{\"broken\":",
                      Line.text("Run it:\n\n```bash\necho ok\n```", uuid: "a1", at: at(1))]
        let deriver = EarlierOffersDeriver()
        _ = derive(deriver, readySession(sessionA, offers: [entry], replyUUID: "a1"), digestOf(broken))
        let fields = derive(deriver, readySession(sessionA, state: .working), digestOf(broken + [Line.user("wait", uuid: "u2", at: at(5))]))
        let copyOnly = try #require(fields.earlierOffers.first)
        #expect(copyOnly.assessment.commandClass == .partlyRead && !copyOnly.offer.replyReadCompletely)
        #expect(!fields.earlierRegistrations.contains { $0.replyUUID == "a1" }, "nothing can run: no registration")

        // The digest's bounds dropped the offer's turn (two notice turns and a running one remain).
        let reach = EarlierOffersDeriver()
        _ = derive(reach, readySession(sessionA, offers: [entry], replyUUID: "a1"), digestOf(offerTurn))
        var kept = digestOf([SeamLine.noticeTurn(noticeText(taskID: "t1"), uuid: "n1", at: at(5)),
                             Line.text("Agent done.", uuid: "an1", at: at(6)),
                             Line.user("And now?", uuid: "u9", at: at(7))])
        kept.truncated = true
        let far = try #require(derive(reach, readySession(sessionA, state: .working), kept).earlierOffers.first)
        #expect(far.assessment.commandClass == .partlyRead && !far.offer.replyReadCompletely && far.offer.supersession != nil)
        // Without the bounds' doing (pruned by three newer replies), it is gone.
        kept.truncated = false
        #expect(derive(reach, readySession(sessionA, state: .working), kept).earlierOffers.isEmpty)
    }

    @Test func aLatestTurnKeptOpenByMidTurnIsWorkingOnANewerTurn() throws {
        let deriver = EarlierOffersDeriver()
        _ = derive(deriver, readySession(sessionA, offers: [entry], replyUUID: "a1"), digestOf(offerTurn))
        // The mirror shows nothing new; the session file says mid-turn (the digest applies it).
        var digest = digestOf(offerTurn, midTurn: true)
        digest.lastActivityMovedAt = at(4)
        let earlier = try #require(derive(deriver, readySession(sessionA, state: .working), digest).earlierOffers.first)
        let s = try #require(earlier.offer.supersession)
        #expect(s.newerReplies == 0 && s.sessionIsWorking && s.latestAt == at(4) && s.unansweredMessageHead == nil)
    }

    @Test func ownActivityArchivedAndMissingFilesGiveNothing() {
        let deriver = EarlierOffersDeriver()
        var archived = readySession(sessionA, offers: [entry], replyUUID: "a1")
        archived.isArchived = true
        #expect(derive(deriver, archived, digestOf(offerTurn)).earlierRegistrations.isEmpty)
        var fields = CodeDerivedFields()
        deriver.derive(deriveInput(readySession(sessionA, offers: [entry], replyUUID: "a1"), digest: digestOf(offerTurn),
                                   memory: readyStore(folder, clock: clock), files: nil), into: &fields)
        #expect(fields.earlierOffers.isEmpty && fields.earlierRegistrations.isEmpty)
    }

    @Test func aLongFleetDigestStaysCheap() throws {
        // The offer, then 150 notice turns (a fleet session): the facts stay complete and the pass stays cheap.
        var lines = offerTurn
        for n in 1...150 {
            lines.append(SeamLine.noticeTurn(noticeText(taskID: "agent-\(n)"), uuid: "un\(n)", at: at(1 + Double(n) * 0.2)))
            lines.append(Line.text("Agent \(n) reported back.", uuid: "an\(n)", at: at(1.1 + Double(n) * 0.2)))
        }
        let digest = digestOf(lines)
        let deriver = EarlierOffersDeriver()
        _ = derive(deriver, readySession(sessionA, offers: [entry], replyUUID: "a1"), digestOf(offerTurn))
        let started = MonotonicClock.now()
        let fields = derive(deriver, readySession(sessionA, replyUUID: "an150"), digest)
        #expect(MonotonicClock.now() - started < 0.05)
        #expect(fields.earlierOffers.first?.offer.supersession?.newerBackgroundUpdates == 150)
    }

    @Test func theTranscriptNameGivesTheCLISessionID() {
        #expect(EarlierOffersDeriver.cliSessionID(of: files.transcript!) == files.cli)
        #expect(EarlierOffersDeriver.cliSessionID(of: CarefulPath(root: "/tmp", components: ["x.jsonl"])!) == nil)
    }
}
