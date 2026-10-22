import AppKit
import PitboxKit

/// The summary line's view: `height` points tall, placed directly under the block header (above the Ready list),
/// drawn on the block's glass in the header's colours, 12 pt. Counts are semibold; "past ETA" and warnings orange;
/// "▦ N dashboards" pink and a button (`onOpenDashboards`, which opens the dashboards list: it opens nothing outside
/// the block, so it needs no arming). When the line is empty the block gives it no room.
/// When the block is narrow, parts are left out in this order: just finished, ready for you, warnings; the running part
/// and the dashboards button stay.
final class CodeSummaryLineView: NSView {
    static let height: CGFloat = 20

    var line: CodeSummaryLine {
        didSet {
            guard line != oldValue else { return }
            needsLayoutPass = true
            needsDisplay = true
            updateAccessibility()
        }
    }

    /// The dashboards button was clicked.
    var onOpenDashboards: (() -> Void)?
    /// Tests: every string drawn.
    var drawnTexts: [String]?

    private var needsLayoutPass = true
    private var laidOut: [(part: CodeSummaryLine.Part, rect: CGRect)] = []
    private(set) var dashboardsRect: CGRect?
    private var hovered = false
    private var pressed = false

    init(line: CodeSummaryLine = CodeSummaryLine(), frame: CGRect = .zero) {
        self.line = line
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { needsLayoutPass = true }
        super.setFrameSize(newSize)
    }

    // MARK: Colours (on the glass; the header's text colours of the block; contrast checked by SummaryLineTests)

    static let plainDark: UInt32 = 0xC9C4DA, plainLight: UInt32 = 0x3F3A56
    static let numberDark: UInt32 = 0xF2F0F8, numberLight: UInt32 = 0x1E1B2E
    static let attentionDark: UInt32 = 0xFFB36B, attentionLight: UInt32 = 0x6B3C00
    static let dashboardDark: UInt32 = 0xFFC3E2, dashboardLight: UInt32 = 0x7E1A52

    static func color(_ tone: CodeSummaryLine.Run.Tone, dark: Bool) -> NSColor {
        let value: UInt32
        switch tone {
        case .plain: value = dark ? plainDark : plainLight
        case .number: value = dark ? numberDark : numberLight
        case .attention: value = dark ? attentionDark : attentionLight
        case .dashboard: value = dark ? dashboardDark : dashboardLight
        }
        return ThemeColor.srgb(value)
    }

    static func font(_ tone: CodeSummaryLine.Run.Tone) -> NSFont {
        switch tone {
        case .number: return .systemFont(ofSize: 12, weight: .semibold)
        case .dashboard: return .systemFont(ofSize: 12, weight: .medium)
        case .plain, .attention: return .systemFont(ofSize: 12, weight: .regular)
        }
    }

    // MARK: Layout and drawing

    private static let separator = " · "

    static func width(of part: CodeSummaryLine.Part) -> CGFloat {
        part.runs.reduce(0) { $0 + ceil(($1.text as NSString).size(withAttributes: [.font: font($1.tone)]).width) }
    }

    private static var separatorWidth: CGFloat {
        ceil((separator as NSString).size(withAttributes: [.font: font(.plain)]).width)
    }

    /// The parts that fit `width`, each with its rect, leaving out the least needed ones first.
    static func layout(_ line: CodeSummaryLine, width available: CGFloat,
                       height: CGFloat) -> [(part: CodeSummaryLine.Part, rect: CGRect)] {
        var parts = line.parts
        func total(_ list: [CodeSummaryLine.Part]) -> CGFloat {
            list.reduce(0) { $0 + width(of: $1) } + CGFloat(max(0, list.count - 1)) * separatorWidth
        }
        for kind in [CodeSummaryLine.Part.Kind.justFinished, .ready, .warnings] where total(parts) > available {
            parts.removeAll { $0.kind == kind }
        }
        var x: CGFloat = 2
        var out: [(CodeSummaryLine.Part, CGRect)] = []
        for (index, part) in parts.enumerated() {
            if index > 0 { x += separatorWidth }
            let w = min(width(of: part), max(0, available - x))
            out.append((part, CGRect(x: x, y: 0, width: w, height: height)))
            x += w
        }
        return out
    }

    override func layout() {
        super.layout()
        relayoutIfNeeded()
    }

    private func relayoutIfNeeded() {
        guard needsLayoutPass else { return }
        needsLayoutPass = false
        laidOut = Self.layout(line, width: bounds.width - 4, height: bounds.height)
        dashboardsRect = laidOut.first { $0.part.kind == .dashboards }?.rect
        updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        relayoutIfNeeded()
        let dark = ThemeColor.isDark(effectiveAppearance)
        let lineHeight = ceil(Self.font(.plain).ascender - Self.font(.plain).descender + Self.font(.plain).leading)
        let y = ((bounds.height - lineHeight) / 2).rounded()
        for (index, item) in laidOut.enumerated() {
            if index > 0 {
                let sx = item.rect.minX - Self.separatorWidth
                draw(Self.separator, at: CGPoint(x: sx, y: y), width: Self.separatorWidth, tone: .plain, dark: dark)
            }
            var x = item.rect.minX
            for run in item.part.runs {
                let w = ceil((run.text as NSString).size(withAttributes: [.font: Self.font(run.tone)]).width)
                let available = item.rect.maxX - x
                guard available > 2 else { break }
                draw(run.text, at: CGPoint(x: x, y: y), width: min(w, available), tone: run.tone, dark: dark,
                     underline: item.part.kind == .dashboards && hovered)
                x += w
            }
        }
    }

    private func draw(_ text: String, at point: CGPoint, width: CGFloat, tone: CodeSummaryLine.Run.Tone, dark: Bool,
                      underline: Bool = false) {
        drawnTexts?.append(text)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [.font: Self.font(tone), .foregroundColor: Self.color(tone, dark: dark),
                                                         .paragraphStyle: style]
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let height = ceil(Self.font(tone).ascender - Self.font(tone).descender + Self.font(tone).leading)
        (text as NSString).draw(with: CGRect(x: point.x, y: point.y, width: width, height: height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    // MARK: The dashboards button

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        if let rect = dashboardsRect {
            addTrackingArea(NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                                           owner: self, userInfo: nil))
        }
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = dashboardsRect?.contains(convert(event.locationInWindow, from: nil)) ?? false
    }

    override func mouseUp(with event: NSEvent) {
        let inside = dashboardsRect?.contains(convert(event.locationInWindow, from: nil)) ?? false
        defer { pressed = false }
        guard pressed, inside else { return }
        onOpenDashboards?()
    }

    /// The button at `point` (view coordinates), for parent views that route clicks themselves.
    func isDashboardsButton(at point: CGPoint) -> Bool {
        relayoutIfNeeded()
        return dashboardsRect?.contains(point) ?? false
    }

    private func updateAccessibility() {
        setAccessibilityLabel(line.isEmpty ? "No running sessions" : line.text)
        var actions: [NSAccessibilityCustomAction] = []
        if line.dashboards > 0 {
            actions.append(NSAccessibilityCustomAction(name: "Show the dashboards") { [weak self] in
                self?.onOpenDashboards?()
                return true
            })
        }
        setAccessibilityCustomActions(actions)
    }
}
