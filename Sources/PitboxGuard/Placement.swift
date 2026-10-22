import CoreGraphics
import PitboxKit

/// A display as the guard sees it, in Quartz global coordinates (origin top-left of the primary display, y down).
public struct GuardDisplay: Equatable, Sendable {
    /// `CGDirectDisplayID`.
    public var id: UInt32
    /// The whole display.
    public var frame: CGRect
    /// The display minus the menu bar and the Dock.
    public var visibleFrame: CGRect

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
    }
}

/// Pure geometry that keeps a window out of reserved strips. No AppKit, no Accessibility: exhaustively unit-tested.
/// All rectangles use Quartz global coordinates. Corrections only ever change a window's x and width (never y or
/// height), so the title bar stays exactly as reachable as it was, and they never make a window bigger. A window is
/// pushed by the strip's `edge`, never toward the strip's outer side (where a docked host app's strip may sit), so two
/// guards with adjacent strips on the same edge push a window the same way and never bounce it between them.
public enum Placement {
    /// What `correct` or `resolve` decided for one window.
    public struct Correction: Equatable, Sendable {
        public enum Action: String, Sendable {
            /// Narrower. Pushed toward smaller x (a `.right` strip) the left edge stays put; pushed toward larger x
            /// (a `.left` strip) the right edge stays put (so the origin moves too).
            case shrink
            /// Slid sideways at the same size.
            case move
            /// Slid to the edge of the free space and narrowed to fill it.
            case moveAndShrink
            /// Nothing useful can be changed (the frame is returned unchanged).
            case none
        }

        /// The frame to apply; equal to the input frame when `action == .none`.
        public var frame: CGRect
        public var action: Action
        /// False when the window still overlaps a strip afterwards ("cannot fit").
        public var fits: Bool

        public init(frame: CGRect, action: Action, fits: Bool) {
            self.frame = frame; self.action = action; self.fits = fits
        }
    }

    /// Corrects `windowFrame` against one strip.
    ///
    /// Returns nil when the window does not overlap `region` by more than `tolerance` points in both directions.
    /// The direction comes from the strip's `edge` (the screen edge it belongs to), never from where the strip lies on
    /// the display: `.right` means "end at `region.minX`" (the window goes left, to the window side), `.left` means
    /// "start at `region.maxX`". That is the same thing for a strip touching the screen edge, and the only right thing
    /// for an inboard one: the block docked beside a host app's strip can lie left of the display's middle (a notebook
    /// with a wide docked area), and pushing by the middle would send windows into the host's strip, where the host's
    /// guard sends them back. The one exception is a window that belongs to another display: when `screenBounds` (the
    /// visible frame of the display that holds most of the window, see `resolve`) lies wholly beyond the strip's
    /// outer side, past the screen edge the strip belongs to, the window is pushed back toward that display.
    /// Preference order:
    /// 1. shrink in place, if `resizable`, the new width is at least `minSize.width` and keeps at least
    ///    `minShrinkFraction` of the old width (so a window dragged mostly into the strip is moved, not cut to a sliver);
    /// 2. move it at the same size, if `movable` and it then stays within the screen;
    /// 3. shrink in place even if that loses more than `minShrinkFraction`;
    /// 4. move to the screen edge and shrink to the free width;
    /// 5. otherwise get as close as allowed and report `fits == false`.
    /// A window is never pushed further off-screen than the screen edge (or than it already was), never shrunk below
    /// `minSize.width` (unless it already was narrower, in which case it is not shrunk at all) and never enlarged.
    /// Shrinking toward larger x moves the origin, so it needs `movable` too.
    public static func correct(windowFrame: CGRect, region: CGRect, edge: Edge, screenBounds: CGRect, minSize: CGSize,
                               resizable: Bool, movable: Bool = true, minShrinkFraction: CGFloat = 0.5,
                               tolerance: CGFloat = 1) -> Correction? {
        let w = windowFrame.standardized, r = region.standardized, s = screenBounds.standardized
        guard isUsable(w), isUsable(r), isUsable(s), overlaps(w, r, tolerance: tolerance) else { return nil }
        let minWidth = max(1, minSize.width.isFinite ? minSize.width : 1)
        let fraction = min(max(minShrinkFraction.isFinite ? minShrinkFraction : 0, 0), 1)
        let frame = pushDirection(region: r, edge: edge, screenBounds: s, tolerance: tolerance) == .towardMinX
            ? endBefore(r.minX, w, lowBound: min(s.minX, w.minX), minWidth, resizable, movable, fraction)
            : startAfter(r.maxX, w, highBound: max(s.maxX, w.maxX), minWidth, resizable, movable, fraction)
        return Correction(frame: frame, action: action(from: w, to: frame), fits: !overlaps(frame, r, tolerance: tolerance))
    }

