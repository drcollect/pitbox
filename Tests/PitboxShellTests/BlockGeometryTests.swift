import AppKit
import Testing
import PitboxKit
@testable import PitboxShell

/// Off-screen displays (far right of any real arrangement), so nothing here depends on the Mac running the tests.
enum TestDisplays {
    static let primaryHeight: CGFloat = 1440

    /// A 1512 × 982 notebook display: menu bar 33 pt, Dock 70 pt at the bottom.
    static let notebook = BlockDisplay(displayID: 11, uuid: "AAAA-NOTEBOOK", name: "Built-in Display",
                                       frame: CGRect(x: 20000, y: 0, width: 1512, height: 982),
                                       visibleFrame: CGRect(x: 20000, y: 70, width: 1512, height: 879), isMain: true)
    /// A 5120 × 1440 ultrawide beside it.
    static let ultrawide = BlockDisplay(displayID: 12, uuid: "BBBB-ULTRAWIDE", name: "Acme Ultrawide",
                                        frame: CGRect(x: 21512, y: 0, width: 5120, height: 1440),
                                        visibleFrame: CGRect(x: 21512, y: 0, width: 5120, height: 1415), isMain: false)
    /// 1280 wide: two columns (690) exceed half of it (640), one column (355) fits.
    static let narrow = BlockDisplay(displayID: 13, uuid: "CCCC-NARROW", name: "Small",
                                     frame: CGRect(x: 30000, y: 0, width: 1280, height: 800),
                                     visibleFrame: CGRect(x: 30000, y: 0, width: 1280, height: 775), isMain: false)
    /// 700 wide: not even one column (355) fits in half of it (350).
    static let tiny = BlockDisplay(displayID: 14, uuid: "DDDD-TINY", name: "Tiny",
                                   frame: CGRect(x: 40000, y: 0, width: 700, height: 600),
                                   visibleFrame: CGRect(x: 40000, y: 0, width: 700, height: 575), isMain: false)
}

@Suite struct BlockGeometryTests {
    /// The width table in `BlockGeometry`'s doc comment, exactly.
    @Test func widthsMatchTheSpecTable() {
        #expect(BlockGeometry.dockedWidth(columns: 2, hostCell: 301.4) == 631)
        #expect(BlockGeometry.dockedWidth(columns: 1, hostCell: 301.4) == 317)
        #expect(BlockGeometry.dockedWidth(columns: 2, hostCell: 322.7) == 673)
        #expect(BlockGeometry.dockedWidth(columns: 1, hostCell: 322.7) == 339)
        #expect(BlockGeometry.aloneWidth(columns: 2, cell: 323) == 690)
        #expect(BlockGeometry.aloneWidth(columns: 1, cell: 323) == 355)
        #expect(BlockGeometry.railWidth == 24)
        #expect(BlockGeometry.fitAlone(columns: 2, cell: 323, folded: true, visibleWidth: 5120).width == 24)
        #expect(BlockGeometry.fitDocked(columns: 1, hostCell: 301.4, folded: true, maxWidth: 800).width == 24)
        // The parts: gutter 12, padding 16.
        #expect(BlockGeometry.gutter == 12 && BlockGeometry.padding == 16)
    }

