import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The block's slots for the result line and the warning: filled by the builder, laid out in the offer line's place and
/// under the nickname line, drawn by the monitor, the result line's click armed like an opening mark and handed to
/// `onResultClick`; the peek's warnings and result buttons (armed); the Ready actions and the desk tags' results
/// through the same hooks, and the result and warning lines in `enableReady`.
@MainActor
@Suite("Result and warning slots")
struct ResultWarningSlotTests {
    init() { CodeTileLog.enabled = false }

    nonisolated static let preview = CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"), label: "localhost:5173")
    nonisolated static let report = CodeResult(kind: .document, origin: .written, path: "/x/report.md", label: "report.md")
    nonisolated static let stuck = CodeWarning(kind: .failedInARow, since: tileNow.addingTimeInterval(-600), failures: 4, lastExitCode: 1)

    func session(results: [CodeResult] = [preview, report], warnings: [CodeWarning] = [], offers: [CodeOfferEntry] = [],
                 state: CodeSessionState = .reviewReady) -> CodeSessionSnapshot {
        var s = tileSession("local_r1", "Toy Cube · checkout", index: 3, state: state, tldr: "Report written.", offers: offers)
        s.results = results
        s.otherLinkCount = 2
        s.warnings = warnings
        return s
    }

    func item(_ s: CodeSessionSnapshot, hidden: Bool = false) -> CodeMonitorItem {
        CodeMonitorBuilder.item(s, position: 1, total: 1, inputs: CodeMonitorBuilder.Inputs(
            sessions: [s], statuses: [:], runs: CodeOfferRunBook(), hideText: hidden, showText: [:], showsProfiles: false,
            homeDirectory: "/Users/alex", now: tileNow))
    }

    @Test func theBuilderFillsTheSlots() throws {
        let built = item(session(warnings: [Self.stuck]))
        let line = try #require(built.resultLine)
        #expect(line.button.title == "↗ Open preview · localhost:5173" && line.more == "+1 more")
        #expect(built.warningLine?.text == "⚠ Looks stuck: 4 commands failed in a row" && built.warningLine?.short == "⚠ stuck")
        #expect(built.peek.warnings.first?.first == "Looks stuck: 4 commands failed in a row")
        #expect(built.peek.results.first == .label("Results"))
        // An offer line comes first; Hide text keeps no result line and no peek rows.
        #expect(item(session(offers: [tileOffer("ls", session: 3)])).resultLine == nil)
        let hidden = item(session(warnings: [Self.stuck]), hidden: true)
        #expect(hidden.resultLine == nil && hidden.peek.results.isEmpty && hidden.peek.warnings.isEmpty)
        #expect(hidden.warningLine != nil, "the outline stays with Hide text (the line itself is not laid out)")
    }

    @Test func theLayoutPlacesThemOnEverySize() throws {
        let built = item(session(warnings: [Self.stuck]))
        let large = CodeMonitorLayout.compute(built, size: .large, bounds: CGRect(x: 0, y: 0, width: 323, height: 219), showsProfile: false)
        #expect(large.offer != nil && large.warning != nil)
        #expect((large.warning?.minY ?? 0) < (large.offer?.minY ?? 0))
        let medium = CodeMonitorLayout.compute(built, size: .medium, bounds: CGRect(x: 0, y: 0, width: 240, height: 150), showsProfile: false)
        #expect(medium.offer != nil && medium.warning != nil && medium.now == nil && medium.tldr == nil)
        let small = CodeMonitorLayout.compute(built, size: .small, bounds: CGRect(x: 0, y: 0, width: 180, height: 104), showsProfile: false)
        #expect(small.offer == nil && small.warning == nil && small.compact != nil)
        let hidden = CodeMonitorLayout.compute(item(session(warnings: [Self.stuck]), hidden: true), size: .large,
                                               bounds: CGRect(x: 0, y: 0, width: 323, height: 219), showsProfile: false)
        #expect(hidden.offer == nil && hidden.warning == nil)
    }

