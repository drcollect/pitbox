import CoreGraphics

/// A screen strip that other apps' windows must stay out of. Produced by the shell's panel, consumed by the guard,
/// desk tags, drag-to-park and the window parker.
public struct ReservedRegion: Equatable, Sendable {
    public var displayID: UInt32
    /// Global **Quartz** coordinates (origin top-left of the primary display, y down): the same space as
    /// `AXUIElement` positions and `CGWindowListCopyWindowInfo` bounds. Use `ScreenSpace` to convert.
    public var rect: CGRect
    /// The screen edge the region belongs to; windows are pushed toward the other side.
    public var edge: Edge

    public init(displayID: UInt32, rect: CGRect, edge: Edge) {
        self.displayID = displayID
        self.rect = rect
        self.edge = edge
    }
}

/// Implemented by the shell (the panel controller); observed by the guard.
public protocol ReservedRegionSource: AnyObject {
    /// One region per display that currently shows the block. Empty while the block is hidden.
    var regions: [ReservedRegion] { get }
    /// Called (main thread) whenever `regions` changes.
    var onRegionsChanged: (() -> Void)? { get set }
}
