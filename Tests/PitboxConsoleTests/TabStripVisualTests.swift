import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// The design details of the strip that are easy to lose: indicator contrast (3:1 or better, WCAG 1.4.11), controls that
/// keep their contrast when hovered, parts on whole points (crisp on the 1x display), and titles that stay on one line
/// whichever tab is selected.
@MainActor
struct TabStripVisualTests {
    /// What the glass behind the tint can look like: dark appearance over dark wallpapers, light over light ones.
    private func glassLevels(dark: Bool) -> [Double] { dark ? [0.05, 0.2, 0.4] : [0.6, 0.8, 0.95] }

    private func band(_ style: TabStripStyle, _ palette: TerminalPalette, glass: Double) -> NSColor {
        let tint = TerminalTheme.composite(palette.tint(opacity: 0.65), over: NSColor(white: CGFloat(glass), alpha: 1))
        return TerminalTheme.composite(style.band, over: tint)
    }

    // MARK: Contrast

    @Test(arguments: [true, false])
    func statusDotsStandOutFromTheRingAroundThem(dark: Bool) throws {
        let style = TabStripStyle(palette: TerminalTheme.palette(isDark: dark))
        for status in [TabStatus.running, .activity, .attention, .failed, .exited] {
            let dot = try #require(style.dotColor(for: status))
            #expect(TerminalTheme.contrast(dot, style.halo) >= 3, "\(dark ? "dark" : "light") \(status) dot: \(TerminalTheme.contrast(dot, style.halo))")
        }
        #expect(style.dotColor(for: .none) == nil)
        // The same fixed status colors, whatever the drawing appearance.
        let expected = dark ? ["#30D158", "#FF453A"] : ["#248A3D", "#D70015"]
        #expect([TabStatus.running, .failed].map { TerminalTheme.hexString(style.dotColor(for: $0) ?? .clear) } == expected)
    }

    @Test(arguments: [true, false])
    func controlsKeepTheirContrastWhenHovered(dark: Bool) {
        let palette = TerminalTheme.palette(isDark: dark)
        let style = TabStripStyle(palette: palette)
        for glass in glassLevels(dark: dark) {
            let band = band(style, palette, glass: glass)
            let button = TerminalTheme.composite(style.buttonFill, over: band)
            let hovered = TerminalTheme.composite(style.buttonHoverFill, over: button)
            // Glyphs are graphics: 3:1 (the accent glyph the hover used to switch to measured 1.9:1 on light glass).
            for fill in [button, hovered] {
                let glyph = TerminalTheme.composite(style.glyph, over: fill)
                #expect(TerminalTheme.contrast(glyph, fill) >= 3, "+ and chevron over glass \(glass): \(TerminalTheme.contrast(glyph, fill))")
            }
            // The auto-rotate indicator is opaque: its glyph is as readable over any glass, hovered or not.
            for fill in [style.toggleFill, style.toggleHoverFill] {
                #expect(TerminalTheme.contrast(style.toggleGlyph, fill) >= 4.5, "auto-rotate glyph: \(TerminalTheme.contrast(style.toggleGlyph, fill))")
                #expect(TerminalTheme.contrast(fill, band) >= 1.5, "and the indicator stands out from the strip")
            }
        }
    }

    // MARK: Geometry

