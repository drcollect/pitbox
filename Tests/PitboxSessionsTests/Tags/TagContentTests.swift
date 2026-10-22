import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// What a tag says: the main item's priority, its words, the
/// Hide text versions, VoiceOver.
@MainActor
@Suite("desk tags: content")
struct TagContentTests {
    func content(_ session: CodeSessionSnapshot, hidden: Bool = false, suppressed: DeskTagSuppressed = DeskTagSuppressed(),
                 warnings: CodeSettings.Warnings = CodeSettings.Warnings(), lab: Bool = false,
                 commands: CodeSettings.Commands = .copyOnly) -> DeskTagContent? {
        DeskTagContentBuilder.content(.init(session: session, suppressed: suppressed, textHidden: hidden,
                                         warningsShown: warnings, labPill: lab, now: tileNow, clock: tagClock,
                                         commands: commands))
    }

    static let stuck = CodeWarning(kind: .failedInARow, since: tileNow.addingTimeInterval(-300), failures: 4, lastExitCode: 1)
    static let sameFile = CodeWarning(kind: .sameFile, since: tileNow, otherSessionID: "local_o", otherHeadline: "checkout tests",
                                      path: "src/checkout.tsx")
    static let dashboard = CodeDashboard(handle: "polar-shore", site: .test, firstSeen: tileNow.addingTimeInterval(-3600))

    @Test func noTagWhenNothingApplies() {
        #expect(content(tagSession(state: .done)) == nil)
        #expect(content(tagSession(state: .needsYou)) == nil)
        #expect(content(tagSession(state: .quietUnfinished)) == nil, "quiet · turn not finished is not running")
    }

    @Test func oneOfferOpensItsSheet() throws {
        let offer = tileOffer("swift test", session: 1)
        let tag = try #require(content(tagSession(offers: [offer])))
        #expect(tag.main == DeskTagPill(kind: .command, text: "▶ Review…", short: "▶ 1", action: .openOffer(offer.id)))
        let run = try #require(content(tagSession(offers: [offer]), commands: .run))
        #expect(run.main == DeskTagPill(kind: .command, text: "▶ Run…", short: "▶ 1", action: .openOffer(offer.id)))
        #expect(tag.dashboard == nil)
        #expect(tag.logKind == "offer")
    }

    @Test func classWordsWhereTheyMatter() {
        func text(_ commandClass: CommandAssessment.Class, ssh: String? = nil, commands: CodeSettings.Commands = .run) -> String? {
            let session = tagSession(offers: [tileOffer("x", commandClass: commandClass)], place: ssh == nil ? .local : .ssh,
                                     sshHost: ssh)
            return content(session, commands: commands)?.main?.text
        }
        #expect(text(.notFlagged) == "▶ Run…")
        #expect(text(.risky) == "▶ Run… · risky")
        #expect(text(.unclearMachine) == "▶ Run… · machine unclear")
        // Run off (the default): the same pills say Review, the others are unchanged.
        #expect(text(.notFlagged, commands: .copyOnly) == "▶ Review…")
        #expect(text(.risky, commands: .copyOnly) == "▶ Review… · risky")
        #expect(text(.unclearMachine, commands: .copyOnly) == "▶ Review… · machine unclear")
        #expect(text(.needsEditing, commands: .copyOnly) == "▶ Review… · needs editing")
        #expect(text(.blocked, commands: .copyOnly) == "▶ 1 command · blocked")
        #expect(text(.forServer, ssh: "buildbox") == "▶ Review… · for buildbox")
        #expect(text(.forServer) == "▶ Review… · for the server")
        #expect(text(.blocked) == "▶ 1 command · blocked")
        #expect(text(.needsEditing) == "▶ Review… · needs editing")
        #expect(text(.partlyRead) == "▶ Review… · partly read")
        #expect(text(.otherMachine) == "▶ Review… · runs on another machine")
    }

    @Test func fetchNamesTheFile() throws {
        let fetch = tileOffer("scp 'alex@buildbox:/home/alex/draft.md' ~/Downloads/", commandClass: .fetchFile,
                              fetch: FetchFileRequest(alias: "buildbox", replyUser: "alex", remotePath: "/home/alex/draft.md",
                                                      destinationName: nil))
        let tag = try #require(content(tagSession(offers: [fetch])))
        #expect(tag.main?.text == "⤓ Fetch draft.md…")
        #expect(tag.main?.kind == .file)
        #expect(tag.main?.short == "⤓ 1")
    }

