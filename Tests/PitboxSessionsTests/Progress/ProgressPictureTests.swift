import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// PNGs of the progress and dashboard components, when `PITBOX_TEST_OUT` is set:
/// `PITBOX_TEST_OUT=<dir> scripts/test.sh --filter "Progress and dashboard pictures"`. The monitor around the
/// run line is a stand-in (the block draws the real one); colours and words are the components' own.
@MainActor
@Suite("Progress and dashboard pictures")
struct ProgressPictureTests {
    static let now = utcDate(2026, 10, 20, 22, 10)

    // MARK: A stand-in monitor

    /// A bezel, a screen with a headline and a "Now:" line, the run line and bar, and the ▦ pill.
    final class MonitorStandIn: NSView {
        let snapshot: CodeSessionSnapshot
        let size: CodeRunLine.Size
        let now: Date

        init(_ snapshot: CodeSessionSnapshot, size: CodeRunLine.Size, now: Date, frame: CGRect) {
            self.snapshot = snapshot
            self.size = size
            self.now = now
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let bezel = bounds.insetBy(dx: 2, dy: 4)
            ThemeColor.srgb(0x3A3D45).setFill()
            NSBezierPath(roundedRect: bezel, xRadius: 10, yRadius: 10).fill()
            let inset: CGFloat = size == .small ? 4 : (size == .medium ? 5 : 8)
            let screen = bezel.insetBy(dx: inset, dy: inset)
            ThemeColor.srgb(0x101215).setFill()
            NSBezierPath(roundedRect: screen, xRadius: 6, yRadius: 6).fill()
            let pad: CGFloat = size == .small ? 6 : 10
            var y = screen.minY + pad
            func text(_ string: String, _ font: NSFont, _ color: UInt32) {
                (string as NSString).draw(with: CGRect(x: screen.minX + pad, y: y, width: screen.width - 2 * pad, height: 18),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                          attributes: [.font: font, .foregroundColor: ThemeColor.srgb(color)])
                y += 18
            }
            text(snapshot.headline, .systemFont(ofSize: size == .small ? 12 : 13, weight: .semibold), 0xF3F4F6)
            if size == .large { text("Now: running: swift test", .monospacedSystemFont(ofSize: 12, weight: .regular), 0x8EC0FF) }
            let clock = clockLisbon
            if let line = CodeRunLine.make(snapshot, now: now, clock: clock) {
                let words = line.text(for: size)
                let textRect = words == nil ? nil : CGRect(x: screen.minX + pad, y: y, width: screen.width - 2 * pad, height: 18)
                if textRect != nil { y += 20 }
                let bar = CGRect(x: screen.minX + pad, y: size == .small ? screen.maxY - pad - 3 : y, width: screen.width - 2 * pad,
                                 height: 3)
                CodeRunLineDrawing.draw(line, size: size, textRect: textRect, barRect: bar)
            }
            if snapshot.dashboard != nil {
                let style: DashboardPill.Style = size == .large ? .large : (size == .medium ? .medium : .small)
                DashboardPill.draw(style, in: DashboardPill.frame(style, onBezel: bezel))
            }
        }
    }

    static func running(_ eta: CodeETA?, progress: CodeProgress?, state: CodeSessionState = .working,
                        headline: String = "Weather app · forecast refactor", dashboard: Bool = true) -> CodeSessionSnapshot {
        var s = progressSnapshot(state: state, headline: headline)
        s.workStartedAt = now.addingTimeInterval(-34 * 60)
        s.eta = eta
        s.progress = progress
        if dashboard { s.dashboard = CodeDashboard(handle: "polar-shore", site: .test, firstSeen: now) }
        return s
    }

    static let agents = CodeProgress(source: .backgroundTasks, unit: .agents, done: 4, total: 6)
    static var between: CodeProgress {
        var p = agents
        p.pendingBetweenTurns = true
        return p
    }
    static var onTime: CodeETA { CodeETA(kind: .stated, at: now.addingTimeInterval(14 * 60), statedZone: "UTC") }
    static var passed: CodeETA { CodeETA(kind: .stated, at: now.addingTimeInterval(-6 * 60), statedZone: "UTC") }
    static var estimate: CodeETA { CodeETA(kind: .estimate, at: now.addingTimeInterval(9 * 60), minutesLeft: 9) }

