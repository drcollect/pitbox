import AppKit
import PitboxKit

/// The status item's template icon, drawn in code (no asset catalog): a screen outline with the block as a filled
/// strip at its edge (two bars for the columns), or a thin rail when folded. Template, so the menu bar tints it.
enum PitboxMenuIcon {
    static let size = NSSize(width: 18, height: 16)

    /// The icon for an edge and fold state, with `description` for VoiceOver.
    static func image(edge: Edge, folded: Bool, description: String) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, edge: edge, folded: folded)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// The drawing, separate so tests can render it into a bitmap.
    static func draw(in rect: CGRect, edge: Edge, folded: Bool) {
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let screen = rect.insetBy(dx: 1.5, dy: 2.5)
        let outline = NSBezierPath(roundedRect: screen, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1.5
        outline.stroke()
        let inner = screen.insetBy(dx: 2.5, dy: 2.5)
        if folded {
            let x = edge == .right ? inner.maxX - 1.5 : inner.minX
            NSBezierPath(roundedRect: CGRect(x: x, y: inner.minY, width: 1.5, height: inner.height), xRadius: 0.75,
                         yRadius: 0.75).fill()
            return
        }
        // Two columns, each 2.5 pt wide with a 1 pt gutter, flush with the edge.
        let column: CGFloat = 2.5, gutter: CGFloat = 1
        let total = 2 * column + gutter
        let startX = edge == .right ? inner.maxX - total : inner.minX
        for index in 0..<2 {
            let x = startX + CGFloat(index) * (column + gutter)
            NSBezierPath(roundedRect: CGRect(x: x, y: inner.minY, width: column, height: inner.height), xRadius: 0.75,
                         yRadius: 0.75).fill()
        }
    }

    /// "Pitbox", "Pitbox, folded", "Pitbox, hidden".
    static func description(shown: Bool, folded: Bool) -> String {
        let name = AppIdentity.displayName
        if !shown { return "\(name), hidden" }
        return folded ? "\(name), folded" : name
    }
}
