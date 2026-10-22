import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Renders tags and the desk peek over a stand-in for a Claude pop-out on the desk, as PNGs, when `PITBOX_TEST_OUT` is
/// set: `PITBOX_TEST_OUT=<dir> scripts/test.sh --filter renderTagPictures`. Without it the pictures
/// are still drawn and checked for size, so drawing never crashes. No panel is ordered in: views draw through
/// `cacheDisplay`, and the desk is drawn by hand.
@MainActor
@Suite("desk tags: pictures")
struct TagPictureTests {
    init() { DeskTagLog.enabled = false }

    struct Scene {
        var name: String
        var session: CodeSessionSnapshot
        var hidden = false
        var peek = false
        var windowSize = CGSize(width: 760, height: 430)
        var title = "Weather app · forecast refactor (quiet fern)"
        /// The window's left edge on the canvas (negative: partly off the display's left edge).
        var windowX: CGFloat = 40
    }

    static func scenes() -> [Scene] {
        let dashboard = TagPanelTests.dashboard
        let fetch = tileOffer("scp 'alex@buildbox:/home/alex/drafts/recipe-import-notes.md' ~/Downloads/",
                              commandClass: .fetchFile,
                              fetch: FetchFileRequest(alias: "buildbox", replyUser: "alex",
                                                      remotePath: "/home/alex/drafts/recipe-import-notes.md",
                                                      destinationName: nil))
        let eta = CodeETA(kind: .stated, at: tileNow.addingTimeInterval(1260), statedZone: "UTC")
        let progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 4, total: 6)
        return [
            Scene(name: "desktag-run", session: tagSession(offers: [tileOffer("swift test --filter Tags")])),
            Scene(name: "desktag-review-server", session: tagSession(offers: [tileOffer("sudo systemctl restart bridge",
                                                                                     commandClass: .forServer)],
                                                                  place: .ssh, sshHost: "buildbox")),
            Scene(name: "desktag-fetch", session: tagSession(offers: [fetch])),
            Scene(name: "desktag-commands-dashboard", session: tagSession(offers: [tileOffer("make", number: 1),
                                                                               tileOffer("rm -rf .build", number: 2, commandClass: .risky)],
                                                                      dashboard: dashboard)),
            Scene(name: "desktag-stuck", session: tagSession(state: .working, warnings: [TagContentTests.stuck])),
            Scene(name: "desktag-same-file", session: tagSession(state: .working, warnings: [TagContentTests.sameFile])),
            Scene(name: "desktag-eta-dashboard", session: tagSession(state: .working, dashboard: dashboard, eta: eta, progress: progress,
                                                                 workStartedAt: tileNow.addingTimeInterval(-34 * 60))),
            Scene(name: "desktag-late", session: tagSession(state: .working, eta: CodeETA(kind: .stated, at: tileNow.addingTimeInterval(-360),
                                                                                      isLate: true))),
            Scene(name: "desktag-hidden-text", session: tagSession(offers: [tileOffer("a", number: 1), tileOffer("b", number: 2)],
                                                               dashboard: dashboard), hidden: true),
            Scene(name: "desktag-narrow-window", session: tagSession(offers: [fetch]), windowSize: CGSize(width: 330, height: 260)),
            Scene(name: "desktag-compact-off-left-edge", session: tagSession(offers: [fetch]), windowSize: CGSize(width: 700, height: 300),
                  windowX: -480),
            Scene(name: "desktag-desk-peek", session: DeskPeekTests.rich(), peek: true, windowSize: CGSize(width: 980, height: 640)),
            Scene(name: "desktag-desk-peek-hidden", session: DeskPeekTests.rich(), hidden: true, peek: true,
                  windowSize: CGSize(width: 980, height: 520)),
        ]
    }

    @Test func renderTagPictures() throws {
        let out = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for scene in Self.scenes() {
            let png = try #require(Self.picture(scene), "\(scene.name)")
            #expect(png.count > 2000)
            if let out {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try png.write(to: out.appendingPathComponent("\(scene.name).png"))
            }
        }
    }

    /// 2x PNG: the desk, a stand-in Claude pop-out, its tag where `DeskTagPlacement` puts it, and the desk peek beside it.
    static func picture(_ scene: Scene) -> Data? {
        let content = DeskTagContentBuilder.content(.init(session: scene.session, textHidden: scene.hidden, now: tileNow,
                                                       clock: tagClock))
        guard let content else { return nil }
        let margin: CGFloat = 40
        let canvas = CGSize(width: scene.windowSize.width + 2 * margin, height: scene.windowSize.height + 2 * margin)
        // Quartz-style scene coordinates: y down from the canvas top.
        let window = CGRect(x: scene.windowX, y: margin, width: scene.windowSize.width, height: scene.windowSize.height)
        let display = DeskTagDisplay(id: 9, frame: CGRect(origin: .zero, size: canvas),
                                  visibleFrame: CGRect(x: 0, y: 8, width: canvas.width, height: canvas.height - 8))
        guard let layout = DeskTagPlacement.layout(window: window, display: display, strips: [],
                                                widths: DeskTagStackView.naturalWidths(content),
                                                compactWidths: DeskTagStackView.compactWidths(content)) else { return nil }
        let tagView = DeskTagStackView(frame: CGRect(origin: .zero, size: layout.frame.size))
        tagView.configure(content, compact: layout.compact)
        var peekView: DeskPeekView?
        var peekFrame = CGRect.zero
        if scene.peek {
            let model = DeskPeekBuilder.model(.init(session: scene.session, textHidden: scene.hidden, now: tileNow, clock: tagClock,
                                                    homeDirectory: "/Users/alex"))
            let view = DeskPeekView(model: model, frame: CGRect(x: 0, y: 0, width: 360, height: 200))
            let size = CGSize(width: 360, height: min(560, view.preferredHeight, canvas.height - 16))
            view.setFrameSize(size)
            peekFrame = DeskTagPlacement.peekFrame(tag: layout.frame, size: size, display: display, strips: [])
            peekView = view
        }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // A flipped context, so the scene's y-down coordinates draw as on screen and text and images stay upright.
        let cg = base.cgContext
        cg.translateBy(x: 0, y: canvas.height)
        cg.scaleBy(x: 1, y: -1)
        let context = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current = context

        ThemeColor.srgb(0x15171C).setFill()
        CGRect(origin: .zero, size: canvas).fill()
        drawClaudeWindow(window, title: scene.title)
        draw(tagView, at: layout.frame, canvasHeight: canvas.height)
        if let peekView { draw(peekView, at: peekFrame, canvasHeight: canvas.height) }
        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    /// A stand-in for a Claude pop-out: dark body, a title bar with the traffic lights and the title, a reply box.
    static func drawClaudeWindow(_ frame: CGRect, title: String) {
        let body = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        ThemeColor.srgb(0x262624).setFill()
        body.fill()
        let bar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 38)
        ThemeColor.srgb(0x1F1E1D).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10).fill()
        bar.insetBy(dx: 0, dy: 19).offsetBy(dx: 0, dy: 9.5).fill()
        for (index, color) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            ThemeColor.srgb(color).setFill()
            NSBezierPath(ovalIn: CGRect(x: frame.minX + 14 + CGFloat(index) * 20, y: frame.minY + 13, width: 12, height: 12)).fill()
        }
        drawFlipped(title, at: CGPoint(x: frame.minX + 84, y: frame.minY + 11), size: 13, color: 0xC3C2B7, weight: .medium)
        let reply = CGRect(x: frame.minX + 24, y: frame.maxY - 70, width: frame.width - 48, height: 46)
        ThemeColor.srgb(0x30302E).setFill()
        NSBezierPath(roundedRect: reply, xRadius: 12, yRadius: 12).fill()
        drawFlipped("Reply to Claude…", at: CGPoint(x: reply.minX + 14, y: reply.minY + 14), size: 13, color: 0x8C8B85, weight: .regular)
        for line in 0..<4 {
            let y = frame.minY + 70 + CGFloat(line) * 26
            guard y < reply.minY - 20 else { break }
            ThemeColor.srgb(0x3A3A37).setFill()
            NSBezierPath(roundedRect: CGRect(x: frame.minX + 32, y: y, width: (frame.width - 64) * [0.9, 0.7, 0.8, 0.5][line], height: 10),
                         xRadius: 5, yRadius: 5).fill()
        }
    }

    /// Text in the flipped scene (drawn upright, its top-left at `point`).
    static func drawFlipped(_ text: String, at point: CGPoint, size: CGFloat, color: UInt32, weight: NSFont.Weight) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                            .foregroundColor: ThemeColor.srgb(color)])
    }

    /// A view drawn through `cacheDisplay` (the path snapshots take), placed at `frame` in the flipped scene.
    static func draw(_ view: NSView, at frame: CGRect, canvasHeight: CGFloat) {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        NSGraphicsContext.saveGraphicsState()
        // A soft shadow like the panel's window shadow.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = CGSize(width: 0, height: 4)
        shadow.set()
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
