import AppKit
import PitboxKit

/// What the block shows at a given width: two columns, one column, or the 24 pt rail.
public struct BlockFit: Equatable, Sendable {
    /// Columns shown: 2 or 1; 0 while the rail shows.
    public var columns: Int
    /// The panel width in whole points.
    public var width: CGFloat
    /// The column (cell) width the monitors are laid out at.
    public var cell: CGFloat
    /// True when fewer columns are shown than asked for (the limit did not allow them), or the rail without a fold.
    public var reduced: Bool

    public init(columns: Int, width: CGFloat, cell: CGFloat, reduced: Bool) {
        self.columns = columns
        self.width = width
        self.cell = cell
        self.reduced = reduced
    }

    /// True while the rail shows (folded, or nothing else fits).
    public var isRail: Bool { columns == 0 }
}

/// Pure block geometry (docked: docs/DOCK_PROTOCOL.md §7): columns and cell give the width, the display or the host's
/// frame gives the panel frame (AppKit space), and the frame gives the guard region (Quartz space). Widths are rounded
/// to whole points.
///
/// | Case | Cell | Two columns | One column |
/// | --- | --- | --- | --- |
/// | Docked (host cell 301.4) | 301.4 | 631 | 317 |
/// | Docked (host cell 322.7) | 322.7 | 673 | 339 |
/// | Alone | 323 | 690 | 355 |
/// | Folded | | 24 | 24 |
public enum BlockGeometry {
    /// Between two columns.
    public static let gutter: CGFloat = GridMetrics.gutter
    /// Alone on both sides; docked on the window side only (the host's own padding gives the gap on its side).
    public static let padding: CGFloat = GridMetrics.padding
    /// Above the block's content and below the console drawer (both modes).
    public static let verticalPadding: CGFloat = GridMetrics.padding
    /// The folded rail.
    public static let railWidth: CGFloat = 24
    /// The alone cell the monitors were designed at.
    public static let defaultCell: CGFloat = 323
    /// The cell width the settings may choose (alone).
    public static let cellRange: ClosedRange<CGFloat> = 300...360
    /// What a host's cell is clamped to (a single-column host strip can have cells up to about 610 pt).
    public static let hostCellRange: ClosedRange<CGFloat> = 200...640
    /// Alone, the block takes at most this share of the display's visible width.
    public static let aloneMaxShare: CGFloat = 0.5
    /// The docked limit when a host sends none (or nonsense).
    public static let defaultMaxDockedWidth: CGFloat = 800
    /// Top and bottom gaps are each at most this (points).
    public static let maxGap: Double = 600
    /// Shortest block ever produced alone. Gaps that would squeeze it below this shrink proportionally.
    public static let minimumHeight: CGFloat = 300

    // MARK: Inputs made safe

    /// Columns from the settings: 1 stays 1, everything else is 2 (the default).
    public static func sanitizedColumns(_ value: Int) -> Int { value == 1 ? 1 : 2 }

    /// The alone cell from the settings: non-finite is the default, otherwise clamped to `cellRange`.
    public static func clampedCell(_ value: Double) -> CGFloat {
        guard value.isFinite else { return defaultCell }
        return min(max(CGFloat(value), cellRange.lowerBound), cellRange.upperBound)
    }

    /// A host's cell: non-finite or not positive is the alone default, otherwise clamped to `hostCellRange`.
    public static func sanitizedHostCell(_ value: Double) -> CGFloat {
        guard value.isFinite, value > 0 else { return defaultCell }
        return min(max(CGFloat(value), hostCellRange.lowerBound), hostCellRange.upperBound)
    }

    /// A host's `maxWidth`: non-finite or not positive is `defaultMaxDockedWidth`.
    public static func sanitizedMaxWidth(_ value: Double) -> CGFloat {
        guard value.isFinite, value > 0 else { return defaultMaxDockedWidth }
        return CGFloat(value)
    }

