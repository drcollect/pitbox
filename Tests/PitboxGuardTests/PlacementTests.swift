import CoreGraphics
import PitboxKit
import Testing
@testable import PitboxGuard

private let screen = Fixture.visible                                   // (0, 30, 5120, 1312)
private let right = Fixture.rightStrip.rect                           // (3840, 30, 1280, 1312)
private let left = Fixture.leftStrip.rect                             // (0, 30, 1280, 1312)
private let minSize = CGSize(width: 320, height: 200)

/// `edge` is the screen edge the strip belongs to; windows are pushed toward the other side.
private func fix(_ window: CGRect, _ region: CGRect = right, _ edge: Edge = .right, screen s: CGRect = screen,
                 resizable: Bool = true, movable: Bool = true, fraction: CGFloat = 0.5,
                 min: CGSize = minSize) -> Placement.Correction? {
    Placement.correct(windowFrame: window, region: region, edge: edge, screenBounds: s, minSize: min,
                      resizable: resizable, movable: movable, minShrinkFraction: fraction)
}

@Suite("Placement: strip on the right")
struct RightStripTests {
    @Test func windowsClearOfTheStripAreLeftAlone() {
        #expect(fix(CGRect(x: 100, y: 100, width: 800, height: 600)) == nil)
        #expect(fix(CGRect(x: 3040, y: 100, width: 800, height: 600)) == nil, "touching the edge")
        #expect(fix(CGRect(x: 3041, y: 100, width: 800, height: 600)) == nil, "1 pt overlap is within tolerance")
        #expect(fix(CGRect(x: 3042, y: 100, width: 800, height: 600)) != nil)
        #expect(fix(CGRect(x: 3900, y: 1350, width: 400, height: 80)) == nil, "below the strip, in the Dock area")
    }

    @Test func straddlingWindowIsNarrowedToTheEdge() throws {
        let c = try #require(fix(CGRect(x: 1000, y: 100, width: 3000, height: 900)))
        #expect(c.frame == CGRect(x: 1000, y: 100, width: 2840, height: 900))
        #expect(c.action == .shrink)
        #expect(c.fits)
    }

    @Test func maximizedWindowStopsAtTheStrip() throws {
        let c = try #require(fix(Fixture.zoomed))
        #expect(c.frame == Fixture.besideRightStrip)
        #expect(c.action == .shrink)
    }

    @Test func windowFullyInsideIsMovedOutAtFullSize() throws {
        let c = try #require(fix(CGRect(x: 4000, y: 200, width: 600, height: 400)))
        #expect(c.frame == CGRect(x: 3240, y: 200, width: 600, height: 400))
        #expect(c.action == .move)
        #expect(c.fits)
    }

    @Test func windowMostlyInsideSlidesInsteadOfBecomingASliver() throws {
        let window = CGRect(x: 3500, y: 100, width: 1500, height: 800)
        let slid = try #require(fix(window))
        #expect(slid.frame == CGRect(x: 2340, y: 100, width: 1500, height: 800))
        #expect(slid.action == .move)
        let cut = try #require(fix(window, fraction: 0))
        #expect(cut.frame == CGRect(x: 3500, y: 100, width: 340, height: 800), "fraction 0 always prefers shrinking")
    }

    @Test func nonResizableWindowIsMoved() throws {
        let c = try #require(fix(CGRect(x: 1000, y: 100, width: 3000, height: 900), resizable: false))
        #expect(c.frame == CGRect(x: 840, y: 100, width: 3000, height: 900))
        #expect(c.action == .move)
    }

    @Test func nonResizableWindowWiderThanTheFreeSpaceCannotFit() throws {
        let c = try #require(fix(CGRect(x: 500, y: 100, width: 4000, height: 900), resizable: false))
        #expect(c.frame == CGRect(x: 0, y: 100, width: 4000, height: 900), "as far left as the screen allows")
        #expect(!c.fits)
    }

    @Test func resizableWindowWiderThanTheFreeSpaceIsNarrowed() throws {
        let c = try #require(fix(CGRect(x: 0, y: 100, width: 5000, height: 900)))
        #expect(c.frame == CGRect(x: 0, y: 100, width: 3840, height: 900))
    }

    @Test func narrowingBelowTheMinimumMovesInstead() throws {
        let c = try #require(fix(CGRect(x: 3700, y: 100, width: 400, height: 300)))
        #expect(c.frame == CGRect(x: 3440, y: 100, width: 400, height: 300))
        #expect(c.action == .move)
    }

