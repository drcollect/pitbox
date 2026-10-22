import CoreGraphics
import PitboxKit
import Testing
@testable import PitboxGuard

// Push by edge, never by midpoint (docs/DOCK_PROTOCOL.md §7): docked, the block sits inboard, directly beside a host
// app's strip on the same edge. On a notebook the docked area is wider than half the display, so the block's middle
// lies left of the display's middle; the old midpoint rule pushed windows from there into the host's strip.

/// A 14-inch notebook: 1512 pt wide, menu bar 38 pt, Dock hidden.
private let notebook = CGRect(x: 0, y: 38, width: 1512, height: 944)
/// The host's strip at the right edge (470 pt) and the block docked left of it (two columns, 631 pt).
private let hostRight = CGRect(x: 1042, y: 38, width: 470, height: 944)
private let blockRight = CGRect(x: 411, y: 38, width: 631, height: 944)
/// The mirror: host at the left edge, block right of it.
private let hostLeft = CGRect(x: 0, y: 38, width: 470, height: 944)
private let blockLeft = CGRect(x: 470, y: 38, width: 631, height: 944)
private let minSize = CGSize(width: 320, height: 200)

private func fix(_ window: CGRect, _ region: CGRect, _ edge: Edge, screen: CGRect = notebook, resizable: Bool = true,
                 movable: Bool = true, min: CGSize = minSize) -> Placement.Correction? {
    Placement.correct(windowFrame: window, region: region, edge: edge, screenBounds: screen, minSize: min,
                      resizable: resizable, movable: movable)
}

@Suite("Placement: pushed by edge beside a host's strip")
struct PlacementDockedTests {
    @Test func inboardRegionLeftOfTheMiddlePushesToTheWindowSide() throws {
        #expect(blockRight.midX < notebook.midX, "the case the midpoint rule got wrong")
        #expect(Placement.pushDirection(region: blockRight, edge: .right, screenBounds: notebook) == .towardMinX)

        let zoomed = try #require(fix(notebook, blockRight, .right))
        #expect(zoomed.frame == CGRect(x: 0, y: 38, width: 411, height: 944))
        #expect(zoomed.action == .shrink)
        #expect(zoomed.fits)

        let straddling = try #require(fix(CGRect(x: 211, y: 100, width: 1031, height: 500), blockRight, .right))
        #expect(straddling.frame == CGRect(x: 0, y: 100, width: 411, height: 500))
        #expect(straddling.action == .moveAndShrink)

        let small = CGRect(x: 500, y: 100, width: 350, height: 400)
        let inside = try #require(fix(small, blockRight, .right))
        #expect(inside.frame == CGRect(x: 61, y: 100, width: 350, height: 400))
        #expect(inside.action == .move)

        for c in [zoomed, straddling, inside] {
            #expect(c.frame.maxX <= blockRight.minX, "ends at the block's window side")
            #expect(!Placement.overlaps(c.frame, hostRight), "never pushed into the host's strip")
        }
        // What the midpoint rule did here (it chose "start after the block"): straight into the host's strip.
        let old = try #require(fix(small, blockRight, .left))
        #expect(old.frame == CGRect(x: 1042, y: 100, width: 350, height: 400))
        #expect(Placement.overlaps(old.frame, hostRight))
    }

    @Test func leftEdgeMirrorPushesRight() throws {
        #expect(blockLeft.midX > notebook.midX, "the midpoint rule would push left, into the host's strip")
        #expect(Placement.pushDirection(region: blockLeft, edge: .left, screenBounds: notebook) == .towardMaxX)

        let zoomed = try #require(fix(notebook, blockLeft, .left))
        #expect(zoomed.frame == CGRect(x: 1101, y: 38, width: 411, height: 944), "right edge stays put")
        #expect(zoomed.action == .shrink)

        let inside = try #require(fix(CGRect(x: 600, y: 100, width: 350, height: 400), blockLeft, .left))
        #expect(inside.frame == CGRect(x: 1101, y: 100, width: 350, height: 400))
        #expect(inside.action == .move)

        let wide = try #require(fix(CGRect(x: 540, y: 100, width: 500, height: 400), blockLeft, .left))
        #expect(wide.frame == CGRect(x: 1101, y: 100, width: 411, height: 400), "slid to the free space and narrowed")
        #expect(wide.action == .moveAndShrink)

        for c in [zoomed, inside, wide] {
            #expect(c.frame.minX >= blockLeft.maxX)
            #expect(!Placement.overlaps(c.frame, hostLeft))
            #expect(c.fits)
        }
    }

