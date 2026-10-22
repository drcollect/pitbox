import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The click-time check with the Ready derivers running: the tail is read again, the block's exact bytes compared at a
/// unique uuid, an SSH mirror behind its session file counts as working, and the answer carries the facts the parse
/// found. Invented files only.
@Suite("Click-time check of earlier offers", .serialized)
@MainActor
struct ClickCheckTests {
    let tree = FixtureTree("click")
    let clock = ManualClock(Date())
    let processes = Shared<[ClaudeProcessCandidate]>([])
    let folder = SeamFolder("click-memory")
    let cli = "0f3c2a9e-1111-2222-3333-444455556666"

    init() {
        CodeLog.enabled = false
        processes.value = [tree.copyA()]
    }

    var now: Date { clock.now }
    var replyAt: Date { now.addingTimeInterval(-120) }

    func engine(_ derivers: CodeDeriverSet = .ready) -> CodeSessionsEngine {
        var settings = CodeSettings()
        settings.serverNames = ["buildbox": ["box.example"]]
        let engine = CodeSessionsEngine(environment: tree.environment(clock: clock, processes: processes, settings: settings))
        let clock = self.clock
        let memory = CodeMemoryStore(url: folder.file("code-memory.json"), owner: getuid(), clock: { clock.now },
                                     writeInterval: 0.05, writeMax: CodeTuning.memoryWriteMax)
        engine.register(derivers, memory: memory)
        return engine
    }

    var lines: [String] {
        [Line.user("Send me the \(secretWord) draft", uuid: "u1", at: replyAt.addingTimeInterval(-60)),
         Line.text("Fetch it:\n\n```bash\necho \(secretWord)\n```", uuid: "a-final", at: replyAt)]
    }

    func write(midTurn: Bool? = nil, lastActivity: Date? = nil, extra: [String] = []) throws {
        var fixture = SessionFixture()
        fixture.cli = cli
        fixture.lastActivity = lastActivity ?? replyAt
        fixture.midTurn = midTurn
        fixture.summary = ("review_ready", "Draft ready", "", "a-final")
        try tree.writeSession(sessionA, fixture)
        try tree.writeLines(lines + extra, to: tree.mirrorURL(cli))
        try tree.write("Host buildbox\n  HostName 192.0.2.10\n", to: tree.sshConfig)
    }

    func append(_ more: [String]) throws { try tree.writeLines(more, to: tree.mirrorURL(cli), append: true) }

    func started() async throws -> (CodeSessionsEngine, CommandOffer.ID) {
        try write()
        try tree.writePopouts([sessionA])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        let id = try #require(engine.sessions.first?.offers.first?.id)
        return (engine, id)
    }

    func superseded(_ answer: CommandOfferFreshness) -> CommandOffer.Supersession? {
        if case .superseded(let s) = answer { return s }
        return nil
    }

    @Test func aNewMessageAnswersSupersededAndTheParseFindsTheSameFacts() async throws {
        let (engine, id) = try await started()
        #expect(engine.checker.check(id) == .fresh)
        #expect(engine.checker.registered(sessionIndex: id.sessionIndex).last?.keepsOffersWhenSuperseded == true)
        var gone = Set<CommandOffer.ID>()
        engine.onOffersWentStale = { gone.formUnion($0) }

        try append([Line.user("wait", uuid: "u9", at: now)])
        // The click sees it before the monitor does.
        let atClick = try #require(superseded(engine.checker.check(id)))
        #expect(atClick.newerReplies == 0 && atClick.unansweredMessageHead == "wait" && atClick.sessionIsWorking)

        engine.refresh()
        await engine.waitUntilIdle()
        let session = try #require(engine.sessions.first)
        #expect(session.offers.isEmpty && session.earlierOffers.map(\.id) == [id])
        #expect(session.earlierOffers.first?.offer.supersession == atClick, "the parse and the click agree")
        #expect(gone.isEmpty, "superseded, not stale")
        #expect(superseded(await engine.freshnessChecker.freshness(of: id)) == atClick)

        // The session answers: one newer reply, the command still runnable behind R22.
        try append([Line.text("Waiting.", uuid: "a9", at: now)])
        let answered = try #require(superseded(engine.checker.check(id)))
        #expect(answered.newerReplies == 1 && !answered.sessionIsWorking && answered.replies.map(\.head) == ["Waiting."])
        engine.stop()
    }

