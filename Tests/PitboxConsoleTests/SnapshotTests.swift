import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// Renders the console off-screen and writes PNGs for people to look at (`PITBOX_TEST_OUT=<dir>` picks the folder).
@MainActor
struct SnapshotTests {
    static func demoScreen() -> String {
        let esc = "\u{1b}"
        var s = ""
        s += "\(esc)[1;32malex@mac\(esc)[0m:\(esc)[1;34m~/my project\(esc)[0m$ ls -la --color\r\n"
        s += "\(esc)[1;34mPackages\(esc)[0m  \(esc)[1;34mdocs\(esc)[0m  \(esc)[0;32mrun.sh\(esc)[0m  \(esc)[0;36mhelper\(esc)[0m  README.md\r\n"
        s += "ANSI: "
        for i in 0..<8 { s += "\(esc)[4\(i)m  \(esc)[0m" }
        s += " "
        for i in 0..<8 { s += "\(esc)[10\(i)m  \(esc)[0m" }
        s += "\r\nText: "
        for i in [1, 2, 3, 4, 5, 6, 7] { s += "\(esc)[3\(i)mcolor\(i)\(esc)[0m " }
        s += "\r\nBrt:  "
        for i in [1, 2, 3, 4, 5, 6, 7] { s += "\(esc)[9\(i)mcolor\(i)\(esc)[0m " }
        s += "\r\nTrue: "
        for i in 0..<48 { s += "\(esc)[48;2;\(min(255, i * 5));\(max(0, 255 - i * 5));\(128 + (i % 8) * 15)m \(esc)[0m" }
        s += "\r\n256:  "
        for i in stride(from: 16, to: 232, by: 6) { s += "\(esc)[48;5;\(i)m \(esc)[0m" }
        s += "\r\nStyle: \(esc)[1mbold\(esc)[0m \(esc)[2mdim\(esc)[0m \(esc)[3mitalic\(esc)[0m \(esc)[4munder\(esc)[0m \(esc)[9mstrike\(esc)[0m \(esc)[7minverse\(esc)[0m\r\n"
        s += "Wide: 日本語 한국어 🙂🎉 👩‍💻 Ünïcödé ✓ ✗ → ▶ ★\r\n"
        s += "Box:  ┌─┬─┐ ░▒▓█ │ ├─┼─┤ └─┴─┘ \(esc)[7m NORMAL \(esc)[0m\r\n"
        s += "Link: https://example.com/docs?a=1 and src/main.swift:12:5\r\n"
        s += "\(esc)[1;32malex@mac\(esc)[0m:\(esc)[1;34m~/my project\(esc)[0m$ "
        return s
    }

    private func render(light: Bool, name: String) throws -> URL {
        let h = ConsoleHarness(settingsJSON: presetJSON(more: "\"allowSnapshots\": true,"), size: CGSize(width: 618, height: 636))
        h.view.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        _ = h.manager.newSession(); _ = h.manager.newSession()
        h.manager.select(index: 0)
        h.processes[0].changeDirectory("/Users/tester/my project")
        h.processes[1].runJob(named: "htop")
        h.processes[2].info = ForegroundInfo(pgid: h.processes[2].pid, name: "claude", isSessionLeader: false, cwd: "/Users/tester/proj")
        h.manager.pollMetadata()
        h.processes[1].emit("background output\r\n")
        h.processes[2].end(.exited(1))
        h.processes[0].emit(Self.demoScreen())
        h.view.layoutSubtreeIfNeeded()
        let url = artifactDirectory().appendingPathComponent(name)
        #expect(renderPNG(of: h.view, over: (light, h.view.bounds.size), to: url), "rendering failed")
        return url
    }

    @Test func darkConsoleRendersTextColorsAndTabs() throws {
        let url = try render(light: false, name: "terminal-dark.png")
        try assertLooksRendered(url, expectLightBackground: false)
    }

    @Test func lightConsoleRendersTextColorsAndTabs() throws {
        let url = try render(light: true, name: "terminal-light.png")
        try assertLooksRendered(url, expectLightBackground: true)
    }

