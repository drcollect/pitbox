import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// A window that is never shown but can pretend to be key, so focus logic can be tested without touching the screen.
final class OffscreenWindow: NSWindow {
    var pretendKey = false
    var pretendVisible = false
    override var isKeyWindow: Bool { pretendKey }
    override var isVisible: Bool { pretendVisible }
    override var canBecomeKey: Bool { true }
}

/// The console over fakes, hosted in an off-screen window.
@MainActor
final class ConsoleHarness {
    let dir = TempDir()
    let clock = ManualClock()
    let launcher = FakeLauncher()
    let console: ConsoleHost
    let view: ConsoleView
    let window: OffscreenWindow
    private(set) var keyboardRequests: [Bool] = []

    var manager: TerminalSessionManager { view.manager }
    var processes: [FakeProcess] { launcher.processes }

    /// - Parameters:
    ///   - settingsJSON: the console's settings as `TerminalSettings.parse` reads them (nil: the defaults).
    ///   - mode: the terminal's behaviour (a plain shell at start, "+", restore) for the tests of that code, which the
    ///     app keeps but never uses; `.pitbox` for Pitbox's console.
    init(settingsJSON: String? = nil, size: CGSize = CGSize(width: 618, height: 636), saved: SavedState? = nil,
         mode: ConsoleMode = .terminal) {
        if let saved { saved.save(to: dir.paths.stateFile) }
        var requests: ((Bool) -> Void)?
        console = ConsoleHost(settings: testSettings(settingsJSON), keyboardRequester: { requests?($0) }, paths: dir.paths,
                              launcher: launcher.launch, clock: clock, environment: fixtureEnvironment(), mode: mode)
        view = console.makeConsoleView()
        // Hover comes from the tests alone, never from wherever the real pointer happens to be on the screen.
        view.strip.pointerLocation = { nil }
        window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // No order-in/out animation: while the display sleeps it never ends and keeps a GCD pool thread.
        window.animationBehavior = .none
        window.pretendVisible = true   // the console counts as shown; nothing is ever ordered onto the real screen
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        requests = { [unowned self] in keyboardRequests.append($0) }
    }

    func makeKey(_ key: Bool = true) {
        window.pretendKey = key
        NotificationCenter.default.post(name: key ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: window)
    }

    func layout(_ size: CGSize) {
        window.setContentSize(size)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
    }

    /// A key-down event for the shortcut tests.
    func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: keyCode)!
    }

    var selectedView: ConsoleTerminalView? { manager.selectedSession?.view }

    /// The strip's tab titles.
    var stripTitles: [String] { view.strip.items.map(\.title) }
}

/// A left-button event on the strip of `h` at `point` (strip coordinates).
@MainActor
func stripMouseEvent(_ h: ConsoleHarness, _ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: h.view.strip.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                    windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                                    pressure: type == .leftMouseUp ? 0 : 1))
}

/// Clicks the strip like a real mouse: a mouse-down and a mouse-up at the same place (`count` is the click's place in a
/// double- or triple-click).
@MainActor
func clickStrip(_ h: ConsoleHarness, at point: CGPoint, count: Int = 1) throws {
    h.view.strip.mouseDown(with: try stripMouseEvent(h, .leftMouseDown, at: point, clickCount: count))
    h.view.strip.mouseUp(with: try stripMouseEvent(h, .leftMouseUp, at: point, clickCount: count))
}

/// Where tests put pictures for people to look at: `PITBOX_TEST_OUT` if set, else a temp folder.
func artifactDirectory() -> URL {
    let base = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("pitbox-console-artifacts", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Renders a view (with its layer tint) over a soft gradient, like the block's glass, and returns the bitmap.
@MainActor
func renderBitmap(of view: NSView, over background: (light: Bool, size: CGSize)) -> NSBitmapImageRep? {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let size = view.bounds.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    // Backdrop: a diagonal gradient standing in for the glass over a wallpaper.
    let colors = background.light
        ? [NSColor(srgbRed: 0.72, green: 0.80, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.98, green: 0.85, blue: 0.78, alpha: 1)]
        : [NSColor(srgbRed: 0.10, green: 0.22, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.42, green: 0.16, blue: 0.36, alpha: 1)]
    NSGradient(colors: colors)?.draw(in: CGRect(origin: .zero, size: size), angle: 315)
    NSGraphicsContext.restoreGraphicsState()
    // Views draw into their own rep, then composite.
    guard let viewRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: viewRep)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let image = NSImage(size: size)
    image.addRepresentation(viewRep)
    image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Renders a view (with its layer tint) over a soft gradient, like the block's glass, and writes a PNG.
@MainActor
func renderPNG(of view: NSView, over background: (light: Bool, size: CGSize), to url: URL) -> Bool {
    guard let rep = renderBitmap(of: view, over: background),
          let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: url)) != nil
}
