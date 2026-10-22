import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// Draws several views one above the other on the gradient that stands in for the block's glass, each with a small
/// label, and writes a PNG. `scale` 2 renders a Retina picture (twice the pixels for the same points).
@MainActor
func renderStack(_ rows: [(label: String, view: NSView)], light: Bool, scale: CGFloat = 1, to url: URL) -> Bool {
    let gap: CGFloat = 8, labelHeight: CGFloat = 14
    let width = (rows.map(\.view.bounds.width).max() ?? 0).rounded(.up)
    let height = rows.reduce(gap) { $0 + $1.view.bounds.height + labelHeight + gap }.rounded(.up)
    guard width > 0, height > 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return false }
    rep.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let colors = light
        ? [NSColor(srgbRed: 0.72, green: 0.80, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.98, green: 0.85, blue: 0.78, alpha: 1)]
        : [NSColor(srgbRed: 0.10, green: 0.22, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.42, green: 0.16, blue: 0.36, alpha: 1)]
    NSGradient(colors: colors)?.draw(in: CGRect(x: 0, y: 0, width: width, height: height), angle: 315)
    var top = gap   // from the top edge of the picture
    for (label, view) in rows {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let viewRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        viewRep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: viewRep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(viewRep)
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                              .foregroundColor: NSColor(white: light ? 0.1 : 0.95, alpha: 0.85)]
        label.draw(at: CGPoint(x: 6, y: height - top - labelHeight + 1), withAttributes: labelAttributes)
        top += labelHeight
        image.draw(in: CGRect(x: 0, y: height - top - view.bounds.height, width: view.bounds.width, height: view.bounds.height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        top += view.bounds.height + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: url)) != nil
}

/// Renders the tab strip in every situation that matters (dark and light, 1 to 20 tabs, hover, status dots, narrow consoles) so
/// people can look at it: `PITBOX_TEST_OUT=<dir> scripts/test.sh PitboxConsole --filter TabStripSnapshotTests`. The
/// counts and states galleries are also written at 2x (`-2x.png`), where small misalignments are easier to see.
@MainActor
struct TabStripSnapshotTests {
    static let folders = ["my project", "Downloads", "proj", "tmp", "docs", "a-very-long-folder-name-for-a-project", "src", "Desktop",
                          "notes", "build", "widgets", "logs", "scripts", "assets", "tests", "Music", "bin", "web", "data", "old"]

    /// A console with `count` tabs (the `selected` one showing), its strip and a sliver of terminal.
    static func console(count: Int, selected: Int, width: CGFloat = 618, light: Bool, rotate: Bool = false, onExit: String = "closeIfClean",
                     decorate: (ConsoleHarness) -> Void = { _ in }) -> ConsoleHarness {
        let h = ConsoleHarness(settingsJSON: presetJSON(onExit: onExit, more: "\"maxSessions\": 24, \"autoRotate\": \(rotate),"),
                            size: CGSize(width: width, height: 78))
        h.view.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        for _ in 1..<max(1, count) { _ = h.manager.newSession() }
        for (index, process) in h.processes.enumerated() {
            process.changeDirectory(index == 0 ? "/Users/tester" : "/Users/tester/\(folders[(index - 1) % folders.count])")
        }
        h.manager.pollMetadata()
        h.manager.select(index: min(selected, count - 1))
        h.processes[min(selected, count - 1)].emit("\u{1b}[1;32malex@mac\u{1b}[0m:\u{1b}[1;34m~\u{1b}[0m$ ls\r\n")
        decorate(h)
        h.view.layoutSubtreeIfNeeded()
        h.view.strip.needsDisplay = true
        return h
    }

    static func render(light: Bool, name: String, scale: CGFloat = 1, rows: [(String, ConsoleHarness)]) -> URL {
        let url = artifactDirectory().appendingPathComponent(name)
        #expect(renderStack(rows.map { ($0.0, $0.1.view) }, light: light, scale: scale, to: url), "rendering \(name) failed")
        return url
    }

