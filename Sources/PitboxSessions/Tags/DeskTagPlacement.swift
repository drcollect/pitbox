import CoreGraphics
import Foundation
import PitboxKit

/// One display, in Quartz global coordinates (origin at the primary display's top-left, y down), like window-server
/// bounds and the strip's reserved regions.
struct DeskTagDisplay: Equatable, Sendable {
    var id: UInt32
    var frame: CGRect
    /// Menu bar to Dock.
    var visibleFrame: CGRect
}

/// Where a tag goes, in Quartz coordinates.
struct DeskTagLayout: Equatable {
    /// The stack of pills: the main item on top, ▦ under it, right-aligned.
    var frame: CGRect
    /// Only the glyph's circle and the short form (the window or the room is too narrow).
    var compact: Bool
    /// Inside the window (a window just under the menu bar).
    var inside: Bool
}

/// Tag and desk-peek placement. Pure, Quartz coordinates.
enum DeskTagPlacement {
    /// The height of a stack of `count` pills.
    static func stackHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * DeskTagTuning.pillHeight + CGFloat(count - 1) * DeskTagTuning.pillGap
    }

    /// The display a window is on: the one holding most of it; nil when it is on none.
    static func display(for window: CGRect, in displays: [DeskTagDisplay]) -> DeskTagDisplay? {
        var best: (display: DeskTagDisplay, area: CGFloat)?
        for display in displays {
            let overlap = display.frame.intersection(window)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (display, area) }
        }
        return best?.display
    }

    /// The tag beside `window`: right-aligned at the window's right edge minus `rightInset`, the first pill centred on the
    /// window's top edge (half above it, half over its title bar); fully inside (top + 4 pt) when there is less than
    /// 12 pt above the window in its display's visible frame; inside the visible frame; its right edge at least 4 pt
    /// left of a strip on the right (right of a strip on the left); never wider than the window minus 40 pt, else the
    /// compact form. Nil when not even the compact form fits.
    /// - Parameters:
    ///   - widths: each pill's natural width (at most 260 pt), top first.
    ///   - compactWidths: each pill's width in the compact form.
    static func layout(window: CGRect, display: DeskTagDisplay, strips: [ReservedRegion], widths: [CGFloat],
                       compactWidths: [CGFloat], rightInset: CGFloat = DeskTagTuning.rightInset) -> DeskTagLayout? {
        guard !widths.isEmpty, widths.count == compactWidths.count else { return nil }
        let visible = display.visibleFrame
        let height = stackHeight(count: widths.count)
        let roomAbove = window.minY - visible.minY
        let inside = roomAbove < DeskTagTuning.insideBelowRoom
        var top = inside ? window.minY + DeskTagTuning.insideTop : window.minY - DeskTagTuning.pillHeight / 2
        top = min(max(top, visible.minY), visible.maxY - height)

        var right = min(window.maxX - rightInset, visible.maxX)
        var left = visible.minX
        let band = CGRect(x: visible.minX, y: top, width: visible.width, height: height)
        for strip in strips where strip.rect.intersects(band) && strip.rect.intersects(display.frame) {
            switch strip.edge {
            case .right: right = min(right, strip.rect.minX - DeskTagTuning.stripGap)
            case .left: left = max(left, strip.rect.maxX + DeskTagTuning.stripGap)
            }
        }
        let room = min(window.width - DeskTagTuning.windowMargin, right - left)
        let natural = widths.max() ?? 0
        let compactWidth = compactWidths.max() ?? 0
        let compact: Bool
        let width: CGFloat
        if natural <= room {
            compact = false
            width = natural
        } else if compactWidth <= room {
            compact = true
            width = compactWidth
        } else {
            return nil
        }
        return DeskTagLayout(frame: CGRect(x: right - width, y: top, width: width, height: height), compact: compact,
                          inside: inside)
    }

    /// The desk peek next to the tag, on the side away from the strip (left of the tag for a strip on the right, which
    /// is also the side without a strip), its top level with the tag's, inside the visible frame and never over the
    /// strip; below the tag when neither side has room.
    static func peekFrame(tag: CGRect, size: CGSize, display: DeskTagDisplay, strips: [ReservedRegion]) -> CGRect {
        let visible = display.visibleFrame.insetBy(dx: DeskTagTuning.peekMargin, dy: DeskTagTuning.peekMargin)
        let height = min(size.height, visible.height)
        let width = min(size.width, visible.width)
        let onDisplay = strips.filter { $0.rect.intersects(display.frame) }
        let stripOnLeft = onDisplay.contains { $0.edge == .left } && !onDisplay.contains { $0.edge == .right }
        var minX = visible.minX
        var maxX = visible.maxX
        for strip in onDisplay {
            switch strip.edge {
            case .right: maxX = min(maxX, strip.rect.minX - DeskTagTuning.stripGap)
            case .left: minX = max(minX, strip.rect.maxX + DeskTagTuning.stripGap)
            }
        }
        let leftX = tag.minX - DeskTagTuning.peekGap - width
        let rightX = tag.maxX + DeskTagTuning.peekGap
        let leftFits = leftX >= minX
        let rightFits = rightX + width <= maxX
        var y = tag.minY
        var x: CGFloat
        if stripOnLeft ? rightFits : leftFits {
            x = stripOnLeft ? rightX : leftX
        } else if stripOnLeft ? leftFits : rightFits {
            x = stripOnLeft ? leftX : rightX
        } else {
            // Below the tag, right-aligned with it.
            x = tag.maxX - width
            y = tag.maxY + DeskTagTuning.peekGap
        }
        x = min(max(x, minX), max(minX, maxX - width))
        y = min(max(y, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