    @Test func thePartsOfATabSitOnWholePoints() {
        func isWhole(_ rect: CGRect) -> Bool {
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0 == $0.rounded() }
        }
        for width in [40, 41, 56, 71, 72, 116, 177, 180] as [CGFloat] {
            let tab = CGRect(x: 37, y: TabStripView.pillTop, width: width, height: TabStripView.pillHeight)
            for digits in [1, 2] {
                let compact = TabLayout.isCompact(width)
                let badge = TabStripView.badgeFrame(in: tab, digits: digits, compact: compact)
                let dot = TabStripView.dotFrame(on: badge)
                #expect(isWhole(badge) && isWhole(dot), "\(width) pt, \(digits) digit(s): badge \(badge), dot \(dot)")
                #expect(tab.contains(badge), "the badge is inside its tab")
                #expect(dot.minY - TabStripView.dotHalo >= 0 && dot.maxX + TabStripView.dotHalo <= tab.maxX + 1, "the dot and its ring stay in the strip")
            }
            let bar = TabStripView.underlineFrame(in: tab)
            let badge = TabStripView.badgeFrame(in: tab, digits: 1, compact: false)
            #expect(isWhole(bar) && bar.minY >= badge.maxY + 1 && bar.maxY <= tab.maxY - 1, "the accent bar sits on the bottom edge, below the badge: \(bar)")
        }
    }

    /// The console's corners can be rounded up to 48 pt; the strip then moves its tabs and buttons in, so the corners
    /// never cut into the first tab or the chevron. The default console keeps the 8 pt margins.
    @Test(arguments: [0, 18, 32, 48] as [CGFloat])
    func roundConsoleCornersNeverCutIntoTheFirstTabOrTheChevron(radius: CGFloat) throws {
        #expect(TabStripView.sideInset(consoleCornerRadius: 18) == 8)
        let h = TabStripSnapshotTests.console(count: 3, selected: 0, light: false)
        let console = h.console.makeConsoleView(cornerRadius: radius)
        h.window.contentView = console
        console.frame = CGRect(x: 0, y: 0, width: 618, height: 78)
        console.layoutSubtreeIfNeeded()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 618, pixelsHigh: 78, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        console.cacheDisplay(in: console.bounds, to: rep)
        let strip = console.strip
        let (first, menu) = (strip.tabFrames[0].frame, strip.menuFrame)
        // The outermost pixel of each rounded corner (45 degrees round its arc) is painted, not masked away.
        let d = ((TabStripView.cornerRadius - 0.5) * (1 - 1 / CGFloat(2).squareRoot())).rounded(.down)
        for point in [CGPoint(x: first.minX + d, y: first.minY + d), CGPoint(x: menu.maxX - 1 - d, y: menu.minY + d)] {
            let alpha = rep.colorAt(x: Int(point.x), y: Int(point.y))?.alphaComponent ?? 0
            #expect(alpha > 0.6, "corner radius \(radius): the console's corner cuts into the strip at \(point) (alpha \(alpha))")
        }
    }

    /// Very round console corners must not cut off the terminal's corner cells either (a block cursor or box drawing in the
    /// bottom row): the padding grows from about 29 pt on. Before, 32 pt already cut into the bottom-left cell.
    @Test(arguments: [0, 18, 30, 32, 40, 48] as [CGFloat])
    func roundConsoleCornersNeverCutIntoTheTerminalsCornerCells(radius: CGFloat) throws {
        let h = ConsoleHarness(settingsJSON: #"{"allowSnapshots": true}"#)
        let console = h.console.makeConsoleView(cornerRadius: radius)
        h.window.contentView = console
        console.frame = CGRect(x: 0, y: 0, width: 618, height: 636)
        console.layoutSubtreeIfNeeded()
        let view = try #require(console.manager.selectedSession?.view)
        let (cols, rows) = (view.terminal.cols, view.terminal.rows)
        // Full blocks in the first and the last cell of the bottom row.
        h.processes[0].emit(String(repeating: "\r\n", count: rows) + "\u{2588}" + String(repeating: " ", count: cols - 2) + "\u{2588}")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 618, pixelsHigh: 636, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        console.cacheDisplay(in: console.bounds, to: rep)
        // The rows fill the view from the top (the default console fits 37 rows exactly; a leftover goes below the last row).
        let frame = view.convert(view.bounds, to: console)   // the console is flipped
        let cell = view.cellSize
        let bottom = frame.minY + CGFloat(rows) * cell.height - 1
        let corners = [CGPoint(x: frame.minX, y: bottom), CGPoint(x: frame.minX + CGFloat(cols) * cell.width - 1, y: bottom)]
        for point in corners {
            let alpha = rep.colorAt(x: Int(point.x), y: Int(point.y))?.alphaComponent ?? 0
            #expect(alpha > 0.9, "corner radius \(radius): the console's corner cuts the bottom row's corner cell at \(point) (alpha \(alpha))")
        }
        let padding = ConsoleView.terminalPadding(consoleCornerRadius: radius)
        #expect(radius > 28 || (padding.side == ConsoleView.sidePadding && padding.bottom == ConsoleView.bottomPadding),
                "up to 28 pt the terminal keeps its 10 and 8 pt padding (72x37 in the default console)")
    }

    // MARK: Rendered pixels (1x, like the real display)

    private func pixel(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor {
        rep.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) ?? .clear
    }

    /// The first row, from the top of `tab`, where title ink shows in the title area.
    private func firstInkRow(_ rep: NSBitmapImageRep, tab: CGRect) -> Int? {
        let fill = pixel(rep, tab.midX + 20, tab.minY + 3)
        let left = TabStripView.badgeFrame(in: tab, digits: 1, compact: false).maxX + 7
        for y in Int(tab.minY) + 2..<Int(tab.maxY) - 3 {
            for x in Int(left)..<Int(left) + 40 where TerminalTheme.contrast(pixel(rep, CGFloat(x), CGFloat(y)), fill) > 2 { return y }
        }
        return nil
    }

    @Test(arguments: [false, true])
    func titlesStayOnOneLineWhicheverTabIsSelected(light: Bool) throws {
        // Tabs 2 and 3 show the same folder; tab 2 is selected.
        let h = TabStripSnapshotTests.console(count: 3, selected: 1, light: light) { h in
            h.processes[1].changeDirectory("/Users/tester/Folder")
            h.processes[2].changeDirectory("/Users/tester/Folder")
            h.manager.pollMetadata()
        }
        let rep = try #require(renderBitmap(of: h.view, over: (light, h.view.bounds.size)))
        let strip = h.view.strip
        let selected = try #require(firstInkRow(rep, tab: strip.tabFrames[1].frame))
        let other = try #require(firstInkRow(rep, tab: strip.tabFrames[2].frame))
        #expect(selected == other, "\(light ? "light" : "dark"): the selected title starts on row \(selected), the other on \(other)")
    }

    @Test(arguments: [false, true])
    func theAccentBarAndTheDotsAreCrispOnTheOneXDisplay(light: Bool) throws {
        let h = TabStripSnapshotTests.console(count: 3, selected: 1, light: light) { h in
            h.processes[2].runJob(named: "npm")
            h.manager.pollMetadata()
        }
        let rep = try #require(renderBitmap(of: h.view, over: (light, h.view.bounds.size)))
        let strip = h.view.strip
        let style = strip.style
        let contrast = { (a: NSColor, b: NSColor) in TerminalTheme.contrast(a, b) }
        // The bar: whole rows of accent, and the row above it is the tab's fill (no half-covered row).
        let active = strip.tabFrames[1].frame
        let bar = TabStripView.underlineFrame(in: active)
        let fill = pixel(rep, active.midX + 20, active.minY + 3)
        for y in [bar.minY, bar.maxY - 1] {
            #expect(contrast(pixel(rep, active.midX, y), style.accent) < 1.1, "accent bar row \(y): \(TerminalTheme.hexString(pixel(rep, active.midX, y)))")
        }
        #expect(contrast(pixel(rep, active.midX, bar.minY - 1), fill) < 1.05, "the row above the bar is plain fill")
        // The running dot of tab 3: its top row is (nearly) all dot, not a half-covered row.
        let other = strip.tabFrames[2].frame
        let dot = TabStripView.dotFrame(on: TabStripView.badgeFrame(in: other, digits: 1, compact: false))
        let green = try #require(style.dotColor(for: .running))
        #expect(contrast(pixel(rep, dot.midX, dot.midY), green) < 1.05)
        #expect(contrast(pixel(rep, dot.midX, dot.minY), green) < 1.3, "top row of the dot: \(TerminalTheme.hexString(pixel(rep, dot.midX, dot.minY)))")
    }
}
