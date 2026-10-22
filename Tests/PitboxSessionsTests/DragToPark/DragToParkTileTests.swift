import AppKit
import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

// Drag-to-park on the block: the bucket under the pointer, its outline, the session's own bucket and the move after the
// park, on a real block view in an off-screen window that is never shown, with the bucket test helpers. No real window,
// event or file of the user's.

@MainActor
@Suite("Drag-to-park on the block's buckets")
struct DragToParkTileTests {
    init() { CodeTileLog.enabled = false }

    /// Unsorted (u1, u2) and Toy Cube (t1) in a 992 × 798 block.
    private func scene() -> (BucketHarness, toy: String, view: CodeMonitorsTileView, window: NSWindow) {
        let h = BucketHarness()
        let toy = h.makeBuckets(["Toy Cube"])[0]
        h.set(bucketSessions("u", 2) + bucketSessions("t", 1))
        h.model.moveSession("local_t1", toBucket: toy)
        let (view, window) = makeBucketTileView(h)
        return (h, toy, view, window)
    }

    /// A screen point (AppKit) at the centre of a bucket's header.
    private func headerPoint(_ view: CodeMonitorsTileView, _ id: String, _ window: NSWindow) throws -> CGPoint {
        let header = try #require(view.bucketHeaders[id])
        return window.convertPoint(toScreen: header.convert(bucketCentre(header.bounds), to: nil))
    }

    @Test func withUnsortedAloneNoBucketIsNamed() {
        let h = BucketHarness()
        h.set(bucketSessions("u", 2))
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        // Over Unsorted's body, which the block does place (a monitor drag could target it).
        let body = view.folder.convert(bucketCentre(view.folder.bounds), to: nil)
        #expect(view.bucket(atWindowPoint: body) == CodeBucket.unsortedID)
        let inside = window.convertPoint(toScreen: body)
        #expect(CodeDropTile.target(in: view, atScreenPoint: inside) == nil, "the plain look: no bucket to name")
        #expect(CodeDropTile.ownTarget(in: view, of: "local_u1") == nil)
        #expect(CodeDropTarget.labelText(nil) == "Drop to pit")
    }

    @Test func theBucketUnderThePointerIsTheTargetAndTheOwnBucketElsewhere() throws {
        let (_, toy, view, window) = scene()
        defer { window.close() }
        let target = CodeDropTile.target(in: view, atScreenPoint: try headerPoint(view, toy, window))
        #expect(target == CodeDropTarget(bucketID: toy, bucketName: "Toy Cube"))
        let unsorted = CodeDropTile.target(in: view, atScreenPoint: try headerPoint(view, CodeBucket.unsortedID, window))
        #expect(unsorted == CodeDropTarget(bucketID: CodeBucket.unsortedID, bucketName: "Unsorted"))
        // The block's own header band is no bucket.
        let header = window.convertPoint(toScreen: view.convert(CGPoint(x: 200, y: 10), to: nil))
        #expect(CodeDropTile.target(in: view, atScreenPoint: header) == nil)
        #expect(CodeDropTile.ownTarget(in: view, of: "local_t1")?.bucketID == toy)
        #expect(CodeDropTile.ownTarget(in: view, of: "local_new")?.bucketID == CodeBucket.unsortedID, "Unsorted for a new one")
        // A block that is not visible offers no target.
        view.visibilityProbe = { _ in false }
        view.refreshVisibility()
        #expect(CodeDropTile.target(in: view, atScreenPoint: try headerPoint(view, toy, window)) == nil)
    }

    @Test func theSlotOutlinesTheBucketAndAParkMovesTheSession() throws {
        let (h, toy, view, window) = scene()
        defer { window.close() }
        let drop = CodeDragToPark(claims: RecordingClaims(), parker: FakeDropParker(), desk: { [] },
                                  processes: { [] }, stripRegions: { [] }, conditions: CodeDragToParkConditions(),
                                  system: FakeDragSystem(), label: FakeDropLabel())
        drop.attach(tile: view)
        let target = CodeDropTarget(bucketID: toy, bucketName: "Toy Cube")
        drop.onSlotChange?(CodeDropSlot(sessionID: "local_u1", target: target))
        #expect(view.externalDropTarget == toy)
        let placed = try #require(view.placedBuckets.first { $0.id == toy })
        #expect(!view.dropOutline.isHidden)
        #expect(view.dropOutline.frame == view.scrolledStackFrame(placed.area).insetBy(dx: 0, dy: -4))
        drop.onSlotChange?(nil)
        #expect(view.externalDropTarget == nil)
        #expect(view.dropOutline.isHidden)
        drop.onParked?("local_u1", target)
        #expect(h.layout[toy] == ["local_u1", "local_t1"], "at its first-seen place")
        drop.onParked?("local_u1", target)
        #expect(h.layout[toy] == ["local_u1", "local_t1"], "already there: nothing moves")
        #expect(h.parker.performed.isEmpty, "moving between buckets touches no window")
    }

    /// The whole drop on the block: a pop-out dragged over the Toy Cube bucket arms with "Drop to pit in Toy Cube",
    /// outlines that bucket, parks, and its session lands in Toy Cube.
    @Test func aPopOutDroppedOverABucketParksIntoIt() throws {
        let (h, toy, view, window) = scene()
        defer { window.close() }
        let system = FakeDragSystem()
        let parker = FakeDropParker()
        let label = FakeDropLabel()
        // The strip is where the block's window is (AppKit 0…992 × 0…798 on a 1440 pt high display, in Quartz).
        let strip = ReservedRegion(displayID: 1, rect: CGRect(x: 0, y: 1440 - 798, width: 992, height: 798), edge: .right)
        let drop = CodeDragToPark(claims: RecordingClaims(), parker: parker, desk: { parker.deskPopouts },
                                  processes: { [ClaudeProcessInfo(pid: 4242, profile: .a)] }, stripRegions: { [strip] },
                                  conditions: CodeDragToParkConditions(dragToPark: true, stripShown: true), system: system,
                                  label: label)
        drop.attach(tile: view)
        system.windows = [CodeDragWindow(number: 77, pid: 4242, bounds: DropFixture.desk, layer: 0, alpha: 1)]
        parker.deskPopouts = [CodeDropPopout(sessionID: "local_u1", index: 1, pid: 4242, windowNumber: 77)]
        drop.refresh()
        let over = system.quartzPoint(fromAppKit: try headerPoint(view, toy, window))
        system.press(at: DropFixture.grab)
        for _ in 0..<12 {
            system.move(77, dx: (over.x - DropFixture.grab.x) / 12, dy: (over.y - DropFixture.grab.y) / 12)
            system.advance(1.0 / 30)
        }
        system.advance(0.4)
        #expect(label.shown?.text == "Drop to pit in Toy Cube")
        #expect(view.externalDropTarget == toy, "the bucket's outline")
        system.release()
        #expect(view.externalDropTarget == nil)
        system.advance(0.07)
        #expect(parker.parks.first?.frame == DropFixture.desk)
        parker.answer(0, .parked)
        #expect(h.layout[toy] == ["local_u1", "local_t1"])
        drop.stop()
    }
}
