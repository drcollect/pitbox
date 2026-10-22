import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Where a tag goes and where the desk peek opens. Quartz coordinates.
@Suite("desk tags: placement")
struct TagPlacementTests {
    let one: [CGFloat] = [120]
    let compact: [CGFloat] = [44]

    @Test func ordinaryWindowRightAlignedAndCentredOnTheTopEdge() throws {
        let layout = try #require(DeskTagPlacement.layout(window: tagWindowBounds, display: tagDisplay, strips: [tagStrip],
                                                       widths: one, compactWidths: compact))
        #expect(layout.frame.maxX == tagWindowBounds.maxX - 24)
        #expect(layout.frame.midY == tagWindowBounds.minY, "half above the window, half over its title bar")
        #expect(layout.frame.size == CGSize(width: 120, height: 22))
        #expect(!layout.compact && !layout.inside)
        #expect(DeskTagTuning.rightInset == CodeTuning.tagRightInset)
    }

    @Test func twoPillsStackWithTheFirstOnTheEdge() throws {
        let layout = try #require(DeskTagPlacement.layout(window: tagWindowBounds, display: tagDisplay, strips: [],
                                                       widths: [150, 100], compactWidths: [44, 30]))
        #expect(layout.frame.height == 48)
        #expect(layout.frame.minY == tagWindowBounds.minY - 11)
        #expect(layout.frame.width == 150)
    }

    @Test func windowUnderTheMenuBarGetsItsTagInside() throws {
        let high = CGRect(x: 300, y: 35, width: 900, height: 700)
        let layout = try #require(DeskTagPlacement.layout(window: high, display: tagDisplay, strips: [], widths: one,
                                                       compactWidths: compact))
        #expect(layout.inside)
        #expect(layout.frame.minY == high.minY + 4)
        // 12 pt of room is enough to stay half above.
        let room = CGRect(x: 300, y: 42, width: 900, height: 700)
        let outside = try #require(DeskTagPlacement.layout(window: room, display: tagDisplay, strips: [], widths: one,
                                                        compactWidths: compact))
        #expect(!outside.inside)
        #expect(outside.frame.minY >= tagDisplay.visibleFrame.minY)
    }

    @Test func neverInsideTheStrip() throws {
        let under = CGRect(x: 1200, y: 300, width: 700, height: 500)   // its right part under the strip (1600…)
        let layout = try #require(DeskTagPlacement.layout(window: under, display: tagDisplay, strips: [tagStrip], widths: one,
                                                       compactWidths: compact))
        #expect(layout.frame.maxX == tagStrip.rect.minX - 4)
        #expect(!layout.frame.intersects(tagStrip.rect))
        let left = ReservedRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 400, height: 1200), edge: .left)
        let near = CGRect(x: 100, y: 300, width: 500, height: 500)
        let leftLayout = try #require(DeskTagPlacement.layout(window: near, display: tagDisplay, strips: [left],
                                                           widths: [200], compactWidths: compact))
        #expect(leftLayout.frame.minX >= left.rect.maxX + 4)
    }

    @Test func narrowRoomGivesTheJAndACount() throws {
        // The window hangs off the display's left edge: only 156 pt of room up to its right edge minus the inset.
        let offLeft = CGRect(x: -500, y: 300, width: 680, height: 500)
        let layout = try #require(DeskTagPlacement.layout(window: offLeft, display: tagDisplay, strips: [], widths: [220],
                                                       compactWidths: [48]))
        #expect(layout.compact)
        #expect(layout.frame.width == 48)
        #expect(layout.frame.minX >= tagDisplay.visibleFrame.minX)
        // Never wider than the window minus 40 pt.
        let small = CGRect(x: 300, y: 300, width: 320, height: 300)
        let fits = try #require(DeskTagPlacement.layout(window: small, display: tagDisplay, strips: [], widths: [260],
                                                     compactWidths: [48]))
        #expect(!fits.compact)
        let tooWide = DeskTagPlacement.layout(window: small, display: tagDisplay, strips: [], widths: [290], compactWidths: [48])
        #expect(tooWide?.compact == true)
        // Not even the compact form: nothing.
        let none = CGRect(x: -800, y: 300, width: 830, height: 500)
        #expect(DeskTagPlacement.layout(window: none, display: tagDisplay, strips: [], widths: [220], compactWidths: [48]) == nil)
    }

    @Test func clampedToTheVisibleFrame() throws {
        let offRight = CGRect(x: 1200, y: 300, width: 1200, height: 500)
        let display = DeskTagPlacement.display(for: offRight, in: [tagDisplay, tagSecondDisplay])
        #expect(display?.id == 1)
        let layout = try #require(DeskTagPlacement.layout(window: offRight, display: tagDisplay, strips: [], widths: one,
                                                       compactWidths: compact))
        #expect(layout.frame.maxX <= tagDisplay.visibleFrame.maxX)
    }

    @Test func secondDisplay() throws {
        let window = CGRect(x: 2400, y: 400, width: 800, height: 500)
        let display = try #require(DeskTagPlacement.display(for: window, in: [tagDisplay, tagSecondDisplay]))
        #expect(display.id == 2)
        let layout = try #require(DeskTagPlacement.layout(window: window, display: display, strips: [tagStrip], widths: one,
                                                       compactWidths: compact))
        #expect(layout.frame.maxX == window.maxX - 24, "the first display's strip does not clamp a tag on the second")
        #expect(DeskTagPlacement.display(for: CGRect(x: 5000, y: 5000, width: 400, height: 300), in: [tagDisplay]) == nil)
    }

    @Test func deskPeekOnTheSideAwayFromTheStrip() {
        let tag = CGRect(x: 1056, y: 189, width: 120, height: 22)
        let size = CGSize(width: 360, height: 400)
        let frame = DeskTagPlacement.peekFrame(tag: tag, size: size, display: tagDisplay, strips: [tagStrip])
        #expect(frame.maxX == tag.minX - 8)
        #expect(frame.minY == tag.minY)
        // No room on the left: to the right, never into the strip.
        let leftTag = CGRect(x: 200, y: 189, width: 120, height: 22)
        let right = DeskTagPlacement.peekFrame(tag: leftTag, size: size, display: tagDisplay, strips: [tagStrip])
        #expect(right.minX == leftTag.maxX + 8)
        // Neither side: below the tag, right-aligned with it, out of the strip.
        let narrow = DeskTagDisplay(id: 3, frame: CGRect(x: 0, y: 0, width: 700, height: 900),
                                 visibleFrame: CGRect(x: 0, y: 25, width: 700, height: 875))
        let middle = CGRect(x: 300, y: 100, width: 120, height: 22)
        let below = DeskTagPlacement.peekFrame(tag: middle, size: size, display: narrow, strips: [])
        #expect(below.minY == middle.maxY + 8)
        #expect(below.maxX <= narrow.visibleFrame.maxX - 8)
        // A strip on the left: the peek goes right of the tag.
        let leftStrip = ReservedRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 400, height: 1200), edge: .left)
        let mirrored = DeskTagPlacement.peekFrame(tag: CGRect(x: 900, y: 300, width: 120, height: 22), size: size,
                                               display: tagDisplay, strips: [leftStrip])
        #expect(mirrored.minX == 1028, "\(mirrored)")
        // Clamped into the visible frame vertically.
        let low = DeskTagPlacement.peekFrame(tag: CGRect(x: 1000, y: 1150, width: 120, height: 22), size: size,
                                          display: tagDisplay, strips: [tagStrip])
        #expect(low.maxY <= tagDisplay.visibleFrame.maxY - 8)
    }
}