    /// The fallbacks are the ones a strip touching the edge with the same free space gets today: an inboard region
    /// only changes the direction, never the preference order.
    @Test func windowTooWideForTheSpaceLeftFallsBackAsToday() throws {
        let edgeStrip = CGRect(x: 411, y: 38, width: 1101, height: 944)   // the whole docked area as one strip
        let rigid = CGRect(x: 300, y: 100, width: 1000, height: 500)
        let a = try #require(fix(rigid, blockRight, .right, resizable: false))
        #expect(a.frame == CGRect(x: 0, y: 100, width: 1000, height: 500), "as far left as the screen allows")
        #expect(!a.fits)
        #expect(a == fix(rigid, edgeStrip, .right, resizable: false))

        let stubborn = CGRect(x: 300, y: 100, width: 800, height: 500)
        let wideMinimum = CGSize(width: 500, height: 200)
        let b = try #require(fix(stubborn, blockRight, .right, min: wideMinimum))
        #expect(b.frame == CGRect(x: 0, y: 100, width: 500, height: 500), "never below the minimum width")
        #expect(!b.fits)
        #expect(b == fix(stubborn, edgeStrip, .right, min: wideMinimum))

        let pinned = try #require(fix(rigid, blockRight, .right, resizable: false, movable: false))
        #expect(pinned.frame == rigid)
        #expect(pinned.action == .none)

        for c in [a, b] { #expect(c.frame.maxX <= 1300, "a window that cannot fit never moves toward the host") }
    }

    /// The one exception to "by edge": a window that belongs to the next display, past the screen edge the region
    /// belongs to, goes back onto that display.
    @Test func windowFromTheDisplayBeyondTheEdgeGoesBackToIt() throws {
        let main = Fixture.main.visibleFrame                                   // x 0..5120
        let beyondRight = CGRect(x: 5120, y: 25, width: 1920, height: 1055)
        let beyondLeft = CGRect(x: -1920, y: 25, width: 1920, height: 1055)
        let block = CGRect(x: 2902, y: 30, width: 631, height: 1312)          // docked beside a 1587 pt host strip
        #expect(Placement.pushDirection(region: Fixture.rightStrip.rect, edge: .right, screenBounds: main)
                == .towardMinX)
        #expect(Placement.pushDirection(region: Fixture.rightStrip.rect, edge: .right, screenBounds: beyondRight)
                == .towardMaxX)
        #expect(Placement.pushDirection(region: block, edge: .right, screenBounds: beyondRight) == .towardMaxX)
        #expect(Placement.pushDirection(region: block, edge: .right, screenBounds: beyondLeft) == .towardMinX)
        #expect(Placement.pushDirection(region: Fixture.leftStrip.rect, edge: .left, screenBounds: main) == .towardMaxX)
        #expect(Placement.pushDirection(region: Fixture.leftStrip.rect, edge: .left, screenBounds: beyondLeft)
                == .towardMinX)

        let left = GuardDisplay(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                visibleFrame: beyondLeft)
        let c = try #require(Placement.resolve(windowFrame: CGRect(x: -1500, y: 100, width: 1800, height: 800),
                                               regions: [Fixture.leftStrip], displays: [Fixture.main, left],
                                               minSize: minSize, resizable: true))
        #expect(c.frame == CGRect(x: -1500, y: 100, width: 1500, height: 800), "narrowed back onto its own display")
        #expect(c.fits)
    }

    /// Both regions of the docked area in one `resolve` (as a guard reserving the whole area would): one pass, the
    /// same direction for both.
    @Test func bothRegionsOfTheDockedAreaPushTheSameWay() throws {
        let display = GuardDisplay(id: 7, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: notebook)
        let regions = [ReservedRegion(displayID: 7, rect: hostRight, edge: .right),
                       ReservedRegion(displayID: 7, rect: blockRight, edge: .right)]
        let c = try #require(Placement.resolve(windowFrame: CGRect(x: 900, y: 100, width: 500, height: 400),
                                               regions: regions, displays: [display], minSize: minSize,
                                               resizable: true))
        #expect(c.frame == CGRect(x: 0, y: 100, width: 411, height: 400))
        #expect(c.fits)
    }

    /// Random regions anywhere on the display (inboard or at the edge), random edges: every invariant of
    /// `PlacementPropertyTests` holds, and a window is never pushed toward the region's edge (the host's side).
    @Test func randomInboardRegionsNeverPushTowardTheirEdge() {
        var g = PlacementPropertyTests.Generator(state: 0xD0C4)
        var corrected = 0, fitted = 0
        for _ in 0..<20_000 {
            let s = CGRect(x: g.int(-3000...3000), y: g.int(-500...500), width: g.int(400...6000),
                           height: g.int(300...2000))
            let regionWidth = CGFloat(max(24, Int(s.width * CGFloat(g.int(2...60)) / 100)))
            let r = CGRect(x: s.minX + CGFloat(g.int(0...Int(s.width - regionWidth))), y: s.minY, width: regionWidth,
                           height: s.height)
            let edge: Edge = g.bool() ? .right : .left
            let width = g.int(50...Int(s.width * 1.3))
            let w = CGRect(x: g.int(Int(s.minX) - width / 2...Int(s.maxX) - width / 2),
                           y: g.int(Int(s.minY)...Int(s.maxY) - 40), width: width, height: g.int(40...Int(s.height)))
            let resizable = g.bool(), movable = g.bool()
            let minWidth = CGFloat(g.int(100...800))
            let fraction = CGFloat(g.int(0...10)) / 10
            guard let c = Placement.correct(windowFrame: w, region: r, edge: edge, screenBounds: s,
                                            minSize: CGSize(width: minWidth, height: 200), resizable: resizable,
                                            movable: movable, minShrinkFraction: fraction) else {
                #expect(!Placement.overlaps(w, r), "nil only when there is nothing to fix: \(w) \(r)")
                continue
            }
            corrected += 1
            let f = c.frame
            let context = "window \(w) region \(r) \(edge) screen \(s) resizable \(resizable) movable \(movable) "
                + "min \(minWidth)"
            if edge == .right {
                #expect(f.minX <= w.minX && f.maxX <= w.maxX, "never toward the right edge: \(context)")
            } else {
                #expect(f.minX >= w.minX && f.maxX >= w.maxX, "never toward the left edge: \(context)")
            }
            #expect(f.minY == w.minY && f.height == w.height, "never changes y or height: \(context)")
            #expect(f.width <= w.width, "never grows: \(context)")
            #expect(f.width >= min(w.width, minWidth), "never below the minimum: \(context)")
            if !resizable { #expect(f.width == w.width, "\(context)") }
            #expect(f.minX >= min(s.minX, w.minX) && f.maxX <= max(s.maxX, w.maxX),
                    "never pushed further off-screen: \(context)")
            #expect(f.minX == f.minX.rounded() && f.width == f.width.rounded(), "whole points: \(context)")
            #expect(c.fits == !Placement.overlaps(f, r), "fits is truthful: \(context)")
            #expect(c.action == Placement.action(from: w, to: f), "\(context)")
            // Completeness: whenever a fitting frame exists on the window side within the rules, one is found.
            let possible: Bool
            if edge == .right {
                let free = r.minX - min(s.minX, w.minX)
                possible = (movable && (resizable ? free >= min(w.width, minWidth) : free >= w.width))
                    || (resizable && r.minX - w.minX >= minWidth)
            } else {
                let free = max(s.maxX, w.maxX) - r.maxX
                possible = movable && (resizable ? free >= min(w.width, minWidth) : free >= w.width)
            }
            if possible { #expect(c.fits, "a fitting frame exists: \(context)") }
            if c.fits { fitted += 1 }
        }
        #expect(corrected > 5_000)
        #expect(fitted > 3_000)
    }
}
