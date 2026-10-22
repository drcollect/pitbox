import AppKit
import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The rail's spring-loaded unfold: while the block is folded, drag-to-pit watches pop-out drags
/// only to say when one hovers the rail (nothing is claimed, armed or parked there); after the unfold the same drag arms
/// over the block as any other. Fakes only.
@MainActor
@Suite("Drag-to-park: the rail's spring-loaded unfold")
struct DragToParkRailTests {
    init() { CodeTileLog.enabled = false }

    /// The published region, as the panel changes it (the rail while folded, the block after the unfold).
    final class Regions {
        var rects: [ReservedRegion]
        init(_ rects: [ReservedRegion]) { self.rects = rects }
    }

    /// The 24 pt rail at the right edge of the fixture's display (Quartz).
    static let rail = ReservedRegion(displayID: 1, rect: CGRect(x: 5096, y: 30, width: 24, height: 1312), edge: .right)

    @MainActor
    struct Rig {
        let system = FakeDragSystem()
        let parker = FakeDropParker()
        let claims = RecordingClaims()
        let label = FakeDropLabel()
        let regions = Regions([DragToParkRailTests.rail])
        let controller: CodeDragToPark
        let hovers = HoverBox()

        init(conditions: CodeDragToParkConditions = CodeDragToParkConditions(dragToPark: true, stripShown: false,
                                                                              railShown: true)) {
            let parker = self.parker
            let regions = self.regions
            controller = CodeDragToPark(claims: claims, parker: parker, desk: { parker.deskPopouts },
                                        processes: { [ClaudeProcessInfo(pid: 4242, profile: .a)] },
                                        stripRegions: { regions.rects }, conditions: conditions, system: system, label: label)
            system.windows = [CodeDragWindow(number: 77, pid: 4242, bounds: DropFixture.desk, layer: 0, alpha: 1)]
            parker.deskPopouts = [DropFixture.popout]
            controller.ownBucket = { _ in DropFixture.unsorted }
            let hovers = self.hovers
            controller.onRailHover = { hovers.values.append($0) }
            controller.refresh()
        }

        /// Presses the title bar and drags the window until the pointer is at x = `to` (Quartz), 30 polls a second.
        func drag(to x: CGFloat) {
            system.press(at: DropFixture.grab)
            for _ in 0..<12 {
                system.move(77, dx: (x - DropFixture.grab.x) / 12)
                system.advance(1.0 / 30)
            }
        }
    }

    @MainActor
    final class HoverBox {
        var values: [Bool] = []
    }

    @Test func aDragOverTheRailSpringLoadsItAndArmsAfterTheUnfold() throws {
        let rig = Rig()
        #expect(rig.system.repeatingTimers == [1] && rig.system.monitorsInstalled, "folded: drags are still watched")
        rig.drag(to: 5100)
        rig.system.advance(0.3)
        #expect(rig.hovers.values == [true], "the pointer is over the rail with a pop-out")
        #expect(rig.claims.log == ["claimable [4242]"], "nothing is claimed over the rail")
        #expect(rig.label.shown == nil, "no drop label over the rail")
        // The rail's 0.6 s timer fired: the panel unfolds (its region becomes the block's) and the app tells the drop.
        rig.regions.rects = [DragRig.strip]
        rig.controller.setRailShown(false)
        rig.controller.setStripVisible(true)
        #expect(rig.hovers.values == [true, false])
        rig.system.advance(0.4)
        #expect(rig.claims.log.last == "claim 4242 77", "the same drag arms over the block")
        #expect(rig.label.shown?.text == "Drop to pit in Unsorted")
        rig.system.release()
        rig.system.advance(0.07)
        let park = try #require(rig.parker.parks.first)
        #expect(park.frame == DropFixture.desk, "the frame from before the drag")
    }

    @Test func leavingTheRailEndsTheHoverAndAReleaseThereDoesNothing() {
        let rig = Rig()
        rig.drag(to: 5100)
        #expect(rig.hovers.values == [true])
        rig.system.move(77, dx: -800)
        rig.system.advance(1.0 / 30)
        #expect(rig.hovers.values == [true, false])
        rig.system.move(77, dx: 800)
        rig.system.advance(1.0 / 30)
        #expect(rig.hovers.values == [true, false, true])
        rig.system.release()
        rig.system.advance(1)
        #expect(rig.hovers.values == [true, false, true, false], "the release ends the hover")
        #expect(rig.parker.parks.isEmpty && rig.claims.log == ["claimable [4242]"], "nothing parks on the rail")
        #expect(rig.system.repeatingTimers == [1], "the 30 Hz poll stopped")
    }

    @Test func hiddenOrOffWatchesNothing() {
        let rig = Rig(conditions: CodeDragToParkConditions(dragToPark: true, stripShown: false, railShown: false))
        #expect(rig.system.repeatingTimers.isEmpty && !rig.system.monitorsInstalled, "hidden: nothing runs")
        rig.controller.setRailShown(true)
        #expect(rig.system.repeatingTimers == [1])
        var off = CodeSettings()
        off.dragToPark = false
        rig.controller.update(settings: off)
        #expect(rig.system.repeatingTimers.isEmpty && !rig.system.monitorsInstalled, "drag-to-pit off: nothing runs")
        #expect(!CodeDragToParkConditions(dragToPark: true, stripShown: false, railShown: true).allowsArming)
        #expect(CodeDragToParkConditions(dragToPark: true, stripShown: false, railShown: true).watchesDrags)
    }

    @Test func stoppingEndsAHover() {
        let rig = Rig()
        rig.drag(to: 5100)
        #expect(rig.hovers.values == [true])
        rig.controller.stop()
        #expect(rig.hovers.values == [true, false])
    }
}