/// When a tag hides.
@Suite("desk tags: visibility")
struct TagVisibilityTests {
    let shown = DeskTagGlobalState(stripVisible: true, settingOn: true, feasible: true)

    func reason(_ facts: DeskTagWindowFacts, global: DeskTagGlobalState? = nil, content: Bool = true,
                display: DeskTagDisplay? = tagDisplay) -> DeskTagHideReason? {
        DeskTagVisibility.hideReason(global: global ?? shown, hasContent: content, facts: facts, display: display)
    }

    func facts(_ window: DeskTagServerWindow?, _ change: (inout DeskTagWindowFacts) -> Void = { _ in }) -> DeskTagWindowFacts {
        var facts = DeskTagWindowFacts(window: window, wasRead: true)
        change(&facts)
        return facts
    }

    @Test func shownWhenEverythingHolds() {
        #expect(reason(facts(tagWindow())) == nil)
    }

    @Test func globalRules() {
        #expect(reason(facts(tagWindow()), global: DeskTagGlobalState(stripVisible: false, settingOn: true, feasible: true)) == .stripHidden)
        #expect(reason(facts(tagWindow()), global: DeskTagGlobalState(stripVisible: true, settingOn: false, feasible: true)) == .settingOff)
        #expect(reason(facts(tagWindow()), global: DeskTagGlobalState(stripVisible: true, settingOn: true, feasible: false)) == .notFeasible)
        #expect(reason(facts(tagWindow()), content: false) == .noContent)
    }

