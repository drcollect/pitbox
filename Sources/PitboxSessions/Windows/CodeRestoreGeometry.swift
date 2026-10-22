import CoreGraphics
import Foundation

/// Where a restored window may go: its saved frame, clamped to the current screen's
/// visible frame minus the strip, so the window guard has nothing to correct. Quartz global coordinates throughout.
enum CodeRestoreGeometry {
    /// The display to restore onto: the one the window was parked on when it is still there, else the one holding most
    /// of the frame, else the first (the menu-bar display).
    static func display(for frame: CGRect, preferredID: UInt32?, displays: [CodeDisplay]) -> CodeDisplay? {
        if let preferredID, let match = displays.first(where: { $0.id == preferredID }) { return match }
        let best = displays.max { area(of: $0.frame.intersection(frame)) < area(of: $1.frame.intersection(frame)) }
        if let best, area(of: best.frame.intersection(frame)) > 0 { return best }
        return displays.first
    }

    /// The display's visible frame without the strip's column. A strip on the right edge cuts the area at its left
    /// side, one on the left at its right side (the guard keeps whole columns clear, gaps or not).
    static func usableArea(of display: CodeDisplay, stripRects: [CGRect]) -> CGRect {
        var usable = display.visibleFrame
        for strip in stripRects where strip.intersects(display.frame) {
            if strip.midX >= usable.midX {
                usable.size.width = max(0, min(usable.maxX, strip.minX) - usable.minX)
            } else {
                let newMin = min(max(usable.minX, strip.maxX), usable.maxX)
                usable.size.width = max(0, usable.maxX - newMin)
                usable.origin.x = newMin
            }
        }
        return usable
    }

    /// `frame` moved (and shrunk only if it must) to lie inside `area`. An empty area leaves the frame as it is.
    static func clamp(_ frame: CGRect, into area: CGRect) -> CGRect {
        guard area.width >= 1, area.height >= 1, frame.width > 0, frame.height > 0 else { return frame }
        let width = min(frame.width, area.width)
        let height = min(frame.height, area.height)
        let x = min(max(frame.minX, area.minX), area.maxX - width)
        let y = min(max(frame.minY, area.minY), area.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(.down), height: height.rounded(.down))
    }

    /// The display a frame sits on, for the record: the one holding most of it.
    static func displayID(for frame: CGRect, displays: [CodeDisplay]) -> UInt32 {
        display(for: frame, preferredID: nil, displays: displays)?.id ?? 0
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }
}