    static func monitors() -> NSView {
        let canvas = FlippedCanvas(frame: CGRect(x: 0, y: 0, width: 992, height: 560))
        let cases: [(CodeSessionSnapshot, CodeRunLine.Size, CGRect)] = [
            (running(onTime, progress: agents), .large, CGRect(x: 0, y: 0, width: 323, height: 150)),
            (running(passed, progress: agents, headline: "Photo sorter · dedupe"), .large,
             CGRect(x: 335, y: 0, width: 323, height: 150)),
            (running(onTime, progress: between, state: .done, headline: "fleet · Toy Cube checkout"), .large,
             CGRect(x: 670, y: 0, width: 323, height: 150)),
            (running(estimate, progress: agents, headline: "Chess clock · timer bug"), .medium, CGRect(x: 0, y: 170, width: 323, height: 120)),
            (running(onTime, progress: agents, headline: "Garden planner · sync", dashboard: false), .medium,
             CGRect(x: 335, y: 170, width: 323, height: 120)),
            (running(passed, progress: agents, headline: "Trail map · offline cache"), .medium, CGRect(x: 670, y: 170, width: 323, height: 120)),
            (running(estimate, progress: agents, headline: "Habit tracker · streaks"), .small, CGRect(x: 0, y: 310, width: 155, height: 104)),
            (running(passed, progress: agents, headline: "robot gestures"), .small, CGRect(x: 167, y: 310, width: 155, height: 104)),
            (running(nil, progress: agents, headline: "Bike log · weekly charts"), .small, CGRect(x: 335, y: 310, width: 155, height: 104)),
        ]
        for (snapshot, size, frame) in cases {
            canvas.addSubview(MonitorStandIn(snapshot, size: size, now: now, frame: frame))
        }
        let summary = CodeSummaryLineView(frame: CGRect(x: 0, y: 440, width: 992, height: CodeSummaryLineView.height))
        summary.line = CodeSummaryLine.make(sessions: cases.map(\.0), readyItems: 4, justFinished: 2, now: now, clock: clockLisbon)
        canvas.addSubview(summary)
        let narrow = CodeSummaryLineView(frame: CGRect(x: 0, y: 470, width: 420, height: CodeSummaryLineView.height))
        narrow.line = summary.line
        canvas.addSubview(narrow)
        var x: CGFloat = 0
        for style in [DashboardPill.Style.large, .medium, .small, .tag, .panel(DashboardWords.button),
                      .panel(DashboardWords.openButton), .panel(DashboardWords.open)] {
            let size = DashboardPill.size(style)
            let button = DashboardButtonView(style: style, tooltip: nil, frame: CGRect(x: x, y: 510, width: size.width, height: size.height))
            button.clock = { 0 }
            button.pointer = { _ in nil }
            button.rearm()
            button.clock = { 10 }
            canvas.addSubview(button)
            x += size.width + 14
        }
        return canvas
    }

    static func list(hideText: Bool) -> NSView {
        func session(_ id: String, _ headline: String, _ state: CodeSessionState, _ handle: String, updated: Bool) -> CodeSessionSnapshot {
            var s = progressSnapshot(id, state: state, headline: headline)
            s.dashboard = CodeDashboard(handle: handle, site: .test, firstSeen: now.addingTimeInterval(-90 * 60),
                                        lastBuilderCallAt: updated ? now.addingTimeInterval(-4 * 60) : nil)
            return s
        }
        let sessions = [
            session("local_l1", "Weather app · forecast refactor", .working, "polar-shore", updated: true),
            session("local_l2", "Docs site · link checker", .reviewReady, "silver-moss", updated: true),
            session("local_l3", "Toy Cube · product page", .needsYou, "amber-reef", updated: false),
            session("local_l4", "Photo sorter · dedupe", .working, "quiet-fjord", updated: true),
            session("local_l5", "Garden planner · sync", .problem, "north-gale", updated: false),
        ]
        let rows = DashboardList.rows(sessions, ownActivityOnly: ["local_l4"], hideText: hideText, clock: clockLisbon)
        let height = DashboardListView.preferredHeight(rows: rows.count)
        let view = DashboardListView(rows: rows, frame: CGRect(x: 0, y: 0, width: 657, height: height))
        // Shown a while ago, the pointer elsewhere: the Open buttons are armed.
        view.buttonClock = { 0 }
        for button in view.buttons.values {
            button.pointer = { _ in nil }
            button.rearm()
        }
        view.buttonClock = { 10 }
        return view
    }

    final class FlippedCanvas: NSView {
        override var isFlipped: Bool { true }
    }

    @Test func renderPictures() throws {
        let out = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let cases: [(String, NSView, Bool)] = [
            ("progress-running-dark", Self.monitors(), true),
            ("progress-running-light", Self.monitors(), false),
            ("dashboards-list-dark", Self.list(hideText: false), true),
            ("dashboards-list-hidden-light", Self.list(hideText: true), false),
        ]
        for (name, view, dark) in cases {
            let png = try #require(Self.picture(of: view, dark: dark), "\(name)")
            #expect(png.count > 2000)
            if let out {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try png.write(to: out.appendingPathComponent("\(name).png"))
            }
        }
    }