    @Test func theMonitorDrawsTheLinesAndArmsTheResultClick() throws {
        let clock = Shared<TimeInterval>(100)
        let view = CodeMonitorView(item: item(session(results: [], warnings: [Self.stuck])), size: .large, showsProfile: false,
                                   frame: CGRect(x: 0, y: 0, width: 323, height: 219))
        view.clock = { clock.value }
        view.pointerProbe = { nil }
        // Re-lay out with the test's clock (the line appears now).
        view.configure(item: item(session(results: [Self.report, Self.preview], warnings: [Self.stuck])), size: .large, showsProfile: false)
        var clicks: [CodeMonitorView.Target] = []
        view.onClick = { _, target in clicks.append(target) }
        view.drawnTexts = []
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(view.drawnTexts?.contains("▤ Open report.md") == true)
        #expect(view.drawnTexts?.contains("⚠ Looks stuck: 4 commands failed in a row") == true)
        let offer = try #require(view.layoutInfo.offer)
        #expect(view.target(at: CGPoint(x: offer.midX, y: offer.midY)) == .result)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = view
        func click() {
            let point = view.convert(CGPoint(x: offer.midX, y: offer.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            }
        }
        click()
        #expect(clicks.isEmpty, "a press right after the line appeared is ignored")
        clock.value += 0.9
        click()
        #expect(clicks == [.result])
        window.contentView = nil
    }

    @Test func aResultClickReachesTheCompositionRootsHook() throws {
        let h = TileHarness()
        h.set([session()])
        var got: [(String, String)] = []
        h.model.onResultClick = { session, button, _ in got.append((session.id, button.title)) }
        let line = try #require(h.model.snapshot.monitors.first?.resultLine)
        h.model.clickResult(line.button, sessionID: "local_r1", anchor: .zero)
        #expect(got.count == 1 && got[0].0 == "local_r1" && got[0].1 == "↗ Open preview · localhost:5173")
        h.model.clickResult(line.button, sessionID: "local_gone", anchor: .zero)
        #expect(got.count == 1)
    }

    @Test func readyCardsAndDeskTagsReachTheResultHooks() throws {
        let h = TileHarness()
        let server = CodeResult(kind: .serverFile, origin: .handedOver, path: "/home/buildbox/out/demo.mp4", label: "demo.mp4",
                                toolUseID: "toolu_send", at: tileNow.addingTimeInterval(-60))
        h.set([session(results: [Self.preview, Self.report, server])])
        var got: [String] = []
        var fetched: [String] = []
        h.model.onResultClick = { session, button, _ in got.append("\(session.id) \(button.action.rawValue) \(button.title)") }
        h.model.onFetchedFile = { name, open, _ in fetched.append("\(open ? "open" : "show") \(name)") }
        let opener = CodeDashboardOpener { _ in }
        for action in [CodeReadyAction.openResult(sessionID: "local_r1", result: Self.report),
                       .fetchResult(sessionID: "local_r1", result: server), .openFetched(fileName: "notes.md"),
                       .showFetchedInFinder(fileName: "notes.md"), .openResult(sessionID: "local_gone", result: Self.report)] {
            PitboxBlock.perform(action, anchor: .zero, model: h.model, opener: opener)
        }
        #expect(got == ["local_r1 open ▤ Open report.md", "local_r1 fetch ⤓ Fetch demo.mp4…"])
        #expect(fetched == ["open notes.md", "show notes.md"])
        // desk tags' ↗ and ▤: the result's first button, as on the monitor's line.
        PitboxBlock(model: h.model).openResult(Self.preview.id, sessionID: "local_r1", anchor: .zero)
        #expect(got.last == "local_r1 open ↗ Open preview · localhost:5173")
    }

    @Test func enablingReadyWiresTheFetchedRuleAndWarningOK() throws {
        let h = TileHarness()
        let clock = ManualClock(tileNow)
        let folder = SeamFolder("slot-ready")
        defer { withExtendedLifetime(folder) {} }
        let memory = readyStore(folder, clock: clock)
        PitboxBlock(model: h.model)
            .enableReady(memory: memory, environment: CodeReadyEnvironment(clock: { tileNow }, schedule: ReadyScheduler().schedule))
        let list = try #require(h.model.ready?.list)
        #expect(list.fetchedFileOpens("release-notes 2.md"), "a document gets Open")
        #expect(!list.fetchedFileOpens("report.html") && !list.fetchedFileOpens("eval-tables.zip"), "the rest Show in Finder only")
        list.onWarningOK?("local_r1", Self.stuck)
        let records: [WarningSilenceRecord] = memory.read(.silenced, session: "local_r1") ?? []
        #expect(records.map(\.rule) == ["failed_in_a_row"])
    }

    @Test func thePeekShowsWarningsAndArmsItsResultButtons() throws {
        let clock = Shared<TimeInterval>(50)
        let peek = CodeMonitorPeekView(item: item(session(results: [], warnings: [Self.stuck])), frame: CGRect(x: 0, y: 0, width: 657, height: 450))
        peek.clock = { clock.value }
        peek.pointerProbe = { nil }
        peek.update(item: item(session(results: [Self.report], warnings: [Self.stuck])))
        let buttons = peek.contentButtons.filter { if case .result = $0.action { return true } else { return false } }
        let open = try #require(buttons.first)
        #expect(open.title == "▤ Open report.md")
        var actions: [CodeMonitorPeekView.Action] = []
        peek.onAction = { actions.append($0) }
        let window = NSWindow(contentRect: peek.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = peek
        func click() {
            let point = peek.convert(CGPoint(x: open.rect.midX, y: open.rect.midY - peek.scrollOffset), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                if type == .leftMouseDown { peek.mouseDown(with: event) } else { peek.mouseUp(with: event) }
            }
        }
        click()
        #expect(actions.isEmpty)
        clock.value += 0.9
        click()
        #expect(actions.count == 1)
        peek.drawnTexts = []
        let rep = try #require(peek.bitmapImageRepForCachingDisplay(in: peek.bounds))
        peek.cacheDisplay(in: peek.bounds, to: rep)
        #expect(peek.drawnTexts?.contains("⚠ Looks stuck: 4 commands failed in a row") == true)
        #expect(peek.drawnTexts?.contains("Last failure: exit code 1") == true)
        #expect(peek.drawnTexts?.contains("2 other links in the reply (open them from the session)") == true)
        window.contentView = nil
    }
}

/// The slots on real monitors and in the real peek, as PNGs when `PITBOX_TEST_OUT` is set:
/// `PITBOX_TEST_OUT=<dir> scripts/test.sh --filter renderSlotPictures`.
@MainActor
@Suite("Result and warning slot pictures")
struct ResultWarningSlotPictures {
    @Test func renderSlotPictures() throws {
        CodeTileLog.enabled = false
        let out = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let slots = ResultWarningSlotTests()
        let warned = slots.item(slots.session(warnings: [ResultWarningSlotTests.stuck]))
        let plain = slots.item(slots.session())
        let cases: [(String, CodeMonitorItem, CodeMonitorSize, CGSize)] = [
            ("slot-large-warned", warned, .large, CGSize(width: 323, height: 219)),
            ("slot-large-result", plain, .large, CGSize(width: 323, height: 219)),
            ("slot-medium-warned", warned, .medium, CGSize(width: 240, height: 150)),
            ("slot-small-warned", warned, .small, CGSize(width: 180, height: 104)),
        ]
        for (name, item, size, frame) in cases {
            let view = CodeMonitorView(item: item, size: size, showsProfile: false, frame: CGRect(origin: .zero, size: frame))
            view.reduceMotion = { true }
            let png = try #require(PictureTests.picture(of: view, size: frame, dark: true))
            if let out {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try png.write(to: out.appendingPathComponent("\(name).png"))
            }
        }
        let peek = CodeMonitorPeekView(item: warned, frame: CGRect(x: 0, y: 0, width: 657, height: 450))
        let png = try #require(PictureTests.picture(of: peek, size: peek.frame.size, dark: true))
        if let out { try png.write(to: out.appendingPathComponent("slot-peek.png")) }
    }
}
