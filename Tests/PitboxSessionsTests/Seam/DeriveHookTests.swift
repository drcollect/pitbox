import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The derive hook through the engine: derivers get the digest, the snapshot, the clock, the store
/// and the settings; their fields reach the snapshot; recent sessions come from session files alone.
@Suite("Derive hook", .serialized)
@MainActor
struct DeriveHookTests {
    let tree = FixtureTree("derive")
    let clock = ManualClock(Date())
    let candidates = Shared<[ClaudeProcessCandidate]>([])
    let settings = Shared(CodeSettings.withTestProfiles)
    let folder = SeamFolder("derive-memory")
    let cliA = "0f3c2a9e-1111-2222-3333-444455556666"
    let cliB = "1f3c2a9e-1111-2222-3333-444455556666"

    init() {
        CodeLog.enabled = false
        candidates.value = [tree.copyA()]
    }

    var now: Date { clock.now }

    func store() -> CodeMemoryStore {
        let clock = self.clock
        return CodeMemoryStore(url: folder.file("code-memory.json"), owner: getuid(), clock: { clock.now },
                               writeInterval: 0.05, writeMax: CodeTuning.memoryWriteMax)
    }

    func engine(_ derivers: CodeDeriverSet? = nil, memory: CodeMemoryStore? = nil) -> CodeSessionsEngine {
        let settings = self.settings
        let candidates = self.candidates
        var environment = tree.environment(clock: clock, processes: candidates)
        environment.settings = { settings.value }
        let engine = CodeSessionsEngine(environment: environment)
        if let derivers { engine.register(derivers, memory: memory ?? store()) }
        return engine
    }

    /// An SSH session: a finished turn (2 h old) whose reply holds a command, a current review_ready summary.
    func fixture(cli: String) -> SessionFixture {
        var fixture = SessionFixture()
        fixture.cli = cli
        fixture.lastActivity = now.addingTimeInterval(-120)
        fixture.summary = ("review_ready", "Draft ready \(secretWord)", "", "a-final-\(cli.prefix(4))")
        return fixture
    }

    func writeSession(_ id: String = sessionA, cli: String? = nil, extraLines: [String] = [],
                      change: (inout SessionFixture) -> Void = { _ in }) throws {
        let cli = cli ?? cliA
        let at = now.addingTimeInterval(-7200)
        var fixture = fixture(cli: cli)
        change(&fixture)
        try tree.writeSession(id, fixture)
        try tree.writeLines([
            Line.user("Send me the \(secretWord) draft", uuid: "u1-\(cli.prefix(4))", at: at),
            SeamLine.edit("/home/someone/project/shared.swift", id: "toolu_shared", uuid: "e1-\(cli.prefix(4))", at: at),
            SeamLine.result("toolu_shared", uuid: "r1-\(cli.prefix(4))", at: at, content: "ok"),
        ] + extraLines + [
            Line.text("Fetch it:\n\n```bash\necho \(secretWord)\n```", uuid: "a-final-\(cli.prefix(4))", at: at),
        ], to: tree.mirrorURL(cli))
        try tree.write("Host buildbox\n  HostName 192.0.2.10\n", to: tree.sshConfig)
    }

    func snapshot(_ engine: CodeSessionsEngine, _ id: String = sessionA) -> CodeSessionSnapshot? {
        engine.sessions.first { $0.id == id }
    }

