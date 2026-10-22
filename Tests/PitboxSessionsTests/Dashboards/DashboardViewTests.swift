import AppKit
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The ▦ button, its arming, the opener and the dashboards list.
@MainActor
@Suite("Dashboard buttons and list", .serialized)
struct DashboardViewTests {
    init() { CodeLog.enabled = false }

    @Test func openButtonsArmAfterTheDelayAndNeverUnderTheRestingPointer() {
        var arming = DashboardOpenArming()
        #expect(!arming.accepts(pressBegan: 100), "not shown yet")
        arming.appeared(at: 10, pointerInside: false)
        #expect(!arming.accepts(pressBegan: 10.5) && arming.accepts(pressBegan: 10.9))
        // Appearing under the pointer: the first press is swallowed until the pointer leaves and comes back.
        arming.appeared(at: 20, pointerInside: true)
        #expect(!arming.accepts(pressBegan: 21) && !arming.accepts(pressBegan: 25))
        arming.pointerExited()
        arming.pointerEntered(at: 25.1)
        #expect(arming.accepts(pressBegan: 25.2))
        // A layout move re-arms.
        arming.appeared(at: 30, pointerInside: false)
        #expect(!arming.accepts(pressBegan: 30.5) && arming.accepts(pressBegan: 30.9))
    }

    @Test func theButtonViewOpensOnlyOnAnArmedPress() {
        var now = 50.0
        var opened = 0
        let view = DashboardButtonView(style: .tag, tooltip: "https://dash.example.com/dash/polar-shore/",
                                       frame: CGRect(x: 0, y: 0, width: 120, height: 22))
        view.clock = { now }
        view.pointer = { _ in CGPoint(x: 10, y: 10) }
        view.onOpen = { opened += 1 }
        view.rearm()
        now = 51
        view.press(began: now)
        #expect(opened == 0, "it appeared under the pointer")
        view.pointer = { _ in nil }
        view.rearm()
        now = 51.5
        view.press(began: now)
        #expect(opened == 0, "0.5 s after a move")
        now = 51.9
        view.press(began: now)
        #expect(opened == 1, "0.9 s after it")
        #expect(view.toolTip == "https://dash.example.com/dash/polar-shore/" && !view.acceptsFirstResponder)
        #expect(view.accessibilityLabel() == "Dashboard")
        #expect(DashboardPill.size(.medium).height == 16 && DashboardPill.size(.small).height == 14)
        #expect(DashboardPill.title(.large) == "▦ Dashboard" && DashboardPill.title(.medium) == "▦")
    }

    @Test func theButtonTakesNoAccessibilityPressOnlyARealClick() {
        var now = 50.0
        var opened = 0
        let view = DashboardButtonView(style: .large, tooltip: "https://dash.example.com/dash/polar-shore/",
                                       frame: CGRect(x: 0, y: 0, width: 120, height: 22))
        view.clock = { now }
        view.pointer = { _ in nil }
        view.onOpen = { opened += 1 }
        view.rearm()
        now = 52
        #expect(view.arming.isArmed(now: now), "armed: only the press kind decides")
        // The ▦ button opens a URL: another process's Accessibility press must not.
        #expect(!view.isAccessibilitySelectorAllowed(#selector(NSView.accessibilityPerformPress)))
        #expect(!view.accessibilityPerformPress())
        #expect(opened == 0)
        #expect(view.accessibilityRole() == .button && view.accessibilityLabel() == "Dashboard", "still announced")
        view.press(began: now)
        #expect(opened == 1, "a real click opens it")
    }

