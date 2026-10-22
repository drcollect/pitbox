import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// The tab strip as a whole: size, numbers and shortcuts, status dots, tooltips, many tabs (compress, then scroll), narrow
/// consoles, hover, and what the rendered strip looks like (the active tab must stand out, in dark and light).
@MainActor
struct TabStripTests {
    private func console(count: Int, selected: Int = 0, width: CGFloat = 618, light: Bool = false, onExit: String = "closeIfClean",
                      decorate: (ConsoleHarness) -> Void = { _ in }) -> ConsoleHarness {
        TabStripSnapshotTests.console(count: count, selected: selected, width: width, light: light, onExit: onExit, decorate: decorate)
    }

    // MARK: Size

    @Test func theStripIsTallerAndTheTitlesAreLarger() {
        #expect(TabStripView.height == 34 && TabStripView.pillHeight >= 24)
        #expect(TabStripView.titleSize == 13)
        let h = ConsoleHarness(size: CGSize(width: 618, height: 636))
        #expect(h.view.strip.frame.height == 34 && h.view.strip.intrinsicContentSize.height == 34)
    }

    @Test func theTerminalKeepsItsRowsDespiteTheTallerStrip() throws {
        let h = ConsoleHarness(size: CGSize(width: 618, height: 636))
        let size = h.launcher.sizes[0]
        #expect(size.cols == 72 && size.rows == 37, "a 2x8 console (618 x 636 pt) is still 72x37 (SF Mono 13): \(size)")
        let view = try #require(h.selectedView)
        #expect(view.frame.height == 636 - TabStripView.height - ConsoleView.bottomPadding - ConsoleView.topGap
                && TabStripView.height + ConsoleView.bottomPadding + ConsoleView.topGap == 44,
                "the strip's 2 extra points come out of the padding, not out of the terminal")
    }

    // MARK: Numbers, shortcuts, status

    @Test func tabsAreNumberedAndTheShortcutsMatch() {
        #expect((0..<3).map { TabNumbering.shortcutDigit(index: $0, count: 3) } == [1, 2, 3])
        #expect(TabNumbering.shortcutDigit(index: 7, count: 12) == 8, "Cmd-8 is the eighth tab")
        #expect(TabNumbering.shortcutDigit(index: 8, count: 12) == nil && TabNumbering.shortcutDigit(index: 10, count: 12) == nil)
        #expect(TabNumbering.shortcutDigit(index: 11, count: 12) == 9, "Cmd-9 is the last tab")
        #expect(TabNumbering.shortcutDigit(index: 8, count: 9) == 9)
        #expect(TabNumbering.badge(index: 0) == 1 && TabNumbering.badge(index: 19) == 20)
        // The table the shortcuts really use agrees.
        #expect(TerminalShortcuts.match(KeyInput(keyCode: 0, characters: "2", command: true)) == .selectSession(1))
        #expect(TerminalShortcuts.match(KeyInput(keyCode: 0, characters: "9", command: true)) == .selectLastSession)
    }

    @Test func tooltipsNameTheShortcutOfEachTab() {
        let h = console(count: 12, selected: 0)
        let strip = h.view.strip
        #expect(strip.toolTip(forTag: 1).contains("\u{2318}1"))
        #expect(strip.toolTip(forTag: 2).contains("my project"), "the tab's own tooltip (its title and folder) comes first")
        #expect(strip.toolTip(forTag: 2).contains("Select: \u{2318}2"))
        #expect(!strip.toolTip(forTag: 10).contains("Select:"), "tabs 9 to 11 have no digit shortcut")
        #expect(strip.toolTip(forTag: 12).contains("\u{2318}9 (last tab)"))
        #expect(strip.toolTip(forTag: 99) == "", "an unknown tag is empty, never a crash")
    }

    @Test func thePlusButtonsTooltipListsTheShortcuts() {
        let h = console(count: 2)
        let strip = h.view.strip
        let text = strip.toolTip(forTag: 100_001)
        for expected in ["\u{2318}T", "\u{2318}W", "\u{2318}1", "\u{2318}9", "\u{2303}Tab", "\u{2318}\u{21E7}]", "\u{2318}\u{2325}\u{2192}", "\u{2318}\u{238B}"] {
            #expect(text.contains(expected), "the tooltip mentions \(expected)")
        }
        #expect(strip.toolTip(forTag: 100_002).contains("preset"))
        strip.canCreate = false
        #expect(strip.toolTip(forTag: 100_001).contains("limit"), "at the tab limit the tooltip says why")
    }

    @Test func statusDotsFollowWhatTheSessionsDo() throws {
        let h = console(count: 6, selected: 0, onExit: "keep") { h in
            h.processes[1].runJob(named: "htop")
            h.processes[2].emit("output\r\n")
            h.processes[3].emit("\u{7}")
            h.processes[4].end(.exited(1))
            h.processes[5].end(.exited(0))
            h.manager.pollMetadata()
        }
        let status = h.view.strip.items.map(TabStatus.init)
        #expect(status == [.none, .running, .activity, .attention, .failed, .exited])
        #expect(h.view.strip.items[1].isBusy && !h.view.strip.items[0].isBusy)
        #expect(h.view.strip.items[4].exitFailed && !h.view.strip.items[5].exitFailed)
        for tab in status where tab != .none { #expect(tab.summary != nil) }
        // Selecting the busy tab keeps its running dot; the activity dot of a tab goes away once it is seen.
        h.manager.select(index: 2)
        #expect(TabStatus(h.view.strip.items[2]) == .none)
        h.manager.select(index: 1)
        #expect(TabStatus(h.view.strip.items[1]) == .running)
        // The most urgent state wins.
        let item = TabStripView.Item(id: UUID(), title: "x", isSelected: false, hasActivity: true, needsAttention: true, hasExited: true,
                                     confirmingClose: false, tooltip: "", isBusy: true, exitFailed: true)
        #expect(TabStatus(item) == .attention)
        // VoiceOver hears the state and the position.
        let strip = h.view.strip
        strip.layoutSubtreeIfNeeded()
        let children = try #require(strip.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children[1].accessibilityHelp()?.contains("Tab 2 of 6") == true && children[1].accessibilityHelp()?.contains("Running a program") == true)
    }

    // MARK: Many tabs

    @Test(arguments: [(1, 618), (3, 618), (8, 618), (20, 618), (1, 303), (3, 303), (8, 303), (20, 303), (8, 1248), (20, 1248)] as [(Int, Int)])
    func manyTabsCompressOrScrollWithoutBreaking(count: Int, width: Int) {
        for selected in [0, count / 2, count - 1] {
            let h = console(count: count, selected: selected, width: CGFloat(width))
            let strip = h.view.strip
            #expect(strip.tabFrames.count == count)
            #expect(strip.newFrame.minX >= strip.viewport.maxX && strip.menuFrame.maxX <= strip.bounds.width, "the controls stay put on the right")
            let frame = strip.tabFrames[selected].frame
            #expect(strip.viewport.insetBy(dx: -0.5, dy: 0).contains(frame), "\(count) tabs at \(width) pt: the selected tab \(selected) is in view: \(frame) in \(strip.viewport)")
            #expect(frame.width >= min(TabLayout.selectedMinWidth, strip.viewport.width), "and readable")
            #expect(strip.tabFrames.allSatisfy { $0.frame.width >= TabLayout.minWidth && $0.frame.minY >= 0 && $0.frame.maxY <= TabStripView.height })
            let widths = strip.tabFrames.map(\.frame.width)
            if !strip.isOverflowing {
                #expect(TabLayout.contentWidth(of: widths) <= strip.viewport.width + 0.5)
                #expect(strip.tabFrames.allSatisfy { strip.viewport.insetBy(dx: -0.5, dy: 0).contains($0.frame) })
            } else {
                #expect(widths.enumerated().allSatisfy { $0.offset == selected || $0.element == TabLayout.minWidth }, "overflowing tabs are as narrow as they get")
            }
            // Titles, dots and numbers never make the strip lay out differently from its accessibility view.
            #expect(strip.accessibilityChildren()?.count == count + 2)
        }
    }

    /// Pins the known threshold of the default 2-column console (viewport 540 pt): up to 6 tabs keep their titles, from 7 on
    /// every tab but the selected one shows only its number. Changing it is a design decision (`selectedMinWidth`,
    /// `compactBelow`).
    @Test func fromSevenTabsTheOthersAreNumberOnlyAtTheDefaultWidth() {
        #expect(console(count: 1).view.strip.viewport.width == 540)
        #expect(!TabLayout.widths(count: 6, selectedIndex: 0, available: 540).dropFirst().contains(where: TabLayout.isCompact))
        #expect(TabLayout.widths(count: 7, selectedIndex: 0, available: 540).dropFirst().allSatisfy(TabLayout.isCompact))
    }

    @Test func twentyTabsScrollAndKeepTheSelectedTabInView() {
        let h = console(count: 20, selected: 0)
        let strip = h.view.strip
        #expect(strip.isOverflowing && strip.scrollOffset == 0)
        h.manager.select(index: 19)
        #expect(strip.scrollOffset > 0 && strip.viewport.contains(strip.tabFrames[19].frame), "selecting the last tab scrolls it into view")
        #expect(abs(strip.scrollOffset - (strip.contentWidth - strip.viewport.width)) < 1, "as far as the content goes")
        h.manager.select(index: 10)
        #expect(strip.viewport.contains(strip.tabFrames[10].frame))
        h.manager.selectNext()
        #expect(strip.viewport.contains(strip.tabFrames[11].frame), "rotating with the keyboard follows the selection")
        // Scrolling by hand is clamped, and a title refresh does not undo it.
        strip.scroll(by: -10_000)
        #expect(strip.scrollOffset == 0)
        strip.scroll(by: 10_000)
        #expect(abs(strip.scrollOffset - (strip.contentWidth - strip.viewport.width)) < 1)
        strip.scroll(by: -10_000)
        h.processes[3].changeDirectory("/tmp")
        h.manager.pollMetadata()
        #expect(strip.scrollOffset == 0, "a scroll by hand stays while the selection has not changed")
        // Tabs that are scrolled out of the viewport take no clicks; the ones in it do.
        strip.scroll(by: 300)
        let clipped = strip.tabFrames.first { $0.frame.minX < strip.viewport.minX && $0.frame.maxX > strip.viewport.minX + 6 }
        if let clipped {
            #expect(strip.hit(at: CGPoint(x: strip.viewport.minX - 3, y: clipped.frame.midY)) == nil, "the margin left of the viewport is not a tab")
            #expect(strip.hit(at: CGPoint(x: strip.viewport.minX + 3, y: clipped.frame.midY)) == .tab(clipped.id))
        }
        #expect(strip.tabFrames.filter { strip.viewport.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }.count >= 8)
    }

    @Test func aMouseWheelScrollsOverflowingTabsSideways() throws {
        let h = console(count: 20, selected: 0)
        let strip = h.view.strip
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -3, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cg))
        strip.scrollWheel(with: event)
        #expect(strip.scrollOffset > 0, "a vertical mouse wheel scrolls the tabs sideways")
        let before = strip.scrollOffset
        let few = console(count: 2)
        few.view.strip.scrollWheel(with: event)
        #expect(few.view.strip.scrollOffset == 0 && before > 0, "tabs that fit do not scroll, and the wheel goes to whatever is behind")
    }

    @Test func narrowTabsShowOnlyTheirNumberAndNoCloseButton() throws {
        let h = console(count: 8, selected: 3)
        let strip = h.view.strip
        let narrow = try #require(strip.tabFrames.first { TabLayout.isCompact($0.frame.width) })
        strip.setHover(id: narrow.id, button: nil)
        #expect(strip.hit(at: CGPoint(x: narrow.frame.maxX - 13, y: narrow.frame.midY)) == .tab(narrow.id), "no close button on a number-only tab, even hovered")
        let selected = strip.tabFrames[3]
        #expect(!TabLayout.isCompact(selected.frame.width))
        #expect(strip.hit(at: CGPoint(x: selected.frame.maxX - 13, y: selected.frame.midY)) == .close(selected.id), "the selected tab always has one")
    }

    @Test func everyRoomyTabHasItsCloseButtonTrackedForHover() {
        let h = console(count: 3, selected: 0)
        let strip = h.view.strip
        strip.updateTrackingAreas()
        let closeAreas = strip.trackingAreas.filter { ($0.userInfo as? [String: String])?["close"] != nil }
        #expect(closeAreas.count == 3, "one hover area per close button")
        #expect(strip.trackingAreas.allSatisfy { !$0.options.contains(.mouseMoved) })
        strip.setHover(id: strip.items[1].id, button: nil, close: true)
        #expect(strip.hoverCloseID == strip.items[1].id && strip.hoverID == strip.items[1].id)
        strip.setHover(id: strip.items[1].id, button: nil, close: false)
        #expect(strip.hoverCloseID == nil && strip.hoverID != nil)
    }

    @Test func closingATabWhileHoveringItDropsTheHover() {
        let h = console(count: 3, selected: 0)
        let strip = h.view.strip
        let gone = strip.items[2].id
        strip.setHover(id: gone, button: nil, close: true)
        h.manager.closeNow(gone)
        #expect(strip.hoverID == nil && strip.hoverCloseID == nil)
    }

    // MARK: Colors

    /// What the glass behind the tint can look like: dark appearance over dark wallpapers, light over light ones.
    private func glassLevels(dark: Bool) -> [Double] { dark ? [0.05, 0.2, 0.4] : [0.6, 0.8, 0.95] }

    @Test(arguments: [true, false])
    func titlesAndNumbersAreReadableInEveryStateOverAnyGlass(dark: Bool) {
        let palette = TerminalTheme.palette(isDark: dark)
        let style = TabStripStyle(palette: palette)
        for gray in glassLevels(dark: dark) {
            let glass = NSColor(white: CGFloat(gray), alpha: 1)
            let tint = TerminalTheme.composite(palette.tint(opacity: 0.65), over: glass)
            let band = TerminalTheme.composite(style.band, over: tint)
            for state in [TabStripStyle.TabState.inactive, .hovered, .active, .warning] {
                let colors = style.colors(for: state)
                let fill = TerminalTheme.composite(colors.fill, over: band)
                let title = TerminalTheme.composite(colors.title, over: fill)
                #expect(TerminalTheme.contrast(title, fill) >= 4.5, "\(dark ? "dark" : "light") \(state) title over glass \(gray): \(TerminalTheme.contrast(title, fill))")
                let badge = TerminalTheme.composite(colors.badgeFill, over: fill)
                let digits = TerminalTheme.composite(colors.badgeText, over: badge)
                #expect(TerminalTheme.contrast(digits, badge) >= 4.5, "\(dark ? "dark" : "light") \(state) number over glass \(gray): \(TerminalTheme.contrast(digits, badge))")
            }
        }
    }

    @Test(arguments: [true, false])
    func theActiveTabStandsOutFromTheOthersInColorAndOutline(dark: Bool) {
        let palette = TerminalTheme.palette(isDark: dark)
        let style = TabStripStyle(palette: palette)
        for gray in glassLevels(dark: dark) {
            let tint = TerminalTheme.composite(palette.tint(opacity: 0.65), over: NSColor(white: CGFloat(gray), alpha: 1))
            let band = TerminalTheme.composite(style.band, over: tint)
            let active = TerminalTheme.composite(style.active.fill, over: band)
            let inactive = TerminalTheme.composite(style.inactive.fill, over: band)
            let hovered = TerminalTheme.composite(style.hovered.fill, over: band)
            let activeContrast = TerminalTheme.contrast(active, band)
            let inactiveContrast = TerminalTheme.contrast(inactive, band)
            #expect(activeContrast >= 1.25 && activeContrast > inactiveContrast, "active \(activeContrast) vs inactive \(inactiveContrast) at glass \(gray)")
            #expect(TerminalTheme.contrast(hovered, band) > inactiveContrast, "hover is a visible step")
            // Every tab has an outline that separates it from the strip, and the active one is the accent color.
            let outline = TerminalTheme.composite(style.inactive.outline, over: band)
            #expect(TerminalTheme.contrast(outline, band) >= 1.7, "an inactive tab has a visible outline: \(TerminalTheme.contrast(outline, band))")
            let accent = TerminalTheme.composite(style.active.outline, over: active)
            #expect(TerminalTheme.contrast(accent, active) >= 2.0, "the active outline is a strong accent: \(TerminalTheme.contrast(accent, active))")
        }
        #expect(style.active.badgeFill == palette.accent && style.accent == palette.accent, "the accent is the palette's, like the focus ring")
    }

    @Test func theStripFollowsTheConsolesAppearance() {
        let h = console(count: 2, light: false)
        #expect(h.view.strip.palette.isDark)
        h.view.appearance = NSAppearance(named: .aqua)
        #expect(!h.view.strip.palette.isDark && h.view.strip.style.isDark == false, "switching to the light appearance recolors the strip")
    }

    // MARK: Pictures

    /// The color of the rendered pixel at a point in the strip (top-left origin).
    private func pixel(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor {
        rep.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) ?? .clear
    }

    @Test(arguments: [false, true])
    func theRenderedActiveTabIsUnmistakableAndInactiveTabsAreVisibleTabs(light: Bool) throws {
        let h = console(count: 3, selected: 1, light: light) { h in
            h.view.strip.setHover(id: h.view.strip.items[2].id, button: nil)
        }
        let rep = try #require(renderBitmap(of: h.view, over: (light, h.view.bounds.size)))
        let strip = h.view.strip
        let (first, active, hovered) = (strip.tabFrames[0].frame, strip.tabFrames[1].frame, strip.tabFrames[2].frame)
        let band = pixel(rep, first.maxX + 2, 17)   // between two tabs
        let inactiveFill = pixel(rep, first.midX + 20, first.minY + 3)
        let activeFill = pixel(rep, active.midX + 20, active.minY + 3)
        let hoveredFill = pixel(rep, hovered.midX + 20, hovered.minY + 3)
        let contrast = { (a: NSColor, b: NSColor) in TerminalTheme.contrast(a, b) }
        #expect(contrast(activeFill, band) > contrast(inactiveFill, band) && contrast(activeFill, band) >= 1.25,
                "\(light ? "light" : "dark"): active \(contrast(activeFill, band)) vs inactive \(contrast(inactiveFill, band)) against the strip")
        #expect(contrast(inactiveFill, band) >= 1.03, "an inactive tab has its own fill: \(contrast(inactiveFill, band))")
        #expect(contrast(hoveredFill, band) > contrast(inactiveFill, band), "hover is a visible step")
        // The accent underline of the active tab is really painted in the accent color; the inactive tab has none.
        let accent = TerminalTheme.palette(isDark: !light).accent.usingColorSpace(.sRGB) ?? .black
        let underline = pixel(rep, active.midX, active.maxY - 2.5)
        #expect(abs(underline.redComponent - accent.redComponent) < 0.04 && abs(underline.blueComponent - accent.blueComponent) < 0.04
                && abs(underline.greenComponent - accent.greenComponent) < 0.04, "accent underline: \(TerminalTheme.hexString(underline)) vs \(TerminalTheme.hexString(accent))")
        #expect(contrast(pixel(rep, first.midX, first.maxY - 2.5), accent) > 1.5, "no underline under an inactive tab")
        // The outline of an inactive tab is darker (light) or lighter (dark) than its fill and than the strip.
        let outline = pixel(rep, first.midX + 20, first.minY + 0.5)
        #expect(contrast(outline, inactiveFill) >= 1.2, "the inactive tab's outline shows: \(contrast(outline, inactiveFill))")
    }
}
