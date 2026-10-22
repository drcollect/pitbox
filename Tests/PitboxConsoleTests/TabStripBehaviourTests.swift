import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// Behaviour of the redesigned strip that the pictures cannot show: hit targets, middle and Control clicks, hover when tabs
/// move under a still pointer, keeping the selected tab in view in narrow strips and after a close, the status dot of a
/// background tab that failed, readable ended tabs, and what VoiceOver gets.
@MainActor
struct TabStripBehaviourTests {
    private func console(count: Int, selected: Int = 0, width: CGFloat = 618, rotate: Bool = false, onExit: String = "closeIfClean",
                      decorate: (ConsoleHarness) -> Void = { _ in }) -> ConsoleHarness {
        TabStripSnapshotTests.console(count: count, selected: selected, width: width, light: false, rotate: rotate, onExit: onExit,
                                   decorate: decorate)
    }

    private func inView(_ strip: TabStripView, _ index: Int) -> Bool {
        strip.viewport.insetBy(dx: -0.5, dy: 0).contains(strip.tabFrames[index].frame)
    }

    // MARK: Hit targets

    @Test func everyControlTakesClicksOnAtLeast24By24Points() throws {
        let h = console(count: 3, selected: 0, rotate: true)
        let strip = h.view.strip
        for rect in [strip.newHitFrame, strip.menuHitFrame, strip.rotateHitFrame] {
            #expect(rect.width >= 24 && rect.height >= 24, "\(rect)")
        }
        // The hit areas are real: the edges of each one answer with its control.
        let menu = strip.menuHitFrame, rotate = strip.rotateHitFrame
        #expect(strip.hit(at: CGPoint(x: menu.maxX - 0.5, y: strip.bounds.midY)) == .presetMenu, "the chevron's area runs to the right edge")
        #expect(strip.hit(at: CGPoint(x: menu.minX + 0.5, y: 1)) == .presetMenu)
        #expect(strip.hit(at: CGPoint(x: rotate.minX + 0.5, y: rotate.midY)) == .autoRotate)
        #expect(strip.hit(at: CGPoint(x: rotate.maxX - 0.5, y: rotate.midY)) == .autoRotate)
        #expect(!strip.rotateHitFrame.intersects(strip.viewport) && !strip.rotateHitFrame.intersects(strip.newHitFrame),
                "the bigger areas overlap neither the tabs nor the + button")
        // A tab is 26 pt tall and at least 40 wide; its close button takes clicks on 24 x 24 pt.
        let selected = strip.tabFrames[0].frame
        #expect(selected.height >= 24 && strip.tabFrames.allSatisfy { $0.frame.width >= 24 })
        let closeCenter = CGPoint(x: selected.maxX - 16, y: selected.midY)
        for dx in [-11.5, 11.5] as [CGFloat] {
            #expect(strip.hit(at: CGPoint(x: closeCenter.x + dx, y: closeCenter.y)) == .close(strip.items[0].id), "close at dx \(dx)")
        }
        for dy in [-11.5, 11.5] as [CGFloat] {
            #expect(strip.hit(at: CGPoint(x: closeCenter.x, y: closeCenter.y + dy)) == .close(strip.items[0].id), "close at dy \(dy)")
        }
    }

    // MARK: Middle click, Control click

    @Test func aMiddleClickOnAHoveredTabsCloseButtonClosesTheTab() throws {
        let h = console(count: 3, selected: 0)
        let strip = h.view.strip
        let target = strip.tabFrames[2]
        strip.setHover(id: target.id, button: nil)   // the pointer is on it, so its close button shows
        let point = CGPoint(x: target.frame.maxX - 16, y: target.frame.midY)
        #expect(strip.hit(at: point) == .close(target.id))
        #expect(strip.middleClickTarget(at: point) == target.id)
        // Through the real event path (a center-button up event built from a Quartz event).
        let base = try #require(NSEvent.mouseEvent(with: .otherMouseUp, location: strip.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                   windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let cg = try #require(base.cgEvent)
        cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        let event = try #require(NSEvent(cgEvent: cg))
        #expect(event.buttonNumber == 2)
        strip.otherMouseUp(with: event)
        #expect(!h.manager.sessions.contains { $0.id == target.id }, "a middle click on the close button closes the tab, like anywhere else on it")
        #expect(strip.middleClickTarget(at: CGPoint(x: strip.newFrame.midX, y: strip.newFrame.midY)) == nil, "not on +")
    }

    @Test func aControlClickOpensTheMenuAndNeverSelectsOrCloses() throws {
        let h = console(count: 3, selected: 0)
        let strip = h.view.strip
        let other = strip.tabFrames[1]
        let menu = try #require(strip.contextMenu(for: .close(other.id)))
        #expect(menu.items.map(\.title).contains("Close Tab"), "the tab's own menu, also on its close button")
        #expect(strip.contextMenu(for: .newSession)?.items.contains { $0.title == "Auto-rotate Tabs" } == true)
        #expect(strip.contextMenu(for: .newSession)?.items.contains { $0.title == "Edit Presets…" } == false)
        #expect(strip.contextMenu(for: nil) == nil && strip.contextMenu(for: .autoRotate) == nil)

        // With no menu to show (so no menu pops up in the test), a Control-click on a tab or a close button does nothing.
        strip.tabMenuProvider = nil
        strip.setHover(id: other.id, button: nil)
        for point in [CGPoint(x: other.frame.minX + 20, y: other.frame.midY), CGPoint(x: other.frame.maxX - 16, y: other.frame.midY)] {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: strip.convert(point, to: nil), modifierFlags: .control,
                                                        timestamp: 0, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            #expect(TabStripView.isContextClick(event))
            strip.mouseDown(with: event)
        }
        #expect(h.manager.sessions.count == 3 && h.manager.selectedIndex == 0, "Control-click is a right click: no select, no close")
        let plain = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: strip.convert(CGPoint(x: other.frame.minX + 20, y: other.frame.midY), to: nil),
                                                    modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!TabStripView.isContextClick(plain))
        strip.mouseDown(with: plain)
        #expect(h.manager.selectedIndex == 1, "a plain click still selects")
    }

    // MARK: Hover

    /// "+" and the chevron touch: moving from one to the other can deliver the chevron's enter before the exit of "+".
    @Test func leavingPlusAfterEnteringTheChevronKeepsTheChevronHighlighted() throws {
        let h = console(count: 2)
        let strip = h.view.strip
        strip.updateTrackingAreas()
        func area(_ name: String) throws -> NSTrackingArea {
            try #require(strip.trackingAreas.first { ($0.userInfo as? [String: String])?["button"] == name })
        }
        func exit(_ area: NSTrackingArea) throws -> NSEvent {
            try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
                                                context: nil, eventNumber: 0, trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil))
        }
        let plusArea = try area("new")
        let plusExit = try exit(plusArea)
        #expect(plusExit.trackingArea === plusArea)
        strip.setHover(id: nil, button: .presetMenu)   // entered the chevron
        strip.mouseExited(with: plusExit)              // then left "+"
        #expect(strip.hoverButton == .presetMenu, "the exit of + does not clear the chevron's hover")
        strip.mouseExited(with: try exit(try area("menu")))
        #expect(strip.hoverButton == nil, "leaving the chevron does")
    }

    @Test func theTabThatSlidesUnderAStillPointerShowsItsHoverAndItsCloseButton() throws {
        let h = console(count: 5, selected: 0, width: 1248)   // roomy: every tab is as wide as a tab gets, before and after a close
        let strip = h.view.strip
        #expect(Set(strip.tabFrames.map(\.frame.width)) == [TabLayout.maxWidth])
        let hovered = strip.tabFrames[1]
        let pointer = CGPoint(x: hovered.frame.maxX - 16, y: hovered.frame.midY)   // on tab 2's close button
        strip.pointerLocation = { pointer }
        strip.setHover(id: hovered.id, button: nil, close: true)
        #expect(strip.hit(at: pointer) == .close(hovered.id))
        strip.activate(strip.hit(at: pointer), at: pointer)   // click: closes tab 2, tab 3 slides under the pointer
        let next = try #require(strip.tabFrames.first { $0.frame.contains(pointer) })
        #expect(next.id != hovered.id && strip.hoverID == next.id && strip.hoverCloseID == next.id,
                "the tab now under the pointer is hovered, on its close button")
        #expect(strip.hit(at: pointer) == .close(next.id), "so a second click at the same place closes the next tab, as in a browser")
        // A pointer outside the strip clears the hover when tabs change; an unknown one leaves it alone.
        strip.pointerLocation = { CGPoint(x: 10, y: 500) }
        _ = h.manager.newSession()
        #expect(strip.hoverID == nil && strip.hoverButton == nil)
        strip.pointerLocation = { nil }
        strip.setHover(id: nil, button: .newSession)
        _ = h.manager.newSession()
        #expect(strip.hoverButton == .newSession)
    }

    @Test func turningAutoRotateOffUnderThePointerDropsItsHover() {
        let h = console(count: 3, rotate: true)
        let strip = h.view.strip
        let pointer = CGPoint(x: strip.rotateFrame.midX, y: strip.rotateFrame.midY)
        strip.pointerLocation = { pointer }
        strip.setHover(id: nil, button: .autoRotate)
        strip.activate(.autoRotate, at: pointer)
        #expect(!h.manager.autoRotate && !strip.autoRotateOn)
        #expect(strip.hoverButton != .autoRotate, "the indicator is gone; what is under the pointer now is what is hovered")
    }

    // MARK: Keeping the selected tab in view

    @Test(arguments: [(200, false), (230, true), (250, true), (303, true)] as [(Int, Bool)])
    func inANarrowStripTheSelectedTabIsWhollyInView(width: Int, rotate: Bool) {
        let h = console(count: 8, selected: 7, width: CGFloat(width), rotate: rotate)
        let strip = h.view.strip
        #expect(inView(strip, 7))
        for index in [2, 6, 0, 7, 3] {   // left, right, the ends, back
            h.manager.select(index: index)
            #expect(inView(strip, index), "\(width) pt, auto-rotate \(rotate): tab \(index + 1) at \(strip.tabFrames[index].frame) in \(strip.viewport)")
        }
    }

    @Test func revealingATabShrinksTheMarginsBeforeItCutsTheTab() {
        // Room for the tab and full margins: 28 pt of the neighbours stay in view.
        #expect(TabLayout.offset(revealing: CGRect(x: 300, y: 0, width: 116, height: 26), current: 0, content: 1000, viewport: 400) == 44)
        #expect(TabLayout.offset(revealing: CGRect(x: 300, y: 0, width: 116, height: 26), current: 500, content: 1000, viewport: 400) == 272)
        // A viewport of 130: margins of 7 each, the tab is whole in both directions.
        let right = TabLayout.offset(revealing: CGRect(x: 300, y: 0, width: 116, height: 26), current: 0, content: 1000, viewport: 130)
        #expect(right <= 300 && right + 130 >= 416, "\(right)")
        let left = TabLayout.offset(revealing: CGRect(x: 300, y: 0, width: 116, height: 26), current: 600, content: 1000, viewport: 130)
        #expect(left <= 300 && left + 130 >= 416, "\(left)")
        // Wider than the viewport: its start (number and title) shows.
        #expect(TabLayout.offset(revealing: CGRect(x: 300, y: 0, width: 116, height: 26), current: 0, content: 1000, viewport: 90) == 300)
    }

    @Test func closingATabBeforeTheSelectedOneKeepsTheSelectedTabInView() {
        let h = console(count: 20, selected: 0)
        let strip = h.view.strip
        h.manager.select(index: 19)
        h.manager.select(index: 5)   // scrolled back: tab 6 sits near the left edge
        #expect(strip.scrollOffset > 0 && inView(strip, 5))
        h.manager.closeNow(h.manager.sessions[4].id)   // middle click or the menu on tab 5
        let selected = h.manager.selectedIndex ?? -1
        #expect(selected == 4 && inView(strip, selected), "the selected tab moved left by one tab and is brought back: \(strip.tabFrames[selected].frame)")
        // A title refresh still leaves a scroll by hand alone.
        strip.scroll(by: 200)
        let scrolled = strip.scrollOffset
        h.processes[2].changeDirectory("/tmp")
        h.manager.pollMetadata()
        #expect(strip.scrollOffset == scrolled)
    }

    /// Tiny or empty strips (a console squeezed by a narrow block, the first layout at zero width, no tabs yet) lay
    /// out, hit test, draw and describe themselves without crashing, and tabs never sit under the controls.
    @Test func tinyAndEmptyStripsStayWellBehaved() throws {
        for width in [0, 1, 50, 100, 150, 200] as [CGFloat] {
            for count in [1, 3, 24] {
                let h = console(count: count, selected: count - 1, rotate: count == 3)
                h.layout(CGSize(width: width, height: 78))   // squeezed after the shells started
                let strip = h.view.strip
                #expect(strip.tabFrames.count == count && strip.viewport.width >= 0)
                for entry in strip.tabFrames {
                    let visible = entry.frame.intersection(strip.viewport)
                    #expect(visible.isNull || visible.width <= 0 || !visible.intersects(strip.newHitFrame.union(strip.menuHitFrame)))
                }
                for x in stride(from: 0, through: max(0, width), by: 7) { _ = strip.hit(at: CGPoint(x: x, y: 17)) }
                #expect(strip.accessibilityChildren()?.count == count + 2 + (count == 3 ? 1 : 0))
                if width > 0 { #expect(renderBitmap(of: h.view, over: (false, h.view.bounds.size)) != nil) }
            }
        }
        let empty = TabStripView(frame: CGRect(x: 0, y: 0, width: 300, height: TabStripView.height))
        empty.pointerLocation = { nil }
        empty.layoutSubtreeIfNeeded()
        #expect(empty.tabFrames.isEmpty && !empty.isOverflowing && empty.hit(at: CGPoint(x: 20, y: 17)) == nil)
        #expect(empty.accessibilityChildren()?.count == 2)
        let rep = try #require(empty.bitmapImageRepForCachingDisplay(in: empty.bounds))
        empty.cacheDisplay(in: empty.bounds, to: rep)
    }

    // MARK: Status and readability

    @Test func aProgramThatFailsInABackgroundTabShowsTheRedDotEvenAfterPrinting() {
        let h = console(count: 3, selected: 0, onExit: "closeIfClean") { h in
            h.processes[1].emit("error: build failed\r\n")
            h.processes[1].end(.exited(1))
            h.processes[2].emit("done\r\n")   // output alone: the accent dot
        }
        let status = h.view.strip.items.map(TabStatus.init)
        #expect(status == [.none, .failed, .activity], "\(status)")
        #expect(h.view.strip.toolTip(forTag: 2).contains("ended with an error"))
        // The bell still comes first.
        let item = TabStripView.Item(id: UUID(), title: "x", isSelected: false, hasActivity: true, needsAttention: true, hasExited: true,
                                     confirmingClose: false, tooltip: "", isBusy: false, exitFailed: true)
        #expect(TabStatus(item) == .attention)
        var clean = item
        clean.needsAttention = false
        clean.exitFailed = false
        #expect(TabStatus(clean) == .activity, "unseen output outranks a clean end")
    }

    @Test(arguments: [true, false])
    func theDimmedTitleOfAnEndedTabIsStillReadable(dark: Bool) {
        let palette = TerminalTheme.palette(isDark: dark)
        let style = TabStripStyle(palette: palette)
        for gray in dark ? [0.05, 0.2, 0.4] : [0.6, 0.8, 0.95] {
            let tint = TerminalTheme.composite(palette.tint(opacity: 0.65), over: NSColor(white: CGFloat(gray), alpha: 1))
            let band = TerminalTheme.composite(style.band, over: tint)
            for state in [TabStripStyle.TabState.inactive, .hovered] {
                let colors = style.colors(for: state)
                let fill = TerminalTheme.composite(colors.fill, over: band)
                let title = TerminalTheme.composite(colors.title.withAlphaComponent(style.exitedTitleAlpha), over: fill)
                let ratio = TerminalTheme.contrast(title, fill)
                #expect(ratio >= 4.5, "\(dark ? "dark" : "light") \(state) ended title over glass \(gray): \(ratio)")
            }
        }
    }

    // MARK: VoiceOver

    @Test func voiceOverGetsAnEnabledTabGroupWithCloseActions() throws {
        let h = console(count: 3, selected: 0, rotate: true) { h in
            h.processes[2].runJob(named: "vim")
            h.manager.pollMetadata()
            _ = h.manager.requestClose(h.manager.sessions[2].id)
        }
        let strip = h.view.strip
        #expect(strip.isAccessibilityElement() && strip.accessibilityRole() == .tabGroup && strip.accessibilityLabel() == "Terminal tabs",
                "the strip is a tab group VoiceOver can see (a plain view's role and label are ignored)")
        #expect(h.view.isAccessibilityElement() && h.view.accessibilityRole() == .group)
        let children = try #require(strip.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children.count == 3 + 3, "three tabs, New Tab, Presets and the auto-rotate indicator")
        for tab in children.prefix(3) {
            #expect(tab.isAccessibilityEnabled(), "not read as dimmed")
            #expect(tab.accessibilityRole() == .radioButton && tab.accessibilitySubrole() == TabStripView.tabButtonSubrole)
        }
        #expect(children.suffix(3).allSatisfy { $0.isAccessibilityEnabled() })
        #expect(children[5].accessibilityLabel() == "Auto-rotate Is On")
        // The tab asking for confirmation says so.
        #expect(children[2].accessibilityLabel()?.contains("Kill?") == true && children[2].accessibilityHelp()?.contains("3 seconds") == true)
        #expect(children[1].accessibilityLabel()?.contains("Kill?") == false)
        // Any tab can be closed without the mouse: its "Close Tab" action.
        let close = try #require(children[1].accessibilityCustomActions()?.first { $0.name == "Close Tab" })
        #expect(close.handler?() == true)
        #expect(h.manager.sessions.count == 2, "the idle shell in tab 2 closed")
        // At the tab limit New Tab is disabled, and it comes back when a tab closes.
        let full = ConsoleHarness(settingsJSON: #"{"maxSessions": 2}"#)
        _ = full.manager.newSession()
        full.view.strip.layoutSubtreeIfNeeded()
        var elements = try #require(full.view.strip.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(elements[2].accessibilityLabel() == "New Tab" && !elements[2].isAccessibilityEnabled())
        full.manager.closeNow(full.manager.sessions[1].id)
        elements = try #require(full.view.strip.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(elements[1].accessibilityLabel() == "New Tab" && elements[1].isAccessibilityEnabled())
        // Pressing the auto-rotate indicator turns it off.
        #expect(children[5].accessibilityPerformPress())
        #expect(!h.manager.autoRotate)
    }

    /// The strip lays out again on every title refresh and every scroll step. The VoiceOver cursor sits on an element
    /// object: it must stay the same object, with fresh contents.
    @Test func voiceOverElementsSurviveTitleRefreshesAndScrolling() throws {
        let h = console(count: 20, selected: 0)
        let strip = h.view.strip
        let before = try #require(strip.accessibilityChildren() as? [NSAccessibilityElement])
        h.processes[1].changeDirectory("/private/var")
        h.manager.pollMetadata()
        strip.scroll(by: 120)
        let after = try #require(strip.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(before.count == after.count && zip(before, after).allSatisfy { $0 === $1 }, "the same elements")
        #expect(after[1].accessibilityLabel() == "var", "with the new title")
        #expect(after[1].accessibilityFrameInParentSpace() == strip.tabFrames[1].frame, "and the scrolled frame")
        // A closed tab's element goes; the others stay.
        let closing = h.manager.sessions[3].id
        h.manager.closeNow(closing)
        let rest = try #require(strip.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(rest.count == before.count - 1 && !rest.contains { $0 === before[3] } && rest[4] === before[5])
        #expect(rest[0].accessibilityHelp()?.hasPrefix("Tab 1 of 19") == true)
    }
}
