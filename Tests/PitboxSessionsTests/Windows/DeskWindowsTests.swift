import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The parker publishes the matched pop-outs on the desk (for desk tags and drag-to-park).
@MainActor
@Suite("Desk windows published by the parker")
struct DeskWindowsTests {
    init() { CodeTileLog.enabled = false }

    @Test func onlyMatchedDeskPopOutsAreListedWithTheirNumbers() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        let a = WindowsHarness.pidA
        h.world.add(WindowsTestWindow(pid: a, number: 10, title: "Claude", frame: CGRect(x: 0, y: 30, width: 1330, height: 620)))
        h.world.add(WindowsTestWindow(pid: a, number: 11, title: "Alpha", frame: CGRect(x: 200, y: 120, width: 900, height: 700)))
        h.world.add(WindowsTestWindow(pid: a, number: 12, title: "Beta", frame: CGRect(x: 1300, y: 120, width: 900, height: 700)))
        h.parker.start()
        h.update([windowSession("local_alpha", title: "Alpha", index: 1), windowSession("local_beta", title: "Beta", index: 2),
                  windowSession("local_gone", title: "Not a window", index: 3)])
        #expect(h.parker.deskWindows["local_alpha"] == CodeDeskWindow(pid: a, windowNumber: 11))
        #expect(h.parker.deskWindows["local_beta"] == CodeDeskWindow(pid: a, windowNumber: 12))
        #expect(h.parker.deskWindows["local_gone"] == nil, "a session without a matched window has none")
        #expect(h.parker.deskWindows.count == 2, "the main window titled Claude never counts")
    }
}