    @Test func severalOffersOpenThePeekAtTheCommands() throws {
        let offers = [tileOffer("a", number: 1), tileOffer("b", number: 2, commandClass: .risky), tileOffer("c", number: 3)]
        let tag = try #require(content(tagSession(offers: offers)))
        #expect(tag.main?.text == "▶ 3 commands… · 1 risky")
        #expect(tag.main?.short == "▶ 3")
        #expect(tag.main?.action == .openPeek(.commands))
        let blocked = [tileOffer("a", number: 1, commandClass: .risky), tileOffer("b", number: 2, commandClass: .blocked)]
        #expect(content(tagSession(offers: blocked))?.main?.text == "▶ 2 commands… · 1 blocked")
        #expect(content(tagSession(offers: [tileOffer("a", number: 1), tileOffer("b", number: 2)]))?.main?.text == "▶ 2 commands…")
    }

    @Test func earlierRepliesCountAndDismissedOffersGo() throws {
        let latest = tileOffer("a", number: 1, reply: "r2")
        let earlier = tileOffer("b", number: 1, reply: "r1")
        let both = try #require(content(tagSession(offers: [latest], earlierOffers: [earlier])))
        #expect(both.main?.text == "▶ 2 commands…")
        let one = content(tagSession(offers: [latest], earlierOffers: [earlier]), suppressed: DeskTagSuppressed(offers: [latest.id]))
        #expect(one?.main?.action == .openOffer(earlier.id))
        #expect(content(tagSession(offers: [latest]), suppressed: DeskTagSuppressed(offers: [latest.id])) == nil)
    }

    @Test func priorityOfferThenWarningThenRunning() throws {
        let running = tagSession(state: .working, warnings: [Self.stuck], workStartedAt: tileNow.addingTimeInterval(-720))
        #expect(content(running)?.main?.text == "⚠ Looks stuck")
        #expect(content(running)?.main?.action == .openPeek(.warnings))
        var withOffer = running
        withOffer.offers = [tileOffer("make")]
        #expect(content(withOffer)?.main?.kind == .command)
        var plain = running
        plain.warnings = []
        #expect(content(plain)?.main?.text == "Running 12 min")
        #expect(content(plain)?.main?.action == .openPeek(.top))
    }

    @Test func warningsFollowSettingsAndSilence() {
        let session = tagSession(state: .working, warnings: [Self.sameFile])
        #expect(content(session)?.main?.text == "⚠ Same file as “checkout tests”")
        #expect(content(session, warnings: CodeSettings.Warnings(stuck: true, sameFile: false))?.main?.kind == .running)
        let silenced = DeskTagSuppressed(warnings: [session.id: [Self.sameFile.id]])
        #expect(content(session, suppressed: silenced)?.main?.kind == .running)
        let both = tagSession(state: .done, warnings: [Self.sameFile, Self.stuck])
        #expect(content(both)?.main?.text == "⚠ Looks stuck", "looks stuck before same file")
    }