    /// A top or bottom gap: non-finite or negative is 0, at most `maxGap`.
    public static func clampedGap(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, maxGap)
    }

    // MARK: Widths

    /// The columns' own width: `columns × cell + (columns − 1) × gutter`.
    public static func columnsWidth(columns: Int, cell: CGFloat) -> CGFloat {
        let n = CGFloat(max(1, columns))
        return n * cell + (n - 1) * gutter
    }

    /// Alone: `columns × cell + gutters + 2 × padding`, rounded (2 × 323 → 690, 1 × 323 → 355).
    public static func aloneWidth(columns: Int, cell: CGFloat) -> CGFloat {
        (columnsWidth(columns: columns, cell: cell) + 2 * padding).rounded()
    }

    /// Docked: `columns × hostCell + gutters + padding` (window side only), rounded (2 × 301.4 → 631, 1 × 301.4 → 317).
    public static func dockedWidth(columns: Int, hostCell: CGFloat) -> CGFloat {
        (columnsWidth(columns: columns, cell: hostCell) + padding).rounded()
    }

    /// Alone: the asked-for columns if they fit in `aloneMaxShare` of the visible width, else one column, else the rail.
    /// Folded is always the rail.
    public static func fitAlone(columns: Int, cell: Double, folded: Bool, visibleWidth: CGFloat) -> BlockFit {
        let cell = clampedCell(cell)
        let limit = max(0, visibleWidth) * aloneMaxShare
        return fit(columns: sanitizedColumns(columns), cell: cell, folded: folded, limit: limit) {
            aloneWidth(columns: $0, cell: cell)
        }
    }

    /// Docked: the asked-for columns if they fit in the host's `maxWidth`, else one column, else the rail.
    public static func fitDocked(columns: Int, hostCell: Double, folded: Bool, maxWidth: Double) -> BlockFit {
        let cell = sanitizedHostCell(hostCell)
        let limit = sanitizedMaxWidth(maxWidth)
        return fit(columns: sanitizedColumns(columns), cell: cell, folded: folded, limit: limit) {
            dockedWidth(columns: $0, hostCell: cell)
        }
    }

    private static func fit(columns: Int, cell: CGFloat, folded: Bool, limit: CGFloat,
                            width: (Int) -> CGFloat) -> BlockFit {
        if folded { return BlockFit(columns: 0, width: railWidth, cell: cell, reduced: false) }
        for n in stride(from: columns, through: 1, by: -1) where width(n) <= limit {
            return BlockFit(columns: n, width: width(n), cell: cell, reduced: n != columns)
        }
        return BlockFit(columns: 0, width: railWidth, cell: cell, reduced: true)
    }

    // MARK: Frames

    /// The visible frame, or the full frame when the visible frame is degenerate or outside the display.
    public static func usableFrame(of display: BlockDisplay) -> CGRect {
        let v = display.visibleFrame.standardized
        if v.width < 1 || v.height < 1 || !display.frame.standardized.insetBy(dx: -1, dy: -1).contains(v) {
            return display.frame.standardized
        }
        return v
    }

    /// The gaps applied to a usable height: each made safe (`clampedGap`), and reduced proportionally when together they
    /// would leave less than `minimumHeight` (an area shorter than that gets no gaps at all).
    public static func effectiveGaps(top: Double, bottom: Double, availableHeight: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let t = CGFloat(clampedGap(top))
        let b = CGFloat(clampedGap(bottom))
        let room = max(0, availableHeight - min(minimumHeight, availableHeight))
        let total = t + b
        guard total > room, total > 0 else { return (t, b) }
        let scale = room / total
        return (t * scale, b * scale)
    }

    /// Alone: flush with `edge` of the display's visible frame (beside a side Dock, not under it), the visible height
    /// minus the top and bottom gaps, `width` wide (at most the usable width). Whole points.
    public static func aloneFrame(on display: BlockDisplay, edge: Edge, width: CGFloat, topGap: Double = 0,
                                  bottomGap: Double = 0) -> CGRect {
        let usable = usableFrame(of: display)
        let w = min(max(1, width.rounded()), max(1, usable.width.rounded(.down)))
        let x = edge == .right ? usable.maxX - w : usable.minX
        let gaps = effectiveGaps(top: topGap, bottom: bottomGap, availableHeight: usable.height)
        let bottom = (usable.minY + gaps.bottom).rounded()
        let top = (usable.maxY - gaps.top).rounded()
        let height = max(top - bottom, min(minimumHeight, usable.height.rounded(.down)))
        return CGRect(x: x.rounded(), y: bottom, width: w, height: height)
    }

    /// Docked: adjacent to the host's frame on its window side (left of a right-edge host, right of a left-edge one),
    /// with the host's exact top and bottom. `hostFrame` is in AppKit global coordinates, as the dock message carries
    /// it. Nil when the host frame is not usable (not finite, empty).
    public static func dockedFrame(hostFrame: CGRect, hostEdge: Edge, width: CGFloat) -> CGRect? {
        let host = hostFrame.standardized
        guard host.minX.isFinite, host.minY.isFinite, host.width.isFinite, host.height.isFinite,
              host.width > 0, host.height > 0, width.isFinite, width > 0 else { return nil }
        let x = hostEdge == .right ? host.minX - width : host.maxX
        return CGRect(x: x, y: host.minY, width: width, height: host.height)
    }

    /// The guard region (Quartz space) of a panel frame (AppKit space). `edge` is the block's edge alone and the host's
    /// edge docked: the guard pushes windows toward the other side. `primaryHeight` is the flip reference
    /// (`ScreenSpace.primaryHeight`).
    public static func region(forPanelFrame frame: CGRect, displayID: UInt32, edge: Edge,
                              primaryHeight: CGFloat) -> ReservedRegion {
        ReservedRegion(displayID: displayID, rect: ScreenSpace.quartz(fromAppKit: frame, primaryHeight: primaryHeight),
                       edge: edge)
    }

    /// The side the windows are on: the other side of `edge` (alone: the block's edge; docked: the host's edge, so the
    /// block's window side is the host's window side).
    public static func windowSide(of edge: Edge) -> Edge { edge == .right ? .left : .right }
}