    @Test func windowRules() {
        #expect(reason(facts(nil)) == .closed)
        #expect(reason(DeskTagWindowFacts()) == .offScreen, "not read yet: not shown")
        #expect(reason(facts(tagWindow(onScreen: false)) { $0.minimized = true }) == .minimized)
        #expect(reason(facts(tagWindow(onScreen: false))) == .offScreen, "another Space or off screen")
        #expect(reason(facts(tagWindow()) { $0.appHidden = true }) == .appHidden)
        #expect(reason(facts(tagWindow()) { $0.fullScreen = true }) == .fullScreen)
        #expect(reason(facts(tagWindow(bounds: tagDisplay.frame))) == .coversDisplay)
        #expect(reason(facts(tagWindow(bounds: CGRect(x: -0.5, y: 0, width: 2000.5, height: 1200)))) == .coversDisplay)
        #expect(reason(facts(tagWindow(bounds: tagDisplay.visibleFrame))) == nil, "a zoomed window keeps its tag")
        #expect(reason(facts(tagWindow(bounds: CGRect(x: 0, y: 100, width: 319, height: 600)))) == .tooSmall)
        #expect(reason(facts(tagWindow(bounds: CGRect(x: 0, y: 100, width: 600, height: 199)))) == .tooSmall)
        #expect(reason(facts(tagWindow(bounds: CGRect(x: 0, y: 100, width: 320, height: 200)))) == nil)
        #expect(reason(facts(tagWindow()) { $0.dragging = true }) == .dragging)
        #expect(reason(facts(tagWindow()) { $0.covered = true }) == .covered)
        #expect(reason(facts(tagWindow()), display: nil) == .noRoom)
    }

    @Test func coveredByTheFrontToBackList() {
        let tag = CGRect(x: 1056, y: 189, width: 120, height: 22)
        let claude = tagWindow()
        let cover = DeskTagServerWindow(number: 900, pid: 55, bounds: CGRect(x: 1000, y: 150, width: 400, height: 300))
        let elsewhere = DeskTagServerWindow(number: 901, pid: 56, bounds: CGRect(x: 0, y: 600, width: 300, height: 300))
        let ownTag = DeskTagServerWindow(number: 902, pid: 777, bounds: tag)
        let menu = DeskTagServerWindow(number: 903, pid: 1, bounds: CGRect(x: 0, y: 0, width: 2000, height: 1200), layer: 25)
        let clear = DeskTagServerWindow(number: 904, pid: 57, bounds: tag, alpha: 0)
        func covered(_ list: [DeskTagServerWindow]) -> Bool {
            DeskTagVisibility.isCovered(tag: tag, claude: claude.number, frontToBack: list, ownPID: 777)
        }
        #expect(covered([cover, claude]))
        #expect(!covered([claude, cover]), "behind the Claude window it covers nothing")
        #expect(!covered([elsewhere, claude]))
        #expect(!covered([ownTag, menu, clear, claude]), "own windows, other layers and invisible windows never count")
        #expect(!covered([cover]), "the Claude window not on screen: other rules decide")
    }

    @Test func orderCheckOfTheFirstCoverMode() {
        let tag = CGRect(x: 1056, y: 189, width: 120, height: 22)
        let panel = DeskTagServerWindow(number: 902, pid: 777, bounds: tag)
        let claude = tagWindow()
        let cover = DeskTagServerWindow(number: 900, pid: 55, bounds: CGRect(x: 1000, y: 150, width: 400, height: 300))
        func holds(_ list: [DeskTagServerWindow]) -> Bool? {
            DeskTagVisibility.orderHolds(panel: 902, claude: claude.number, tag: tag, frontToBack: list, ownPID: 777)
        }
        #expect(holds([panel, claude]) == true)
        #expect(holds([cover, panel, claude]) == true, "a covering window in front of the tag too")
        #expect(holds([panel, cover, claude]) == false, "the tag over a window that covers its Claude window")
        #expect(holds([claude, panel]) == false)
        #expect(holds([claude]) == nil)
    }
}

/// The arming of buttons that open something.
@Suite("desk tags: arming")
struct TagArmingTests {
    @Test func armsAfterTheDelay() {
        let arming = DeskTagArming(appearedAt: 10, pointerInside: false)
        #expect(!arming.allowsPress(at: 10.5))
        #expect(arming.allowsPress(at: 10.8))
        #expect(DeskTagTuning.armDelay == CodeTuning.openButtonArmDelay)
    }

    @Test func underThePointerUntilItLeaves() {
        var arming = DeskTagArming(appearedAt: 10, pointerInside: true)
        #expect(!arming.allowsPress(at: 20), "appeared under the pointer: swallowed until the pointer left")
        arming.pointerExited()
        #expect(arming.allowsPress(at: 20))
    }

    @Test func movingReArms() {
        var arming = DeskTagArming(appearedAt: 10, pointerInside: false)
        arming.moved(at: 15, pointerInside: false)
        #expect(!arming.allowsPress(at: 15.5))
        #expect(arming.allowsPress(at: 15.9))
        arming.moved(at: 20, pointerInside: true)
        #expect(!arming.allowsPress(at: 30))
    }
}
