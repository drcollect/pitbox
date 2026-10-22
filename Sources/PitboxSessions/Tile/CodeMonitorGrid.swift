import CoreGraphics
import Foundation
import PitboxKit

/// Where the monitors of one bucket go (pure, unit-tested). Monitors sit on the panel's grid columns: large and medium
/// ones are one column wide, small ones half a column; 12 pt gutters everywhere. The block's own columns decide how
/// many fit a row (3 as shipped) and so a page: the original design's 4 / 9 / 12, or fewer when the rows a page allows
/// hold fewer (`CodeMonitorSize.perPage(columns:)`). Slim rows are one per line, the block's width × 36 pt, 6 pt apart,
/// 8 a page. A bucket is as tall as the rows it needs (a full page's once there are pages, so turning a page never
/// changes its height); the block scrolls inside when that is taller than the block. The order is fixed and fills row
/// by row.
struct CodeMonitorGrid: Equatable {
    var size: CodeMonitorSize
    /// Slim rows instead of monitors.
    var isRows: Bool
    var columns: Int
    var cell: CGSize
    var count: Int
    var pages: Int
    /// Monitors (or rows) on one page.
    var perPage: Int

    static let gap: CGFloat = 12
    /// The ‹ dots › band under the body, only with more than one page.
    static let pagerHeight: CGFloat = 22

    /// Rows one page fills.
    var rowsPerPage: Int { Int((Double(perPage) / Double(columns)).rounded(.up)) }

    /// Rows the bucket shows: a full page's once there are pages, else what the monitors need (at least one).
    var rows: Int { pages > 1 ? rowsPerPage : max(1, Int((Double(count) / Double(columns)).rounded(.up))) }

    /// The gap between two rows: 12 pt between monitors, 6 between slim rows.
    var rowGap: CGFloat { isRows ? CodeMonitorRows.gap : Self.gap }

    var bodyHeight: CGFloat { CGFloat(rows) * cell.height + CGFloat(rows - 1) * rowGap }

    /// The bucket's natural height: the body, and the pager band under it when there are pages.
    var height: CGFloat { bodyHeight + (pages > 1 ? Self.gap + Self.pagerHeight : 0) }

    /// The layout of `count` monitors in a bucket `width` wide whose grid columns are `stripColumn` wide; `rows` for
    /// slim rows.
    static func layout(count: Int, width: CGFloat, stripColumn: CGFloat, rows: Bool = false) -> CodeMonitorGrid {
        let width = width.isFinite ? max(0, width) : 0
        let stripColumn = stripColumn.isFinite ? stripColumn : 1
        let size = CodeMonitorSize.forCount(count)
        if rows {
            let pages = max(1, Int((Double(count) / Double(CodeMonitorRows.perPage)).rounded(.up)))
            return CodeMonitorGrid(size: size, isRows: true, columns: 1, cell: CGSize(width: max(1, width), height: CodeMonitorRows.height),
                                   count: count, pages: pages, perPage: CodeMonitorRows.perPage)
        }
        let column = max(1, min(stripColumn, width))
        // A hair of slack: 3 columns of 322.67 pt divide 992 pt to 2.9999… in floating point.
        let stripColumns = max(1, LayoutCount.floor((width + gap) / (column + gap) + 0.01))
        let columns = stripColumns * size.perColumn
        let cellWidth = size == .small ? max(1, (column - gap) / 2) : column
        let perPage = size.perPage(columns: columns)
        let pages = max(1, Int((Double(count) / Double(perPage)).rounded(.up)))
        return CodeMonitorGrid(size: size, isRows: false, columns: columns, cell: CGSize(width: cellWidth, height: size.height),
                               count: count, pages: pages, perPage: perPage)
    }

    /// The grid's column width for a block `tileWidth` wide: from the panel's strip width when it is known and agrees
    /// with the block (`GridMetrics`), else the widest column count whose columns are at least
    /// `GridMetrics.minCellWidth`.
    static func stripColumn(tileWidth: CGFloat, stripWidth: CGFloat?) -> CGFloat {
        let tileWidth = tileWidth.isFinite ? max(0, tileWidth) : 0
        if let stripWidth, stripWidth.isFinite, stripWidth > 0 {
            let cell = GridMetrics.cellWidth(forStripWidth: stripWidth)
            let span = max(1, LayoutCount.nearest((tileWidth + gap) / (cell + gap)))
            if abs(CGFloat(span) * cell + CGFloat(span - 1) * gap - tileWidth) < 2 { return cell }
        }
        let span = max(1, LayoutCount.floor((tileWidth + gap) / (GridMetrics.minCellWidth + gap) + 0.001))
        return max(1, (tileWidth - CGFloat(span - 1) * gap) / CGFloat(span))
    }

    /// The monitors of `page` (0-based): their positions in the bucket's list.
    func range(ofPage page: Int) -> Range<Int> {
        let page = min(max(page, 0), pages - 1)
        let start = page * perPage
        return start..<min(count, start + perPage)
    }

    /// The page holding the monitor at `position` (0-based).
    func page(of position: Int) -> Int { min(max(0, position / perPage), pages - 1) }

    /// The frame of slot `slot` (0-based within a page), from the bucket's top-left (flipped coordinates).
    func frame(ofSlot slot: Int) -> CGRect {
        let column = slot % columns
        let row = slot / columns
        return CGRect(x: (CGFloat(column) * (cell.width + Self.gap)).rounded(), y: (CGFloat(row) * (cell.height + rowGap)).rounded(),
                      width: cell.width.rounded(), height: cell.height)
    }

    /// The pager band (only meaningful when `pages > 1`).
    func pagerRect(width: CGFloat) -> CGRect {
        CGRect(x: 0, y: bodyHeight + Self.gap, width: width, height: Self.pagerHeight)
    }
}
