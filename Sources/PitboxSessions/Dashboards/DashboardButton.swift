import AppKit
import PitboxKit

/// The arming of a button that opens something, so a button that appears or moves under a click never opens anything
/// (docs/THREAT_MODEL.md): a left press counts only when it begins and ends on the button, at least
/// `CodeTuning.openButtonArmDelay` (0.8 s) after the button appeared or last moved, and never while the pointer has
/// rested on its place since it appeared (the pointer must leave and come back). Times are `MonotonicClock` seconds.
/// Hosts that draw the ▦ pill themselves (the monitors, the desk tags) keep one per pill and call `appeared` on every
/// layout that shows or moves it.
struct DashboardOpenArming: Equatable, Sendable {
    /// When the button last appeared or moved; infinity until it is shown.
    private(set) var appearedAt: TimeInterval = .infinity
    /// The pointer was over the button's place when it appeared or moved.
    private(set) var pointerWasInside = false
    /// When the pointer last entered the button; nil while it is outside.
    private(set) var pointerEnteredAt: TimeInterval?

    /// The button appeared or moved at `now`, with the pointer inside its place or not.
    mutating func appeared(at now: TimeInterval, pointerInside: Bool) {
        appearedAt = now
        pointerWasInside = pointerInside
        pointerEnteredAt = pointerInside ? nil : pointerEnteredAt
    }

    mutating func pointerEntered(at now: TimeInterval) { pointerEnteredAt = now }

    mutating func pointerExited() {
        pointerEnteredAt = nil
        pointerWasInside = false
    }

    /// Whether a press that began at `pressBegan` counts.
    func accepts(pressBegan: TimeInterval) -> Bool {
        guard appearedAt.isFinite, pressBegan >= appearedAt + CodeTuning.openButtonArmDelay else { return false }
        if pointerWasInside {
            guard let entered = pointerEnteredAt, entered > appearedAt else { return false }
        }
        return true
    }

    /// For drawing: a press starting now would count.
    func isArmed(now: TimeInterval) -> Bool { accepts(pressBegan: now) }
}

/// The pink ▦: its looks, sizes and drawing, for the hosts that draw it (monitors, rows, tags) and for
/// `DashboardButtonView`. Colours: the pill `#F58AC4` with `#2A0B1C` words (8:1); on a dark panel a button
/// filled `#2A1424`, outlined `#6A2F55`, with `#FFC3E2` words (11.6:1). Monitors and panels are dark in both
/// appearances, so these are fixed.
enum DashboardPill {
    enum Style: Equatable, Sendable {
        /// "▦ Dashboard" on a large monitor's bezel, bottom left.
        case large
        /// "▦" as a 16 pt pill on a medium monitor's bezel, and on slim rows.
        case medium
        /// "▦" as a 14 pt pill on a small monitor's bezel.
        case small
        /// "▦ Dashboard" on a desk tag (22 pt).
        case tag
        /// A dark-panel button: "▦ Dashboard" on cards, "▦ Open dashboard" in the peek, "Open" in the list.
        case panel(String)
    }

    static let pink: UInt32 = 0xF58AC4
    static let pinkText: UInt32 = 0x2A0B1C
    static let panelFill: UInt32 = 0x2A1424
    static let panelLine: UInt32 = 0x6A2F55
    static let panelText: UInt32 = 0xFFC3E2

    static func title(_ style: Style) -> String {
        switch style {
        case .large, .tag: return DashboardWords.button
        case .medium, .small: return "▦"
        case .panel(let title): return title
        }
    }

    static func font(_ style: Style) -> NSFont {
        switch style {
        case .large, .tag: return .systemFont(ofSize: 12, weight: .semibold)
        case .medium, .small: return .systemFont(ofSize: 12, weight: .bold)
        case .panel: return .systemFont(ofSize: 12, weight: .medium)
        }
    }

    /// The pill's size.
    static func size(_ style: Style) -> CGSize {
        let height: CGFloat
        let padding: CGFloat
        switch style {
        case .large: (height, padding) = (18, 7)
        case .medium: (height, padding) = (16, 4)
        case .small: (height, padding) = (14, 3)
        case .tag: (height, padding) = (22, 9)
        case .panel: (height, padding) = (22, 10)
        }
        let text = ceil((title(style) as NSString).size(withAttributes: [.font: font(style)]).width)
        return CGSize(width: max(height, text + 2 * padding), height: height)
    }

