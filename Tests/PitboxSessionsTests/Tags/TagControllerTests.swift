import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The controller on fakes: showing, following, hiding, drags, re-ordering,
/// the fallback cover mode, feasibility, idle cost.
@MainActor
@Suite("desk tags: controller")
struct TagControllerTests {
    init() { DeskTagLog.enabled = false }

    nonisolated static let id = "local_t1"
    nonisolated static func offerSession(_ headline: String = "Weather app · forecast refactor") -> CodeSessionSnapshot {
        tagSession(id, headline, offers: [tileOffer("swift test", session: 1)])
    }

    func started(_ sessions: [CodeSessionSnapshot] = [offerSession()], coverMode: DeskTagCoverMode? = nil,
                 feasibility: DeskTagFeasibility = .passed, lab: DeskTagLabOptions = DeskTagLabOptions()) -> TagHarness {
        let h = TagHarness(feasibility: feasibility, lab: lab, coverMode: coverMode)
        h.start()
        h.desk(sessions)
        return h
    }

    func expectedFrame(_ text: String, window: CGRect = tagWindowBounds) -> CGRect {
        let width = DeskTagStackView.width(text)
        return CGRect(x: window.maxX - 24 - width, y: window.minY - 11, width: width, height: 22)
    }

    @Test func showsTheTagAboveItsWindowAtItsPlace() throws {
        let h = started()
        #expect(h.isShown(Self.id))
        #expect(h.quartzFrame(Self.id) == expectedFrame("▶ Review…"))
        let panel = try #require(h.panel(Self.id))
        let show = try #require(h.windowing.shows.first { $0.panel == ObjectIdentifier(panel.panel) })
        #expect(show.above == tagWindowNumber, "ordered directly above its Claude window")
        #expect(show.level == .normal)
        #expect(show.reorder)
        #expect(show.frame == ScreenSpace.appKit(fromQuartz: expectedFrame("▶ Review…"), primaryHeight: 1200))
        #expect(!panel.panel.isVisible, "tests never order a panel in")
        #expect(h.controller.shownCount == 1)
    }

    @Test func noContentNoTagAndNothingObserved() {
        let h = started([tagSession(Self.id, state: .done)])
        #expect(!h.isShown(Self.id))
        #expect(h.ax.observeCalls.isEmpty)
        #expect(h.timeline.pendingTimers == 0, "idle: no timer at all")
        // An offer arrives: the window is watched and read, then the tag shows.
        h.desk([Self.offerSession()])
        #expect(h.ax.observeCalls == [tagPID])
        #expect(h.isShown(Self.id))
    }

    @Test func followsMovesAndResizesWithoutReordering() throws {
        let h = started()
        let panel = try #require(h.panel(Self.id))
        let moved = CGRect(x: 420, y: 260, width: 900, height: 700)
        h.move(to: moved)
        #expect(h.quartzFrame(Self.id) == expectedFrame("▶ Review…", window: moved))
        #expect(h.windowing.lastShow(panel.panel)?.reorder == false)
        let resized = CGRect(x: 420, y: 260, width: 1100, height: 760)
        h.move(to: resized, note: .resized)
        h.advance(0.02)
        #expect(h.quartzFrame(Self.id) == expectedFrame("▶ Review…", window: resized))
    }

    @Test func minimizedHidesAndComesBack() {
        let h = started()
        h.server.windows[tagWindowNumber]?.isOnScreen = false
        h.ax.post(.miniaturized, pid: tagPID)
        h.advance(0.3)
        #expect(!h.isShown(Self.id))
        #expect(h.tag(Self.id)?.reason == .minimized)
        h.server.windows[tagWindowNumber]?.isOnScreen = true
        h.ax.post(.deminiaturized, pid: tagPID)
        h.settle()
        #expect(h.isShown(Self.id))
    }

    @Test func anotherSpaceIsCheckedOnTheSpaceNotification() {
        let h = started()
        h.server.windows[tagWindowNumber]?.isOnScreen = false
        h.system.post(.spaceChanged)
        h.settle()
        #expect(!h.isShown(Self.id), "at once, not at the next backstop pass")
        #expect(h.tag(Self.id)?.reason == .offScreen)
        h.server.windows[tagWindowNumber]?.isOnScreen = true
        h.system.post(.spaceChanged)
        h.settle()
        #expect(h.isShown(Self.id))
    }

