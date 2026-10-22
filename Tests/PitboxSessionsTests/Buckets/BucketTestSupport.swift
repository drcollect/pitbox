import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

// Helpers for the bucket tests: a scratch folder per test, a block model over the block's fakes with a bucket store
// of the test's choosing, and synthetic mouse events. Nothing here touches a real window of another app, a file of
// Claude's or the user's buckets file.

/// A scratch folder for one test's `code-buckets.json`, removed by `cleanUp()`.
struct BucketTestFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("buckets-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var file: URL { url.appendingPathComponent("code-buckets.json") }
    var corrupt: URL { url.appendingPathComponent("code-buckets.json.corrupt") }

    func write(_ text: String) throws { try Data(text.utf8).write(to: file) }

    /// The file's top-level object as Foundation values.
    func json() throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}

/// A store on a file, read at `now`, writing at once on `flush()` (a long interval keeps writes to the test's flushes).
@MainActor
func bucketStore(_ folder: BucketTestFolder, now: Date = tileNow, owner: uid_t = getuid(), interval: TimeInterval = 60) -> CodeBucketStore {
    CodeBucketStore(url: folder.file, owner: owner, now: now, writeInterval: interval)
}

/// A block model over the block's fakes (`TileTestFakes.swift`) with the given bucket store.
@MainActor
struct BucketHarness {
    let source = TileTestSource()
    let parker = TileTestParker()
    let presenter = TileTestPresenter()
    let pasteboard = TileTestPasteboard()
    let model: CodeMonitorsModel
    let keyboard = BucketCalls<Bool>()
    let marks = BucketCalls<String>()
    /// The model's clock; tests move it.
    let clock = BucketClock()

    init(store: CodeBucketStore? = nil, settings: CodeSettings = CodeSettings()) {
        model = CodeMonitorsModel(source: source, parker: parker, presenter: presenter, freshness: TileTestFreshness(),
                                  settings: settings, pasteboard: pasteboard, buckets: store)
        let clock = self.clock, keyboard = self.keyboard, marks = self.marks
        model.now = { clock.now }
        model.homeDirectory = "/Users/alex"
        model.keyboardRequester = { keyboard.calls.append($0) }
        model.onMarkClick = { session, mark in marks.calls.append("\(session) \(mark)") }
        model.start()
    }

    /// The sessions, every one on the desk unless said otherwise.
    func set(_ sessions: [CodeSessionSnapshot], onDesk: Bool = true) {
        if onDesk { parker.onDesk(sessions.map(\.id)) }
        source.sessions = sessions
    }

    /// Makes buckets with these names (in order) and returns their ids.
    @discardableResult
    func makeBuckets(_ names: [String]) -> [String] {
        names.compactMap { name in
            guard let id = model.createBucket() else { return nil }
            model.renameBucket(id, to: name)
            return id
        }
    }

    /// The monitors' ids per bucket, in the buckets' order.
    var layout: [String: [String]] {
        Dictionary(uniqueKeysWithValues: model.snapshot.sections.map { ($0.id, $0.monitors.map(\.id)) })
    }

    func section(_ id: String) -> CodeBucketSection? { model.snapshot.sections.first { $0.id == id } }
}

/// Calls recorded by a fake closure.
@MainActor
final class BucketCalls<T> {
    var calls: [T] = []
}

/// A clock tests move.
@MainActor
final class BucketClock {
    var now = tileNow
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// `count` sessions named `<prefix>1…` (all copy A, done unless `states` says otherwise).
func bucketSessions(_ prefix: String, _ count: Int, from start: Int = 1, states: [Int: CodeSessionState] = [:]) -> [CodeSessionSnapshot] {
    (start..<(start + count)).map { n in
        tileSession("local_\(prefix)\(n)", "\(prefix) \(n)", index: n, state: states[n] ?? .done, tldr: "Summary \(n)")
    }
}

/// A block view in an off-screen window (as `makeTileView`), for a bucket harness.
@MainActor
func makeBucketTileView(_ h: BucketHarness, size: CGSize = CGSize(width: 992, height: 798)) -> (CodeMonitorsTileView, NSWindow) {
    let view = CodeMonitorsTileView(model: h.model)
    view.visibilityProbe = { _ in true }
    view.pointerProbe = { nil }
    view.screenFrame = { $0.convert($0.bounds, to: nil) }
    view.menuPresenter = { _, _, _ in }
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.isOpaque = false
    window.backgroundColor = .clear
    view.frame = CGRect(origin: .zero, size: size)
    window.contentView = view
    view.folder.reduceMotion = { true }
    view.refresh()
    return (view, window)
}

/// A mouse event at `point` in `view`'s coordinates (or at `windowPoint`, the window's).
@MainActor
func bucketMouse(_ type: NSEvent.EventType, at point: CGPoint? = nil, in view: NSView, windowPoint: CGPoint? = nil,
                 clickCount: Int = 1) -> NSEvent? {
    let location = windowPoint ?? view.convert(point ?? .zero, to: nil)
    return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                              windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clickCount,
                              pressure: 1)
}

/// A click (down and up at one point) on a view.
@MainActor
func bucketClick(_ view: NSView, at point: CGPoint, clickCount: Int = 1) {
    guard let down = bucketMouse(.leftMouseDown, at: point, in: view, clickCount: clickCount),
          let up = bucketMouse(.leftMouseUp, at: point, in: view, clickCount: clickCount) else {
        Issue.record("could not make mouse events")
        return
    }
    view.mouseDown(with: down)
    view.mouseUp(with: up)
}

func bucketCentre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

/// Draws a view once into a bitmap (its `draw(_:)` runs, so `drawnTexts` fill).
@MainActor
func bucketRender(_ view: NSView) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        Issue.record("no bitmap for the view")
        return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
}