    /// Where a monitor's pill sits: on the bezel's bottom edge, 8 pt from its left, in a flipped
    /// view's coordinates.
    static func frame(_ style: Style, onBezel bezel: CGRect) -> CGRect {
        let size = size(style)
        return CGRect(x: bezel.minX + 8, y: (bezel.maxY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    static func isPanel(_ style: Style) -> Bool {
        if case .panel = style { return true }
        return false
    }

    /// VoiceOver's name for the button (no session text).
    static func accessibilityName(_ style: Style) -> String {
        switch style {
        case .panel(let title) where title == DashboardWords.open: return "Open dashboard"
        case .panel(let title): return title.replacingOccurrences(of: "▦ ", with: "")
        default: return "Dashboard"
        }
    }

    /// Draws the pill in `rect`: brighter under the pointer, darker while pressed, dimmed while not armed.
    static func draw(_ style: Style, in rect: CGRect, hovered: Bool = false, pressed: Bool = false, armed: Bool = true) {
        let fill: NSColor, text: NSColor
        var line: NSColor?
        switch style {
        case .panel:
            fill = ThemeColor.srgb(pressed ? 0x3A1C33 : (hovered && armed ? 0x34192D : panelFill))
            line = ThemeColor.srgb(panelLine)
            text = ThemeColor.srgb(panelText, alpha: armed ? 1 : 0.6)
        default:
            fill = ThemeColor.srgb(pressed ? 0xD873AB : (hovered && armed ? 0xFF9FD2 : pink), alpha: armed ? 1 : 0.7)
            text = ThemeColor.srgb(pinkText)
        }
        let radius = isPanel(style) ? 6 : rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let line {
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            outline.lineWidth = 1
            line.setStroke()
            outline.stroke()
        }
        let font = font(style)
        let height = ceil(font.ascender - font.descender + font.leading)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.lineBreakMode = .byTruncatingTail
        (title(style) as NSString).draw(with: CGRect(x: rect.minX + 2, y: (rect.midY - height / 2).rounded(),
                                                     width: rect.width - 4, height: height),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: font, .foregroundColor: text, .paragraphStyle: center])
    }
}

/// A ▦ button as its own view (cards, the peek, desk tags, the dashboards list): it draws `DashboardPill`, arms by
/// `DashboardOpenArming`, shows the address as its tooltip and calls `onOpen` on an armed click. It never takes the
/// keyboard and accepts the first mouse (one click acts in a panel that is not key).
final class DashboardButtonView: NSView {
    var style: DashboardPill.Style { didSet { if style != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var onOpen: (() -> Void)?
    /// The monotonic clock and the pointer's place in this view's coordinates (tests replace them).
    var clock: () -> TimeInterval = { MonotonicClock.now() }
    var pointer: ((DashboardButtonView) -> CGPoint?) = { view in
        guard let window = view.window else { return nil }
        return view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }
    private(set) var arming = DashboardOpenArming()
    private var hovered = false
    private var pressBegan: TimeInterval?
    private var rearmTimer: Timer?

    /// A button of `style`; `tooltip` is the full address (`DashboardWords.tooltip`).
    init(style: DashboardPill.Style, tooltip: String?, frame: CGRect = .zero) {
        self.style = style
        super.init(frame: frame)
        toolTip = tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(DashboardPill.accessibilityName(style))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { DashboardPill.size(style) }

    // MARK: Arming

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { rearm() } else { rearmTimer?.invalidate() }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = newOrigin != frame.origin
        super.setFrameOrigin(newOrigin)
        if moved, window != nil { rearm() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            updateTrackingAreas()
            if window != nil { rearm() }
        }
    }

    /// The button appeared or moved now: it arms again (the host calls this too after a layout change that moved it).
    func rearm() {
        let inside = pointer(self).map { bounds.contains($0) } ?? false
        arming.appeared(at: clock(), pointerInside: inside)
        pressBegan = nil
        needsDisplay = true
        rearmTimer?.invalidate()
        let timer = Timer(timeInterval: CodeTuning.openButtonArmDelay + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        RunLoop.main.add(timer, forMode: .common)
        rearmTimer = timer
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        arming.pointerEntered(at: clock())
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        arming.pointerExited()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        pressBegan = clock()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let began = pressBegan
        pressBegan = nil
        needsDisplay = true
        guard let began, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press(began: began)
    }

    /// A press that began at `began` and ended on the button: opens when armed, else does nothing.
    func press(began: TimeInterval) {
        guard arming.accepts(pressBegan: began) else { return }
        onOpen?()
    }

    /// No Accessibility press: the button opens a URL, and nothing that acts accepts a press another process can send
    /// (docs/THREAT_MODEL.md). Only a real click opens a dashboard.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformPress) { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func accessibilityPerformPress() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        DashboardPill.draw(style, in: bounds, hovered: hovered, pressed: pressBegan != nil,
                           armed: arming.isArmed(now: clock()))
    }
}