    @Test func oneChangedByteIsStale() async throws {
        let (engine, id) = try await started()
        // The same uuid, one byte more in the block (in place: the same file, larger).
        try tree.writeLines([lines[0], Line.text("Fetch it:\n\n```bash\necho \(secretWord)!\n```", uuid: "a-final", at: replyAt)],
                            to: tree.mirrorURL(cli))
        #expect(engine.checker.check(id) == .stale)
        engine.stop()
    }

    @Test func aUUIDSeenTwiceInTheTailIsStale() async throws {
        let (engine, id) = try await started()
        try append([lines[1]])
        #expect(engine.checker.check(id) == .stale)
        engine.stop()
    }

    @Test func anSSHMirrorBehindItsSessionFileAnswersSupersededWorking() async throws {
        let (engine, id) = try await started()
        let activity = replyAt.addingTimeInterval(30)
        try write(midTurn: true, lastActivity: activity)
        let mid = try #require(superseded(engine.checker.check(id)))
        #expect(mid.newerReplies == 0 && mid.sessionIsWorking && mid.unansweredMessageHead == nil)
        #expect(abs(mid.latestAt.timeIntervalSince(activity)) < 0.01)
        // No midTurn, but lastActivityAt 11 s past the reply: working too; 9 s: fresh.
        try write(lastActivity: replyAt.addingTimeInterval(11))
        #expect(superseded(engine.checker.check(id))?.sessionIsWorking == true)
        try write(lastActivity: replyAt.addingTimeInterval(9))
        #expect(engine.checker.check(id) == .fresh)
        engine.stop()
    }

    @Test func aThirdNewerReplyIsStale() async throws {
        let (engine, id) = try await started()
        let three = (1...3).flatMap { n in
            [Line.user("Message \(n)", uuid: "u\(n + 1)", at: now.addingTimeInterval(Double(n))),
             Line.text("Answer \(n)", uuid: "a\(n + 1)", at: now.addingTimeInterval(Double(n) + 0.5))]
        }
        try append(Array(three.prefix(4)))
        #expect(superseded(engine.checker.check(id))?.newerReplies == 2)
        try append(Array(three.suffix(2)))
        #expect(engine.checker.check(id) == .stale)
        engine.stop()
    }

    @Test func aCutTranscriptIsStale() async throws {
        let (engine, id) = try await started()
        let handle = try FileHandle(forWritingTo: tree.mirrorURL(cli))
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 10)
        try handle.close()
        #expect(engine.checker.check(id) == .stale)
        engine.stop()
    }

    @Test func aDayLaterItIsStale() async throws {
        let (engine, id) = try await started()
        clock.advance(CommandOffer.maxAge + 60)
        #expect(engine.checker.check(id) == .stale)
        engine.stop()
    }

    @Test func withoutWaveTwoPhaseOnesRuleHolds() async throws {
        try write()
        try tree.writePopouts([sessionA])
        let engine = engine(.none)
        engine.start()
        await engine.waitUntilIdle()
        let id = try #require(engine.sessions.first?.offers.first?.id)
        try append([Line.user("wait", uuid: "u9", at: now)])
        #expect(engine.checker.check(id) == .stale)
        engine.stop()
    }

    @Test func aLongTailIsCheckedWithinTheTimeout() async throws {
        // About 1 MB of invented work before the request.
        let filler = (0..<1200).flatMap { n in
            [Line.toolUse("Bash", id: "toolu_f\(n)", uuid: "f\(n)", at: replyAt.addingTimeInterval(-3600),
                          input: ["command": String(repeating: "x", count: 300), "description": "step \(n)"]),
             Line.toolResult("toolu_f\(n)", uuid: "fr\(n)", at: replyAt.addingTimeInterval(-3600),
                             content: String(repeating: "y", count: 400))]
        }
        try write()
        try tree.writeLines([Line.user("Start", uuid: "u0", at: replyAt.addingTimeInterval(-3700))] + filler + lines,
                            to: tree.mirrorURL(cli))
        try tree.writePopouts([sessionA])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        let id = try #require(engine.sessions.first?.offers.first?.id)
        try append([Line.user("wait", uuid: "u9", at: now)])
        let started = MonotonicClock.now()
        let answer = await engine.freshnessChecker.freshness(of: id)
        #expect(MonotonicClock.now() - started < CommandOfferFreshness.checkTimeout)
        #expect(superseded(answer)?.unansweredMessageHead == "wait")
        engine.stop()
    }
}
