import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The engine over invented folders that look like Claude's: copy A's pop-outs, an SSH session with a finished reply
/// that holds a command, and a local session that is working.
@Suite("Engine", .serialized)
@MainActor
struct EngineTests {
    let tree = FixtureTree("engine")
    let clock = ManualClock(Date())
    let processes = Shared<[ClaudeProcessCandidate]>([])
    let sshCLI = "0f3c2a9e-1111-2222-3333-444455556666"
    let localCLI = "1f3c2a9e-1111-2222-3333-444455556666"
    let scp = "scp 'someone@192.0.2.10:/home/someone/\(secretWord).md' ~/Downloads/"

    init() {
        CodeLog.enabled = false
        processes.value = [tree.copyA()]
    }

    var now: Date { clock.now }

    func engine(settings: CodeSettings? = nil, watches: Bool = false, maxWatched: Int = 24) -> CodeSessionsEngine {
        var defaults = CodeSettings()
        defaults.serverNames = ["buildbox": ["box.example"]]
        return CodeSessionsEngine(environment: tree.environment(clock: clock, processes: processes, settings: settings ?? defaults,
                                                                watches: watches, maxWatched: maxWatched))
    }

    /// The SSH session: a finished turn whose reply holds the scp command, with a current review_ready summary.
    func writeSSHSession(id: String = sessionA, cli: String? = nil, change: (inout SessionFixture) -> Void = { _ in }) throws {
        let cli = cli ?? sshCLI
        let at = now.addingTimeInterval(-120)
        var fixture = SessionFixture()
        fixture.cli = cli
        fixture.lastActivity = at
        fixture.summary = ("review_ready", "Draft ready \(secretWord)", "", "a-final-\(cli.prefix(4))")
        change(&fixture)
        try tree.writeSession(id, fixture)
        try tree.writeLines([
            Line.user("Send me the \(secretWord) draft\nplease", uuid: "u1", at: at),
            Line.toolUse("Bash", id: "toolu_1", uuid: "a1", at: at, input: ["description": "Write the draft", "command": "x"]),
            Line.toolResult("toolu_1", uuid: "r1", at: at),
            Line.text("Fetch it on your Mac:\n\n```bash\n\(scp)\n```", uuid: "a-final-\(cli.prefix(4))", at: at),
        ], to: tree.mirrorURL(cli))
        try tree.write("Host buildbox\n  HostName 192.0.2.10\n", to: tree.sshConfig)
    }

    /// The local session: a tool call waiting for its result, written just now.
    func writeLocalSession(id: String = sessionB) throws -> String {
        let cwd = tree.localFolder()
        var fixture = SessionFixture()
        fixture.title = "Tidy the \(secretWord) tests (calm otter)"
        fixture.cli = localCLI
        fixture.sshHost = nil
        fixture.cwd = cwd
        fixture.lastActivity = now
        try tree.writeSession(id, fixture)
        try tree.writeLines([
            Line.user("Tidy up", uuid: "u1", at: now.addingTimeInterval(-20)),
            Line.toolUse("Bash", id: "toolu_2", uuid: "a1", at: now.addingTimeInterval(-5), input: ["description": "Run the tests"]),
        ], to: tree.localTranscriptURL(localCLI, cwd: cwd))
        return cwd
    }

    func snapshot(_ engine: CodeSessionsEngine, _ id: String) -> CodeSessionSnapshot? { engine.sessions.first { $0.id == id } }