    /// 1, 3, 8 and 20 tabs at the default 2-column width (618 pt) and at 1 column (303 pt).
    private func counts(light: Bool) {
        let theme = light ? "light" : "dark"
        var rows: [(String, ConsoleHarness)] = []
        for (count, selected) in [(1, 0), (3, 1), (8, 3), (20, 12)] {
            rows.append(("\(theme) \(count) tab(s), 618 pt", Self.console(count: count, selected: selected, light: light)))
        }
        _ = Self.render(light: light, name: "tabs-\(theme)-counts.png", rows: rows)
        _ = Self.render(light: light, name: "tabs-\(theme)-counts-2x.png", scale: 2, rows: rows)
        var narrow: [(String, ConsoleHarness)] = []
        for (count, selected) in [(1, 0), (3, 1), (8, 3), (20, 12)] {
            narrow.append(("\(theme) \(count) tab(s), 303 pt", Self.console(count: count, selected: selected, width: 303, light: light)))
        }
        _ = Self.render(light: light, name: "tabs-\(theme)-narrow.png", rows: narrow)
        var wide: [(String, ConsoleHarness)] = []
        for (count, selected) in [(1, 0), (5, 2), (12, 4)] {
            wide.append(("\(theme) \(count) tab(s), 1248 pt (4 columns)", Self.console(count: count, selected: selected, width: 1248, light: light)))
        }
        _ = Self.render(light: light, name: "tabs-\(theme)-wide.png", rows: wide)
    }

    /// Hover on a tab, on its close button, on "+", on the chevron; the dots; "Kill?"; auto-rotate; scrolled.
    private func states(light: Bool) {
        let theme = light ? "light" : "dark"
        var rows: [(String, ConsoleHarness)] = []
        rows.append(("hover on tab 3", Self.console(count: 4, selected: 0, light: light) { h in
            h.view.strip.setHover(id: h.view.strip.items[2].id, button: nil)
        }))
        rows.append(("hover on the close button of tab 3", Self.console(count: 4, selected: 0, light: light) { h in
            h.view.strip.setHover(id: h.view.strip.items[2].id, button: nil, close: true)
        }))
        rows.append(("hover on +", Self.console(count: 3, selected: 1, light: light) { h in h.view.strip.setHover(id: nil, button: .newSession) }))
        rows.append(("hover on the chevron", Self.console(count: 3, selected: 1, light: light) { h in h.view.strip.setHover(id: nil, button: .presetMenu) }))
        rows.append(("dots: running (2), output (3), bell (4), failed (5), ended (6)", Self.console(count: 6, selected: 0, light: light, onExit: "keep") { h in
            h.processes[1].runJob(named: "htop")
            h.processes[2].emit("output\r\n")
            h.processes[3].emit("\u{7}")
            h.processes[4].end(.exited(1))
            h.processes[5].end(.exited(0))
            h.manager.pollMetadata()
        }))
        rows.append(("selected tab running a program, kill? on tab 2", Self.console(count: 3, selected: 0, light: light, rotate: true) { h in
            h.processes[0].runJob(named: "vim")
            h.processes[1].runJob(named: "claude")
            h.manager.pollMetadata()
            _ = h.manager.requestClose(h.manager.sessions[1].id)
        }))
        rows.append(("20 tabs: tab 13 was selected, then tab 20 (scrolled to the end)", Self.console(count: 20, selected: 12, light: light) { h in
            h.manager.select(index: 19)
        }))
        // The buttons while the mouse button is down on them (they act on mouse-up).
        func press(_ h: ConsoleHarness, _ point: CGPoint) {
            if let event = try? stripMouseEvent(h, .leftMouseDown, at: point) { h.view.strip.mouseDown(with: event) }
        }
        rows.append(("pressed: the close button of the hovered tab 3", Self.console(count: 3, selected: 0, light: light) { h in
            let tab = h.view.strip.tabFrames[2].frame
            h.view.strip.setHover(id: h.view.strip.items[2].id, button: nil, close: true)
            press(h, CGPoint(x: tab.maxX - 16, y: tab.midY))
        }))
        rows.append(("pressed: +", Self.console(count: 3, selected: 1, light: light, rotate: true) { h in
            press(h, CGPoint(x: h.view.strip.newFrame.midX, y: h.view.strip.newFrame.midY))
        }))
        rows.append(("pressed: the auto-rotate indicator", Self.console(count: 3, selected: 1, light: light, rotate: true) { h in
            press(h, CGPoint(x: h.view.strip.rotateFrame.midX, y: h.view.strip.rotateFrame.midY))
        }))
        _ = Self.render(light: light, name: "tabs-\(theme)-states.png", rows: rows)
        _ = Self.render(light: light, name: "tabs-\(theme)-states-2x.png", scale: 2, rows: rows)
    }

    @Test func darkGalleries() { counts(light: false); states(light: false) }
    @Test func lightGalleries() { counts(light: true); states(light: true) }
}