    /// Not blank: the tint is there, and there are pixels of several distinct colors (text and color blocks).
    private func assertLooksRendered(_ url: URL, expectLightBackground: Bool) throws {
        let data = try Data(contentsOf: url)
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == 618 && rep.pixelsHigh == 636)
        var colors = Set<UInt32>()
        var luminance = 0.0
        var samples = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt32(c.redComponent * 255) >> 3, g = UInt32(c.greenComponent * 255) >> 3, b = UInt32(c.blueComponent * 255) >> 3
                colors.insert(r << 10 | g << 5 | b)
                luminance += TerminalTheme.luminance(c)
                samples += 1
            }
        }
        #expect(colors.count > 60, "many distinct colors: \(colors.count)")
        let mean = luminance / Double(samples)
        #expect(expectLightBackground ? mean > 0.3 : mean < 0.3, "mean luminance \(mean)")
    }
}


/// Anything that renders the console with `cacheDisplay` (a screenshot helper, a PDF export) gets a notice in place of
/// the terminal's contents: a terminal can show secrets. Only the console's settings (`allowSnapshots`) lift it.
@MainActor
struct SnapshotRedactionTests {
    private func terminalRegionColors(_ h: ConsoleHarness, skipNoticeBand: Bool) throws -> Set<UInt32> {
        let view = h.view
        h.selectedView.map { _ in }
        h.processes[0].emit("\u{1b}[31mSECRET-TOKEN-ABC123\u{1b}[0m\r\nsecond line of secrets\r\n")
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var colors = Set<UInt32>()
        let top = Int(TabStripView.height) + 4
        for y in top..<(rep.pixelsHigh - 22) {   // the view's rounded corners are not part of the comparison
            if skipNoticeBand, abs(y - (top + (rep.pixelsHigh - top) / 2)) < 14 { continue }
            for x in 22..<(rep.pixelsWide - 22) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        return colors
    }

    @Test func snapshotsDoNotShowTheTerminalByDefault() throws {
        let h = ConsoleHarness(size: CGSize(width: 618, height: 636))
        let colors = try terminalRegionColors(h, skipNoticeBand: true)
        #expect(colors.count <= 3, "outside the notice line the terminal area is one flat color, not the terminal: \(colors.count) colors")
    }

    @Test func aRedactedSnapshotLeavesFocusAndTheViewTreeAlone() throws {
        let h = ConsoleHarness(size: CGSize(width: 618, height: 636))
        h.makeKey()
        h.view.focusTerminal()
        let subviewsBefore = h.view.subviews.count
        let responderBefore = h.window.firstResponder
        _ = try terminalRegionColors(h, skipNoticeBand: true)
        #expect(h.view.subviews.count == subviewsBefore, "the cover is removed again")
        #expect(h.window.firstResponder === responderBefore && h.view.isFocused, "a snapshot never steals typing focus")
        #expect(h.view.dataWithPDF(inside: h.view.bounds).count > 0)
    }

    @Test func theHumanCanAllowSnapshots() throws {
        let h = ConsoleHarness(settingsJSON: #"{"allowSnapshots": true}"#, size: CGSize(width: 618, height: 636))
        let colors = try terminalRegionColors(h, skipNoticeBand: false)
        #expect(colors.count > 3, "with allowSnapshots the terminal is drawn: \(colors.count) colors")
    }

    @Test func theRedactedConsoleLooksIntentional() throws {
        let h = ConsoleHarness(settingsJSON: presetJSON(), size: CGSize(width: 618, height: 636))
        h.view.appearance = NSAppearance(named: .darkAqua)
        h.processes[0].emit(SnapshotTests.demoScreen())
        let url = artifactDirectory().appendingPathComponent("terminal-redacted.png")
        #expect(renderPNG(of: h.view, over: (false, h.view.bounds.size), to: url))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func snapshotsAreRedactedByDefault() throws {
        #expect(TerminalSettings.standard.allowSnapshots == false)
        #expect(ConsoleHarness().console.settings.allowSnapshots == false, "the host's default settings")
        let parsed = try #require(TerminalSettings.parse(Data(SettingsTests.fullSettingsJSON.utf8)))
        #expect(parsed.settings.allowSnapshots == false && parsed.warnings.isEmpty)
    }
}
