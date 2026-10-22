import AppKit
import PitboxKit

/// The colours of warnings (warning and late `#FFB36B`). On a monitor's screen, in the peek and on the dark card the
/// dark values apply; `dark: false` is for words on the block's light glass. Contrast is checked by
/// `WarningViewTests` (4.5:1 for words, 3:1 for the outline).
struct CodeWarningPalette: Equatable {
    var dark: Bool

    static let orange: UInt32 = 0xFFB36B, orangeLight: UInt32 = 0x6B3C00
    /// The monitor's screen outline and the card's border.
    static let outline: UInt32 = 0xB86A1F
    /// The Warning card's fill.
    static let cardFill: UInt32 = 0x231A0F
    static let detail: UInt32 = 0xFFCF9E, detailLight: UInt32 = 0x4A2A00

    var words: UInt32 { dark ? Self.orange : Self.orangeLight }
    var detail: UInt32 { dark ? Self.detail : Self.detailLight }

    static func color(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor { ThemeColor.srgb(value, alpha: alpha) }

    /// The orange screen outline of a warned monitor, stroked inside `rect` (the monitor drawing calls it).
    static func strokeOutline(_ rect: CGRect, radius: CGFloat, width: CGFloat = 1.5) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
        color(outline).setStroke()
        path.lineWidth = width
        path.stroke()
    }
}

/// The orange warning line of large and medium monitors: "⚠ Looks stuck: 4 commands failed in a row", one
/// line, cut at the end, 12 pt; the first warning when there are several, "+1" after it. Self-contained, for surfaces that
/// host views (the desk peek); a monitor draws the same line itself (`CodeMonitorWarningLine`). It takes no clicks.
final class CodeWarningLineView: NSView {
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    private(set) var text: String
    var palette: CodeWarningPalette { didSet { needsDisplay = true } }

    init(warnings: [CodeWarning], now: Date, hidden: Bool, palette: CodeWarningPalette = CodeWarningPalette(dark: true),
         width: CGFloat) {
        text = Self.text(warnings, now: now, hidden: hidden)
        self.palette = palette
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: ceil(Self.font.ascender - Self.font.descender) + 2))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(warnings: [CodeWarning], now: Date, hidden: Bool) {
        let next = Self.text(warnings, now: now, hidden: hidden)
        guard next != text else { return }
        text = next
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    /// The line's words: the first warning, and "+1" for each more.
    static func text(_ warnings: [CodeWarning], now: Date, hidden: Bool) -> String {
        guard let first = warnings.first else { return "" }
        let more = warnings.count > 1 ? "  +\(warnings.count - 1)" : ""
        return CodeWarningWords.line(first, now: now, hidden: hidden) + more
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: bounds, withAttributes: [
            .font: Self.font, .foregroundColor: CodeWarningPalette.color(palette.words), .paragraphStyle: paragraph,
        ])
    }
}

/// The peek's warnings (the peek shows the last failure's exit code): each warning's statement in orange and
/// its facts below in a lighter orange. Self-contained (`accessoryHeight(forWidth:)`), for surfaces that host views; the
/// monitor's peek draws the same lines (`CodeWarningWords.peekLines`) with its own elements.
final class CodeWarningDetailsView: NSView {
    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let detailFont = NSFont.systemFont(ofSize: 12)

    private(set) var lines: [(text: String, title: Bool)] = []
    var palette: CodeWarningPalette { didSet { needsDisplay = true } }

    init(warnings: [CodeWarning], now: Date, hidden: Bool, palette: CodeWarningPalette = CodeWarningPalette(dark: true),
         width: CGFloat) {
        self.palette = palette
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Warnings")
        update(warnings: warnings, now: now, hidden: hidden)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The height the section takes (0 without warnings).
    var height: CGFloat { frame.height }

    /// The height at any width: one line per fact, cut at the end (the shape of the block's `CodeTileAccessory`).
    func accessoryHeight(forWidth width: CGFloat) -> CGFloat { height }

    func update(warnings: [CodeWarning], now: Date, hidden: Bool) {
        lines = warnings.flatMap { warning -> [(text: String, title: Bool)] in
            let all = CodeWarningWords.peekLines(warning, now: now, hidden: hidden)
            return all.enumerated().map { (text: $0.offset == 0 ? "⚠ " + $0.element : $0.element, title: $0.offset == 0) }
        }
        let height = lines.reduce(CGFloat(0)) { $0 + Self.lineHeight($1.title) } + CGFloat(max(0, warnings.count - 1)) * 6
        setFrameSize(CGSize(width: frame.width, height: height))
        setAccessibilityLabel(lines.map(\.text).joined(separator: ". "))
        needsDisplay = true
    }

    private static func lineHeight(_ title: Bool) -> CGFloat {
        let font = title ? titleFont : detailFont
        return ceil(font.ascender - font.descender + font.leading) + 2
    }

    override func draw(_ dirtyRect: NSRect) {
        var y: CGFloat = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (index, line) in lines.enumerated() {
            if line.title, index > 0 { y += 6 }
            let height = Self.lineHeight(line.title)
            (line.text as NSString).draw(in: CGRect(x: 0, y: y, width: bounds.width, height: height), withAttributes: [
                .font: line.title ? Self.titleFont : Self.detailFont, .paragraphStyle: paragraph,
                .foregroundColor: CodeWarningPalette.color(line.title ? palette.words : palette.detail),
            ])
            y += height
        }
    }
}
