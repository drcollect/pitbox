import AppKit
import PitboxKit

/// A monitor being dragged between buckets. Pressing on a monitor and moving 5 pt starts it (bucket mode only; a press
/// that does not move stays a click). The monitor dims to 35 % and a small card follows the pointer: the headline and
/// "Drop in a bucket". Targets are every bucket's header or body, folded ones included; the bucket under the pointer
/// (not the monitor's own) shows a 2 pt accent outline.
///
/// - A drop on another bucket moves the session there, at its stable place.
/// - A drop on its own bucket, or anywhere else in the block, changes nothing.
/// - A drop outside the block does what a click on that monitor does (restore, activate on another Space, the
///   deep link for a closed window, nothing while "window not matched"); the drop point is not used.
/// - Escape cancels; so do the block hiding or folding (`dismissOverlays`), and the session going away.
///
/// It is a tracking of the monitor view's own mouse events: no pasteboard, no drag session, nothing leaves the app, and
/// no window is touched before the drop.
struct CodeMonitorDrag: Equatable {
    /// What a drop would do now.
    enum Drop: Equatable {
        case move(toBucket: String)
        /// Outside the block: the monitor's click.
        case click
        case nothing
    }

    var sessionID: String
    var fromBucket: String
    /// The bucket under the pointer (its own included), nil elsewhere.
    var over: String?
    var outsideStrip = false
    /// The block took the keyboard for Escape; it is handed back at the end.
    var tookKeyboard = false

    var drop: Drop { Self.drop(over: over, from: fromBucket, outsideStrip: outsideStrip) }

    /// The bucket that shows the drop outline: one the drop would move the session to.
    var highlighted: String? {
        if case .move(let bucket) = drop { return bucket }
        return nil
    }

    static func drop(over: String?, from: String, outsideStrip: Bool) -> Drop {
        if outsideStrip { return .click }
        if let over, over != from { return .move(toBucket: over) }
        return .nothing
    }

    /// The card's second line.
    static let cardHint = "Drop in a bucket"
}

/// The card that follows the pointer during a drag: the monitor's headline (plain text already) and "Drop in a bucket".
/// It never takes clicks.
final class CodeMonitorDragCard: NSView {
    private(set) var headline: String
    static let size = CGSize(width: 200, height: 46)

    init(headline: String) {
        self.headline = headline
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = CGSize(width: 0, height: -4)
            return shadow
        }()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: card, xRadius: 9, yRadius: 9)
        CodeMonitorPalette.color(0x1B1E25, 0.96).setFill()
        path.fill()
        path.lineWidth = 1.5
        PitboxTheme.accent.color(dark: true).setStroke()
        path.stroke()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let titleFont = CodeMonitorFonts.bodyStrong, hintFont = CodeMonitorFonts.body
        let titleHeight = CodeMonitorFonts.lineHeight(titleFont), hintHeight = CodeMonitorFonts.lineHeight(hintFont)
        let top = card.midY - (titleHeight + hintHeight) / 2
        (headline as NSString).draw(with: CGRect(x: card.minX + 10, y: top.rounded(), width: card.width - 20, height: titleHeight),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: titleFont, .foregroundColor: CodeMonitorPalette.color(CodeMonitorPalette.headline),
                                                 .paragraphStyle: style])
        (CodeMonitorDrag.cardHint as NSString).draw(
            with: CGRect(x: card.minX + 10, y: (top + titleHeight).rounded(), width: card.width - 20, height: hintHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: hintFont, .foregroundColor: CodeMonitorPalette.color(CodeMonitorPalette.dim), .paragraphStyle: style])
    }
}

/// The 2 pt accent outline around the bucket a drop would move a monitor to (also a window dropped over a
/// bucket by drag-to-park). It never takes clicks.
final class CodeBucketDropOutline: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = ThemeColor.isDark(effectiveAppearance)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        path.lineWidth = 2
        PitboxTheme.accent.color(dark: dark).setStroke()
        path.stroke()
        PitboxTheme.accent.color(dark: dark).withAlphaComponent(0.06).setFill()
        path.fill()
    }
}