    /// Corrects a window against every strip it overlaps (largest overlap first), each pushed by its own `edge`
    /// (see `correct`), using the display that holds most of the window for the screen bounds. Returns nil when it
    /// overlaps no strip or lies on no display.
    public static func resolve(windowFrame: CGRect, regions: [ReservedRegion], displays: [GuardDisplay],
                               minSize: CGSize, resizable: Bool, movable: Bool = true,
                               minShrinkFraction: CGFloat = 0.5, tolerance: CGFloat = 1) -> Correction? {
        let original = windowFrame.standardized
        guard isUsable(original) else { return nil }
        let hits = regions.filter { overlaps(original, $0.rect, tolerance: tolerance) }
        guard !hits.isEmpty, let home = homeDisplay(for: original, displays: displays) else { return nil }
        var frame = original
        for region in hits.sorted(by: { overlapArea(original, $0.rect) > overlapArea(original, $1.rect) }) {
            if let step = correct(windowFrame: frame, region: region.rect, edge: region.edge,
                                  screenBounds: home.visibleFrame, minSize: minSize, resizable: resizable,
                                  movable: movable, minShrinkFraction: minShrinkFraction, tolerance: tolerance) {
                frame = step.frame
            }
        }
        let fits = !regions.contains { overlaps(frame, $0.rect, tolerance: tolerance) }
        return Correction(frame: frame, action: action(from: original, to: frame), fits: fits)
    }

    /// Which way `correct` pushes a window out of a strip.
    public enum Direction: Equatable, Sendable {
        /// Toward smaller x: the window ends at the strip's `minX`.
        case towardMinX
        /// Toward larger x: the window starts at the strip's `maxX`.
        case towardMaxX
    }

    /// The direction `correct` uses: away from the strip's `edge`, toward the window side (`.right` → `.towardMinX`,
    /// `.left` → `.towardMaxX`), whether the strip touches the screen edge or sits inboard beside another app's strip.
    /// Only when `screenBounds` (the window's home display) lies wholly beyond the strip's outer side, past that
    /// screen edge, does the window go the other way, back toward its own display.
    /// Known limit: a display stacked above or below whose left (or right) edge falls inside the docked area's x-range
    /// is not "wholly beyond", so a window that belongs to it but straddles into the docked area is narrowed toward the
    /// window side instead of being pushed onto its display. It never makes the two guards fight.
    public static func pushDirection(region: CGRect, edge: Edge, screenBounds: CGRect,
                                     tolerance: CGFloat = 1) -> Direction {
        let r = region.standardized, s = screenBounds.standardized
        switch edge {
        case .right: return s.minX >= r.maxX - tolerance ? .towardMaxX : .towardMinX
        case .left: return s.maxX <= r.minX + tolerance ? .towardMinX : .towardMaxX
        }
    }

    /// The display holding the largest part of `frame` (the first one on a tie), or nil if it is on none.
    public static func homeDisplay(for frame: CGRect, displays: [GuardDisplay]) -> GuardDisplay? {
        var best: GuardDisplay?
        var bestArea: CGFloat = 0
        for display in displays {
            let area = overlapArea(frame, display.frame)
            if area > bestArea { best = display; bestArea = area }
        }
        return best
    }

