import AppKit

/// Monitor grid constants (points): one source of truth for the block's columns and rows.
public enum GridMetrics {
    public static let padding: CGFloat = 16
    public static let gutter: CGFloat = 12
    public static let minCellWidth: CGFloat = 300
    /// One grid row. A monitor `n` rows tall is `81n - 12` pt: 1 row is 69 pt, 2 rows are 150 pt.
    public static let rowHeight: CGFloat = 69

    /// Number of grid columns that fit in a block `w` points wide (at least 1).
    public static func columns(forStripWidth w: CGFloat) -> Int {
        max(1, Int(floor((w - 2 * padding + gutter) / (minCellWidth + gutter))))
    }

    public static func cellWidth(forStripWidth w: CGFloat) -> CGFloat {
        let c = CGFloat(columns(forStripWidth: w))
        return (w - 2 * padding - (c - 1) * gutter) / c
    }
}

/// Conversions between AppKit screen space (origin bottom-left of the primary display, y up) and Quartz global
/// space (origin top-left of the primary display, y down). Accessibility (`AXUIElement`) and
/// `CGWindowListCopyWindowInfo` use Quartz space; `NSScreen`/`NSWindow` use AppKit space.
public enum ScreenSpace {
    /// Height of the primary display: the reference for the flip.
    public static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    public static func quartz(fromAppKit r: CGRect, primaryHeight h: CGFloat = ScreenSpace.primaryHeight) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    public static func appKit(fromQuartz r: CGRect, primaryHeight h: CGFloat = ScreenSpace.primaryHeight) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// The `CGDirectDisplayID` of a screen (0 if unknown).
    public static func displayID(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
