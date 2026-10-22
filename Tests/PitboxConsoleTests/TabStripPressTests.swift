import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// Close, "+" and the auto-rotate indicator are buttons: like standard macOS buttons they look pressed while the button is
/// down, act on mouse-up over themselves, and do nothing when the press is dragged off them first. A tab selects and the
/// chevron opens its menu on mouse-down, as macOS tab bars and pop-up buttons do.
@MainActor
struct TabStripPressTests {
    private func point(in rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// The point on the close button of a tab (its centre is 16 pt from the tab's right edge).
    private func closePoint(_ tab: CGRect) -> CGPoint { CGPoint(x: tab.maxX - 16, y: tab.midY) }

    @Test func closePlusAndAutoRotateActOnMouseUpAndAPressDraggedOffIsCancelled() throws {
        let h = TabStripSnapshotTests.console(count: 2, selected: 1, light: false, rotate: true)
        let strip = h.view.strip
        let away = CGPoint(x: strip.bounds.midX, y: strip.bounds.maxY + 40)   // dragged off the strip before letting go
        let targets: [(String, CGPoint)] = [("close", closePoint(strip.tabFrames[1].frame)), ("+", point(in: strip.newFrame)),
                                            ("auto-rotate", point(in: strip.rotateFrame))]
        for (name, point) in targets {
            let before = (h.manager.sessions.map(\.id), h.manager.autoRotate)
            strip.mouseDown(with: try stripMouseEvent(h, .leftMouseDown, at: point))
            #expect(h.manager.sessions.map(\.id) == before.0 && h.manager.autoRotate == before.1, "\(name): nothing happens while the button is down")
            #expect(strip.pressedTarget == strip.hit(at: point) && strip.pressedInside, "\(name) looks pressed")
            strip.mouseDragged(with: try stripMouseEvent(h, .leftMouseDragged, at: away))
            #expect(!strip.pressedInside, "\(name): dragged off, it no longer looks pressed")
            strip.mouseUp(with: try stripMouseEvent(h, .leftMouseUp, at: away))
            #expect(h.manager.sessions.map(\.id) == before.0 && h.manager.autoRotate == before.1, "\(name): released outside, so cancelled")
            #expect(strip.pressedTarget == nil)
        }
    }

    @Test func aClickReleasedOnTheCloseButtonCloses() throws {
        let h = TabStripSnapshotTests.console(count: 2, selected: 1, light: false)
        let strip = h.view.strip
        let tab = strip.tabFrames[1]
        try clickStrip(h, at: closePoint(tab.frame))
        #expect(h.manager.sessions.count == 1 && !h.manager.sessions.contains { $0.id == tab.id })
    }

    @Test func plusAndAutoRotateActWhenReleasedOverThemEvenAfterADragOffAndBack() throws {
        let h = TabStripSnapshotTests.console(count: 2, selected: 0, light: false, rotate: true)
        let strip = h.view.strip
        let plus = point(in: strip.newFrame)
        strip.mouseDown(with: try stripMouseEvent(h, .leftMouseDown, at: plus))
        strip.mouseDragged(with: try stripMouseEvent(h, .leftMouseDragged, at: CGPoint(x: plus.x, y: 200)))
        strip.mouseDragged(with: try stripMouseEvent(h, .leftMouseDragged, at: CGPoint(x: plus.x + 3, y: plus.y)))
        #expect(strip.pressedInside, "back over the button: pressed again")
        strip.mouseUp(with: try stripMouseEvent(h, .leftMouseUp, at: CGPoint(x: plus.x + 3, y: plus.y)))
        #expect(h.manager.sessions.count == 3 && h.keyboardRequests == [true], "released over +: a new tab, which takes the keyboard")
        try clickStrip(h, at: point(in: strip.rotateFrame))
        #expect(!h.manager.autoRotate && !strip.autoRotateOn)
    }

    @Test func aHiddenTabsCloseButtonThatIsPressedStaysUntilTheRelease() throws {
        let h = TabStripSnapshotTests.console(count: 3, selected: 0, light: false)
        let strip = h.view.strip
        let target = strip.tabFrames[2]
        strip.setHover(id: target.id, button: nil, close: true)   // the pointer is on it, so its close button shows
        let point = closePoint(target.frame)
        strip.mouseDown(with: try stripMouseEvent(h, .leftMouseDown, at: point))
        strip.setHover(id: nil, button: nil)   // AppKit reported the pointer leaving the tab during the drag
        #expect(strip.hit(at: point) == .close(target.id), "the pressed close button stays where it was")
        strip.mouseUp(with: try stripMouseEvent(h, .leftMouseUp, at: point))
        #expect(!h.manager.sessions.contains { $0.id == target.id })
    }

    @Test func theKillConfirmationStillTakesTwoDeliberateClicks() throws {
        let h = TabStripSnapshotTests.console(count: 3, selected: 1, light: false)
        h.processes[1].runJob(named: "vim")
        h.manager.pollMetadata()
        let strip = h.view.strip
        let tab = strip.tabFrames[1]
        let point = closePoint(tab.frame)
        strip.mouseDown(with: try stripMouseEvent(h, .leftMouseDown, at: point))
        #expect(h.manager.closeConfirmationID == nil, "nothing is asked while the button is down")
        strip.mouseUp(with: try stripMouseEvent(h, .leftMouseUp, at: point))
        #expect(h.manager.closeConfirmationID == tab.id && strip.items[1].confirmingClose && h.processes[1].terminateCount == 0)
        try clickStrip(h, at: point)
        #expect(h.manager.sessions.count == 2 && h.processes[1].terminateCount == 1, "the second click ends the program")
    }

    /// The pressed look is really painted: the close circle, the "+" half of the split button and the indicator each
    /// change while pressed, and go back when the press is dragged off.
    @Test(arguments: [false, true])
    func aPressedButtonLooksPressed(light: Bool) throws {
        let h = TabStripSnapshotTests.console(count: 2, selected: 1, light: light, rotate: true)
        let strip = h.view.strip
        let tab = strip.tabFrames[1].frame
        // Fill-only points (no glyph strokes) inside each control.
        let samples: [(String, CGPoint, CGPoint)] = [
            ("close", closePoint(tab), CGPoint(x: tab.maxX - 22, y: tab.midY)),
            ("+", point(in: strip.newFrame), CGPoint(x: strip.newFrame.minX + 6, y: strip.newFrame.midY)),
            ("auto-rotate", point(in: strip.rotateFrame), CGPoint(x: strip.rotateFrame.minX + 3, y: strip.rotateFrame.midY)),
        ]
        func pixel(_ at: CGPoint) throws -> NSColor {
            let rep = try #require(renderBitmap(of: h.view, over: (light, h.view.bounds.size)))
            return rep.colorAt(x: Int(at.x), y: Int(at.y))?.usingColorSpace(.sRGB) ?? .clear
        }
        for (name, target, sample) in samples {
            let normal = try pixel(sample)
            strip.mouseDown(with: try stripMouseEvent(h, .leftMouseDown, at: target))
            let pressed = try pixel(sample)
            strip.mouseDragged(with: try stripMouseEvent(h, .leftMouseDragged, at: CGPoint(x: target.x, y: 300)))
            let draggedOff = try pixel(sample)
            strip.mouseUp(with: try stripMouseEvent(h, .leftMouseUp, at: CGPoint(x: target.x, y: 300)))
            #expect(TerminalTheme.contrast(pressed, normal) >= 1.15,
                    "\(light ? "light" : "dark") \(name): pressed \(TerminalTheme.hexString(pressed)) vs \(TerminalTheme.hexString(normal))")
            #expect(TerminalTheme.contrast(draggedOff, normal) < 1.02, "\(name): dragged off, it looks as before")
        }
    }

