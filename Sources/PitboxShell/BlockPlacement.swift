import AppKit
import PitboxKit

/// The block's own settings the panel uses (the app reads and writes them in the settings file). Values come
/// in as they are stored and are made safe where they are used (`BlockGeometry`).
public struct BlockSettings: Equatable, Sendable {
    /// 2 (default) or 1 (`"columns"`).
    public var columns: Int
    /// Folded into the rail (`"folded"`).
    public var folded: Bool
    /// The screen edge alone (`"edge"`, default right). Docked, the host's edge wins.
    public var edge: Edge
    /// The display alone, by display UUID; nil or `"main"` for the main display (`"display"`).
    public var displayUUID: String?
    /// The alone cell width, 300...360 (`"cellWidth"`, default 323).
    public var cellWidth: Double
    /// Points below the menu bar left free (alone only), 0...600.
    public var topGap: Double
    /// Points above the Dock left free (alone only), 0...600.
    public var bottomGap: Double
    /// "Keep Above Windows" (default on: floating − 1); off: behind normal windows. Docked, the host's level wins.
    public var keepAboveWindows: Bool
    /// Absent from native full-screen Spaces (default on).
    public var hideInFullscreen: Bool

    public init(columns: Int = 2, folded: Bool = false, edge: Edge = .right, displayUUID: String? = nil,
                cellWidth: Double = Double(BlockGeometry.defaultCell), topGap: Double = 0, bottomGap: Double = 0,
                keepAboveWindows: Bool = true, hideInFullscreen: Bool = true) {
        self.columns = columns
        self.folded = folded
        self.edge = edge
        self.displayUUID = displayUUID
        self.cellWidth = cellWidth
        self.topGap = topGap
        self.bottomGap = bottomGap
        self.keepAboveWindows = keepAboveWindows
        self.hideInFullscreen = hideInFullscreen
    }
}

/// Where the host wants the docked block (the dock link's `place`, docs/DOCK_PROTOCOL.md §5.5).
public struct DockPlace: Equatable, Sendable {
    /// The host's strip frame, AppKit global coordinates.
    public var hostFrame: CGRect
    /// The host's display.
    public var displayID: UInt32
    /// The host's screen edge; the block sits on the host's window side.
    public var edge: Edge
    /// The host's window level (raw `NSWindow.Level`); the block uses the same level (clamped, see
    /// `BlockPanelController.dockedLevel(_:)`).
    public var level: Int
    /// False while the host hides its strip: the block hides with it.
    public var visible: Bool
    /// True during the host's live width drag: the panel follows, the guard region waits (docs/DOCK_PROTOCOL.md §5.5).
    public var live: Bool
    /// The host's column (cell) width.
    public var cell: Double
    /// The most the block may take (the host keeps the whole docked area within its own limit).
    public var maxWidth: Double

    public init(hostFrame: CGRect, displayID: UInt32, edge: Edge, level: Int, visible: Bool = true, live: Bool = false,
                cell: Double, maxWidth: Double = Double(BlockGeometry.defaultMaxDockedWidth)) {
        self.hostFrame = hostFrame
        self.displayID = displayID
        self.edge = edge
        self.level = level
        self.visible = visible
        self.live = live
        self.cell = cell
        self.maxWidth = maxWidth
    }
}

/// Alone at the screen edge (edge and display from `BlockSettings`) or docked beside a host.
public enum BlockPlacement: Equatable, Sendable {
    case alone
    case docked(DockPlace)

    /// The dock place, when docked.
    public var dockPlace: DockPlace? {
        if case .docked(let place) = self { return place }
        return nil
    }

    public var isDocked: Bool { dockPlace != nil }
}

/// How the block's content is laid out right now; the block's root view (from the sessions module) follows it.
public struct BlockLayout: Equatable, Sendable {
    /// Columns shown: 2 or 1; 0 while the rail shows.
    public var columns: Int
    /// The column width.
    public var cell: CGFloat
    /// True while the rail shows (folded, or nothing else fits).
    public var showsRail: Bool
    /// True when the user folded the block (the rail may also show because nothing else fits: `showsRail`).
    public var folded: Bool
    /// Docked beside a host.
    public var docked: Bool
    /// The side the windows are on (the panel's inner edge; the fold "−" sits on the other side when docked).
    public var windowSide: Edge
    /// Padding on the left and right of the columns: 16 and 16 alone; docked 16 on the window side, 0 on the host's.
    public var leftPadding: CGFloat
    public var rightPadding: CGFloat

    public init(columns: Int, cell: CGFloat, showsRail: Bool, folded: Bool, docked: Bool, windowSide: Edge,
                leftPadding: CGFloat, rightPadding: CGFloat) {
        self.columns = columns
        self.cell = cell
        self.showsRail = showsRail
        self.folded = folded
        self.docked = docked
        self.windowSide = windowSide
        self.leftPadding = leftPadding
        self.rightPadding = rightPadding
    }

    /// The side the host is on, when docked.
    public var hostSide: Edge? { docked ? (windowSide == .left ? .right : .left) : nil }

    /// The columns' own width.
    public var columnsWidth: CGFloat { showsRail ? 0 : BlockGeometry.columnsWidth(columns: columns, cell: cell) }

    /// The layout for a fit (`BlockGeometry.fitAlone` / `fitDocked`) at an edge (alone: the block's; docked: the host's).
    public static func make(fit: BlockFit, folded: Bool, docked: Bool, edge: Edge) -> BlockLayout {
        let windowSide = BlockGeometry.windowSide(of: edge)
        let pad = BlockGeometry.padding
        var left = pad, right = pad
        if docked {
            // No padding on the host's side: its own 16 pt give the gap.
            if windowSide == .left { right = 0 } else { left = 0 }
        }
        if fit.isRail { left = 0; right = 0 }
        return BlockLayout(columns: fit.columns, cell: fit.cell, showsRail: fit.isRail, folded: folded, docked: docked,
                           windowSide: windowSide, leftPadding: left, rightPadding: right)
    }
}