    @Test func fullScreenCoveringAndSmallWindowsHide() {
        let h = started()
        h.ax.fullScreen[CodeWindowKey(pid: tagPID, number: tagWindowNumber)] = true
        h.ax.post(.resized, pid: tagPID)
        h.advance(0.35)
        #expect(h.tag(Self.id)?.reason == .fullScreen)
        h.ax.fullScreen[CodeWindowKey(pid: tagPID, number: tagWindowNumber)] = false
        h.move(to: tagDisplay.frame, note: .resized)
        h.advance(0.35)
        #expect(h.tag(Self.id)?.reason == .coversDisplay)
        h.move(to: CGRect(x: 300, y: 300, width: 300, height: 300), note: .resized)
        h.advance(0.35)
        #expect(h.tag(Self.id)?.reason == .tooSmall)
        h.move(to: tagWindowBounds, note: .resized)
        h.advance(0.35)
        #expect(h.isShown(Self.id))
    }

    @Test func closedWindowHides() {
        let h = started()
        h.server.windows[tagWindowNumber] = nil
        h.ax.post(.destroyed, pid: tagPID, number: tagWindowNumber)
        h.settle()
        #expect(h.tag(Self.id)?.reason == .closed)
    }

    @Test func hiddenAppHidesItsTags() {
        let h = started()
        h.ax.post(.appHidden, pid: tagPID)
        h.settle()
        #expect(h.tag(Self.id)?.reason == .appHidden)
        h.ax.post(.appShown, pid: tagPID)
        h.settle()
        #expect(h.isShown(Self.id))
    }

    @Test func stripHiddenHidesEverythingAndStopsObserving() {
        let h = started()
        h.controller.setStripVisible(false)
        h.settle()
        #expect(!h.isShown(Self.id))
        #expect(h.ax.unobserveCalls == [tagPID])
        h.advance(1.1)
        #expect(h.timeline.pendingTimers == 0, "the backstop stopped: no timer left")
        h.controller.setStripVisible(true)
        h.settle()
        #expect(h.isShown(Self.id))
    }

    @Test func settingOffHidesTags() {
        let h = started()
        var settings = CodeSettings()
        settings.deskTags = false
        h.controller.update(settings: settings)
        h.settle()
        #expect(!h.isShown(Self.id))
        #expect(h.ax.unobserveCalls == [tagPID])
    }

