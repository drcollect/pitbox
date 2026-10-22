import AppKit

/// A custom-drawn control of the command sheet: mouse only. It is never first responder
/// (so no key can press it), has no key equivalent and is never a default button. A press counts only when a real left
/// mouse button goes down on it (a single click, not a double click's second half, not Control-click) and comes up on
/// it, and the press began after the button armed (`CommandArming`). Run, Type, Fetch file, Copy, the ticks and the
/// fetched file's Open offer no Accessibility press action: VoiceOver reads them, with a hint, and cannot press them
/// (nothing that acts accepts a press another process can send; Close, Cancel and Show in Finder do).
@MainActor
final class CommandSheetButton: NSView {
    enum Style: Equatable {
        /// Yes, run this; Fetch file.
        case go
        /// Yes, run this risky command.
        case danger
        /// Copy, Type, Cancel, …
        case secondary
        /// A disclosure ("▸ How it runs").
        case plain
        /// The header's ✕.
        case glyph
        /// One choice of a pair (This Mac / The server, the login user).
        case chip
        /// A red line's tick box, with its words.
        case tick
    }

    var title: String { didSet { if title != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    /// The small grey part after a tick's words ("line 2").
    var detail: String? { didSet { if detail != oldValue { needsDisplay = true } } }
    var style: Style { didSet { if style != oldValue { needsDisplay = true } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { if !isEnabled { dropPress() }; needsDisplay = true } } }
    /// A chip that is picked, a tick that is ticked.
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var rule: CommandArming.Rule = .normal { didSet { if rule != oldValue { needsDisplay = true } } }
    var allowsAccessibilityPress = false
    var accessibilityHint: String?
    var palette = CommandSheetPalette(dark: true) { didSet { if palette != oldValue { needsDisplay = true } } }
    var onPress: (() -> Void)?
    /// The sheet's arming now, and its clock (`MonotonicClock` in the app).
    var arming: () -> CommandArming
    var clock: () -> TimeInterval

    private(set) var pressBegan: TimeInterval?
    private(set) var pressedInside = false
    /// When the pointer last entered; nil while it is outside.
    private(set) var pointerEnteredAt: TimeInterval?

    init(title: String, style: Style, arming: @escaping () -> CommandArming, clock: @escaping () -> TimeInterval) {
        self.title = title
        self.style = style
        self.arming = arming
        self.clock = clock
        super.init(frame: .zero)
        setAccessibilityElement(true)
        switch style {
        case .tick: setAccessibilityRole(.checkBox)
        case .chip: setAccessibilityRole(.radioButton)
        default: setAccessibilityRole(.button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    // MARK: Pressing

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, event.clickCount == 1, !event.modifierFlags.contains(.control) else { return }
        beginPress()
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressBegan != nil else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressedInside {
            pressedInside = inside
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard event.type == .leftMouseUp else { return }
        endPress(inside: bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    /// A press begins now (tests call it directly).
    func beginPress() {
        guard isEnabled, !isHidden else { return }
        pressBegan = clock()
        pressedInside = true
        needsDisplay = true
    }

    /// The press ends: it acts only if it ends inside, the button is still enabled, and the press began after arming.
    func endPress(inside: Bool) {
        let began = pressBegan
        pressBegan = nil
        pressedInside = false
        needsDisplay = true
        guard inside, isEnabled, !isHidden, let began else { return }
        guard arming().accepts(rule, pressBegan: began, pointerEnteredAt: pointerEnteredAt) else { return }
        onPress?()
    }

    /// The sheet re-armed: a press in progress no longer counts.
    func dropPress() {
        guard pressBegan != nil else { return }
        pressBegan = nil
        pressedInside = false
        needsDisplay = true
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { pointerEntered() }
    override func mouseExited(with event: NSEvent) { pointerExited() }

    /// The pointer came over the button now (tests call it directly).
    func pointerEntered() {
        pointerEnteredAt = clock()
        needsDisplay = true
    }

    func pointerExited() {
        pointerEnteredAt = nil
        needsDisplay = true
    }

    private var pointerIsInside: Bool {
        if pointerEnteredAt != nil { return true }
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// True when a press beginning now would count.
    var isArmed: Bool { arming().isArmed(rule, now: clock(), pointerEnteredAt: pointerEnteredAt, pointerInside: pointerIsInside) }

    // MARK: Accessibility

    override func accessibilityLabel() -> String? { title }
    override func accessibilityHelp() -> String? { accessibilityHint ?? toolTip }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityValue() -> Any? {
        switch style {
        case .tick, .chip: return isSelected ? 1 : 0
        default: return nil
        }
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformPress) { return allowsAccessibilityPress }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func accessibilityPerformPress() -> Bool {
        guard allowsAccessibilityPress, isEnabled, !isHidden, isArmed else { return false }
        onPress?()
        return true
    }

    // MARK: Size and drawing

    var naturalWidth: CGFloat {
        switch style {
        case .glyph: return 24
        case .plain: return CommandSheetFonts.width(title, CommandSheetFonts.note) + 14
        case .chip: return CommandSheetFonts.width(title, CommandSheetFonts.note) + 26
        case .tick: return 0
        default: return CommandSheetFonts.width(title, CommandSheetFonts.button) + 26
        }
    }

    /// A tick's height for `width`: its words wrap.
    func tickHeight(width: CGFloat) -> CGFloat {
        let text = tickText()
        let rect = text.boundingRect(with: CGSize(width: max(40, width - 40), height: 10_000), options: [.usesLineFragmentOrigin])
        return max(30, ceil(rect.height) + 14)
    }

    private func tickText() -> NSAttributedString {
        let out = NSMutableAttributedString(string: title, attributes: [.font: CommandSheetFonts.note, .foregroundColor: palette.redText])
        if let detail {
            out.append(NSAttributedString(string: "   (" + detail + ")", attributes: [.font: CommandSheetFonts.note,
                                                                                    .foregroundColor: palette.redText.withAlphaComponent(0.7)]))
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let armed = isEnabled && isArmed
        let pressed = pressBegan != nil && pressedInside
        let hovered = armed && pointerEnteredAt != nil
        let alpha: CGFloat = armed ? 1 : (isEnabled ? 0.45 : 0.32)
        let rect = bounds
        switch style {
        case .go, .danger:
            let base = style == .go ? palette.go : palette.danger
            let fill = pressed ? base.blended(withFraction: 0.25, of: .black) ?? base : (hovered ? base.blended(withFraction: 0.12, of: .white) ?? base : base)
            fill.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).fill()
            drawTitle(color: (style == .go ? palette.onGo : palette.onDanger).withAlphaComponent(armed ? 1 : 0.8), font: CommandSheetFonts.button)
        case .secondary:
            let fill = pressed ? palette.secondaryHover.blended(withFraction: 0.2, of: .black) ?? palette.secondaryHover
                : (hovered ? palette.secondaryHover : palette.secondary)
            fill.withAlphaComponent(alpha).setFill()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            path.fill()
            palette.line.withAlphaComponent(alpha).setStroke()
            path.lineWidth = 1
            path.stroke()
            drawTitle(color: palette.fg.withAlphaComponent(alpha), font: CommandSheetFonts.button)
        case .plain:
            if pressed || hovered {
                palette.secondary.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            let font = CommandSheetFonts.note
            let size = (title as NSString).size(withAttributes: [.font: font])
            (title as NSString).draw(at: CGPoint(x: 7, y: rect.midY - size.height / 2),
                                     withAttributes: [.font: font, .foregroundColor: palette.dim])
        case .glyph:
            if pressed || hovered {
                palette.secondary.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            }
            let path = NSBezierPath()
            let inset = rect.insetBy(dx: 8, dy: 8)
            path.move(to: CGPoint(x: inset.minX, y: inset.minY))
            path.line(to: CGPoint(x: inset.maxX, y: inset.maxY))
            path.move(to: CGPoint(x: inset.maxX, y: inset.minY))
            path.line(to: CGPoint(x: inset.minX, y: inset.maxY))
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            palette.dim.setStroke()
            path.stroke()
        case .chip:
            let fill = isSelected ? palette.accentSoft : (hovered ? palette.secondaryHover : palette.secondary)
            fill.withAlphaComponent(alpha).setFill()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
            path.fill()
            (isSelected ? palette.accent : palette.line).withAlphaComponent(alpha).setStroke()
            path.lineWidth = isSelected ? 1.5 : 1
            path.stroke()
            drawTitle(color: palette.fg.withAlphaComponent(alpha), font: CommandSheetFonts.note)
        case .tick:
            palette.redFill.setFill()
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            card.fill()
            palette.redLine.setStroke()
            card.lineWidth = 1
            card.stroke()
            let box = CGRect(x: 10, y: 9, width: 14, height: 14)
            let boxPath = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            (isSelected ? palette.red : palette.fill).withAlphaComponent(alpha).setFill()
            boxPath.fill()
            palette.red.withAlphaComponent(alpha).setStroke()
            boxPath.lineWidth = 1.4
            boxPath.stroke()
            if isSelected {
                let check = NSBezierPath()
                check.move(to: CGPoint(x: box.minX + 3, y: box.midY))
                check.line(to: CGPoint(x: box.minX + 6, y: box.maxY - 3.5))
                check.line(to: CGPoint(x: box.maxX - 3, y: box.minY + 3.5))
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                palette.fill.setStroke()
                check.stroke()
            }
            tickText().draw(with: CGRect(x: 32, y: 7, width: max(40, rect.width - 40), height: rect.height - 10),
                            options: [.usesLineFragmentOrigin])
        }
    }

    private func drawTitle(color: NSColor, font: NSFont) {
        let size = (title as NSString).size(withAttributes: [.font: font])
        (title as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                 withAttributes: [.font: font, .foregroundColor: color])
    }
}
