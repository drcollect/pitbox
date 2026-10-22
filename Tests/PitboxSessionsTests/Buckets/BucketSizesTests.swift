import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Folder sizes per bucket, pages from the block's real columns, slim rows, the page-dot ring, clamping
/// and pages remembered per bucket.
@MainActor
@Suite("Buckets: sizes and pages")
struct BucketSizesTests {
    init() { CodeTileLog.enabled = false }

    /// The default strip (1024 pt): columns of 322.67 pt; a block of n columns is n × 322.67 + (n − 1) × 12 wide.
    static let column: CGFloat = (1024 - 32 - 24) / 3
    static func width(columns: Int) -> CGFloat { CGFloat(columns) * column + CGFloat(columns - 1) * 12 }

    @Test(arguments: [(1, CodeMonitorSize.large), (4, .large), (5, .medium), (9, .medium), (10, .small), (12, .small), (13, .small),
                      (25, .small)])
    func theCountDecidesTheSize(_ count: Int, _ size: CodeMonitorSize) {
        #expect(CodeMonitorSize.forCount(count) == size)
        #expect(CodeMonitorGrid.layout(count: count, width: 992, stripColumn: Self.column).size == size)
    }

    @Test(arguments: [(1, [2, 3, 4]), (2, [4, 6, 8]), (3, [4, 9, 12]), (4, [4, 9, 12])])
    func aPageHoldsWhatTheTilesColumnsAllow(_ columns: Int, _ perPage: [Int]) {
        let width = Self.width(columns: columns)
        let pages = [4, 9, 12].map { CodeMonitorGrid.layout(count: $0, width: width, stripColumn: Self.column).perPage }
        #expect(pages == perPage, "\(columns) columns")
        // A page is never taller than its rows: 2 large, 3 medium, 2 small.
        for (count, rows) in [(4, 2), (9, 3), (12, 2)] {
            let grid = CodeMonitorGrid.layout(count: count, width: width, stripColumn: Self.column)
            #expect(grid.rowsPerPage <= rows, "\(columns) columns, \(count)")
        }
        // 13 small monitors at 3 columns: two pages of 12 and 1; at 1 column: four pages of 4.
        if columns == 1 { #expect(CodeMonitorGrid.layout(count: 13, width: width, stripColumn: Self.column).pages == 4) }
        if columns == 3 { #expect(CodeMonitorGrid.layout(count: 13, width: width, stripColumn: Self.column).pages == 2) }
    }

    @Test func slimRowsAreEightAPageAcrossTheTile() {
        let rows = CodeMonitorGrid.layout(count: 8, width: 992, stripColumn: Self.column, rows: true)
        #expect(rows.isRows && rows.columns == 1 && rows.perPage == 8 && rows.pages == 1)
        #expect(rows.cell == CGSize(width: 992, height: 36))
        #expect(rows.bodyHeight == 330 && rows.height == 330)
        #expect(rows.frame(ofSlot: 1) == CGRect(x: 0, y: 42, width: 992, height: 36))
        let more = CodeMonitorGrid.layout(count: 9, width: 992, stripColumn: Self.column, rows: true)
        #expect(more.pages == 2 && more.range(ofPage: 1) == 8..<9)
        #expect(more.height == 330 + 12 + CodeMonitorGrid.pagerHeight)
    }

    @Test func aPageWithANeedsYouOrAWarningMonitorRingsItsDot() {
        let h = BucketHarness()
        var sessions = bucketSessions("p", 13, states: [13: .needsYou])
        h.set(sessions)
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        #expect(view.folder.grid.pages == 2)
        #expect(!view.folder.pageAsksForAttention(0) && view.folder.pageAsksForAttention(1))
        // A Problem alone rings nothing; a warning does.
        sessions[12].state = .problem
        sessions[3].warnings = [CodeWarning(kind: .failedInARow, since: tileNow, failures: 4, lastExitCode: 1)]
        h.set(sessions)
        #expect(view.folder.pageAsksForAttention(0) && !view.folder.pageAsksForAttention(1))
    }

    @Test func thePageIsClampedWhenMonitorsLeaveAndRememberedPerBucket() throws {
        let h = BucketHarness()
        let sideBucket = try #require(h.makeBuckets(["Acme"]).first)
        h.set(bucketSessions("u", 13) + bucketSessions("c", 13))
        for n in 1...13 { h.model.moveSession("local_c\(n)", toBucket: sideBucket) }
        let (view, window) = makeBucketTileView(h, size: CGSize(width: 992, height: 1200))
        defer { window.close() }
        let body = try #require(view.otherFolders[sideBucket])
        body.show(page: 1)
        #expect(h.model.page(of: sideBucket) == 1 && h.model.page(of: CodeBucket.unsortedID) == 0)
        #expect(view.folder.page == 0)
        // Another view of the block (as after a rebuild) shows the same pages.
        let (other, otherWindow) = makeBucketTileView(h, size: CGSize(width: 992, height: 1200))
        defer { otherWindow.close() }
        #expect(other.otherFolders[sideBucket]?.page == 1)
        // A monitor leaves: one page is left, and the remembered page follows.
        h.set(bucketSessions("u", 13) + bucketSessions("c", 12))
        #expect(body.grid.pages == 1 && body.page == 0)
        #expect(h.model.page(of: sideBucket) == 0)
    }

    @Test func everyBucketGetsItsOwnSize() throws {
        let h = BucketHarness()
        let ids = h.makeBuckets(["Acme", "Toy Cube"])
        h.set(bucketSessions("u", 2) + bucketSessions("c", 7) + bucketSessions("t", 13))
        for n in 1...7 { h.model.moveSession("local_c\(n)", toBucket: ids[0]) }
        for n in 1...13 { h.model.moveSession("local_t\(n)", toBucket: ids[1]) }
        let (view, window) = makeBucketTileView(h, size: CGSize(width: 992, height: 1400))
        defer { window.close() }
        #expect(view.folder.grid.size == .large)
        #expect(view.otherFolders[ids[0]]?.grid.size == .medium)
        #expect(view.otherFolders[ids[1]]?.grid.size == .small && view.otherFolders[ids[1]]?.grid.pages == 2)
        // Monitors sit on the strip's columns in every bucket.
        let large = try #require(view.folder.monitorView("local_u1"))
        let medium = try #require(view.otherFolders[ids[0]]?.monitorView("local_c1"))
        #expect(abs(large.frame.width - Self.column) < 1 && abs(medium.frame.width - Self.column) < 1)
        #expect(abs(view.content.convert(medium.bounds, from: medium).minX) < 0.5)
    }

    @Test func slimRowsAreASetting() throws {
        var settings = CodeSettings()
        settings.look = .rows
        let h = BucketHarness(settings: settings)
        let entry = tileOffer("make test", session: 2)
        h.set([tileSession("local_r1", "Row one", index: 1, state: .working),
               tileSession("local_r2", "Row two", index: 2, state: .reviewReady, offers: [entry])])
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        #expect(view.folder.grid.isRows)
        let row = try #require(view.folder.monitorView("local_r2"))
        #expect(row.isRow && row.frame.height == 36 && row.frame.width == 992)
        // The row's button is "Review…" (Run is off by default) and opens what the offer line opens: the sheet.
        #expect(row.item.rowAction == "Review…")
        let button = try #require(row.layoutInfo.offer)
        bucketClick(row, at: bucketCentre(button))
        #expect(h.presenter.presented.map(\.offer.id) == [entry.id])
        // A click elsewhere on the row does the window click; no profile stripe with one copy.
        bucketClick(row, at: CGPoint(x: 40, y: 18))
        #expect(h.parker.performed.map(\.0) == [.park])
        #expect(row.layoutInfo.stripe == nil)
        h.source.runningProfiles = [.a, .b]
        #expect(view.folder.monitorView("local_r2")?.layoutInfo.stripe != nil)
    }
}