    @Test func tagsStandInForDeskMonitorsOnlyWhenTheyCanShow() {
        #expect(TagHarness(feasibility: .untested).controller.standsInForDeskMonitors == false,
                "desk pop-outs keep their monitors until C16 passes (D10)")
        #expect(TagHarness(feasibility: .untested, lab: DeskTagLabOptions(enabled: true)).controller.standsInForDeskMonitors)
        #expect(TagHarness(feasibility: .failed, lab: DeskTagLabOptions(enabled: true)).controller.standsInForDeskMonitors == false)
        let h = started()
        #expect(h.controller.standsInForDeskMonitors)
        var changes: [Bool] = []
        h.controller.onStandInChanged = { changes.append($0) }
        var settings = CodeSettings()
        settings.deskTags = false
        h.controller.update(settings: settings)
        h.controller.update(settings: settings)
        settings.deskTags = true
        h.controller.update(settings: settings)
        #expect(changes == [false, true])
    }

    @Test func untestedFeasibilityShowsTagsOnlyInTheLab() {
        let off = started(feasibility: .untested)
        #expect(!off.isShown(Self.id))
        #expect(off.ax.observeCalls.isEmpty, "the Ready list carries desk sessions alone")
        let failed = started(feasibility: .failed, lab: DeskTagLabOptions(enabled: true))
        #expect(!failed.isShown(Self.id), "a failed window-ordering check wins over the lab")
        let lab = started([tagSession(Self.id, state: .done)], feasibility: .untested, lab: DeskTagLabOptions(enabled: true))
        #expect(lab.isShown(Self.id), "the lab tag on a throwaway pop-out")
        #expect(lab.tag(Self.id)?.content?.main?.kind == .lab)
    }

    @Test func dragHidesTheTagAndItShowsAgainAfterTheRelease() {
        let h = started()
        h.button.down = true
        let dragged = CGRect(x: 500, y: 240, width: 900, height: 700)
        h.move(to: dragged)
        #expect(!h.isShown(Self.id))
        #expect(h.tag(Self.id)?.reason == .dragging)
        h.advance(0.5)
        #expect(!h.isShown(Self.id), "the button is still down")
        h.button.down = false
        h.advance(0.06)
        #expect(h.isShown(Self.id), "the button is up and the last move is older than 0.15 s")
        #expect(h.quartzFrame(Self.id) == expectedFrame("▶ Review…", window: dragged))
        // Released right after the last move: 0.15 s after that move.
        h.button.down = true
        let again = CGRect(x: 560, y: 260, width: 900, height: 700)
        h.move(to: again)
        h.button.down = false
        h.advance(0.1)
        #expect(!h.isShown(Self.id))
        h.advance(0.1)
        #expect(h.isShown(Self.id))
        #expect(h.quartzFrame(Self.id) == expectedFrame("▶ Review…", window: again))
        h.advance(1)
        #expect(h.controller.dragTimer == nil, "no poll after the drag")
    }

    @Test func activationAndFocusReorderAboveTheWindow() throws {
        let h = started()
        let panel = try #require(h.panel(Self.id))
        for note in [CodeWindowNotification.appActivated, .focusedWindowChanged, .mainWindowChanged] {
            h.windowing.reset()
            h.ax.post(note, pid: tagPID)
            h.settle()
            let show = try #require(h.windowing.lastShow(panel.panel))
            #expect(show.reorder && show.above == tagWindowNumber)
        }
        // The app itself activating can bring its windows forward: back above the Claude window.
        h.windowing.reset()
        h.system.post(.appActivated(777))
        let own = try #require(h.windowing.lastShow(panel.panel))
        #expect(own.reorder && own.above == tagWindowNumber)
        // Another app activating changes nothing in the first cover mode (the window server's order covers the tag).
        h.windowing.reset()
        h.system.post(.appActivated(55))
        h.settle()
        #expect(h.windowing.shows.isEmpty)
    }

    @Test func fallbackHidesWhenAWindowInFrontCoversTheTag() throws {
        let h = TagHarness(coverMode: .floating)
        h.server.frontToBack = [tagWindow()]
        h.start()
        h.desk([Self.offerSession()])
        let panel = try #require(h.panel(Self.id))
        #expect(h.isShown(Self.id))
        #expect(h.windowing.lastShow(panel.panel)?.level == .floating)
        #expect(h.windowing.lastShow(panel.panel)?.above == nil)
        let cover = DeskTagServerWindow(number: 900, pid: 55, bounds: CGRect(x: 1000, y: 100, width: 500, height: 400))
        h.server.frontToBack = [cover, tagWindow()]
        h.advance(1)
        #expect(h.tag(Self.id)?.reason == .covered, "the 1 Hz pass sees it")
        h.server.frontToBack = [tagWindow(), cover]
        h.system.post(.appActivated(55))
        h.settle()
        #expect(h.isShown(Self.id), "another app's activation checks again at once")
    }

    @Test func alwaysOnTopPopOutGetsItsLevel() throws {
        let h = TagHarness()
        h.server.windows[tagWindowNumber] = tagWindow(layer: 3)
        h.start()
        h.desk([Self.offerSession()])
        let panel = try #require(h.panel(Self.id))
        #expect(h.windowing.lastShow(panel.panel)?.level == NSWindow.Level(rawValue: 3),
                "a panel is ordered directly above a window of its own level")
        let floating = TagHarness(coverMode: .floating)
        floating.server.windows[tagWindowNumber] = tagWindow(layer: 3)
        floating.server.frontToBack = [tagWindow(layer: 3)]
        floating.start()
        floating.desk([Self.offerSession()])
        let other = try #require(floating.panel(Self.id))
        #expect(floating.windowing.lastShow(other.panel)?.level == NSWindow.Level(rawValue: 4))
        // Another always-on-top window in front of it covers the tag; an ordinary one cannot.
        let ordinary = DeskTagServerWindow(number: 900, pid: 55, bounds: CGRect(x: 1000, y: 100, width: 500, height: 400))
        floating.server.frontToBack = [ordinary, tagWindow(layer: 3)]
        floating.advance(1)
        #expect(floating.isShown(Self.id))
        var onTop = ordinary
        onTop.layer = 3
        floating.server.frontToBack = [onTop, tagWindow(layer: 3)]
        floating.advance(1)
        #expect(floating.tag(Self.id)?.reason == .covered)
    }

    @Test func removedDeskWindowRemovesItsTag() throws {
        let h = started()
        let panel = try #require(h.panel(Self.id))
        h.controller.update(sessions: [Self.offerSession()], deskWindows: [])
        h.settle()
        #expect(!h.windowing.isShown(panel.panel))
        #expect(h.tag(Self.id) == nil)
        #expect(h.ax.unwatchCalls == [CodeWindowKey(pid: tagPID, number: tagWindowNumber)])
    }

    @Test func suppressedOffersTakeTheTagAway() {
        let h = started()
        let offer = Self.offerSession().offers[0].id
        h.controller.setSuppressed(DeskTagSuppressed(offers: [offer]))
        h.settle()
        #expect(!h.isShown(Self.id))
        #expect(h.tag(Self.id)?.reason == .noContent)
    }

    @Test func hideTextAndShowTextShortenThePills() {
        let h = started()
        h.controller.setHideText(true)
        #expect(h.panel(Self.id)?.view.shownText(0) == "▶ 1")
        #expect(h.quartzFrame(Self.id)?.width == DeskTagStackView.width("▶ 1"))
        h.controller.setHideText(false)
        var settings = CodeSettings()
        settings.showText["A"] = false
        h.controller.update(settings: settings)
        #expect(h.panel(Self.id)?.view.shownText(0) == "▶ 1")
    }

    @Test func nextToTheStripTheTagStaysOut() {
        let h = started()
        let under = CGRect(x: 1100, y: 300, width: 800, height: 600)
        h.move(to: under)
        let frame = h.quartzFrame(Self.id)
        #expect(frame?.maxX == tagStrip.rect.minX - 4)
    }

    @Test func runningWordsAreRebuiltWhileShownOnly() {
        let session = tagSession(Self.id, state: .working, workStartedAt: tileNow.addingTimeInterval(-600))
        let h = started([session])
        #expect(h.panel(Self.id)?.view.shownText(0) == "Running 10 min")
        #expect(h.controller.clockTimer != nil)
        var now = tileNow
        h.controller.dateNow = { now }
        now = tileNow.addingTimeInterval(60)
        h.advance(DeskTagController.clockInterval)
        #expect(h.panel(Self.id)?.view.shownText(0) == "Running 11 min")
        h.controller.setStripVisible(false)
        h.settle()
        #expect(h.controller.clockTimer == nil)
    }

    @Test func twoTagsOnTwoWindows() {
        let other = tagSession("local_t2", "Docs site · link checker", index: 2, state: .working)
        let h = TagHarness()
        h.server.windows[502] = tagWindow(502, bounds: CGRect(x: 100, y: 500, width: 700, height: 500))
        h.start()
        h.desk([Self.offerSession(), other])
        #expect(h.isShown(Self.id) && h.isShown("local_t2"))
        #expect(h.ax.observeCalls == [tagPID], "one observer for the copy")
        h.server.windows[502]?.isOnScreen = false
        h.ax.post(.miniaturized, pid: tagPID)
        h.advance(0.3)
        #expect(h.isShown(Self.id))
        #expect(!h.isShown("local_t2"))
    }

    @Test func stopHidesEverything() {
        let h = started()
        h.controller.stop()
        h.settle()
        #expect(!h.isShown(Self.id))
        #expect(h.ax.unobserveCalls == [tagPID])
        #expect(h.system.stops == 1)
    }
}

