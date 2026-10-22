import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Dragging monitors between buckets with a fake pointer (synthetic mouse events on the block's own
/// views: no window of any app is touched, nothing goes through a pasteboard).
@MainActor
@Suite("Buckets: dragging monitors")
struct MonitorDragTests {
    init() { CodeTileLog.enabled = false }

    /// Unsorted (u1, u2), Acme (c1) and Toy Cube (t1, folded), in a 992 × 798 block.
    private func scene() throws -> (BucketHarness, sideBucket: String, toy: String, view: CodeMonitorsTileView, window: NSWindow) {
        let h = BucketHarness()
        let ids = h.makeBuckets(["Acme", "Toy Cube"])
        h.set(bucketSessions("u", 2) + bucketSessions("c", 1) + bucketSessions("t", 1))
        h.model.moveSession("local_c1", toBucket: ids[0])
        h.model.moveSession("local_t1", toBucket: ids[1])
        h.model.toggleFolded(ids[1])
        let (view, window) = makeBucketTileView(h)
        return (h, ids[0], ids[1], view, window)
    }

    /// The centre of a bucket's header in the block's coordinates.
    private func headerCentre(_ view: CodeMonitorsTileView, _ id: String) throws -> CGPoint {
        let header = try #require(view.bucketHeaders[id])
        return view.convert(bucketCentre(header.bounds), from: header)
    }

    /// Presses on monitor `id`, moves 2 pt, then to `point` (the block's coordinates) or `windowPoint`, and releases
    /// there unless `release` is false.
    private func drag(_ view: CodeMonitorsTileView, _ id: String, to point: CGPoint? = nil, windowPoint: CGPoint? = nil,
                      release: Bool = true) throws {
        let monitor = try #require(view.monitorView(id))
        let start = bucketCentre(monitor.layoutInfo.screen)
        monitor.mouseDown(with: try #require(bucketMouse(.leftMouseDown, at: start, in: monitor)))
        monitor.mouseDragged(with: try #require(bucketMouse(.leftMouseDragged, at: CGPoint(x: start.x + 2, y: start.y), in: monitor)))
        let target = try windowPoint ?? view.convert(try #require(point), to: nil)
        monitor.mouseDragged(with: try #require(bucketMouse(.leftMouseDragged, in: monitor, windowPoint: target)))
        if release { monitor.mouseUp(with: try #require(bucketMouse(.leftMouseUp, in: monitor, windowPoint: target))) }
    }

    @Test func aDropOnAnotherBucketMovesTheSessionToItsStablePlace() throws {
        let (h, sideBucket, _, view, window) = try scene()
        defer { window.close() }
        try drag(view, "local_u2", to: try headerCentre(view, sideBucket))
        #expect(h.layout[sideBucket] == ["local_u2", "local_c1"])
        #expect(h.layout[CodeBucket.unsortedID] == ["local_u1"])
        // The body works as a target too, and the move back puts it back in its place.
        let body = try #require(view.otherFolders[sideBucket])
        try drag(view, "local_u2", to: view.convert(CGPoint(x: body.bounds.maxX - 20, y: body.bounds.midY), from: body))
        #expect(h.layout[sideBucket] == ["local_u2", "local_c1"])
        let unsorted = try #require(view.bucketHeaders[CodeBucket.unsortedID])
        try drag(view, "local_u2", to: view.convert(bucketCentre(unsorted.bounds), from: unsorted))
        #expect(h.layout[CodeBucket.unsortedID] == ["local_u1", "local_u2"])
        // Nothing went near a window.
        #expect(h.parker.performed.isEmpty)
    }

    @Test func aFoldedBucketsHeaderIsATarget() throws {
        let (h, _, toy, view, window) = try scene()
        defer { window.close() }
        try drag(view, "local_u1", to: try headerCentre(view, toy))
        #expect(h.layout[toy] == ["local_u1", "local_t1"])
        #expect(h.model.buckets.bucket(toy)?.folded == true)
    }

    @Test func aDropOnItsOwnBucketOrBetweenBucketsChangesNothing() throws {
        let (h, sideBucket, _, view, window) = try scene()
        defer { window.close() }
        let before = h.layout
        try drag(view, "local_u1", to: try headerCentre(view, CodeBucket.unsortedID))
        #expect(h.layout == before)
        // The gap between Unsorted's body and Acme's header.
        let header = try #require(view.bucketHeaders[sideBucket])
        let gap = view.convert(CGPoint(x: 400, y: header.frame.minY - 6), from: view.content)
        try drag(view, "local_u1", to: gap)
        #expect(h.layout == before)
        #expect(h.parker.performed.isEmpty)
    }

    @Test func escapeCancels() throws {
        let (h, sideBucket, _, view, window) = try scene()
        defer { window.close() }
        let before = h.layout
        try drag(view, "local_u1", to: try headerCentre(view, sideBucket), release: false)
        #expect(view.drag?.highlighted == sideBucket)
        let other = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
                                                  keyCode: 0))
        #expect(view.dragKeyDown(other) === other)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))
        #expect(view.dragKeyDown(escape) == nil)
        #expect(view.drag == nil && view.dragCard == nil && view.dropOutline.isHidden)
        // The release afterwards does nothing.
        let monitor = try #require(view.monitorView("local_u1"))
        monitor.mouseUp(with: try #require(bucketMouse(.leftMouseUp, in: monitor, windowPoint: view.convert(try headerCentre(view, sideBucket), to: nil))))
        #expect(h.layout == before && h.parker.performed.isEmpty)
        #expect(!monitor.dimmed)
    }

    @Test func aDropOutsideTheStripDoesWhatAClickDoes() throws {
        let (h, _, _, view, window) = try scene()
        defer { window.close() }
        let outside = CGPoint(x: -60, y: 200)
        let cases: [(CodeWindowPlace, CodeWindowClick?)] = [(.parked(since: tileNow), .restore), (.otherSpace, .activate),
                                                            (.closed, .openInMainWindow), (.notMatched, nil), (.onDesk, .park)]
        for (place, click) in cases {
            let count = h.parker.performed.count
            h.parker.statuses["local_u1"] = CodeWindowStatus(place: place)
            try drag(view, "local_u1", windowPoint: outside)
            if let click {
                #expect(h.parker.performed.count == count + 1 && h.parker.performed.last?.0 == click, "\(place)")
            } else {
                #expect(h.parker.performed.count == count, "\(place)")
            }
            #expect(h.layout[CodeBucket.unsortedID] == ["local_u1", "local_u2"])
        }
    }

    @Test func aPressThatMovesLessThan5PointsIsStillAClick() throws {
        let (h, _, _, view, window) = try scene()
        defer { window.close() }
        let monitor = try #require(view.monitorView("local_u1"))
        let start = bucketCentre(monitor.layoutInfo.screen)
        monitor.mouseDown(with: try #require(bucketMouse(.leftMouseDown, at: start, in: monitor)))
        monitor.mouseDragged(with: try #require(bucketMouse(.leftMouseDragged, at: CGPoint(x: start.x + 3, y: start.y + 3), in: monitor)))
        monitor.mouseUp(with: try #require(bucketMouse(.leftMouseUp, at: CGPoint(x: start.x + 3, y: start.y + 3), in: monitor)))
        #expect(view.drag == nil)
        #expect(h.parker.performed.map(\.0) == [.park])
    }

    @Test func duringADragTheMonitorDimsTheCardFollowsAndNoPeekOpens() throws {
        let (h, sideBucket, _, view, window) = try scene()
        defer { window.close() }
        let target = try headerCentre(view, sideBucket)
        try drag(view, "local_u1", to: target, release: false)
        let monitor = try #require(view.monitorView("local_u1"))
        #expect(monitor.dimmed && monitor.isDragging)
        let card = try #require(view.dragCard)
        #expect(!card.isHidden && card.headline == "u 1")
        #expect(abs(card.frame.minX - (target.x + 12)) < 1)
        // The outline sits on Acme.
        let placed = try #require(view.placedBuckets.first { $0.id == sideBucket })
        #expect(!view.dropOutline.isHidden)
        #expect(view.dropOutline.frame == view.scrolledStackFrame(placed.area).insetBy(dx: 0, dy: -4))
        // No peek opens, by hover or by dwell.
        view.monitorView("local_u2")?.setHovered(true)
        #expect(view.dwellWork == nil)
        view.openPeek("local_u2")
        #expect(view.peekView == nil)
        // The block holds the keyboard for Escape until the drop.
        #expect(h.keyboard.calls == [true])
        monitor.mouseUp(with: try #require(bucketMouse(.leftMouseUp, in: monitor, windowPoint: view.convert(target, to: nil))))
        #expect(h.keyboard.calls == [true, false])
        #expect(view.dragCard == nil && view.dropOutline.isHidden)
    }

    @Test func aDragEndsAsACancelWhenTheStripHidesArrangingStartsOrTheSessionGoes() throws {
        let (h, sideBucket, _, view, window) = try scene()
        defer { window.close() }
        let before = h.layout
        let target = try headerCentre(view, sideBucket)
        try drag(view, "local_u1", to: target, release: false)
        h.model.setStripVisible(false)
        #expect(view.drag == nil && view.dragCard == nil)
        let monitor = try #require(view.monitorView("local_u1"))
        monitor.mouseUp(with: try #require(bucketMouse(.leftMouseUp, in: monitor, windowPoint: view.convert(target, to: nil))))
        #expect(h.layout == before)
        h.model.setStripVisible(true)
        try drag(view, "local_u1", to: target, release: false)
        h.model.closeOverlays()   // the block folded or hid (`dismissOverlays`): the drag ends as a cancel
        #expect(view.drag == nil)
        try drag(view, "local_u2", to: target, release: false)
        h.set(bucketSessions("u", 1) + bucketSessions("c", 1) + bucketSessions("t", 1))
        #expect(view.drag == nil)
        #expect(h.parker.performed.isEmpty)
        #expect(h.keyboard.calls == [true, false, true, false, true, false])
    }

    @Test func withUnsortedAloneAPressThatMovesStaysAClick() throws {
        let h = BucketHarness()
        h.set(bucketSessions("u", 2))
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        let monitor = try #require(view.monitorView("local_u1"))
        let start = bucketCentre(monitor.layoutInfo.screen)
        monitor.mouseDown(with: try #require(bucketMouse(.leftMouseDown, at: start, in: monitor)))
        monitor.mouseDragged(with: try #require(bucketMouse(.leftMouseDragged, at: CGPoint(x: start.x + 30, y: start.y), in: monitor)))
        monitor.mouseUp(with: try #require(bucketMouse(.leftMouseUp, at: CGPoint(x: start.x + 30, y: start.y), in: monitor)))
        #expect(view.drag == nil && h.keyboard.calls.isEmpty)
        #expect(h.parker.performed.map(\.0) == [.park])
    }
}