    @Test func theOpenerRebuildsTheAddressAndLogsNoHandle() {
        let lines = Shared<[String]>([])
        let token = CodeLog.observe { line in lines.value.append(line) }
        defer { CodeLog.stopObserving(token) }
        var opened: [URL] = []
        let opener = CodeDashboardOpener { opened.append($0) }
        let dashboard = CodeDashboard(handle: "polar-shore", site: .test, firstSeen: fixtureNow)!
        #expect(opener.open(dashboard, sessionIndex: 3))
        #expect(!opener.open(handle: "Polar-Shore", site: .test, sessionIndex: 3)
            && !opener.open(handle: "x/../y", site: .test, sessionIndex: 3))
        #expect(opened.map(\.absoluteString) == ["https://dash.example.com/dash/polar-shore/"])
        #expect(lines.value.contains("INFO result opened session=#3 kind=dashboard"))
        #expect(lines.value.allSatisfy { !$0.contains("polar") && !$0.contains("dash.example") })
    }

    func session(_ id: String, index: Int, headline: String, state: CodeSessionState, handle: String?,
                 builder: Date? = nil) -> CodeSessionSnapshot {
        var s = progressSnapshot(id, index: index, state: state, headline: headline)
        s.dashboard = handle.flatMap { CodeDashboard(handle: $0, site: .test, firstSeen: utcDate(2026, 10, 20, 22, 40), lastBuilderCallAt: builder) }
        return s
    }

    @Test func listRowsInTheGivenOrderWithoutOpenForSessionsTheUserDidNotUse() {
        let sessions = [
            session(sessionA, index: 1, headline: "wake phrase build", state: .working, handle: "polar-shore",
                    builder: utcDate(2026, 10, 20, 23, 14)),
            session(sessionB, index: 2, headline: "no board here", state: .done, handle: nil),
            session(sessionC, index: 3, headline: "insider migration\u{202E}", state: .reviewReady, handle: "quiet-fjord"),
        ]
        let rows = DashboardList.rows(sessions, ownActivityOnly: [sessionC], hideText: false, clock: clockUTC)
        #expect(rows.map(\.sessionID) == [sessionA, sessionC])
        #expect(rows[0].detail == "dash.example.com/dash/polar-shore/ · updated 23:14" && rows[0].canOpen)
        #expect(rows[1].detail == "dash.example.com/dash/quiet-fjord/ · since 22:40" && !rows[1].canOpen)
        #expect(rows[1].headline == "insider migration⟨U+202E⟩", "session text through the plain-text renderer")
        #expect(rows[0].stateWord == "working" && rows[1].stateWord == "review ready")
        let hidden = DashboardList.rows(sessions, ownActivityOnly: [], hideText: true, clock: clockUTC)
        #expect(hidden[0].detail == "dashboard · updated 23:14" && hidden[0].tooltip == nil)
        #expect(DashboardList.title(count: 2) == "Dashboards · 2")
        #expect(DashboardWords.peekLine(sessions[0].dashboard!, clock: clockUTC) == "▦ Open dashboard · since 22:40 · updated 23:14")
    }

    @Test func theListOpensArmedRowsAndReArmsRowsThatMove() throws {
        var now = 100.0
        var opened: [String] = []
        let rows = (0..<8).map { index in
            DashboardListRow(sessionID: "local_r\(index)", index: index, state: .working, stateWord: "working",
                             headline: "Session \(index)", detail: "dash.example.com/dash/row-\(index)/ · updated 23:14",
                             tooltip: nil, canOpen: index != 2)
        }
        let list = DashboardListView(rows: rows, frame: CGRect(x: 0, y: 0, width: 520, height: 240))
        list.buttonClock = { now }
        list.onOpen = { opened.append($0) }
        #expect(list.buttons.count == 7, "no Open for the row the user never used")
        let first = try #require(list.buttons["local_r0"])
        first.pointer = { _ in nil }
        first.rearm()
        now = 101
        first.press(began: now)
        #expect(opened == ["local_r0"])
        // Scrolling moves the rows: their buttons arm again before they open anything.
        list.scroll(to: 60)
        let moved = try #require(list.buttons["local_r1"])
        moved.pointer = { _ in nil }
        moved.rearm()
        now = 101.3
        moved.press(began: now)
        #expect(opened == ["local_r0"])
        now = 102
        moved.press(began: now)
        #expect(opened == ["local_r0", "local_r1"])
        #expect(DashboardListView.preferredHeight(rows: 8) > 240)
    }
}
