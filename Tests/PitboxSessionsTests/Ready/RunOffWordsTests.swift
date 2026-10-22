import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// With `commands` copyOnly (the default: the sheet has no Run) every surface that offers a command says
/// "Review…", never "Run…", and still opens the sheet: Ready cards and Later rows, a monitor's row button and peek, desk
/// tags and the desk peek, and their VoiceOver labels. With `run` nothing changes. A settings change relabels at once.
@MainActor
@Suite("Run off: review words", .serialized)
struct RunOffWordsTests {
    init() {
        CodeTileLog.enabled = false
        DeskTagLog.enabled = false
    }

    static let runnable: [CommandAssessment.Class] = [.notFlagged, .risky, .unclearMachine]
    static let reviewOnly: [CommandAssessment.Class] = [.needsEditing, .otherMachine, .forServer, .partlyRead, .blocked]

    @Test func theSheetButtonSaysReviewWhileRunIsOff() {
        for commandClass in Self.runnable {
            let assessment = tileOffer("x", commandClass: commandClass).assessment
            #expect(CodeOfferWords.reviewTitle(assessment, commands: .copyOnly) == "Review…", "\(commandClass)")
            #expect(CodeOfferWords.reviewTitle(assessment, commands: .run) == "▶ Run…", "\(commandClass)")
        }
        for commandClass in Self.reviewOnly {
            let assessment = tileOffer("x", commandClass: commandClass).assessment
            #expect(CodeOfferWords.reviewTitle(assessment, commands: .copyOnly) == "Review…", "\(commandClass)")
            #expect(CodeOfferWords.reviewTitle(assessment, commands: .run) == "Review…", "\(commandClass)")
        }
        let fetch = tileOffer("x", commandClass: .fetchFile).assessment
        #expect(CodeOfferWords.reviewTitle(fetch, commands: .copyOnly) == "⤓ Fetch…")
        #expect(CodeOfferWords.reviewTitle(fetch, commands: .run) == "⤓ Fetch…")
        #expect(CodeSettings().commands == .copyOnly, "Run is off for new installs")
    }

