import CoreGraphics
import PitboxKit
import Testing
@testable import PitboxGuard

/// Regression: corrections caused by the user resizing the strip were counted as the app fighting the guard, so after
/// three widenings in 10 s the window beside the strip was left under it.
@Suite("Engine: strip width changes")
struct WidthRegionFightTests {
    private static func rightStrip(innerEdge x: CGFloat) -> ReservedRegion {
        ReservedRegion(displayID: 1, rect: CGRect(x: x, y: 30, width: 5120 - x, height: 1312), edge: .right)
    }

    /// Four widenings of 100 pt, two seconds apart (slider releases, typed widths left for 1 s, handle drags).
    @Test func wideningTheStripAFewTimesDoesNotPutTheNeighbourOnACooldown() {
        let sim = Simulation([FakeWindow(1, Fixture.besideRightStrip)])
        sim.run(until: 0.5)
        #expect(sim.sets.isEmpty, "the window already ends at the strip")
        var edge: CGFloat = 3840
        for _ in 1...4 {
            edge -= 100
            sim.engine.setRegions([Self.rightStrip(innerEdge: edge)], now: sim.now)
            sim.run(for: 2)
            #expect(sim.frame(1)?.maxX == edge, "the window ends at the widened strip")
        }
        #expect(sim.engine.fightingCount(now: sim.now) == 0, "no window is on a fight cooldown")
        #expect(!sim.logs.contains { $0.contains("keeps ending up over the block") })
    }
}