    @Test(arguments: [true, false])
    func glyphsKeepTheirContrastOnThePressedFills(dark: Bool) {
        let palette = TerminalTheme.palette(isDark: dark)
        let style = TabStripStyle(palette: palette)
        for glass in dark ? [0.05, 0.2, 0.4] : [0.6, 0.8, 0.95] {
            let tint = TerminalTheme.composite(palette.tint(opacity: 0.65), over: NSColor(white: CGFloat(glass), alpha: 1))
            let band = TerminalTheme.composite(style.band, over: tint)
            // "+" (a graphic: 3:1) on the pressed half of the split button.
            let button = TerminalTheme.composite(style.buttonFill, over: band)
            let pressedButton = TerminalTheme.composite(style.buttonPressedFill, over: button)
            let glyph = TerminalTheme.composite(style.glyph, over: pressedButton)
            #expect(TerminalTheme.contrast(glyph, pressedButton) >= 3, "+ pressed over glass \(glass): \(TerminalTheme.contrast(glyph, pressedButton))")
            // The auto-rotate indicator is opaque, like its other states.
            #expect(TerminalTheme.contrast(style.toggleGlyph, style.togglePressedFill) >= 4.5)
            #expect(TerminalTheme.contrast(style.togglePressedFill, band) >= 1.5)
            // The close button's X on its pressed circle, on every tab that can show one (selected, hovered, "Kill?").
            for state in [TabStripStyle.TabState.active, .hovered, .warning] {
                let colors = style.colors(for: state)
                let fill = TerminalTheme.composite(colors.fill, over: band)
                let circle = TerminalTheme.composite(colors.title.withAlphaComponent(TabStripStyle.closePressedAlpha), over: fill)
                let x = TerminalTheme.composite(colors.title, over: circle)
                #expect(TerminalTheme.contrast(x, circle) >= 3, "\(state) close pressed over glass \(glass): \(TerminalTheme.contrast(x, circle))")
            }
        }
    }
}

