import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The progress and dashboard parts in the block: the item decorators (run words, bars, the small monitor's "≈ 9 min",
/// the ▦ pill and its click) and the summary band in the summary slot with the dashboards list. Uses the block's
/// harness (`TileHarness`, `makeTileView`): fakes only, an off-screen window.
@MainActor
@Suite("Progress and dashboards in the block", .serialized)
struct TileHookTests {
    init() {
        CodeTileLog.enabled = false
        CodeLog.enabled = false
    }

    /// A working fleet session (stated ETA, 4 of 6 agents, a dashboard), one between turns with an estimate, an idle one.
    static func sessions() -> [CodeSessionSnapshot] {
        var fleet = tileSession("local_f1", "fleet · Toy Cube checkout", index: 1, state: .working, nickname: "quiet fern",
                                tldr: "Seven tasks approved; the board is live.", now: "subagent: checkout spec", minutesAgo: 0.5)
        fleet.workStartedAt = tileNow.addingTimeInterval(-34 * 60)
        fleet.progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 4, total: 6)
        fleet.eta = CodeETA(kind: .stated, at: tileNow.addingTimeInterval(14 * 60), statedZone: "UTC")
        fleet.dashboard = CodeDashboard(handle: "polar-shore", site: .test, firstSeen: tileNow.addingTimeInterval(-3600),
                                        lastBuilderCallAt: tileNow.addingTimeInterval(-120))
        var between = tileSession("local_f2", "Chess clock · timer bug", index: 2, state: .done, nickname: "copper dune",
                                  tldr: "Matching bookings in three agents.", minutesAgo: 3)
        between.workStartedAt = tileNow.addingTimeInterval(-12 * 60)
        between.progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 3, total: 7, pendingBetweenTurns: true)
        between.eta = CodeETA(kind: .estimate, at: tileNow.addingTimeInterval(16 * 60), minutesLeft: 16)
        let idle = tileSession("local_f3", "Garden planner · sync", index: 3, state: .done, tldr: "Summary posted.", minutesAgo: 20)
        return [fleet, between, idle]
    }

    func harness(opened: Shared<[URL]>, settings: CodeSettings = CodeSettings()) -> TileHarness {
        let h = TileHarness(settings: settings)
        h.model.installRunWords(clock: clockUTC)
        h.model.installDashboardMarks(opener: CodeDashboardOpener { opened.value.append($0) })
        h.set(Self.sessions())
        return h
    }

    @Test func theDecoratorsFillW1sSlots() throws {
        let opened = Shared<[URL]>([])
        let h = TileHarness()
        let earlier = Shared<[String]>([])
        h.model.onMarkClick = { _, markID in earlier.value.append(markID) }
        h.model.installRunWords(clock: clockUTC)
        h.model.installDashboardMarks(opener: CodeDashboardOpener { opened.value.append($0) })
        h.set(Self.sessions())
        let items = h.model.snapshot.monitors
        let fleet = try #require(items.first { $0.id == "local_f1" })
        #expect(fleet.runText == "ETA \(clockUTC.string(tileNow.addingTimeInterval(14 * 60))) · 4/6 agents")
        #expect(fleet.progress == 4.0 / 6.0 && fleet.marks == [CodeDashboardMark.mark])
        #expect(fleet.compactTone == nil, "a stated ETA leaves the small monitor its state word")
        let between = try #require(items.first { $0.id == "local_f2" })
        #expect(between.runText == "≈ 15 min left" && between.compactLine == "≈ 15 min" && between.compactTone == .running)
        #expect(between.progress == 3.0 / 7.0 && between.marks.isEmpty)
        let idle = try #require(items.first { $0.id == "local_f3" })
        #expect(idle.runText == nil && idle.progress == nil && idle.marks.isEmpty)
        #expect(CodeDashboardMark.mark.opens && CodeDashboardMark.mark.place == .footPill && CodeDashboardMark.mark.short == "▦")

        h.model.onMarkClick?("local_f1", CodeDashboardMark.id)
        #expect(opened.value.map(\.absoluteString) == ["https://dash.example.com/dash/polar-shore/"])
        h.model.onMarkClick?("local_f2", CodeDashboardMark.id)
        #expect(opened.value.count == 1, "no dashboard, nothing opens")
        h.model.onMarkClick?("local_f1", "unread")
        #expect(earlier.value == ["unread"], "other features' marks go on to their handler")
        // A slim row shows the run text on its right (the block's row layout reads it).
        #expect(CodeMonitorLayout.rowStatus(fleet) == fleet.runText)
    }

    @Test func theSummaryBandSitsInTheSlotAndOpensTheDashboardsList() throws {
        let opened = Shared<[URL]>([])
        let h = harness(opened: opened)
        let (view, window) = makeTileView(h)
        defer { window.close() }
        let band = CodeSummaryAccessory(model: h.model, opener: CodeDashboardOpener { opened.value.append($0) }, clock: clockUTC)
        view.summaryAccessory = band
        #expect(band.frame.minY == CodeMonitorsTileView.headerHeight && band.frame.height == CodeSummaryLineView.height)
        #expect(band.lineView.line.text
            == "2 running · next done ≈ \(clockUTC.string(tileNow.addingTimeInterval(14 * 60))) · ▦ 1 dashboard")
        #expect(view.contentFrame.minY == CodeMonitorsTileView.headerHeight + CodeSummaryLineView.height)

        #expect(band.accessibilityChildren()?.count == 1)
        band.toggleDashboards()
        let panel = try #require(band.panel)
        #expect(panel.superview === view && panel.rows.map(\.sessionID) == ["local_f1"])
        #expect(band.accessibilityChildren()?.count == 2, "VoiceOver reaches the open list through the band")
        #expect(panel.frame.minY >= band.frame.maxY && panel.frame.width <= CodeSummaryAccessory.panelWidth)
        // An armed Open opens the dashboard; the rows' buttons are armed by `DashboardButtonView`.
        let open = try #require(panel.buttons["local_f1"])
        var clock = 1_000.0
        open.clock = { clock }
        open.pointer = { _ in nil }
        open.rearm()
        clock += 1
        open.press(began: clock)
        #expect(opened.value.map(\.absoluteString) == ["https://dash.example.com/dash/polar-shore/"])

        // Whatever closes the block's overlays closes it (the block hiding or folding).
        h.model.closeOverlays()
        #expect(band.panel == nil && panel.superview == nil)
        // Escape closes it and is consumed; other keys pass.
        band.toggleDashboards()
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                                                   charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        let letter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "a",
                                                   charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(band.handle(letter) == false && band.panel != nil)
        #expect(band.handle(escape) == true && band.panel == nil)
        // A second click on "▦ 1 dashboard" closes it again.
        band.toggleDashboards()
        band.toggleDashboards()
        #expect(band.panel == nil)

        // Nothing running and no dashboard: the band takes no room.
        h.set([tileSession("local_x1", "Idle", state: .done)])
        #expect(band.accessoryHeight(forWidth: 992) == 0 && band.isHidden)
        #expect(view.contentFrame.minY == CodeMonitorsTileView.headerHeight)
    }

    // MARK: Pictures

    @Test func renderTilePictures() throws {
        let out = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        var rows = CodeSettings()
        rows.look = .rows
        let cases: [(String, CodeSettings, Bool, Bool, CGSize)] = [
            ("progress-block-large-dark", CodeSettings(), true, false, CGSize(width: 992, height: 474)),
            ("progress-block-list-light", CodeSettings(), false, true, CGSize(width: 992, height: 474)),
            ("progress-block-rows-dark", rows, true, false, CGSize(width: 992, height: 300)),
        ]
        for (name, settings, dark, list, size) in cases {
            let opened = Shared<[URL]>([])
            let h = harness(opened: opened, settings: settings)
            var many = Self.sessions()
            for n in 4...6 {
                var s = tileSession("local_g\(n)", ["robot gestures", "Bike log · weekly charts", "Trail map · offline cache"][n - 4], index: n,
                                    state: .working, tldr: "Working through the list.", now: "running: swift test",
                                    minutesAgo: 1)
                s.workStartedAt = tileNow.addingTimeInterval(-Double(n * 7) * 60)
                s.progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: n - 3, total: 4)
                if n == 5 { s.eta = CodeETA(kind: .stated, at: tileNow.addingTimeInterval(-6 * 60), statedZone: "UTC") }
                if n == 6 { s.dashboard = CodeDashboard(handle: "quiet-fjord", site: .test, firstSeen: tileNow.addingTimeInterval(-600)) }
                many.append(s)
            }
            h.set(many)
            let (view, window) = makeTileView(h, size: size)
            view.summaryAccessory = CodeSummaryAccessory(model: h.model, opener: CodeDashboardOpener { _ in }, clock: clockUTC)
            if list, let band = view.summaryAccessory as? CodeSummaryAccessory {
                band.toggleDashboards()
                for button in band.panel?.buttons.values.map({ $0 }) ?? [] {
                    button.clock = { 0 }
                    button.pointer = { _ in nil }
                    button.rearm()
                    button.clock = { 10 }
                }
            }
            view.testsRenderUnredacted = true
            let png = try #require(ProgressPictureTests.picture(of: view, dark: dark), "\(name)")
            #expect(png.count > 2000)
            if let out {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try png.write(to: out.appendingPathComponent("\(name).png"))
            }
            window.close()
        }
    }
}