    @Test func cellAndInputsAreMadeSafe() {
        #expect(BlockGeometry.clampedCell(323) == 323)
        #expect(BlockGeometry.clampedCell(250) == 300)
        #expect(BlockGeometry.clampedCell(400) == 360)
        #expect(BlockGeometry.clampedCell(.nan) == 323)
        #expect(BlockGeometry.clampedCell(.infinity) == 323)
        #expect(BlockGeometry.aloneWidth(columns: 2, cell: BlockGeometry.clampedCell(360)) == 764)
        #expect(BlockGeometry.sanitizedHostCell(301.4) == 301.4)
        #expect(BlockGeometry.sanitizedHostCell(-5) == 323)
        #expect(BlockGeometry.sanitizedHostCell(.nan) == 323)
        #expect(BlockGeometry.sanitizedHostCell(10_000) == 640)
        #expect(BlockGeometry.sanitizedMaxWidth(0) == 800)
        #expect(BlockGeometry.sanitizedMaxWidth(.infinity) == 800)
        #expect(BlockGeometry.sanitizedMaxWidth(631) == 631)
        #expect(BlockGeometry.sanitizedColumns(1) == 1)
        for odd in [0, 2, 3, -1, 99] { #expect(BlockGeometry.sanitizedColumns(odd) == 2) }
        #expect(BlockGeometry.clampedGap(-3) == 0 && BlockGeometry.clampedGap(.nan) == 0 && BlockGeometry.clampedGap(9000) == 600)
    }

    @Test func aloneFallsBackToOneColumnThenTheRail() {
        // At most half the visible width.
        let wide = BlockGeometry.fitAlone(columns: 2, cell: 323, folded: false, visibleWidth: 1512)
        #expect(wide == BlockFit(columns: 2, width: 690, cell: 323, reduced: false))
        let exact = BlockGeometry.fitAlone(columns: 2, cell: 323, folded: false, visibleWidth: 1380)
        #expect(exact.columns == 2, "690 is exactly 50% of 1380")
        let one = BlockGeometry.fitAlone(columns: 2, cell: 323, folded: false, visibleWidth: 1280)
        #expect(one == BlockFit(columns: 1, width: 355, cell: 323, reduced: true))
        let asked = BlockGeometry.fitAlone(columns: 1, cell: 323, folded: false, visibleWidth: 1280)
        #expect(asked == BlockFit(columns: 1, width: 355, cell: 323, reduced: false))
        let rail = BlockGeometry.fitAlone(columns: 2, cell: 323, folded: false, visibleWidth: 700)
        #expect(rail.isRail && rail.width == 24 && rail.reduced)
        let folded = BlockGeometry.fitAlone(columns: 2, cell: 323, folded: true, visibleWidth: 700)
        #expect(folded.isRail && !folded.reduced)
    }

    @Test func dockedFallsBackWithinTheHostsMaxWidth() {
        #expect(BlockGeometry.fitDocked(columns: 2, hostCell: 301.4, folded: false, maxWidth: 800)
            == BlockFit(columns: 2, width: 631, cell: 301.4, reduced: false))
        #expect(BlockGeometry.fitDocked(columns: 2, hostCell: 301.4, folded: false, maxWidth: 631).columns == 2)
        #expect(BlockGeometry.fitDocked(columns: 2, hostCell: 301.4, folded: false, maxWidth: 630)
            == BlockFit(columns: 1, width: 317, cell: 301.4, reduced: true))
        let rail = BlockGeometry.fitDocked(columns: 2, hostCell: 301.4, folded: false, maxWidth: 300)
        #expect(rail.isRail && rail.reduced && rail.width == 24)
        // A host sending nonsense gets the defaults (cell 323, limit 800).
        #expect(BlockGeometry.fitDocked(columns: 2, hostCell: .nan, folded: false, maxWidth: -1).width == 674)
    }

    @Test func aloneFrameSitsAtTheEdgeOfTheVisibleFrame() {
        let d = TestDisplays.notebook
        let right = BlockGeometry.aloneFrame(on: d, edge: .right, width: 690)
        #expect(right == CGRect(x: 20822, y: 70, width: 690, height: 879))
        let left = BlockGeometry.aloneFrame(on: d, edge: .left, width: 690)
        #expect(left == CGRect(x: 20000, y: 70, width: 690, height: 879))
        // Gaps shorten it from the top and bottom only.
        let gapped = BlockGeometry.aloneFrame(on: d, edge: .right, width: 355, topGap: 100, bottomGap: 200)
        #expect(gapped == CGRect(x: 21157, y: 270, width: 355, height: 579))
        // Gaps that would leave less than 300 pt shrink proportionally.
        let squeezed = BlockGeometry.aloneFrame(on: d, edge: .right, width: 355, topGap: 600, bottomGap: 600)
        #expect(squeezed.height >= 300 && squeezed.minY >= 70 && squeezed.maxY <= 949)
        // A side Dock: flush with the visible frame, not under the Dock.
        let sideDock = BlockDisplay(displayID: 2, uuid: "X", name: "x", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 1442, height: 949), isMain: true)
        #expect(BlockGeometry.aloneFrame(on: sideDock, edge: .right, width: 690).maxX == 1442)
        // A degenerate visible frame falls back to the whole display.
        let broken = BlockDisplay(displayID: 3, uuid: "Y", name: "y", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: .zero, isMain: true)
        #expect(BlockGeometry.aloneFrame(on: broken, edge: .left, width: 690) == CGRect(x: 0, y: 0, width: 690, height: 982))
    }

    @Test func dockedFrameIsAdjacentWithTheHostsTopAndBottom() throws {
        // Host at the right edge (31% of 5120): the block sits left of it.
        let host = CGRect(x: 23533, y: 98, width: 1587, height: 1312)
        let left = try #require(BlockGeometry.dockedFrame(hostFrame: host, hostEdge: .right, width: 631))
        #expect(left == CGRect(x: 22902, y: 98, width: 631, height: 1312))
        #expect(left.maxX == host.minX && left.minY == host.minY && left.maxY == host.maxY)
        // Host at the left edge: the block sits right of it.
        let leftHost = CGRect(x: 20000, y: 120, width: 1024, height: 1200)
        let right = try #require(BlockGeometry.dockedFrame(hostFrame: leftHost, hostEdge: .left, width: 339))
        #expect(right == CGRect(x: 21024, y: 120, width: 339, height: 1200))
        // Unusable host frames give no frame.
        #expect(BlockGeometry.dockedFrame(hostFrame: .zero, hostEdge: .right, width: 631) == nil)
        #expect(BlockGeometry.dockedFrame(hostFrame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), hostEdge: .right,
                                          width: 631) == nil)
        #expect(BlockGeometry.dockedFrame(hostFrame: host, hostEdge: .right, width: 0) == nil)
    }

    @Test func regionIsThePanelInQuartzWithTheGivenEdge() {
        let frame = CGRect(x: 20822, y: 70, width: 690, height: 879)
        let region = BlockGeometry.region(forPanelFrame: frame, displayID: 11, edge: .right, primaryHeight: 1440)
        #expect(region == ReservedRegion(displayID: 11, rect: CGRect(x: 20822, y: 491, width: 690, height: 879), edge: .right))
        #expect(ScreenSpace.appKit(fromQuartz: region.rect, primaryHeight: 1440) == frame)
        #expect(BlockGeometry.windowSide(of: .right) == .left && BlockGeometry.windowSide(of: .left) == .right)
    }

    @Test func layoutPaddingFollowsTheMode() {
        let two = BlockFit(columns: 2, width: 631, cell: 301.4, reduced: false)
        let docked = BlockLayout.make(fit: two, folded: false, docked: true, edge: .right)
        #expect(docked.windowSide == .left && docked.hostSide == .right)
        #expect(docked.leftPadding == 16 && docked.rightPadding == 0)
        let dockedLeftHost = BlockLayout.make(fit: two, folded: false, docked: true, edge: .left)
        #expect(dockedLeftHost.leftPadding == 0 && dockedLeftHost.rightPadding == 16 && dockedLeftHost.hostSide == .left)
        let alone = BlockLayout.make(fit: BlockFit(columns: 2, width: 690, cell: 323, reduced: false), folded: false,
                                     docked: false, edge: .right)
        #expect(alone.leftPadding == 16 && alone.rightPadding == 16 && alone.hostSide == nil)
        #expect(alone.columnsWidth + alone.leftPadding + alone.rightPadding == 690)
        let rail = BlockLayout.make(fit: BlockFit(columns: 0, width: 24, cell: 323, reduced: false), folded: true,
                                    docked: true, edge: .right)
        #expect(rail.showsRail && rail.leftPadding == 0 && rail.rightPadding == 0 && rail.columnsWidth == 0)
    }

    @Test func displayChoiceFallsBackToTheMainDisplay() {
        let all = [TestDisplays.notebook, TestDisplays.ultrawide]
        #expect(BlockDisplay.choose(remembered: nil, among: all) == TestDisplays.notebook)
        #expect(BlockDisplay.choose(remembered: "main", among: all) == TestDisplays.notebook)
        #expect(BlockDisplay.choose(remembered: " Main ", among: all) == TestDisplays.notebook)
        #expect(BlockDisplay.choose(remembered: "bbbb-ultrawide", among: all) == TestDisplays.ultrawide)
        #expect(BlockDisplay.choose(remembered: "GONE", among: all) == TestDisplays.notebook)
        #expect(BlockDisplay.choose(remembered: "GONE", among: [TestDisplays.ultrawide]) == TestDisplays.ultrawide)
        #expect(BlockDisplay.choose(remembered: nil, among: []) == nil)
    }

    @MainActor @Test func theRealDisplaysAreReadable() {
        let displays = BlockDisplay.current()
        #expect(displays.filter(\.isMain).count <= 1)
        if let main = displays.first {
            #expect(main.isMain)
            #expect(main.uuid == BlockDisplay.uuid(of: main.displayID) ?? "")
        }
        #expect(BlockDisplay.uuid(of: 0) == nil)
    }
}