    @Test func derivedFieldsReachTheSnapshotAndPhaseOneFieldsStay() async throws {
        try writeSession()
        try tree.writePopouts([sessionA])
        let memory = store()
        let at = now
        let deriver = RecordingDeriver { input, fields in
            fields.workStartedAt = input.digest.latestHumanOrPeerTurn?.startedAt
            fields.progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 4, total: 6)
            fields.eta = CodeETA(kind: .estimate, at: at.addingTimeInterval(540), minutesLeft: 9)
            fields.results = [CodeResult(kind: .artifact, origin: .replyLink,
                                         url: URL(string: "https://claude.ai/artifact/abcdefgh"), label: "artifact")]
            fields.otherLinkCount = 2
            fields.warnings = [CodeWarning(kind: .silence, since: at)]
            fields.dashboard = CodeDashboard(handle: "polar-shore", site: .test, firstSeen: at)
            fields.finished = input.snapshot.replyUUID.map { CodeFinishedMark(replyUUID: $0, at: at, ranSeconds: 1260) }
            fields.unread = true
        }
        let engine = engine(CodeDeriverSet(perSession: [deriver]), memory: memory)
        engine.start()
        await engine.waitUntilIdle()
        let session = try #require(snapshot(engine))
        #expect(session.state == .reviewReady && session.offers.count == 1, "the parsed fields unchanged")
        #expect(session.replyUUID == "a-final-0f3c")
        #expect(abs((session.workStartedAt?.timeIntervalSince(now) ?? 0) + 7200) < 0.01, "timestamps keep milliseconds")
        #expect(session.progress?.done == 4 && session.progress?.fraction == 4.0 / 6.0)
        #expect(session.eta?.minutesLeft == 9 && session.results.count == 1 && session.otherLinkCount == 2)
        #expect(session.warnings.map(\.kind) == [.silence] && session.dashboard?.handle == "polar-shore")
        #expect(session.finished?.replyUUID == "a-final-0f3c" && session.unread)

