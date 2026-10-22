import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The panels never take the keyboard (docs/THREAT_MODEL.md), contain no text field, and their clicks act without
/// arming except where something opens outside the app.
@MainActor
@Suite("desk tags: panels and clicks")
struct TagPanelTests {
    init() { DeskTagLog.enabled = false }

    static let id = "local_t1"
    static let dashboard = CodeDashboard(handle: "polar-shore", site: .test, firstSeen: tileNow.addingTimeInterval(-3600),
                                         lastBuilderCallAt: tileNow.addingTimeInterval(-600))

    /// A view that records every key event it is sent.
    final class KeyRecorder: NSView {
        var keys = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys += 1 }
        override func keyUp(with event: NSEvent) { keys += 1 }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { keys += 1; return true }
    }

    static func keyEvent(_ characters: String, code: UInt16, type: NSEvent.EventType = .keyDown,
                         modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    /// Every view in the hierarchy.
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    @Test func tagAndPeekPanelsCanNeverBecomeKeyOrMain() {
        let tag = DeskTagPanel()
        let peek = DeskPeekPanel(sessionID: Self.id, model: DeskPeekModel(title: "x", state: .done))
        for panel in [tag.panel, peek.panel] {
            #expect(!panel.canBecomeKey)
            #expect(!panel.canBecomeMain)
            #expect(!panel.becomesKeyOnlyIfNeeded)
            #expect(!panel.hidesOnDeactivate)
            #expect(!panel.isMovable)
            #expect(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.borderless))
            #expect(panel.collectionBehavior == [.canJoinAllSpaces, .transient, .ignoresCycle])
            #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
            #expect(panel.defaultButtonCell == nil)
            #expect(panel.animationBehavior == .none)
            panel.makeKey()
            panel.makeMain()
            #expect(!panel.isKeyWindow && !panel.isMainWindow)
            #expect(!panel.isVisible)
        }
    }

    @Test func keyEventsSentToThePanelsAreNeverDelivered() throws {
        for panel in [DeskTagPanel().panel, DeskPeekPanel(sessionID: Self.id, model: DeskPeekModel(title: "x", state: .done)).panel] {
            let recorder = KeyRecorder(frame: CGRect(x: 0, y: 0, width: 50, height: 20))
            panel.contentView?.addSubview(recorder)
            _ = panel.makeFirstResponder(recorder)
            for (characters, code) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53)), (" ", UInt16(49)), ("p", UInt16(35))] {
                let down = try #require(Self.keyEvent(characters, code: code))
                let up = try #require(Self.keyEvent(characters, code: code, type: .keyUp))
                panel.sendEvent(down)
                panel.sendEvent(up)
                #expect(!panel.performKeyEquivalent(with: down))
                let command = try #require(Self.keyEvent(characters, code: code, modifiers: .command))
                panel.sendEvent(command)
                #expect(!panel.performKeyEquivalent(with: command))
            }
            #expect(recorder.keys == 0)
        }
    }

    @Test func noTextFieldAnywhere() throws {
        let h = TagHarness()
        h.start()
        let session = tagSession(Self.id, state: .working, offers: [tileOffer("make release")], dashboard: Self.dashboard,
                                 results: [CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"),
                                                      label: "localhost:5173")])
        h.desk([session])
        h.click(Self.id, 0)   // ▶ Review… opens the sheet, not the peek
        let tag = try #require(h.panel(Self.id))
        h.controller.openPeek(Self.id, focus: .top)
        let peek = try #require(h.controller.peek)
        for root in [tag.panel.contentView, peek.panel.contentView].compactMap({ $0 }) {
            for view in Self.views(root) {
                #expect(!(view is NSTextField) && !(view is NSTextView) && !(view is NSSecureTextField))
                #expect(!view.acceptsFirstResponder)
            }
        }
    }

    @Test func oneOfferOpensItsSheetAtTheTag() throws {
        let h = TagHarness()
        h.start()
        let offer = tileOffer("swift test")
        h.desk([tagSession(Self.id, offers: [offer])])
        let anchor = try #require(h.tag(Self.id)?.shownFrame)
        h.click(Self.id)
        #expect(h.actions.calls == [.offer(offer.id, Self.id, anchor)])
        #expect(h.controller.peek == nil)
        #expect(h.windowing.lastShow(try #require(h.panel(Self.id)).panel)?.reorder == true,
                "back above its window after the click")
    }

    @Test func severalOffersOrAWarningOpenTheDeskPeek() throws {
        let h = TagHarness()
        h.start()
        let offers = [tileOffer("a", number: 1), tileOffer("b", number: 2)]
        h.desk([tagSession(Self.id, state: .working, offers: offers)])
        h.click(Self.id)
        let peek = try #require(h.controller.peek)
        #expect(peek.sessionID == Self.id)
        #expect(h.controller.peekFocus == .commands)
        #expect(peek.view.model.commands.count == 2)
        #expect(h.actions.calls.isEmpty, "opening the peek runs nothing")
        #expect(h.windowing.isShown(peek.panel))
        // A second click on the tag closes it.
        h.click(Self.id)
        #expect(h.controller.peek == nil)
        // A click on a command row opens that command's sheet.
        h.click(Self.id)
        let row = try #require(h.controller.peek?.view.visibleButtons().first { if case .offer = $0.action { return true }; return false })
        h.controller.peek?.view.press(at: CGPoint(x: row.rect.midX, y: row.rect.midY))
        h.controller.peek?.view.release(at: CGPoint(x: row.rect.midX, y: row.rect.midY))
        #expect(h.actions.calls.count == 1)
        if case .offer(let id, let session, _)? = h.actions.calls.first {
            #expect(id == offers[0].id && session == Self.id)
        } else {
            Issue.record("expected the sheet of the first offer")
        }
    }

    @Test func dashboardPillArmsAfterItAppeared() throws {
        let h = TagHarness()
        h.start()
        h.desk([tagSession(Self.id, state: .done, dashboard: Self.dashboard)])
        h.click(Self.id)
        #expect(h.actions.calls.isEmpty, "a press 0.0 s after it appeared is swallowed")
        h.advance(0.5)
        h.click(Self.id)
        #expect(h.actions.calls.isEmpty)
        h.advance(0.35)
        h.click(Self.id)
        #expect(h.actions.calls == [.dashboard(Self.id)])
    }

    @Test func dashboardPillUnderThePointerSwallowsThePressUntilThePointerLeaves() throws {
        let h = TagHarness()
        h.start()
        h.desk([tagSession(Self.id, state: .done)])
        // The dashboard appears where the pointer already is.
        let expected = ScreenSpace.appKit(fromQuartz: CGRect(x: tagWindowBounds.maxX - 24 - DeskTagStackView.width("▦ Dashboard"),
                                                             y: tagWindowBounds.minY - 11, width: DeskTagStackView.width("▦ Dashboard"),
                                                             height: 22), primaryHeight: 1200)
        h.system.pointer = CGPoint(x: expected.midX, y: expected.midY)
        h.desk([tagSession(Self.id, state: .done, dashboard: Self.dashboard)])
        h.advance(2)
        h.click(Self.id)
        #expect(h.actions.calls.isEmpty, "never while the pointer was over its place when it appeared")
        h.panel(Self.id)?.view.notePointerLeft()
        h.click(Self.id)
        #expect(h.actions.calls == [.dashboard(Self.id)])
    }

    @Test func aMoveReArmsTheDashboardPill() throws {
        let h = TagHarness()
        h.start()
        h.desk([tagSession(Self.id, state: .done, dashboard: Self.dashboard)])
        h.advance(2)
        h.move(to: CGRect(x: 360, y: 260, width: 900, height: 700))
        h.click(Self.id)
        #expect(h.actions.calls.isEmpty, "it moved: armed again from the move")
        h.advance(0.9)
        h.click(Self.id)
        #expect(h.actions.calls == [.dashboard(Self.id)])
    }

    @Test func deskPeekClosesAfterThePointerLeftTagAndPeek() throws {
        let h = TagHarness()
        h.start()
        h.desk([tagSession(Self.id, state: .working, warnings: [TagContentTests.stuck])])
        h.click(Self.id)
        let peek = try #require(h.controller.peek)
        #expect(h.controller.peekFocus == .warnings)
        h.controller.tagHover(Self.id, inside: true)
        h.controller.tagHover(Self.id, inside: false)
        h.advance(0.2)
        #expect(h.controller.peek != nil)
        peek.view.onHover?(true)   // into the peek in time
        h.advance(0.5)
        #expect(h.controller.peek != nil)
        peek.view.onHover?(false)
        h.advance(0.26)
        #expect(h.controller.peek == nil)
        #expect(!h.windowing.isShown(peek.panel))
    }

    @Test func escapeClosesThePeekOnlyThroughTheLocalMonitorWhileActive() throws {
        let h = TagHarness()
        h.start()
        h.desk([tagSession(Self.id, state: .working)])
        h.click(Self.id)
        let peek = try #require(h.controller.peek)
        // Sent to the panel itself, Escape does nothing.
        let escape = try #require(Self.keyEvent("\u{1b}", code: 53))
        peek.panel.sendEvent(escape)
        peek.panel.cancelOperation(nil)
        #expect(h.controller.peek != nil)
        // Claude active: a local monitor never sees the key.
        h.system.ownActive = false
        #expect(!h.system.pressEscape())
        #expect(h.controller.peek != nil)
        // The app active: the monitor closes it.
        h.system.ownActive = true
        #expect(h.system.pressEscape())
        #expect(h.controller.peek == nil)
        #expect(h.system.escapeMonitors.isEmpty, "the monitor goes with the peek")
    }

    @Test func peekClosesWithTheBlockTheTagAndTheOverlays() throws {
        let h = TagHarness()
        h.start()
        h.desk([tagSession(Self.id, state: .working)])
        h.click(Self.id)
        h.controller.setStripVisible(false)
        #expect(h.controller.peek == nil)
        h.controller.setStripVisible(true)
        h.settle()
        h.click(Self.id)
        h.controller.dismissOverlays()
        #expect(h.controller.peek == nil)
        h.click(Self.id)
        h.server.windows[tagWindowNumber]?.isOnScreen = false
        h.ax.post(.miniaturized, pid: tagPID)
        h.advance(0.3)
        #expect(h.controller.peek == nil, "its tag hid")
    }

    @Test func peekResultAndDashboardButtonsAreArmedParkAndCopyLinkAreNot() throws {
        let h = TagHarness()
        h.start()
        let preview = CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"), label: "localhost:5173")
        h.desk([tagSession(Self.id, state: .working, dashboard: Self.dashboard, results: [preview])])
        h.click(Self.id, 0)
        let view = try #require(h.controller.peek?.view)
        func tap(_ match: (DeskPeekModel.Action) -> Bool) throws {
            let button = try #require(view.visibleButtons().first { match($0.action) })
            view.press(at: CGPoint(x: button.rect.midX, y: button.rect.midY))
            view.release(at: CGPoint(x: button.rect.midX, y: button.rect.midY))
        }
        try tap { $0 == .result(preview.id) }
        try tap { $0 == .dashboard }
        #expect(h.actions.calls.isEmpty, "just appeared: swallowed")
        try tap { $0 == .copyLink }
        #expect(h.actions.calls == [.copyLink(Self.id)])
        h.advance(0.9)
        try tap { $0 == .result(preview.id) }
        try tap { $0 == .dashboard }
        #expect(h.actions.calls == [.copyLink(Self.id), .result(preview.id, Self.id), .dashboard(Self.id)])
        try tap { $0 == .park }
        #expect(h.actions.calls.last == .park(Self.id))
        #expect(h.controller.peek == nil, "Park closes the peek")
    }

    @Test func peekButtonUnderThePointerSwallowsThePressUntilThePointerLeaves() throws {
        let h = TagHarness()
        h.start()
        let preview = CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"), label: "localhost:5173")
        h.desk([tagSession(Self.id, state: .working, results: [preview])])
        // Find where the result button will be, then open the peek again with the pointer already there.
        h.click(Self.id)
        let first = try #require(h.controller.peek?.view)
        let button = try #require(first.visibleButtons().first { $0.action == .result(preview.id) })
        let screen = try #require(first.window?.convertToScreen(first.convert(button.rect, to: nil)))
        h.click(Self.id)
        #expect(h.controller.peek == nil)
        h.system.pointer = CGPoint(x: screen.midX, y: screen.midY)
        h.click(Self.id)
        let view = try #require(h.controller.peek?.view)
        h.advance(2)
        let point = CGPoint(x: button.rect.midX, y: button.rect.midY)
        view.press(at: point)
        view.release(at: point)
        #expect(h.actions.calls.isEmpty, "it appeared under the pointer: swallowed however long it waits")
        view.notePointerLeft()
        view.press(at: point)
        view.release(at: point)
        #expect(h.actions.calls == [.result(preview.id, Self.id)])
    }

    @Test func peekIsOpaqueBesideTheTagAwayFromTheStrip() throws {
        let h = TagHarness()
        h.start()
        h.desk([tagSession(Self.id, state: .working)])
        h.click(Self.id)
        let peek = try #require(h.controller.peek)
        let tagFrame = try #require(h.tag(Self.id)?.shownFrame)
        let frame = try #require(h.windowing.lastShow(peek.panel)?.frame)
        #expect(frame.width == 360)
        #expect(frame.maxX == tagFrame.minX - 8, "left of the tag: the strip is on the right")
        #expect(frame.maxY == tagFrame.maxY, "level with the tag's top")
    }

    @Test func voiceOverPressesActLikeClicks() throws {
        let h = TagHarness()
        h.start()
        let offer = tileOffer("make")
        h.desk([tagSession(Self.id, offers: [offer])])
        let view = try #require(h.panel(Self.id)?.view)
        #expect(view.accessibilityLabels == ["Pitbox for “Weather app · forecast refactor”: ▶ Review…"])
        let element = try #require(view.accessibilityChildren()?.first as? DeskTagAccessiblePill)
        #expect(element.accessibilityPerformPress())
        #expect(h.actions.calls.count == 1)
    }

    @Test func clicksOnTheGapsAreNotPartOfTheTag() throws {
        let h = TagHarness()
        h.start()
        h.desk([tagSession(Self.id, state: .working, warnings: [TagContentTests.stuck], dashboard: Self.dashboard)])
        let view = try #require(h.panel(Self.id)?.view)
        #expect(view.pillRects.count == 2)
        let gap = CGPoint(x: view.bounds.maxX - 4, y: view.pillRects[0].maxY + 2)
        #expect(view.pillIndex(at: gap) == nil)
        let narrowPill = view.pillRects.min { $0.width < $1.width } ?? .zero
        let beside = CGPoint(x: narrowPill.minX - 3, y: narrowPill.midY)
        #expect(view.pillIndex(at: beside) == nil, "left of the narrower pill is not the tag")
        #expect(view.pillIndex(at: CGPoint(x: view.pillRects[0].midX, y: view.pillRects[0].midY)) == 0)
    }
}