    @Test func narrowsBelowTheFractionWhenSlidingCannotWork() throws {
        // Wider than the free space, so it cannot slide; narrowing keeps only 46%, which is still the best option.
        let c = try #require(fix(CGRect(x: 2000, y: 100, width: 4000, height: 900)))
        #expect(c.frame == CGRect(x: 2000, y: 100, width: 1840, height: 900))
        #expect(c.action == .shrink)
        #expect(c.fits)
    }

    @Test func slidesToTheScreenEdgeAndNarrowsWhenNothingElseWorks() throws {
        // Narrowing in place would go below the minimum and it is too wide to slide: use all of the free space.
        let c = try #require(fix(CGRect(x: 3700, y: 100, width: 4000, height: 900)))
        #expect(c.frame == CGRect(x: 0, y: 100, width: 3840, height: 900))
        #expect(c.action == .moveAndShrink)
        #expect(c.fits)
    }

    @Test func notMovableButResizableShrinksInPlace() throws {
        let c = try #require(fix(CGRect(x: 1000, y: 100, width: 3000, height: 900), movable: false))
        #expect(c.frame == CGRect(x: 1000, y: 100, width: 2840, height: 900))
    }

    @Test func neitherMovableNorResizableIsReportedAsCannotFit() throws {
        let window = CGRect(x: 3500, y: 100, width: 800, height: 600)
        let c = try #require(fix(window, resizable: false, movable: false))
        #expect(c.frame == window)
        #expect(c.action == .none)
        #expect(!c.fits)
    }

    @Test func alreadyOffScreenWindowIsNeverPushedFurtherOut() throws {
        let small = CGRect(x: 0, y: 30, width: 1280, height: 700)
        let strip = CGRect(x: 960, y: 30, width: 320, height: 700)
        let c = try #require(fix(CGRect(x: -300, y: 100, width: 1400, height: 500), strip, screen: small,
                                 resizable: false))
        #expect(c.frame.minX == -300)
        #expect(!c.fits)
    }

    @Test func fractionalStripEdgeGivesWholePointsThatClearIt() throws {
        let laptop = CGRect(x: 0, y: 30, width: 1366, height: 700)
        let strip = CGRect(x: 1024.5, y: 30, width: 341.5, height: 700)
        let c = try #require(fix(CGRect(x: 100, y: 100, width: 1100, height: 500), strip, screen: laptop))
        #expect(c.frame == CGRect(x: 100, y: 100, width: 924, height: 500))
        #expect(c.frame.maxX <= strip.minX)
    }
}

@Suite("Placement: strip on the left")
struct LeftStripTests {
    @Test func straddlingWindowIsNarrowedFromTheLeft() throws {
        let c = try #require(fix(CGRect(x: 500, y: 100, width: 2500, height: 900), left, .left))
        #expect(c.frame == CGRect(x: 1280, y: 100, width: 1720, height: 900), "right edge stays put")
        #expect(c.action == .shrink)
    }

    @Test func maximizedWindowStartsAtTheStrip() throws {
        let c = try #require(fix(Fixture.zoomed, left, .left))
        #expect(c.frame == CGRect(x: 1280, y: 30, width: 3840, height: 1312))
    }

    @Test func windowFullyInsideIsMovedRight() throws {
        let c = try #require(fix(CGRect(x: 100, y: 200, width: 800, height: 400), left, .left))
        #expect(c.frame == CGRect(x: 1280, y: 200, width: 800, height: 400))
        #expect(c.action == .move)
    }

    @Test func narrowingFromTheLeftNeedsAMovableWindow() throws {
        let window = CGRect(x: 500, y: 100, width: 2500, height: 900)
        let c = try #require(fix(window, left, .left, movable: false))
        #expect(c.frame == window)
        #expect(!c.fits)
    }

    @Test func nonResizableWindowWiderThanTheFreeSpaceHugsTheRightEdge() throws {
        let c = try #require(fix(CGRect(x: 100, y: 100, width: 4500, height: 900), left, .left, resizable: false))
        #expect(c.frame == CGRect(x: 620, y: 100, width: 4500, height: 900))
        #expect(!c.fits)
    }
}

@Suite("Placement: small screens, several displays, odd strips")
struct PlacementEdgeCaseTests {
    private let tiny = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let tinyStrip = CGRect(x: 300, y: 0, width: 100, height: 300)