    @Test func readyCardsLaterRowsAndVoiceOver() throws {
        for commands in [CodeSettings.Commands.copyOnly, .run] {
            let folder = SeamFolder("run-off-ready-\(commands.rawValue)")
            defer { withExtendedLifetime(folder) {} }
            let list = CodeReadyList(memory: readyStore(folder, clock: ManualClock(readyNow)))
            list.schedule = ReadyScheduler().schedule
            list.clock = utcClock
            list.now = { readyNow }
            var actions: [CodeReadyAction] = []
            list.onAction = { action, _ in actions.append(action) }
            let session = readySession(sessionA, index: 1, offers: [readyOffer("echo ok", session: sessionA, index: 1, reply: "r1")])
            let followed = CodeFollowedSet(monitors: [session], statuses: [sessionA: CodeWindowStatus(place: .onDesk)], parked: [],
                                           recent: [], recentHours: 6, now: readyNow)
            list.update(CodeReadyInput(sessions: [session], followed: followed,
                                       statuses: [sessionA: CodeWindowStatus(place: .onDesk)], now: readyNow, commands: commands))
            let card = try #require(list.snapshot.entries.first { $0.item.kind == .command }?.item)
            let main = try #require(card.buttons.first)
            #expect(main.title == (commands == .run ? "▶ Run…" : "Review…"))
            let view = CodeReadyListView(list: list)
            view.frame = CGRect(x: 0, y: 0, width: 992, height: 400)
            view.refresh()
            let labels = (view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
            #expect(labels.contains(commands == .run ? "Run command" : "Review command"))
            #expect(commands == .run || !labels.contains { $0.contains("Run") })
            // Either way the button only opens the sheet.
            list.press(main.action)
            #expect(actions == [.openSheet(session.offers[0].id, sessionID: sessionA)])
            // The Later row's button has the same words.
            list.press(.later(card.id))
            #expect(list.snapshot.later.first?.item.buttons.map(\.title) == ["Unfold", commands == .run ? "Run…" : "Review…"])
        }
    }

    @Test func monitorRowButtonAndPeek() {
        let one = [tileOffer("make test", session: 1)]
        let several = [tileOffer("make test", session: 1), tileOffer("make lint", session: 1, number: 2)]
        let files = [tileOffer("scp a", session: 1, commandClass: .fetchFile), tileOffer("scp b", session: 1, number: 2, commandClass: .fetchFile)]
        func item(_ offers: [CodeOfferEntry], _ commands: CodeSettings.Commands) -> CodeMonitorItem {
            let session = tileSession("local_s1", "Toy Cube · checkout", index: 1, state: .reviewReady, offers: offers)
            let inputs = CodeMonitorBuilder.Inputs(sessions: [session], statuses: [:], runs: CodeOfferRunBook(), hideText: false,
                                                   showText: [:], showsProfiles: false, homeDirectory: "/Users/alex", now: tileNow,
                                                   commands: commands)
            return CodeMonitorBuilder.item(session, position: 1, total: 1, inputs: inputs)
        }
        #expect(item(one, .copyOnly).rowAction == "Review…")
        #expect(item(one, .run).rowAction == "▶ Run…")
        #expect(item(several, .copyOnly).rowAction == "Review…")
        #expect(item(several, .run).rowAction == "▶ Run…")
        #expect(item(files, .copyOnly).rowAction == "⤓ Fetch…" && item(files, .run).rowAction == "⤓ Fetch…")
        #expect(item(several, .copyOnly).peek.offers.map(\.reviewTitle) == ["Review…", "Review…"])
        #expect(item(several, .run).peek.offers.map(\.reviewTitle) == ["▶ Run…", "▶ Run…"])
    }

    @Test func deskTagsAndTheDeskPeek() throws {
        let session = tagSession(offers: [tileOffer("swift test", session: 1), tileOffer("rm -rf .build", number: 2, commandClass: .risky)])
        let single = tagSession(offers: [tileOffer("swift test", session: 1)])
        for commands in [CodeSettings.Commands.copyOnly, .run] {
            let tag = try #require(DeskTagContentBuilder.content(.init(session: single, now: tileNow, clock: tagClock, commands: commands)))
            let main = try #require(tag.main)
            #expect(main.text == (commands == .run ? "▶ Run…" : "▶ Review…"))
            #expect(tag.accessibilityLabel(for: main).hasSuffix(commands == .run ? ": ▶ Run…" : ": ▶ Review…"))
            let peek = DeskPeekBuilder.model(.init(session: session, now: tileNow, clock: tagClock, homeDirectory: "/Users/alex",
                                                   commands: commands))
            let title = commands == .run ? "▶ Run…" : "Review…"
            #expect(peek.commands.map(\.button.title) == [title, title])
            #expect(peek.commands.map(\.button.accessibilityLabel) == ["\(title) command 1", "\(title) command 2"])
        }
    }

    @Test func aSettingsChangeRelabelsTheBlockAtOnce() throws {
        var settings = CodeSettings()
        let h = TileHarness(settings: settings)
        let block = PitboxBlock(model: h.model)
        let folder = SeamFolder("run-off-live")
        defer { withExtendedLifetime(folder) {} }
        block.enableReady(memory: readyStore(folder, clock: ManualClock(tileNow)),
                          environment: CodeReadyEnvironment(clock: { tileNow }, schedule: ReadyScheduler().schedule))
        let ready = try #require(h.model.ready)
        let entry = tileOffer("make test", session: 1)
        h.set([tileSession("local_s1", "Toy Cube · checkout", index: 1, state: .reviewReady, offers: [entry])])
        func words() -> [String?] {
            let card = ready.list.snapshot.entries.first { $0.item.offerID == entry.id }?.item.buttons.first?.title
            let monitor = h.model.snapshot.monitors.first
            return [card, monitor?.rowAction, monitor?.peek.offers.first?.reviewTitle]
        }
        #expect(words() == ["Review…", "Review…", "Review…"])
        settings.commands = .run
        block.update(settings: settings)
        #expect(words() == ["▶ Run…", "▶ Run…", "▶ Run…"], "relabelled at once")
        settings.commands = .copyOnly
        block.update(settings: settings)
        #expect(words() == ["Review…", "Review…", "Review…"])
        // Review… still opens the sheet.
        let button = try #require(ready.list.snapshot.entries.first { $0.item.offerID == entry.id }?.item.buttons.first)
        ready.list.press(button.action)
        #expect(h.presenter.presented.map(\.offer.id) == [entry.id])
    }

    @Test func aSettingsChangeRelabelsTagsAndAnOpenPeekAtOnce() throws {
        let h = TagHarness()
        h.start()
        h.desk([tagSession(TagControllerTests.id, offers: [tileOffer("swift test", session: 1)])])
        h.controller.openPeek(TagControllerTests.id, focus: .commands)
        func words() -> [String?] {
            [h.tag(TagControllerTests.id)?.content?.main?.text, h.controller.peek?.view.model.commands.first?.button.title]
        }
        #expect(words() == ["▶ Review…", "Review…"])
        var settings = CodeSettings()
        settings.commands = .run
        h.controller.update(settings: settings)
        #expect(words() == ["▶ Run…", "▶ Run…"], "relabelled at once")
        let width = DeskTagStackView.width("▶ Run…")
        #expect(h.quartzFrame(TagControllerTests.id)?.width == width, "the tag took the new words' width")
        settings.commands = .copyOnly
        h.controller.update(settings: settings)
        #expect(words() == ["▶ Review…", "Review…"])
    }
}