/// A double-click on the auto-rotate indicator: the first click turns auto-rotate off, the indicator disappears and the
/// tabs widen into its place. The second click must not land on the tab (or its close button) that is now there.
@MainActor
struct AutoRotateDoubleClickTests {
    @Test func aDoubleClickOnTheIndicatorDoesNotCloseTheSelectedTab() throws {
        let h = TabStripSnapshotTests.console(count: 3, selected: 2, light: false, rotate: true)
        let strip = h.view.strip
        let point = CGPoint(x: strip.rotateFrame.midX, y: strip.rotateFrame.midY)
        #expect(strip.hit(at: point) == .autoRotate)
        let ids = h.manager.sessions.map(\.id)
        try clickStrip(h, at: point, count: 1)
        try clickStrip(h, at: point, count: 2)
        #expect(!h.manager.autoRotate)
        #expect(h.manager.sessions.map(\.id) == ids && h.manager.selectedIndex == 2, "the second click hit \(String(describing: strip.hit(at: point)))")
    }

    /// Like the app, the strip knows where the pointer is: the tab that slid under it is hovered and shows its close button.
    @Test(arguments: [3, 4, 5, 6])
    func aDoubleClickOnTheIndicatorClosesNoTab(count: Int) throws {
        let h = TabStripSnapshotTests.console(count: count, selected: 0, light: false, rotate: true)
        let strip = h.view.strip
        let point = CGPoint(x: strip.rotateFrame.midX, y: strip.rotateFrame.midY)
        strip.pointerLocation = { point }
        let ids = h.manager.sessions.map(\.id)
        try clickStrip(h, at: point, count: 1)
        try clickStrip(h, at: point, count: 2)
        try clickStrip(h, at: point, count: 3)
        #expect(!h.manager.autoRotate)
        #expect(h.manager.sessions.map(\.id) == ids && h.manager.selectedIndex == 0, "\(count) tabs")
        try clickStrip(h, at: point, count: 1)
        #expect(h.manager.sessions.count == count - 1, "a separate click acts on what is there now")
    }
}