    /// True when `frame` covers the whole display: non-native full screen, kiosk and presentation windows.
    public static func coversDisplay(_ frame: CGRect, _ display: GuardDisplay, tolerance: CGFloat = 1) -> Bool {
        frame.minX <= display.frame.minX + tolerance && frame.minY <= display.frame.minY + tolerance
            && frame.maxX >= display.frame.maxX - tolerance && frame.maxY >= display.frame.maxY - tolerance
    }

    /// True when `a` and `b` overlap by more than `tolerance` points both horizontally and vertically.
    public static func overlaps(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        let a = a.standardized, b = b.standardized
        let width = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let height = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return width > tolerance && height > tolerance
    }

    /// Frames equal within `tolerance` points (window-server bounds vs Accessibility frames).
    public static func sameFrame(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: - One strip

    /// The window must end at or before `limit` (strip on its right).
    private static func endBefore(_ limit: CGFloat, _ w: CGRect, lowBound: CGFloat, _ minWidth: CGFloat,
                                  _ resizable: Bool, _ movable: Bool, _ fraction: CGFloat) -> CGRect {
        let width = w.width
        let narrowed = floor(limit - w.minX)
        let canNarrow = resizable && narrowed >= minWidth && narrowed < width
        if canNarrow && narrowed >= width * fraction { return with(w, x: w.minX, width: narrowed) }
        if movable {
            let x = floor(limit - width)
            if x >= lowBound { return with(w, x: x, width: width) }
        }
        if canNarrow { return with(w, x: w.minX, width: narrowed) }
        let edge = ceil(lowBound)
        if movable && resizable {
            let span = floor(limit - edge)
            if span >= minWidth { return with(w, x: edge, width: span) }
        }
        // Cannot fit: as far from the strip as allowed, as narrow as allowed.
        let bestWidth = resizable ? min(width, minWidth) : width
        return with(w, x: movable ? min(edge, w.minX) : w.minX, width: bestWidth)
    }

    /// The window must start at or after `limit` (strip on its left).
    private static func startAfter(_ limit: CGFloat, _ w: CGRect, highBound: CGFloat, _ minWidth: CGFloat,
                                   _ resizable: Bool, _ movable: Bool, _ fraction: CGFloat) -> CGRect {
        let width = w.width
        let start = ceil(limit)
        let narrowed = floor(w.maxX - start)
        let canNarrow = resizable && movable && narrowed >= minWidth && narrowed < width
        if canNarrow && narrowed >= width * fraction { return with(w, x: start, width: narrowed) }
        if movable && start + width <= highBound { return with(w, x: start, width: width) }
        if canNarrow { return with(w, x: start, width: narrowed) }
        let edge = floor(highBound)
        if movable && resizable {
            let span = edge - start
            if span >= minWidth { return with(w, x: start, width: span) }
        }
        let bestWidth = resizable && movable ? min(width, minWidth) : width
        return with(w, x: movable ? max(w.minX, edge - bestWidth) : w.minX, width: bestWidth)
    }

    private static func with(_ w: CGRect, x: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: x, y: w.minY, width: width, height: w.height)
    }

    static func action(from a: CGRect, to b: CGRect) -> Correction.Action {
        let moved = abs(a.minX - b.minX) > 0.5, resized = abs(a.width - b.width) > 0.5
        switch (moved, resized) {
        case (false, false): return .none
        case (true, false): return .move
        case (false, true): return .shrink
        case (true, true): return abs(a.maxX - b.maxX) <= 0.5 ? .shrink : .moveAndShrink
        }
    }

    static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let width = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let height = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return width > 0 && height > 0 ? width * height : 0
    }

    static func isUsable(_ r: CGRect) -> Bool {
        r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite && r.width > 0 && r.height > 0
            && abs(r.minX) < 1e7 && abs(r.minY) < 1e7 && r.width < 1e7 && r.height < 1e7
    }
}