    @Test func showsPopOutsWithTheirStatesAndOffers() async throws {
        try writeSSHSession()
        let cwd = try writeLocalSession()
        try tree.writePopouts([sessionA, sessionB])
        let engine = engine()
        var changes = 0
        engine.onChange = { changes += 1 }
        engine.start()
        await engine.waitUntilIdle()
        #expect(changes >= 1)
        #expect(engine.sessions.map(\.id) == [sessionA, sessionB])
        #expect(engine.runningProfiles == [.a] && engine.runningProcesses.first?.pid == 4242 && engine.banner == nil)

        let ssh = try #require(snapshot(engine, sessionA))
        #expect(ssh.headline == "Fix the \(secretWord) build" && ssh.nickname == "quiet fern")
        #expect(ssh.place == .ssh && ssh.sshHost == "buildbox" && ssh.state == .reviewReady)
        #expect(ssh.tldr == "Draft ready \(secretWord)" && ssh.askLine == nil && ssh.popout?.bounds != nil)
        #expect(ssh.turnFinishedAt != nil && ssh.steps.map(\.words) == ["running: Write the draft"])
        let entry = try #require(ssh.offers.first)
        #expect(ssh.offers.count == 1 && ssh.offersNotShown == 0)
        let offer = entry.offer
        #expect(offer.text == scp && offer.blockKind == .tagged("bash") && offer.caption == "Fetch it on your Mac:")
        #expect(offer.replyReadCompletely && offer.total == 1 && offer.id.number == 1 && offer.id.sessionIndex == ssh.index)
        #expect(offer.source.youAsked == "Send me the \(secretWord) draft\nplease" && offer.source.profileLetter == nil)
        #expect(offer.folder == CommandOffer.Folder(path: tree.home.path, isHomeFallback: false))
        #expect(offer.context.runFolder == tree.home.path && offer.context.pathFacts.isEmpty)
        let facts = offer.context.facts
        #expect(facts.place == .ssh && facts.sshAlias == "buildbox" && facts.resolvedHostName == "192.0.2.10")
        #expect(facts.serverNames == ["box.example"] && facts.knownSSHHosts == ["buildbox"])
        #expect(facts.remoteCwd == "/home/someone/project" && facts.localCwd == nil && facts.turnOrigin == .human && !facts.turnReadWeb)
        #expect(facts.localWorkFolder == nil && facts.refusedLocalCwd == nil, "a server path is never walked here")
        #expect(offer.context.programsOnCleanPath?.contains("scp") == true)
        if CommandClassifier.policyVersion == 0 { #expect(entry.assessment.commandClass == .blocked) }
        #expect(engine.checker.registered(sessionIndex: ssh.index).count == 1)

        let local = try #require(snapshot(engine, sessionB))
        #expect(local.place == .local && local.cwd == cwd && local.state == .working)
        #expect(local.now == "running: Run the tests" && local.offers.isEmpty && local.nickname == "calm otter")
        engine.stop()
        await engine.waitUntilIdle()
        #expect(engine.sessions.isEmpty)
    }

    /// H4: an `Include` Pitbox refused (here a link) may hold a `Match exec` it never saw, so `ssh -G` does not run
    /// and the HostName stays unknown.
    @Test func aRefusedIncludeKeepsSSHGFromRunning() async throws {
        try writeSSHSession()
        try tree.writePopouts([sessionA])
        let real = tree.home.appendingPathComponent("dotfiles/extra.conf")
        try tree.write("Host other\n", to: real)
        try FileManager.default.createSymbolicLink(atPath: tree.ssh.appendingPathComponent("extra.conf").path, withDestinationPath: real.path)
        try tree.write("Host buildbox\n  HostName 192.0.2.10\nInclude extra.conf\n", to: tree.sshConfig)
        let asked = Shared<[String]>([])
        var defaults = CodeSettings()
        defaults.serverNames = ["buildbox": ["box.example"]]
        var environment = tree.environment(clock: clock, processes: processes, settings: defaults)
        environment.hostName = { alias in
            asked.value.append(alias)
            return "192.0.2.10"
        }
        let engine = CodeSessionsEngine(environment: environment)
        engine.start()
        await engine.waitUntilIdle()
        let facts = try #require(snapshot(engine, sessionA)?.offers.first).offer.context.facts
        #expect(facts.sshAlias == "buildbox" && facts.resolvedHostName == nil)
        #expect(asked.value.isEmpty, "ssh -G never ran")
        engine.stop()
        await engine.waitUntilIdle()
    }

    /// An `Include` on an external or network volume is never looked up; `ssh -G` would look there, so it does not run.
    @Test func anIncludeOnAnExternalVolumeKeepsSSHGFromRunning() async throws {
        try writeSSHSession()
        try tree.writePopouts([sessionA])
        try tree.write("Host buildbox\n  HostName 192.0.2.10\nInclude /Volumes/pitbox-test-volume/ssh.conf\n", to: tree.sshConfig)
        let asked = Shared<[String]>([])
        var defaults = CodeSettings()
        defaults.serverNames = ["buildbox": ["box.example"]]
        var environment = tree.environment(clock: clock, processes: processes, settings: defaults)
        environment.hostName = { alias in
            asked.value.append(alias)
            return "192.0.2.10"
        }
        let engine = CodeSessionsEngine(environment: environment)
        engine.start()
        await engine.waitUntilIdle()
        let facts = try #require(snapshot(engine, sessionA)?.offers.first).offer.context.facts
        #expect(facts.sshAlias == "buildbox" && facts.resolvedHostName == nil)
        #expect(asked.value.isEmpty, "ssh -G never ran")
        engine.stop()
        await engine.waitUntilIdle()
    }

    /// A local session whose finished reply offers `echo done`, working in `cwd` (nothing has to exist there).
    func writeFinishedLocalSession(cwd: String, id: String = sessionB) throws {
        let at = now.addingTimeInterval(-120)
        var fixture = SessionFixture()
        fixture.title = "Tidy the \(secretWord) tests (calm otter)"
        fixture.cli = localCLI
        fixture.sshHost = nil
        fixture.cwd = cwd
        fixture.lastActivity = at
        fixture.summary = ("review_ready", "Tidied \(secretWord)", "", "a-final-local")
        try tree.writeSession(id, fixture)
        try tree.writeLines([
            Line.user("Tidy up", uuid: "u1", at: at),
            Line.text("Run this:\n\n```bash\necho done\n```", uuid: "a-final-local", at: at),
        ], to: tree.localTranscriptURL(localCLI, cwd: cwd))
    }

    /// A local session working on an external volume: its folder is never looked up, its place is unknown, and its
    /// offers name the folder as refused, so the sheet runs and types none of them. A local one elsewhere does not.
    @Test func aSessionOnAnExternalVolumeHandsItsFolderOverAsRefused() async throws {
        let cwd = "/Volumes/pitbox-test-volume/my project"
        try writeFinishedLocalSession(cwd: cwd)
        try tree.writePopouts([sessionB])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        let session = try #require(snapshot(engine, sessionB))
        #expect(session.place == .unknown && session.cwd == cwd && session.cwdOnRefusedRoot)
        let facts = try #require(session.offers.first).offer.context.facts
        #expect(facts.place == .unknown && facts.refusedLocalCwd == cwd && facts.localCwd == nil && facts.localWorkFolder == cwd)
        engine.stop()
        await engine.waitUntilIdle()

        let local = tree.localFolder("work/here")
        try writeFinishedLocalSession(cwd: local)
        let again = self.engine()
        again.start()
        await again.waitUntilIdle()
        let found = try #require(snapshot(again, sessionB))
        #expect(found.place == .local && !found.cwdOnRefusedRoot)
        let localFacts = try #require(found.offers.first).offer.context.facts
        #expect(localFacts.refusedLocalCwd == nil && localFacts.localWorkFolder == local, "the sheet decides it again")
        again.stop()
        await again.waitUntilIdle()
    }

    @Test func aMissingPopoutsFileMeansNoPopoutsAndFollowedSessionsStillShow() async throws {
        try writeSSHSession()
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        #expect(engine.sessions.isEmpty)
        engine.setWatched([sessionA, "not-a-session"])
        await engine.waitUntilIdle()
        let followed = try #require(engine.sessions.first)
        #expect(engine.sessions.count == 1 && followed.id == sessionA && followed.popout == nil && followed.state == .reviewReady)
        engine.stop()
    }

    @Test func aNewTurnMakesTheOfferStale() async throws {
        try writeSSHSession()
        try tree.writePopouts([sessionA])
        let engine = engine()
        var gone = Set<CommandOffer.ID>()
        engine.onOffersWentStale = { gone.formUnion($0) }
        engine.start()
        await engine.waitUntilIdle()
        let id = try #require(snapshot(engine, sessionA)?.offers.first?.id)
        #expect(await engine.freshnessChecker.freshness(of: id) == .fresh)
        try tree.writeLines([Line.user("thanks", uuid: "u9", at: now)], to: tree.mirrorURL(sshCLI), append: true)
        // The click-time check sees it before the monitor does.
        #expect(engine.checker.check(id) == .stale)
        engine.refresh()
        await engine.waitUntilIdle()
        #expect(snapshot(engine, sessionA)?.offers.isEmpty == true)
        #expect(gone == [id])
        #expect(await engine.freshnessChecker.freshness(of: id) == .stale)
        engine.stop()
    }

    @Test func aNewAssistantEntryOrAnArchivedSessionMakesItStale() async throws {
        try writeSSHSession()
        try tree.writePopouts([sessionA])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        let id = try #require(snapshot(engine, sessionA)?.offers.first?.id)
        try writeSSHSession { $0.archived = true }
        #expect(engine.checker.check(id) == .stale)
        engine.refresh()
        await engine.waitUntilIdle()
        #expect(snapshot(engine, sessionA)?.offers.isEmpty == true && snapshot(engine, sessionA)?.isArchived == true)
        try writeSSHSession()
        engine.refresh()
        await engine.waitUntilIdle()
        let again = try #require(snapshot(engine, sessionA)?.offers.first?.id)
        try tree.writeLines([Line.text("One more thing.", uuid: "a-extra", at: now)], to: tree.mirrorURL(sshCLI), append: true)
        #expect(engine.checker.check(again) == .stale)
        engine.stop()
    }

    @Test func aReplacedOrCutTranscriptDropsTheOfferForGood() async throws {
        try writeSSHSession()
        try tree.writePopouts([sessionA])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        let id = try #require(snapshot(engine, sessionA)?.offers.first?.id)
        // The same lines in a new file (a new inode).
        let copy = tree.root.appendingPathComponent("copy.jsonl")
        try FileManager.default.copyItem(at: tree.mirrorURL(sshCLI), to: copy)
        _ = try FileManager.default.replaceItemAt(tree.mirrorURL(sshCLI), withItemAt: copy)
        #expect(engine.checker.check(id) == .stale)
        engine.refresh()
        await engine.waitUntilIdle()
        #expect(snapshot(engine, sessionA)?.offers.isEmpty == true)
        #expect(snapshot(engine, sessionA)?.state == .reviewReady)
        // A new turn with a new reply is offered again.
        let later = now.addingTimeInterval(-30)
        try tree.writeLines([Line.user("And the other one?", uuid: "u2", at: later),
                             Line.text("```bash\necho two\n```", uuid: "a-two", at: later)], to: tree.mirrorURL(sshCLI), append: true)
        engine.refresh()
        await engine.waitUntilIdle()
        #expect(snapshot(engine, sessionA)?.offers.map(\.offer.text) == ["echo two"])
        // Cut: smaller than before.
        let handle = try FileHandle(forWritingTo: tree.mirrorURL(sshCLI))
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 10)
        try handle.close()
        engine.refresh()
        await engine.waitUntilIdle()
        #expect(snapshot(engine, sessionA)?.offers.isEmpty == true)
        engine.stop()
    }

