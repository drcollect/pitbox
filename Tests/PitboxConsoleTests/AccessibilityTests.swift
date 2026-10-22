import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// VoiceOver must find the terminal itself, not a bare scroller (SwiftTerm gives macOS accessibility nothing).
@MainActor
struct TerminalAccessibilityTests {
    @Test func voiceOverFindsTheTerminalNotABareScroller() throws {
        let h = ConsoleHarness()
        let view = try #require(h.selectedView)
        let children = h.view.accessibilityChildren() ?? []
        #expect(!children.contains { $0 is NSScroller }, "children: \(children)")
        #expect(view.isAccessibilityElement() && view.accessibilityRole() == .textArea && view.accessibilityRoleDescription() == "terminal")
        #expect(children.count == 2 && (children[0] as AnyObject) === h.view.strip && (children[1] as AnyObject) === view,
                "the strip, then the terminal, top to bottom: \(children)")
        #expect(view.accessibilityLabel() == "Terminal, ~", "named after its tab")
        #expect(!(view.accessibilityChildren() ?? []).contains { $0 is NSScroller })
        // A hit on the scroller answers with the terminal.
        let scroller = try #require(view.subviews.first { $0 is NSScroller })
        let center = CGPoint(x: scroller.frame.midX, y: scroller.frame.midY)
        let screen = h.window.convertPoint(toScreen: view.convert(center, to: nil))
        #expect(!(view.accessibilityHitTest(screen) is NSScroller))
    }

    @Test func theTerminalsNameFollowsTheSelectedTab() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession()
        h.processes[1].changeDirectory("/tmp")
        h.manager.pollMetadata()
        let view = try #require(h.selectedView)
        #expect(view.accessibilityLabel() == "Terminal, tmp")
        let children = h.view.accessibilityChildren() ?? []
        #expect(children.count == 2 && (children[1] as AnyObject) === view, "only the selected tab's terminal is in the console")
    }

    @Test func theFindBarStaysReachable() throws {
        let h = ConsoleHarness()
        let view = try #require(h.selectedView)
        h.window.makeFirstResponder(view)
        #expect(view.performKeyEquivalent(with: h.keyEvent("f", keyCode: 3, modifiers: .command)))
        let children = view.accessibilityChildren() ?? []
        #expect(!children.isEmpty && !children.contains { $0 is NSScroller }, "the find bar's controls: \(children)")
    }
}

/// The strip's buttons explain themselves, and VoiceOver hears about changes it would not otherwise notice.
@MainActor
struct StripAccessibilityTests {
    @Test func theStripButtonsExplainThemselvesToVoiceOver() throws {
        let h = TabStripSnapshotTests.console(count: 2, selected: 0, light: false, rotate: true)
        let children = try #require(h.view.strip.accessibilityChildren() as? [NSAccessibilityElement])
        for button in children.suffix(3) {
            #expect(button.accessibilityHelp()?.isEmpty == false, "\(button.accessibilityLabel() ?? "?") has no help")
        }
        #expect(children.suffix(3).map { $0.accessibilityLabel() ?? "" } == ["New Tab", "Presets", "Auto-rotate Is On"])
        #expect(children[2].accessibilityHelp()?.contains("\u{2318}T") == true, "New Tab lists the shortcuts, like its tooltip")
        #expect(children[3].accessibilityHelp() == TabStripHelp.presets && children[4].accessibilityHelp() == TabStripHelp.rotate)
        // At the tab limit New Tab says why it is dimmed.
        let full = ConsoleHarness(settingsJSON: #"{"maxSessions": 1}"#)
        let elements = try #require(full.view.strip.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(elements[1].accessibilityLabel() == "New Tab" && elements[1].accessibilityHelp() == TabStripHelp.newTabDisabled)
    }

    @Test func voiceOverIsToldWhenTheSelectionOrTheTabsChangeAndWhenATabAsksKill() throws {
        let h = TabStripSnapshotTests.console(count: 3, selected: 0, light: false)
        let strip = h.view.strip
        var posts: [(element: Any, name: NSAccessibility.Notification, info: [NSAccessibility.NotificationUserInfoKey: Any]?)] = []
        strip.postAccessibilityNotification = { posts.append(($0, $1, $2)) }
        func posted(_ name: NSAccessibility.Notification, on element: AnyObject) -> Bool {
            posts.contains { $0.name == name && ($0.element as AnyObject) === element }
        }
        let tabs = try #require(strip.accessibilityChildren() as? [NSAccessibilityElement])

        // A selection change (a click, a shortcut or auto-rotate): the two tabs' values and the group's selected child.
        h.manager.select(index: 2)
        #expect(posted(.valueChanged, on: tabs[0]) && posted(.valueChanged, on: tabs[2]) && posted(.selectedChildrenChanged, on: strip))
        #expect(!posts.contains { $0.name == .layoutChanged })
        let selectedChild = try #require(strip.accessibilitySelectedChildren()?.first)
        #expect((selectedChild as AnyObject) === tabs[2])

        // A title refresh posts nothing.
        posts.removeAll()
        h.processes[1].changeDirectory("/tmp")
        h.manager.pollMetadata()
        #expect(posts.isEmpty, "\(posts.map { $0.name })")

        // Tabs that come or go change the layout.
        _ = h.manager.newSession()
        #expect(posted(.layoutChanged, on: strip))
        posts.removeAll()
        h.manager.closeNow(h.manager.sessions[3].id)
        #expect(posted(.layoutChanged, on: strip))

        // "Kill? click again" is announced, from VoiceOver's own Close Tab action and from Cmd-W.
        h.processes[1].runJob(named: "vim")
        h.manager.pollMetadata()
        posts.removeAll()
        let close = try #require(tabs[1].accessibilityCustomActions()?.first { $0.name == "Close Tab" })
        #expect(close.handler?() == true)
        let announcement = try #require(posts.first { $0.name == .announcementRequested })
        let text = announcement.info?[.announcement] as? String
        #expect(text?.contains("vim") == true && text?.contains("3 seconds") == true, "\(text ?? "nil")")
        #expect(announcement.info?[.priority] as? Int == NSAccessibilityPriorityLevel.high.rawValue)
        #expect(h.manager.sessions.count == 3, "it only asked")
        h.manager.select(index: 1)
        posts.removeAll()
        #expect(h.view.handle(.closeSession))
        #expect(!posts.contains { $0.name == .announcementRequested }, "the second Cmd-W closes it: nothing to announce")
        #expect(h.manager.sessions.count == 2)
        // An idle tab closes at once, silently.
        posts.removeAll()
        strip.onClose?(h.manager.sessions[0].id)
        #expect(!posts.contains { $0.name == .announcementRequested } && h.manager.sessions.count == 1)
    }

    @Test func cmdWOnABusyTabIsAnnouncedToo() {
        let h = TabStripSnapshotTests.console(count: 2, selected: 1, light: false)
        var announcements: [String] = []
        h.view.strip.postAccessibilityNotification = { _, name, info in
            if name == .announcementRequested, let text = info?[.announcement] as? String { announcements.append(text) }
        }
        h.processes[1].runJob(named: "npm")
        h.manager.pollMetadata()
        #expect(h.view.handle(.closeSession))
        #expect(announcements.count == 1 && announcements.first?.hasPrefix("npm: ") == true, "\(announcements)")
    }
}