    @Test func runningWordsInOrder() {
        let late = CodeETA(kind: .stated, at: tileNow.addingTimeInterval(-60), statedZone: "UTC", isLate: true)
        let stated = CodeETA(kind: .stated, at: tileNow.addingTimeInterval(3600))
        let estimate = CodeETA(kind: .estimate, at: tileNow.addingTimeInterval(540), minutesLeft: 9)
        let progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 4, total: 6)
        func text(_ eta: CodeETA?, _ progress: CodeProgress?, start: Date? = nil) -> String? {
            content(tagSession(state: .working, eta: eta, progress: progress, workStartedAt: start))?.main?.text
        }
        let clock = tagClock.string(stated.at)
        #expect(text(stated, progress) == "ETA \(clock)")
        #expect(text(late, progress) == "ETA \(tagClock.string(late.at)) passed")
        #expect(text(estimate, progress) == "≈ 9 min left")
        #expect(text(nil, progress) == "4 of 6 agents done")
        #expect(text(nil, nil, start: tileNow.addingTimeInterval(-72 * 60)) == "Running 1 h 12 min")
        #expect(text(nil, nil) == "Running")
        // Background tasks pending between turns count as running even when the state word says done.
        var between = progress
        between.pendingBetweenTurns = true
        #expect(content(tagSession(state: .done, progress: between))?.main?.text == "4 of 6 agents done")
    }

    @Test func estimateRounding() {
        #expect(DeskTagRunText.estimateWords(minutes: 9) == "≈ 9 min left")
        #expect(DeskTagRunText.estimateWords(minutes: 12) == "≈ 10 min left")
        #expect(DeskTagRunText.estimateWords(minutes: 23) == "≈ 25 min left")
        #expect(DeskTagRunText.estimateWords(minutes: 58) == "≈ 1 h left")
        #expect(DeskTagRunText.estimateWords(minutes: 84) == "≈ 1 h 20 min left")
        #expect(DeskTagRunText.estimateWords(minutes: 240) == "≈ 4 h left")
        #expect(DeskTagRunText.estimateWords(minutes: 241) == nil)
        #expect(DeskTagRunText.estimateWords(minutes: 0) == nil)
        #expect(DeskTagRunText.progressWords(CodeProgress(source: .todos, unit: .todos, done: 4, total: 7)) == "4/7 todos")
        #expect(DeskTagRunText.progressWords(CodeProgress(source: .backgroundTasks, unit: .workflows, done: 1, total: 2))
                == "1 of 2 workflows done")
        #expect(DeskTagRunText.progressWords(CodeProgress(source: .backgroundTasks, unit: .tasks, done: 0, total: 0)) == nil)
    }

    @Test func dashboardPillBelowTheMainItem() throws {
        let both = try #require(content(tagSession(state: .working, warnings: [Self.stuck], dashboard: Self.dashboard)))
        #expect(both.pills.map(\.kind) == [.warning, .dashboard])
        #expect(both.dashboard == DeskTagPill(kind: .dashboard, text: "▦ Dashboard", short: "▦", action: .openDashboard))
        #expect(both.dashboard?.needsArming == true)
        #expect(both.main?.needsArming == false)
        let alone = try #require(content(tagSession(state: .done, dashboard: Self.dashboard)))
        #expect(alone.main == nil)
        #expect(alone.pills.count == 1)
    }

    @Test func hideTextShowsSignsAndCountsOnly() throws {
        let offers = [tileOffer("rm -rf ~/x", number: 1, commandClass: .risky), tileOffer("ls", number: 2)]
        let hidden = try #require(content(tagSession(offers: offers, dashboard: Self.dashboard), hidden: true))
        #expect(hidden.pills.map(\.text) == ["▶ 2", "▦"])
        #expect(hidden.headline == nil)
        #expect(content(tagSession(warnings: [Self.sameFile]), hidden: true)?.main?.text == "⚠")
        let running = tagSession(state: .working, eta: CodeETA(kind: .stated, at: tileNow.addingTimeInterval(600)),
                                 workStartedAt: tileNow.addingTimeInterval(-300))
        let text = content(running, hidden: true)?.main?.text
        #expect(text == "Running 5 min", "no ETA clock with Hide text")
        let fetch = tileOffer("scp …", commandClass: .fetchFile,
                              fetch: FetchFileRequest(alias: "buildbox", replyUser: "alex", remotePath: "/home/p/secret-plan.md",
                                                      destinationName: nil))
        #expect(content(tagSession(offers: [fetch]), hidden: true)?.main?.text == "⤓ 1")
    }

    @Test func voiceOverLabels() throws {
        let tag = try #require(content(tagSession(offers: [tileOffer("make")], dashboard: Self.dashboard)))
        #expect(tag.accessibilityLabel(for: try #require(tag.main)) == "Pitbox for “Weather app · forecast refactor”: ▶ Review…")
        let run = try #require(content(tagSession(offers: [tileOffer("make")]), commands: .run))
        #expect(run.accessibilityLabel(for: try #require(run.main)) == "Pitbox for “Weather app · forecast refactor”: ▶ Run…")
        let hidden = try #require(content(tagSession(offers: [tileOffer("make")]), hidden: true))
        #expect(hidden.accessibilityLabel(for: try #require(hidden.main)) == "Pitbox: ▶ 1")
    }

    @Test func sessionTextGoesThroughTheRenderer() throws {
        let warning = CodeWarning(kind: .sameFile, since: tileNow, otherSessionID: "local_o",
                                  otherHeadline: "evil\u{202E}txt.exe\nsecond line")
        let tag = try #require(content(tagSession(warnings: [warning])))
        let text = try #require(tag.main?.text)
        #expect(text.contains("⟨U+202E⟩"))
        #expect(!text.contains("\u{202E}") && !text.contains("\n"))
    }

    @Test func labPillOnlyInTheLabWhenNothingElseApplies() {
        #expect(content(tagSession(state: .done), lab: true)?.main?.kind == .lab)
        #expect(content(tagSession(state: .done), lab: false) == nil)
        #expect(content(tagSession(offers: [tileOffer("x")]), lab: true)?.main?.kind == .command)
    }
}