    /// 2x PNG over a stand-in for the block's glass (the block draws no card).
    static func picture(of view: NSView, dark: Bool) -> Data? {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = view.bounds.size
        let margin: CGFloat = 16
        let total = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(total.width * 2), pixelsHigh: Int(total.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let viewRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        rep.size = total
        view.cacheDisplay(in: view.bounds, to: viewRep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let backdrop = dark ? ThemeColor.srgb(0x2C2C2E) : ThemeColor.srgb(0xE6E6EB)
        backdrop.setFill()
        CGRect(origin: .zero, size: total).fill()
        PitboxTheme.glassTint.color(dark: dark).setFill()
        CGRect(origin: .zero, size: total).fill(using: .sourceOver)
        viewRep.draw(in: CGRect(x: margin, y: margin, width: size.width, height: size.height), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// The summary line's colours and layout (contrast: 4.5:1 for words in both themes).
@MainActor
@Suite("Summary line view")
struct SummaryLineViewTests {
    static func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func luminance(_ rgb: UInt32) -> Double {
        0.2126 * channel(Double((rgb >> 16) & 0xFF) / 255) + 0.7152 * channel(Double((rgb >> 8) & 0xFF) / 255)
            + 0.0722 * channel(Double(rgb & 0xFF) / 255)
    }
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    static func over(_ top: UInt32, _ alpha: Double, _ bottom: UInt32) -> UInt32 {
        func mix(_ shift: UInt32) -> UInt32 {
            UInt32((Double((top >> shift) & 0xFF) * alpha + Double((bottom >> shift) & 0xFF) * (1 - alpha)).rounded()) << shift
        }
        return mix(16) | mix(8) | mix(0)
    }
    static let darkGlass = over(PitboxTheme.glassTint.dark, Double(PitboxTheme.glassTint.darkAlpha), 0x2C2C2E)
    static let lightGlass = over(PitboxTheme.glassTint.light, Double(PitboxTheme.glassTint.lightAlpha), 0xE6E6EB)

    @Test func wordsReadOnTheGlassAndOnTheScreen() {
        typealias V = CodeSummaryLineView
        for color in [V.plainDark, V.numberDark, V.attentionDark, V.dashboardDark] {
            #expect(Self.contrast(color, Self.darkGlass) >= 4.5, "#\(String(color, radix: 16))")
        }
        for color in [V.plainLight, V.numberLight, V.attentionLight, V.dashboardLight] {
            #expect(Self.contrast(color, Self.lightGlass) >= 4.5, "#\(String(color, radix: 16))")
        }
        for color in [CodeRunLineDrawing.text, CodeRunLineDrawing.late, DashboardPill.pink] {
            #expect(Self.contrast(color, 0x101215) >= 4.5, "on the screen #\(String(color, radix: 16))")
        }
        #expect(Self.contrast(DashboardPill.pinkText, DashboardPill.pink) >= 4.5)
        #expect(Self.contrast(DashboardPill.panelText, DashboardPill.panelFill) >= 4.5)
        #expect(Self.contrast(DashboardPill.pink, 0x3A3D45) >= 3, "the pill stands out on the bezel")
        #expect(Self.contrast(CodeRunLineDrawing.bar, CodeRunLineDrawing.track) >= 3)
        #expect(Self.contrast(CodeRunLineDrawing.late, CodeRunLineDrawing.track) >= 3)
    }

    @Test func aNarrowLineLeavesOutTheLeastNeededPartsAndKeepsTheButton() throws {
        var line = CodeSummaryLine.make(sessions: [], readyItems: 4, justFinished: 2, warnings: 1, now: Date(), clock: clockUTC)
        line.parts.append(CodeSummaryLine.Part(kind: .dashboards, runs: [.init(text: "▦ 6 dashboards", tone: .dashboard)]))
        let wide = CodeSummaryLineView.layout(line, width: 900, height: 20)
        #expect(wide.map(\.part.kind) == [.justFinished, .ready, .warnings, .dashboards])
        let narrow = CodeSummaryLineView.layout(line, width: 220, height: 20)
        #expect(narrow.map(\.part.kind).last == .dashboards && !narrow.map(\.part.kind).contains(.justFinished))
        let view = CodeSummaryLineView(line: line, frame: CGRect(x: 0, y: 0, width: 900, height: 20))
        #expect(!view.isDashboardsButton(at: CGPoint(x: 5, y: 10)))
        let button = try #require(view.dashboardsRect)
        #expect(view.isDashboardsButton(at: CGPoint(x: button.midX, y: button.midY)))
        #expect(view.accessibilityLabel() == "2 just finished · 4 ready for you · 1 warning · ▦ 6 dashboards")
    }
}
