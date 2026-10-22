import AppKit
import PitboxKit

/// The dashed "Drop to park" slot: while a drop is armed over a bucket of the visible block, the block puts this view
/// in that bucket at the session's stable place, at the size of that bucket's monitors (or a slim row), and outlines
/// the bucket as a monitor drag's target does. The block owns where it sits (its bucket layout;
/// `CodeDragToPark.onSlotChange` says when and where).
///
/// A picture only: it takes no clicks (hit testing passes through), never the keyboard, and shows no session text.
/// It sits on the block's glass, so its words follow the appearance like the header's (4.5:1, `PaletteTests`); the
/// dashed 2 pt line and the faint fill are the bucket's colour, which the bucket palette keeps at 3:1 on the glass.
final class DropSlotView: NSView {
    static let lineWidth: CGFloat = 2
    static let dash: [CGFloat] = [6, 4]
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// The bucket's colour (Violet, Amber, …); the theme's accent when the bucket has none.
    var tint: NSColor? {
        didSet { needsDisplay = true }
    }
    /// The corner radius of the bucket's monitors (10 large, 8 medium, 7 small; 6 for a slim row).
    var cornerRadius: CGFloat = 10 {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(CodeDropWords.dropToPark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = ThemeColor.isDark(effectiveAppearance)
        let color = tint ?? PitboxTheme.accent.color(dark: dark)
        let inset = Self.lineWidth / 2
        let shape = bounds.insetBy(dx: inset, dy: inset)
        guard shape.width > 4, shape.height > 4 else { return }
        let radius = min(cornerRadius, shape.height / 2)
        let path = NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)
        color.withAlphaComponent(0.10).setFill()
        path.fill()
        path.lineWidth = Self.lineWidth
        path.setLineDash(Self.dash, count: Self.dash.count, phase: 0)
        color.setStroke()
        path.stroke()
        let words = NSAttributedString(string: CodeDropWords.dropToPark, attributes: [
            .font: Self.font, .foregroundColor: CodeMonitorPalette(dark: dark).headerTitle,
        ])
        let size = words.size()
        guard size.width < shape.width - 8 else { return }
        words.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