        let seen = try #require(deriver.seen.last)
        #expect(seen.sessionID == sessionA && seen.now == now && seen.memory === memory && seen.settings == settings.value)
        #expect(seen.digest.turns.count == 1 && seen.digest.latestTurn?.replyUUID == session.replyUUID)
        #expect(seen.snapshot.workStartedAt == nil, "derivers get the parsed snapshot")
        #expect(seen.transcript?.name == "\(cliA).jsonl" && seen.sessionFile?.name == "\(sessionA).json")
        // The click-time registry holds the exact text.
        let reply = try #require(engine.checker.registered(sessionIndex: session.index).last)
        #expect(reply.texts[1] == session.offers.first?.offer.text)
        engine.stop()
    }

    @Test func withoutDeriversTheWaveTwoFieldsStayEmpty() async throws {
        try writeSession()
        try tree.writePopouts([sessionA])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        let session = try #require(snapshot(engine))
        #expect(session.replyUUID == "a-final-0f3c", "the seam fills the reply uuid itself")
        #expect(session.progress == nil && session.eta == nil && session.results.isEmpty && session.warnings.isEmpty)
        #expect(session.dashboard == nil && session.finished == nil && !session.unread && session.earlierOffers.isEmpty)
        engine.stop()
    }

    @Test func deriversRunInOrderAndSeeWhatEarlierOnesWrote() async throws {
        try writeSession()
        try tree.writePopouts([sessionA])
        let sequence = Shared<[String]>([])
        let seenCount = Shared<Int>(-1)
        let late = RecordingDeriver(label: "late", order: CodeDeriveOrder.finished) { _, fields in
            sequence.value.append("late")
            seenCount.value = fields.otherLinkCount
            fields.unread = true
        }
        let early = RecordingDeriver(label: "early", order: CodeDeriveOrder.work) { _, fields in
            sequence.value.append("early")
            fields.otherLinkCount = 3
        }
        let engine = engine(CodeDeriverSet(perSession: [late]) + CodeDeriverSet(perSession: [early]))
        engine.start()
        await engine.waitUntilIdle()
        #expect(sequence.value.prefix(2) == ["early", "late"] && seenCount.value == 3)
        #expect(snapshot(engine)?.otherLinkCount == 3 && snapshot(engine)?.unread == true)
        engine.stop()
    }

    @Test func outputIsReusedUntilAnInputChanges() async throws {
        try writeSession()
        try tree.writePopouts([sessionA])
        let memory = store()
        struct Seen: Codable { var at: Date }
        let at = now
        // It writes its own record each time: that must not make it run again.
        let deriver = RecordingDeriver { input, _ in input.memory.write(.seen, session: input.sessionID, value: Seen(at: at)) }
        let engine = engine(CodeDeriverSet(perSession: [deriver]), memory: memory)
        engine.start()
        await engine.waitUntilIdle()
        #expect(deriver.runs(for: sessionA) == 1)
        engine.reloadSettings()
        await engine.waitUntilIdle()
        #expect(deriver.runs(for: sessionA) == 1, "nothing changed: reused")
        // A record written from outside (the block, on the main thread) brings it back.
        memory.write(.ready, session: sessionA, value: ["warn:\(sessionA):silence": ["state": "dismissed", "at": iso(at)]])
        #expect(await eventually { deriver.runs(for: sessionA) == 2 })
        await engine.waitUntilIdle()
        #expect(deriver.runs(for: sessionA) == 2)
        // New settings.
        settings.value.chime = true
        engine.reloadSettings()
        await engine.waitUntilIdle()
        #expect(deriver.runs(for: sessionA) == 3 && deriver.seen.last?.settings.chime == true)
        // A new transcript line.
        try tree.writeLines([Line.user("thanks", uuid: "u9", at: now)], to: tree.mirrorURL(cliA), append: true)
        engine.refresh()
        await engine.waitUntilIdle()
        #expect(deriver.runs(for: sessionA) == 4 && deriver.seen.last?.digest.turns.count == 2)
        memory.flush()
        engine.stop()
    }

    @Test func aDeadlineRunsTheDeriversAgain() async throws {
        try writeSession()
        try tree.writePopouts([sessionA])
        let start = now
        let deriver = RecordingDeriver { input, fields in
            fields.deadlines = [start.addingTimeInterval(60)]
            fields.eta = input.now >= start.addingTimeInterval(60) ? CodeETA(kind: .stated, at: start, isLate: true) : nil
        }
        let engine = engine(CodeDeriverSet(perSession: [deriver]))
        engine.start()
        await engine.waitUntilIdle()
        #expect(deriver.runs(for: sessionA) == 1 && snapshot(engine)?.eta == nil)
        clock.advance(30)
        engine.reloadSettings()
        await engine.waitUntilIdle()
        #expect(deriver.runs(for: sessionA) == 1)
        clock.advance(31)
        engine.reloadSettings()
        await engine.waitUntilIdle()
        #expect(deriver.runs(for: sessionA) == 2 && snapshot(engine)?.eta?.isLate == true)
        engine.stop()
    }

    @Test func theCrossSessionPassSeesEverySessionWithItsFields() async throws {
        try writeSession(sessionA, cli: cliA)
        try writeSession(sessionB, cli: cliB)
        try tree.writePopouts([sessionA, sessionB])
        let perSession = RecordingDeriver { input, fields in fields.otherLinkCount = input.snapshot.index }
        let first = RecordingCrossDeriver(order: CodeDeriveOrder.sameFile) { sessions, fields in
            guard let one = sessions.first else { return }
            fields[one.sessionID, default: CodeDerivedFields()].warnings.append(
                CodeWarning(kind: .sameFile, since: Date(timeIntervalSince1970: 0), otherSessionID: sessions.last?.sessionID))
        }
        let warnedSeen = Shared<Int>(0)
        let second = RecordingCrossDeriver(order: CodeDeriveOrder.unread) { sessions, fields in
            warnedSeen.value = sessions.filter { !$0.snapshot.warnings.isEmpty }.count
            for session in sessions { fields[session.sessionID]?.unread = !session.snapshot.warnings.isEmpty }
        }
        let engine = engine(CodeDeriverSet(perSession: [perSession], crossSession: [second, first]))
        engine.start()
        await engine.waitUntilIdle()
        let inputs = try #require(first.runs.last)
        #expect(inputs.map(\.sessionID) == [sessionA, sessionB])
        #expect(inputs.allSatisfy { $0.snapshot.otherLinkCount == $0.snapshot.index }, "per-session fields applied")
        #expect(warnedSeen.value == 1, "the later cross deriver sees the earlier one's warning")
        #expect(snapshot(engine, sessionA)?.warnings.first?.otherSessionID == sessionB && snapshot(engine, sessionA)?.unread == true)
        #expect(snapshot(engine, sessionB)?.warnings.isEmpty == true && snapshot(engine, sessionB)?.unread == false)
        engine.stop()
    }

    @Test func aForksCopiedToolUsesAreMarkedInEverySessionThatHoldsThem() async throws {
        try writeSession(sessionA, cli: cliA)
        try writeSession(sessionB, cli: cliB, extraLines: [
            SeamLine.edit("/home/someone/project/own.swift", id: "toolu_own", uuid: "own-1", at: now.addingTimeInterval(-7000)),
            SeamLine.result("toolu_own", uuid: "own-r", at: now.addingTimeInterval(-7000), content: "ok"),
        ])
        try tree.writePopouts([sessionA, sessionB])
        let deriver = RecordingDeriver()
        let engine = engine(CodeDeriverSet(perSession: [deriver]))
        engine.start()
        await engine.waitUntilIdle()
        func uses(_ id: String) -> [CodeTurnDigest.ToolUse] {
            (deriver.seen.last { $0.sessionID == id }?.digest.allItems ?? []).compactMap { item in
                if case .toolUse(let use) = item { return use }
                return nil
            }
        }
        #expect(uses(sessionA).first { $0.id == "toolu_shared" }?.isCopied == true)
        #expect(uses(sessionB).first { $0.id == "toolu_shared" }?.isCopied == true)
        #expect(uses(sessionB).first { $0.id == "toolu_own" }?.isCopied == false)
        engine.stop()
    }

    @Test func growthAndActivityMovesReachTheDigest() async throws {
        let earlier = now.addingTimeInterval(-300)
        try writeSession { $0.lastActivity = earlier }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: tree.mirrorURL(cliA).path)
        try tree.writePopouts([sessionA])
        let deriver = RecordingDeriver()
        let engine = engine(CodeDeriverSet(perSession: [deriver]))
        engine.start()
        await engine.waitUntilIdle()
        var digest = try #require(deriver.seen.last?.digest)
        #expect(abs((digest.lastGrowthAt?.timeIntervalSince1970 ?? 0) - now.addingTimeInterval(-100).timeIntervalSince1970) < 0.01)
        #expect(abs((digest.lastActivityMovedAt?.timeIntervalSince1970 ?? 0) - now.addingTimeInterval(-300).timeIntervalSince1970) < 0.01)
        #expect(digest.publishedArtifacts.isEmpty)

        // The transcript grows; the session file's lastActivityAt moves and it lists an artifact.
        try tree.writeLines([Line.user("more", uuid: "u-more", at: now)], to: tree.mirrorURL(cliA), append: true)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-50)], ofItemAtPath: tree.mirrorURL(cliA).path)
        var moved = fixture(cli: cliA)
        moved.lastActivity = now.addingTimeInterval(-30)
        moved.extra = ["publishedArtifacts": [["url": "https://claude.ai/artifact/abcdefgh12", "title": "\(secretWord)",
                                               "updatedAt": Int(now.timeIntervalSince1970 * 1000)]]]
        try tree.writeSession(sessionA, moved)
        engine.refresh()
        await engine.waitUntilIdle()
        digest = try #require(deriver.seen.last?.digest)
        #expect(abs((digest.lastGrowthAt?.timeIntervalSince1970 ?? 0) - now.addingTimeInterval(-50).timeIntervalSince1970) < 0.01)
        #expect(abs((digest.lastActivityMovedAt?.timeIntervalSince1970 ?? 0) - now.addingTimeInterval(-30).timeIntervalSince1970) < 0.01)
        #expect(digest.publishedArtifacts.map(\.url) == ["https://claude.ai/artifact/abcdefgh12"])
        engine.stop()
    }

    @Test func recentSessionsComeFromSessionFilesAlone() async throws {
        func ms(_ seconds: Double) -> Int { Int(now.addingTimeInterval(seconds).timeIntervalSince1970 * 1000) }
        func write(_ id: String, profile: CodeProfile = .a, _ change: (inout SessionFixture) -> Void) throws {
            var fixture = SessionFixture()
            fixture.cli = "2f3c2a9e-1111-2222-3333-\(id.suffix(12))"
            change(&fixture)
            try tree.writeSession(id, fixture, profile: profile)
        }
        let focused = "local_0aaaaaaa-1111-4111-8111-000000000011"
        let messaged = "local_0aaaaaaa-1111-4111-8111-000000000012"
        let ownOnly = "local_0aaaaaaa-1111-4111-8111-000000000013"
        let archived = "local_0aaaaaaa-1111-4111-8111-000000000014"
        let oldFile = "local_0aaaaaaa-1111-4111-8111-000000000015"
        let broken = "local_0aaaaaaa-1111-4111-8111-000000000016"
        let otherCopy = "local_0bbbbbbb-2222-4222-8222-000000000017"
        try write(focused) { $0.lastActivity = now.addingTimeInterval(-5 * 3600); $0.extra = ["lastFocusedAt": ms(-3600)] }
        try write(messaged) { $0.lastActivity = now.addingTimeInterval(-5 * 3600); $0.extra = ["latestUserFrameAt": ms(-7200)] }
        try write(ownOnly) { $0.lastActivity = now.addingTimeInterval(-3 * 3600) }
        try write(archived) { $0.archived = true; $0.extra = ["lastFocusedAt": ms(-600)] }
        try write(oldFile) { $0.lastActivity = now.addingTimeInterval(-3 * 86_400); $0.extra = ["lastFocusedAt": ms(-600)] }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)],
                                              ofItemAtPath: tree.sessionFileURL(oldFile).path)
        try tree.writeRawSession(broken, #"{"title":"\#(secretWord)","title":"x","lastFocusedAt":\#(ms(-60))}"#)
        try write(otherCopy, profile: .b) { $0.extra = ["lastFocusedAt": ms(-600)] }
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        #expect(engine.recentSessions(within: 6).map(\.id) == [focused, messaged, ownOnly])
        #expect(engine.recentSessions(within: 2.5).map(\.id) == [focused, messaged], "own activity 3 h ago is outside")
        #expect(engine.recentSessions(within: 0).isEmpty && engine.recentSessions(within: -1).isEmpty)
        #expect(engine.recentSessions(within: .nan).isEmpty)
        let first = try #require(engine.recentSessions(within: 6).first)
        #expect(first.profile == .a && first.lastFocusedAt != nil && first.latestUserFrameAt == nil)
        #expect(first.usersLastActivity == first.lastFocusedAt)
        #expect(engine.recentSessions(within: 6)[2].usersLastActivity == nil)
        // Nothing was followed: no session is shown and no transcript was read.
        #expect(engine.sessions.isEmpty && engine.worker.debugState.fullyRead == 0)
        // Copy B starts: its session joins (looked at once the block shows).
        candidates.value = [tree.copyA(), tree.copyB()]
        engine.refreshProcesses()
        await engine.waitUntilIdle()
        #expect(!engine.recentSessions(within: 6).map(\.id).contains(otherCopy), "hidden: nothing is read on its own")
        engine.setStripVisible(true)
        await engine.waitUntilIdle()
        #expect(engine.recentSessions(within: 6).map(\.id).contains(otherCopy))
        engine.setStripVisible(false)
        engine.stop()
        await engine.waitUntilIdle()
        #expect(engine.recentSessions(within: 6).isEmpty)
    }

    @Test func aSessionThatStopsBeingReadIsForgottenByItsDerivers() async throws {
        try writeSession()
        let deriver = RecordingDeriver()
        let cross = RecordingCrossDeriver()
        let engine = engine(CodeDeriverSet(perSession: [deriver], crossSession: [cross]))
        engine.start()
        engine.setWatched([sessionA])
        await engine.waitUntilIdle()
        #expect(deriver.runs(for: sessionA) >= 1 && cross.runs.last?.map(\.sessionID) == [sessionA])
        engine.setWatched([])
        await engine.waitUntilIdle()
        #expect(deriver.left.contains(sessionA) && engine.sessions.isEmpty)
        engine.stop()
    }

    @Test func anOfferMovedToEarlierOffersDoesNotGoStale() async throws {
        try writeSession()
        try tree.writePopouts([sessionA])
        let kept = Shared<[CodeOfferEntry]>([])
        // A stand-in for the earlier-offers deriver: once the latest reply's offers leave, it keeps them as earlier
        // ones.
        let deriver = RecordingDeriver(order: CodeDeriveOrder.earlierOffers) { input, fields in
            if !input.snapshot.offers.isEmpty { kept.value = input.snapshot.offers } else { fields.earlierOffers = kept.value }
        }
        let engine = engine(CodeDeriverSet(perSession: [deriver]))
        var gone = Set<CommandOffer.ID>()
        engine.onOffersWentStale = { gone.formUnion($0) }
        engine.start()
        await engine.waitUntilIdle()
        let id = try #require(snapshot(engine)?.offers.first?.id)
        try tree.writeLines([Line.user("thanks", uuid: "u9", at: now)], to: tree.mirrorURL(cliA), append: true)
        engine.refresh()
        await engine.waitUntilIdle()
        #expect(snapshot(engine)?.offers.isEmpty == true && snapshot(engine)?.earlierOffers.map(\.id) == [id])
        #expect(gone.isEmpty, "superseded, not stale")
        engine.stop()
    }

    @Test func theMemoryOfSessionsGoneFromEveryIndexIsPruned() async throws {
        try writeSession()
        let memory = store()
        struct Seen: Codable { var at: Date }
        let ghost = "local_0ddddddd-4444-4444-8444-000000000099"
        memory.write(.seen, session: sessionA, value: Seen(at: now))
        memory.write(.seen, session: ghost, value: Seen(at: now))
        let engine = engine(CodeDeriverSet(perSession: [RecordingDeriver()]), memory: memory)
        engine.start()
        await engine.waitUntilIdle()
        #expect(await eventually { memory.sessionIDs == [sessionA] })
        memory.flush()
        engine.stop()
    }

    @Test func aSlowPassIsLoggedWithLabelsAndNumbersOnly() async throws {
        let lines = Shared<[String]>([])
        let token = CodeLog.observe { lines.value.append($0) }
        defer { CodeLog.stopObserving(token) }
        try writeSession()
        try tree.writePopouts([sessionA])
        let slow = RecordingDeriver(label: "slow") { _, _ in
            let until = MonotonicClock.now() + 0.015
            while MonotonicClock.now() < until {}
        }
        let engine = engine(CodeDeriverSet(perSession: [slow]))
        engine.start()
        await engine.waitUntilIdle()
        engine.stop()
        await engine.waitUntilIdle()
        #expect(lines.value.contains { $0.contains("derive over budget slowest=slow passes=") && $0.contains("last=session") })
        #expect(lines.value.contains { $0.contains("started") && $0.contains("derivers=1") })
        for line in lines.value {
            #expect(!line.contains(secretWord) && !line.contains(sessionA) && !line.contains(tree.root.path) && !line.contains(cliA))
        }
    }
}