    @Test func offersExpireAfterADay() async throws {
        try writeSSHSession()
        try tree.writePopouts([sessionA])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        let id = try #require(snapshot(engine, sessionA)?.offers.first?.id)
        clock.advance(CommandOffer.maxAge + 60)
        #expect(engine.checker.check(id) == .stale)
        engine.refresh()
        await engine.waitUntilIdle()
        #expect(snapshot(engine, sessionA)?.offers.isEmpty == true)
        engine.stop()
    }

    @Test func theClickTimeCheckGivesUpAfterItsTimeout() async throws {
        try writeSSHSession()
        try tree.writePopouts([sessionA])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        let id = try #require(snapshot(engine, sessionA)?.offers.first?.id)
        engine.checker.timeout = 0.05
        engine.checker.suspendChecks()
        let answer = await engine.freshnessChecker.freshness(of: id)
        engine.checker.resumeChecks()
        #expect(answer == .unknown)
        engine.checker.timeout = CommandOfferFreshness.checkTimeout
        #expect(await engine.freshnessChecker.freshness(of: id) == .fresh)
        // A line still being written after the reply: try again later.
        let handle = try FileHandle(forWritingTo: tree.mirrorURL(sshCLI))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"user\",\"mess".utf8))
        try handle.close()
        #expect(await engine.freshnessChecker.freshness(of: id) == .unknown)
        #expect(engine.checker.check(CommandOffer.ID(sessionIndex: id.sessionIndex, replyUUID: "other", number: 1)) == .stale)
        #expect(engine.checker.check(CommandOffer.ID(sessionIndex: id.sessionIndex, replyUUID: id.replyUUID, number: 2)) == .stale)
        engine.stop()
    }

    @Test func failingSessionFilesAreUnknownAndManyFailuresShowTheBanner() async throws {
        try writeSSHSession()
        try tree.writeRawSession(sessionB, #"{"title":"one","title":"two"}"#)
        try tree.writeRawSession(sessionC, String(repeating: "[", count: 70))
        try tree.writePopouts([sessionA, sessionB, sessionC], titles: [sessionB: "buildbox \u{00B7} Popout title (wild hare)"])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        #expect(snapshot(engine, sessionA)?.state == .reviewReady)
        let failed = try #require(snapshot(engine, sessionB))
        #expect(failed.state == .unknown && failed.offers.isEmpty && failed.place == .unknown)
        // The file failed, so the pop-out's title is used; it is an SSH pop-out, so an exact Host prefix is dropped.
        #expect(failed.headline == "Popout title" && failed.nickname == "wild hare")
        #expect(engine.banner == "Claude's session files changed (Claude 2.42304.0). Showing titles only.")
        try writeSSHSession(id: sessionB, cli: "2f3c2a9e-1111-2222-3333-444455556666")
        engine.refresh()
        await engine.waitUntilIdle()
        #expect(engine.banner == nil)
        #expect(snapshot(engine, sessionB)?.state == .reviewReady)
        engine.stop()
    }

    @Test func badIDsAndLinkedTranscriptsAreUnknown() async throws {
        try writeSSHSession { $0.cli = "../../x-1111-2222-3333-444455556666" }
        let cwd = try writeLocalSession()
        // The local transcript replaced by a link to another file.
        let transcript = tree.localTranscriptURL(localCLI, cwd: cwd)
        let elsewhere = tree.root.appendingPathComponent("elsewhere.jsonl")
        try FileManager.default.moveItem(at: transcript, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: transcript, withDestinationURL: elsewhere)
        try tree.writePopouts([sessionA, sessionB])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        #expect(snapshot(engine, sessionA)?.state == .unknown)
        #expect(snapshot(engine, sessionB)?.state == .unknown)
        #expect(snapshot(engine, sessionB)?.place == .unknown)
        engine.stop()
    }

    @Test func thePlaceIsUnknownWhenTheFactsDisagree() async throws {
        // No sshConfig, but the transcript exists only as an SSH mirror.
        try writeSSHSession { $0.sshHost = nil; $0.cwd = "/nowhere/on/this/mac" }
        try tree.writePopouts([sessionA])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        let session = try #require(snapshot(engine, sessionA))
        #expect(session.place == .unknown && session.state == .reviewReady)
        let offer = try #require(session.offers.first?.offer)
        #expect(offer.context.facts.place == .unknown && offer.context.facts.sshAlias == nil)
        #expect(offer.folder == CommandOffer.Folder(path: tree.home.path, isHomeFallback: true))
        engine.stop()
    }

    @Test func aLocalOfferRunsInItsFolder() async throws {
        let cwd = try writeLocalSession()
        try tree.writeLines([Line.toolResult("toolu_2", uuid: "r2", at: now),
                             Line.text("Now run:\n```zsh\nopen .\n```", uuid: "a-local", at: now)],
                            to: tree.localTranscriptURL(localCLI, cwd: cwd), append: true)
        try tree.writePopouts([sessionB])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        let offer = try #require(snapshot(engine, sessionB)?.offers.first?.offer)
        #expect(offer.folder == CommandOffer.Folder(path: cwd, isHomeFallback: false) && offer.context.runFolder == cwd)
        #expect(offer.context.facts.place == .local && offer.context.facts.localCwd == cwd && offer.context.facts.sshAlias == nil)
        engine.stop()
    }

    @Test func onlyTheRunningKnownCopiesAreRead() async throws {
        try writeSSHSession()
        try tree.writePopouts([sessionA])
        try tree.writeSession(sessionB, SessionFixture(), profile: .b)
        try tree.writePopouts([sessionB], profile: .b)
        let unknownFolder = tree.appSupport.appendingPathComponent("Claude-3p")
        try tree.write(jsonLine(["version": 1, "popouts": [["sessionId": sessionC]]]), to: unknownFolder.appendingPathComponent("session-popouts.json"))
        processes.value = [tree.copyA(), tree.copyB(),
                           ClaudeProcessCandidate(pid: 4444, arguments: ["/y", "--user-data-dir=\(unknownFolder.path)"])]
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        #expect(engine.runningProfiles.map(\.letter) == ["A", "B", "?"])
        #expect(engine.sessions.map(\.id) == [sessionA, sessionB])
        #expect(engine.sessions.map(\.profile.letter) == ["A", "B"])
        // Two copies run: offers name theirs.
        #expect(snapshot(engine, sessionA)?.offers.first?.offer.source.profileName == "A Claude")
        processes.value = [tree.copyA()]
        engine.refreshProcesses()
        await engine.waitUntilIdle()
        #expect(engine.sessions.map(\.id) == [sessionA])
        engine.stop()
    }

    @Test func aCopyIsReadOnlyWhileTheSettingsListIt() async throws {
        try writeSSHSession()
        try tree.writePopouts([sessionA])
        try tree.writeSession(sessionB, SessionFixture(), profile: .b)
        try tree.writePopouts([sessionB], profile: .b)
        processes.value = [tree.copyA(), tree.copyB()]
        let settings = Shared(CodeSettings())   // only the default copy is built in
        var environment = tree.environment(clock: clock, processes: processes)
        environment.settings = { settings.value }
        let engine = CodeSessionsEngine(environment: environment)
        engine.setStripVisible(true)
        engine.start()
        await engine.waitUntilIdle()
        #expect(engine.runningProfiles.map(\.letter) == ["A", "?"])
        #expect(engine.sessions.map(\.id) == [sessionA], "a copy the settings do not list is never read")
        // A hand edit lists it: the engine reads it at once.
        settings.value = CodeSettings.withTestProfiles
        engine.reloadSettings()
        await engine.waitUntilIdle()
        #expect(engine.runningProfiles.map(\.letter) == ["A", "B"])
        #expect(engine.sessions.map(\.id) == [sessionA, sessionB])
        // Unlisted again: it goes.
        settings.value = CodeSettings()
        engine.reloadSettings()
        await engine.waitUntilIdle()
        #expect(engine.sessions.map(\.id) == [sessionA])
        engine.stop()
    }

    @Test func atMost24SessionsAreReadFully() async throws {
        var ids: [String] = []
        for i in 0..<30 {
            let id = String(format: "local_0ddddddd-4444-4444-8444-%012d", i)
            let cli = String(format: "3f3c2a9e-1111-2222-3333-%012d", i)
            ids.append(id)
            try writeSSHSession(id: id, cli: cli)
        }
        try tree.writePopouts(ids)
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        #expect(engine.sessions.count == 30)
        #expect(engine.sessions.prefix(24).allSatisfy { $0.state == .reviewReady })
        #expect(engine.sessions.suffix(6).allSatisfy { $0.state == .unknown })
        #expect(Set(engine.sessions.map(\.index)).count == 30)
        #expect(engine.worker.debugState.fullyRead == 24)
        // Followed sessions come first.
        engine.setWatched([ids[29]])
        await engine.waitUntilIdle()
        #expect(snapshot(engine, ids[29])?.state == .reviewReady)
        #expect(engine.sessions.filter { $0.state == .unknown }.count == 6)
        engine.stop()
    }

    @Test func noSessionTextReachesTheLog() async throws {
        let lines = Shared<[String]>([])
        let token = CodeLog.observe { line in lines.value.append(line) }
        defer { CodeLog.stopObserving(token) }
        try writeSSHSession()
        _ = try writeLocalSession()
        try tree.writeRawSession(sessionC, #"{"title":"\#(secretWord)","title":"x"}"#)
        try tree.writePopouts([sessionA, sessionB, sessionC])
        let engine = engine()
        engine.start()
        await engine.waitUntilIdle()
        try tree.writeLines([Line.user("thanks \(secretWord)", uuid: "u9", at: now)], to: tree.mirrorURL(sshCLI), append: true)
        engine.refresh()
        await engine.waitUntilIdle()
        engine.stop()
        await engine.waitUntilIdle()
        let logged = lines.value
        #expect(logged.contains { $0.contains("offers session=#") && $0.contains("count=1") })
        #expect(logged.contains { $0.contains("file=duplicate-key") })
        let forbidden = [secretWord, tree.root.path, "buildbox", "192.0.2.10", "quiet fern", "calm otter", sessionA, sessionB,
                         sshCLI, "scp", "Downloads", "someone"]
        for word in forbidden {
            #expect(!logged.contains { $0.contains(word) }, "log holds \(word)")
        }
    }

    @Test func fileEventsUpdateTheMonitorWhileTheStripIsVisible() async throws {
        let cwd = try writeLocalSession()
        try tree.writePopouts([sessionB])
        let engine = engine(watches: true)
        engine.start()
        await engine.waitUntilIdle()
        #expect(snapshot(engine, sessionB)?.state == .working)
        // Hidden: no timers armed.
        #expect(engine.worker.debugState.timerArmed == false)
        engine.setStripVisible(true)
        await engine.waitUntilIdle()
        #expect(engine.worker.debugState.timerArmed == true)
        var fixture = SessionFixture()
        fixture.title = "Tidy the \(secretWord) tests (calm otter)"
        fixture.cli = localCLI
        fixture.sshHost = nil
        fixture.cwd = cwd
        fixture.summary = ("completed", "Tests tidied", "", "a-done")
        try tree.writeLines([Line.toolResult("toolu_2", uuid: "r2", at: now), Line.text("All tidy.", uuid: "a-done", at: now)],
                            to: tree.localTranscriptURL(localCLI, cwd: cwd), append: true)
        try tree.writeSession(sessionB, fixture)
        var state = snapshot(engine, sessionB)?.state
        for _ in 0..<50 where state != .done {
            try await Task.sleep(nanoseconds: 100_000_000)
            state = snapshot(engine, sessionB)?.state
        }
        #expect(state == .done)
        #expect(snapshot(engine, sessionB)?.tldr == "Tests tidied")
        // A pop-out closing removes its monitor.
        try tree.writePopouts([])
        var count = engine.sessions.count
        for _ in 0..<50 where count != 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
            count = engine.sessions.count
        }
        #expect(count == 0)
        engine.setStripVisible(false)
        await engine.waitUntilIdle()
        #expect(engine.worker.debugState.timerArmed == false)
        engine.stop()
    }
}