    @Test func tinyScreenWhereNothingFitsGetsAsCloseAsPossible() throws {
        let c = try #require(fix(CGRect(x: 0, y: 20, width: 400, height: 250), tinyStrip, screen: tiny))
        #expect(c.frame == CGRect(x: 0, y: 20, width: 320, height: 250), "never below the minimum width")
        #expect(!c.fits)
    }

    @Test func tinyScreenSmallWindowSlides() throws {
        let c = try #require(fix(CGRect(x: 150, y: 20, width: 250, height: 200), tinyStrip, screen: tiny))
        #expect(c.frame == CGRect(x: 50, y: 20, width: 250, height: 200))
        #expect(c.fits)
    }

    @Test func negativeCoordinatesOnADisplayLeftOfTheMainOne() throws {
        let screenB = CGRect(x: -1920, y: 25, width: 1920, height: 1055)
        let leftB = CGRect(x: -1920, y: 25, width: 480, height: 1055)
        let a = try #require(fix(CGRect(x: -1800, y: 100, width: 800, height: 600), leftB, .left, screen: screenB))
        #expect(a.frame == CGRect(x: -1440, y: 100, width: 440, height: 600))
        let rightB = CGRect(x: -480, y: 25, width: 480, height: 1055)
        let b = try #require(fix(CGRect(x: -1000, y: 100, width: 800, height: 600), rightB, screen: screenB))
        #expect(b.frame == CGRect(x: -1000, y: 100, width: 520, height: 600))
    }

    @Test func windowMostlyOnTheNextDisplayIsPushedBackOntoIt() throws {
        let second = GuardDisplay(id: 2, frame: CGRect(x: 5120, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 5120, y: 25, width: 1920, height: 1055))
        let c = try #require(Placement.resolve(windowFrame: CGRect(x: 5000, y: 100, width: 1500, height: 800),
                                               regions: [Fixture.rightStrip], displays: [Fixture.main, second],
                                               minSize: minSize, resizable: true))
        #expect(c.frame == CGRect(x: 5120, y: 100, width: 1380, height: 800))
        #expect(c.fits)
    }

    @Test func windowOnAnotherDisplayIsUnaffected() {
        let second = GuardDisplay(id: 2, frame: CGRect(x: 5120, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 5120, y: 25, width: 1920, height: 1055))
        #expect(Placement.resolve(windowFrame: CGRect(x: 5300, y: 100, width: 1500, height: 800),
                                  regions: [Fixture.rightStrip], displays: [Fixture.main, second], minSize: minSize,
                                  resizable: true) == nil)
    }

    @Test func stripShorterThanTheWindow() throws {
        let short = CGRect(x: 3840, y: 30, width: 1280, height: 600)
        #expect(fix(CGRect(x: 3000, y: 700, width: 1000, height: 400), short) == nil, "entirely below the strip")
        let c = try #require(fix(CGRect(x: 3000, y: 500, width: 1000, height: 400), short))
        #expect(c.frame.maxX <= 3840)
    }

    @Test func stripTallerThanTheWindow() throws {
        let inside = try #require(fix(CGRect(x: 3900, y: 300, width: 600, height: 200)))
        #expect(inside.frame == CGRect(x: 3240, y: 300, width: 600, height: 200))
        let straddling = try #require(fix(CGRect(x: 3500, y: 300, width: 600, height: 200)))
        #expect(straddling.frame == CGRect(x: 3500, y: 300, width: 340, height: 200), "keeps 57%: narrowed")
    }

    @Test func stripsOnBothEdgesSqueezeTheWindowBetweenThem() throws {
        let c = try #require(Placement.resolve(windowFrame: Fixture.zoomed,
                                               regions: [Fixture.leftStrip, Fixture.rightStrip],
                                               displays: [Fixture.main], minSize: minSize, resizable: true))
        #expect(c.frame == CGRect(x: 1280, y: 30, width: 2560, height: 1312))
        #expect(c.fits)
        #expect(c.action == .moveAndShrink)
    }

    @Test func homeDisplayIsTheOneWithMostOfTheWindow() {
        let second = GuardDisplay(id: 2, frame: CGRect(x: 5120, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 5120, y: 25, width: 1920, height: 1055))
        let displays = [Fixture.main, second]
        #expect(Placement.homeDisplay(for: CGRect(x: 4000, y: 0, width: 1500, height: 500), displays: displays)?.id == 1)
        #expect(Placement.homeDisplay(for: CGRect(x: 5000, y: 0, width: 1500, height: 500), displays: displays)?.id == 2)
        #expect(Placement.homeDisplay(for: CGRect(x: 9000, y: 0, width: 100, height: 100), displays: displays) == nil)
        #expect(Placement.homeDisplay(for: CGRect(x: 5020, y: 0, width: 200, height: 100), displays: displays)?.id == 1,
                "a tie goes to the first display")
    }

    @Test func coversDisplayDetectsNonNativeFullScreen() {
        #expect(Placement.coversDisplay(Fixture.main.frame, Fixture.main))
        #expect(!Placement.coversDisplay(Fixture.visible, Fixture.main))
    }

    @Test func garbageInputIsIgnored() {
        #expect(fix(CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)) == nil)
        #expect(fix(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)) == nil)
        #expect(fix(CGRect(x: 3900, y: 100, width: 0, height: 100)) == nil)
        #expect(fix(CGRect(x: 3900, y: 100, width: 500, height: 500), screen: .zero) == nil)
    }
}

