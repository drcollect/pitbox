import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// Click sequences on a crowded strip, VoiceOver's hit test over scrolled tabs, and restoring many tabs. They click with a
/// mouse-down and a mouse-up, like a real mouse.
@MainActor
struct TabStripEdgeCaseTests {
    @Test func aDoubleClickOnANarrowTabSelectsItAndNeverClosesIt() throws {
        let h = TabStripSnapshotTests.console(count: 8, selected: 3, light: false)
        let strip = h.view.strip
        #expect(strip.tabFrames.map(\.frame.width) == [56, 56, 56, 116, 56, 56, 56, 56])
        let target = strip.tabFrames[5]
        let point = CGPoint(x: target.frame.maxX - 6, y: target.frame.midY)
        #expect(strip.hit(at: point) == .tab(target.id))
        try clickStrip(h, at: point, count: 1)
        #expect(h.manager.selectedIndex == 5 && strip.hit(at: point) == .close(target.id), "the widened tab's close button is under the pointer")
        try clickStrip(h, at: point, count: 2)
        #expect(h.manager.sessions.count == 8 && h.manager.selectedIndex == 5)
    }

    @Test func voiceOverHitTestOnPlusFindsNewTabNotAHiddenTab() throws {
        let h = TabStripSnapshotTests.console(count: 20, selected: 0, light: false)
        let strip = h.view.strip
        let plus = CGPoint(x: strip.newFrame.midX, y: strip.newFrame.midY)
        #expect(strip.tabFrames.contains { $0.frame.contains(plus) }, "a scrolled-out tab lies under +")
        let screen = h.window.convertPoint(toScreen: strip.convert(plus, to: nil))
        #expect((strip.accessibilityHitTest(screen) as? NSAccessibilityElement)?.accessibilityLabel() == "New Tab")
        let children = try #require(strip.accessibilityChildren() as? [NSAccessibilityElement])
        for tab in children.prefix(20) {
            #expect(tab.accessibilityFrameInParentSpace().maxX <= strip.viewport.maxX + 0.5, "no tab's frame covers the controls")
        }
    }

    @Test func aDoubleClickOnABusyTabsCloseButtonOnlyAsks() throws {
        let h = TabStripSnapshotTests.console(count: 3, selected: 1, light: false)
        h.processes[1].runJob(named: "vim")
        h.manager.pollMetadata()
        let strip = h.view.strip
        let tab = strip.tabFrames[1]
        let point = CGPoint(x: tab.frame.maxX - 16, y: tab.frame.midY)
        #expect(strip.hit(at: point) == .close(tab.id))
        try clickStrip(h, at: point, count: 1)
        #expect(h.manager.closeConfirmationID == tab.id && h.manager.sessions.count == 3)
        try clickStrip(h, at: point, count: 2)
        #expect(h.manager.sessions.count == 3 && h.processes[1].terminateCount == 0, "the second click of a double-click is not the deliberate one")
        try clickStrip(h, at: point, count: 1)
        #expect(h.manager.sessions.count == 2 && h.processes[1].terminateCount == 1, "a separate click ends it")
    }

    @Test func twentyRestoredTabsShowTheSavedSelection() {
        let saved = SavedState(selected: 17, tabs: (0..<20).map { _ in .init(preset: "shell", cwd: "/tmp") })
        let h = ConsoleHarness(settingsJSON: #"{"maxSessions": 24}"#, size: CGSize(width: 618, height: 200), saved: saved)
        let strip = h.view.strip
        #expect(h.manager.sessions.count == 20 && h.manager.selectedIndex == 17)
        #expect(strip.viewport.contains(strip.tabFrames[17].frame), "\(strip.tabFrames[17].frame) in \(strip.viewport)")
    }

    @Test func aDoubleClickOnATabCutOffAtTheEdgeStaysOnIt() throws {
        let h = TabStripSnapshotTests.console(count: 20, selected: 0, light: false)
        let strip = h.view.strip
        let edge = try #require(strip.tabFrames.firstIndex { $0.frame.maxX > strip.viewport.maxX && $0.frame.minX < strip.viewport.maxX })
        let point = CGPoint(x: strip.viewport.maxX - 6, y: strip.tabFrames[edge].frame.midY)
        try clickStrip(h, at: point, count: 1)
        #expect(h.manager.selectedIndex == edge && strip.viewport.insetBy(dx: -0.5, dy: 0).contains(strip.tabFrames[edge].frame))
        try clickStrip(h, at: point, count: 2)
        #expect(h.manager.selectedIndex == edge && h.manager.sessions.count == 20)
    }
}
