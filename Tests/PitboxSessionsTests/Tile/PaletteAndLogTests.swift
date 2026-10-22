import AppKit
import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

@Suite("Monitor colours")
struct PaletteTests {
    static func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func luminance(_ rgb: UInt32) -> Double {
        let r = channel(Double((rgb >> 16) & 0xFF) / 255), g = channel(Double((rgb >> 8) & 0xFF) / 255)
        let b = channel(Double(rgb & 0xFF) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    /// `top` at `alpha` over `bottom`.
    static func over(_ top: UInt32, _ alpha: Double, _ bottom: UInt32) -> UInt32 {
        func mix(_ shift: UInt32) -> UInt32 {
            let t = Double((top >> shift) & 0xFF), b = Double((bottom >> shift) & 0xFF)
            return UInt32((t * alpha + b * (1 - alpha)).rounded()) << shift
        }
        return mix(16) | mix(8) | mix(0)
    }
    /// The block's glass without a card, as ThemeTests' stand-ins see it: the glass tint over #2C2C2E / #E6E6EB.
    static let darkGlass = over(PitboxTheme.glassTint.dark, Double(PitboxTheme.glassTint.darkAlpha), 0x2C2C2E)
    static let lightGlass = over(PitboxTheme.glassTint.light, Double(PitboxTheme.glassTint.lightAlpha), 0xE6E6EB)

    typealias P = CodeMonitorPalette

    @Test func screenTextReadsAt4_5() {
        for text in [P.headline, P.text, P.dim, P.nowText, P.askText, P.working, P.amber, P.green, P.red, P.white, P.cyan, P.grey] {
            #expect(Self.contrast(text, P.screen) >= 4.5, "#\(String(text, radix: 16))")
        }
        // The offer pill's own tint under its words.
        for tone in [P.cyan, P.working, P.green, P.red] {
            #expect(Self.contrast(tone, Self.over(tone, 0.18, P.screen)) >= 4.5, "#\(String(tone, radix: 16))")
        }
    }

    @Test func ledsStandOutOnTheBezelAt3() {
        for led in [P.working, P.amber, P.green, P.red, P.white, P.grey] {
            #expect(Self.contrast(led, P.bezel) >= 3, "#\(String(led, radix: 16))")
        }
    }

    @Test func headerWordsReadOnTheGlassInBothAppearances() {
        let pairs: [(UInt32, UInt32)] = [
            (P.headerTitleDark, Self.darkGlass), (P.headerTextDark, Self.darkGlass), (P.headerFaintDark, Self.darkGlass),
            (P.attentionDark, Self.darkGlass), (P.headerTitleLight, Self.lightGlass), (P.headerTextLight, Self.lightGlass),
            (P.headerFaintLight, Self.lightGlass), (P.attentionLight, Self.lightGlass),
        ]
        for (text, glass) in pairs { #expect(Self.contrast(text, glass) >= 4.5, "#\(String(text, radix: 16))") }
        // Button labels on the accent's soft fill over the glass.
        let darkButton = Self.over(PitboxTheme.accentSoft.dark, Double(PitboxTheme.accentSoft.darkAlpha), Self.darkGlass)
        let lightButton = Self.over(PitboxTheme.accentSoft.light, Double(PitboxTheme.accentSoft.lightAlpha), Self.lightGlass)
        #expect(Self.contrast(P.buttonTextDark, darkButton) >= 4.5)
        #expect(Self.contrast(P.buttonTextLight, lightButton) >= 4.5)
    }
}

@MainActor
@Suite("Logs hold no session text", .serialized)
struct LogTests {
    /// Every marker is session text (title, nickname, TL;DR, Ask line, command, folder, host): none may reach a log line.
    static let markers = ["QQTITLE", "QQNICK", "QQTLDR", "QQASK", "qqcommand", "/Users/alex/qqfolder", "qqhost", "QQSTEP"]

    @Test func everyFlowLogsLabelsAndNumbersOnly() async throws {
        CodeTileLog.enabled = false
        CodeTileLog.startRecording()

        // The block: sessions, filter, hide text, the sheet and its events, copies, park all done, attention.
        let h = TileHarness()
        let entry = tileOffer("qqcommand --flag ~/qqfolder", session: 1)
        var session = tileSession("local_qq", "QQTITLE", nickname: "QQNICK", tldr: "QQTLDR", ask: "QQASK",
                                  offers: [entry], place: .ssh, sshHost: "qqhost", cwd: "/Users/alex/qqfolder")
        session.steps = [CodeSessionStep(words: "QQSTEP", at: tileNow)]
        h.set([tileSession("local_other", "Other")])
        h.set([tileSession("local_other", "Other"), session])
        h.model.toggleHideText()
        h.model.toggleHideText()
        h.model.openSheet(entry.id, sessionID: "local_qq", anchor: .zero)
        let events = try #require(h.presenter.presented.first?.events)
        events(.started(runID: UUID()))
        events(.finished(runID: UUID(), exitStatus: 1, seconds: 2))
        events(.refused(reason: "the folder changed after you looked; review again"))
        h.model.copyOffer(entry.id, sessionID: "local_qq")
        h.model.copyLink(sessionID: "local_qq")
        h.model.clickScreen("local_qq")
        h.model.parkAllDone()
        h.set([tileSession("local_other", "Other"), tileSession("local_qq", "QQTITLE", state: .working)])
        let (view, window) = makeTileView(h)
        view.openPeek("local_qq")
        window.close()

        // The window side: join, park, restore, close, deep link, the hotkey.
        let w = WindowsHarness(); defer { w.cleanUp() }
        w.world.add(WindowsTestWindow(pid: WindowsHarness.pidA, number: 11, title: "QQTITLE", frame: CGRect(x: 100, y: 100, width: 900, height: 700)))
        w.parker.start()
        w.update([windowSession("local_qq", title: "QQTITLE")])
        w.parker.perform(.park, sessionID: "local_qq")
        w.queue.run()
        w.parker.perform(.restore, sessionID: "local_qq")
        w.queue.run()
        w.world.minimizeIgnoredCalls = 2
        w.parker.perform(.park, sessionID: "local_qq")
        w.queue.run()

        for _ in 0..<20 { await Task.yield() }
        let lines = CodeTileLog.recorded
        #expect(lines.contains { $0.hasPrefix("sheet opened offer=#1.1") })
        #expect(lines.contains { $0.contains("park ok session=#1") })
        for line in lines {
            for marker in Self.markers { #expect(!line.contains(marker), "\(line)") }
        }
    }
}