/// Invariants over thousands of random screens, strips and windows (seeded, so failures reproduce).
@Suite("Placement: properties")
struct PlacementPropertyTests {
    struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 11
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
        mutating func bool() -> Bool { next() % 2 == 0 }
    }

    @Test func invariantsHoldForRandomCases() {
        var g = Generator(state: 0x5EED)
        var corrected = 0, fitted = 0
        for _ in 0..<20_000 {
            let s = CGRect(x: g.int(-3000...3000), y: g.int(-500...500), width: g.int(400...6000),
                           height: g.int(300...2000))
            let stripWidth = CGFloat(Int(s.width * CGFloat(g.int(10...40)) / 100))
            let onRight = g.bool()
            let r = CGRect(x: onRight ? s.maxX - stripWidth : s.minX, y: s.minY, width: stripWidth, height: s.height)
            let width = g.int(50...Int(s.width * 1.3))
            let w = CGRect(x: g.int(Int(s.minX) - width / 2...Int(s.maxX) - width / 2), y: g.int(Int(s.minY)...Int(s.maxY) - 40),
                           width: width, height: g.int(40...Int(s.height)))
            let resizable = g.bool(), movable = g.bool()
            let minWidth = CGFloat(g.int(100...800))
            let fraction = CGFloat(g.int(0...10)) / 10
            let result = Placement.correct(windowFrame: w, region: r, edge: onRight ? .right : .left,
                                           screenBounds: s, minSize: CGSize(width: minWidth, height: 200),
                                           resizable: resizable, movable: movable, minShrinkFraction: fraction)
            guard let c = result else {
                #expect(!Placement.overlaps(w, r), "nil only when there is nothing to fix: \(w) \(r)")
                continue
            }
            corrected += 1
            let f = c.frame
            let context = "window \(w) strip \(r) screen \(s) resizable \(resizable) movable \(movable) min \(minWidth)"
            #expect(f.minY == w.minY && f.height == w.height, "never changes y or height: \(context)")
            #expect(f.width <= w.width, "never grows: \(context)")
            #expect(f.width >= min(w.width, minWidth), "never below the minimum: \(context)")
            if !resizable { #expect(f.width == w.width, "\(context)") }
            if !movable, !onRight { #expect(f == w, "\(context)") }
            if !movable, onRight { #expect(f.minX == w.minX, "\(context)") }
            #expect(f.minX >= min(s.minX, w.minX) && f.maxX <= max(s.maxX, w.maxX),
                    "never pushed further off-screen: \(context)")
            #expect(f.minX == f.minX.rounded() && f.width == f.width.rounded(), "whole points: \(context)")
            #expect(c.fits == !Placement.overlaps(f, r), "fits is truthful: \(context)")
            #expect(c.action == Placement.action(from: w, to: f), "\(context)")
            // Completeness: whenever a fitting frame exists within the rules, one is found.
            let free = onRight ? r.minX - min(s.minX, w.minX) : max(s.maxX, w.maxX) - r.maxX
            let possible: Bool
            if onRight {
                possible = (movable && (resizable ? free >= min(w.width, minWidth) : free >= w.width))
                    || (resizable && r.minX - w.minX >= minWidth)
            } else {
                possible = movable && (resizable ? free >= min(w.width, minWidth) : free >= w.width)
            }
            if possible { #expect(c.fits, "a fitting frame exists: \(context)") }
            if c.fits { fitted += 1 }
        }
        #expect(corrected > 5_000)
        #expect(fitted > 3_000)
    }
}