/// The closure-based actions for the composition root.
@MainActor
@Suite("desk tags: closure actions")
struct TagClosureActionsTests {
    final class Box {
        var copied: [String] = []
        var opened: [String] = []
    }

    @Test func parkGoesToTheParkerAndCopyLinkBuildsClaudesLink() {
        let parker = TileTestParker()
        let box = Box()
        let actions = DeskTagClosureActions(parker: parker,
                                         openOffer: { id, session, _ in box.opened.append("offer \(id) \(session)") },
                                         openResult: { result, session, _ in box.opened.append("result \(result) \(session)") },
                                         openDashboard: { box.opened.append("dashboard \($0)") },
                                         copyText: { box.copied.append($0) })
        actions.park(sessionID: "local_abc")
        #expect(parker.performed.map(\.0) == [.park])
        #expect(parker.performed.map(\.1) == ["local_abc"])
        actions.copyLink(sessionID: "local_abc")
        actions.copyLink(sessionID: "local_../evil")
        #expect(box.copied == ["claude://claude.ai/epitaxy/local_abc"], "an id failing the grammar copies nothing")
        let offer = CommandOffer.ID(sessionIndex: 3, replyUUID: "r", number: 1)
        actions.openOffer(offer, sessionID: "local_abc", anchor: .zero)
        actions.openResult("preview:x", sessionID: "local_abc", anchor: .zero)
        actions.openDashboard(sessionID: "local_abc")
        #expect(box.opened == ["offer #3.1 local_abc", "result preview:x local_abc", "dashboard local_abc"])
    }
}
