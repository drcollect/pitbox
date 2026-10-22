import AppKit
import PitboxKit

/// The "While you were away" card, always first in Ready for you: "While you were away (22:41–23:12)", up to three
/// sections ("Finished · 2", "Waiting for you · 3", "Still running · 1") of up to 8 lines each ("and 3 more"), and
/// **Got it**. Its line is the block's neutral card line. Plain text only; never the keyboard;
/// VoiceOver reads counts, never headlines.
final class CodeAwayRecapView: NSView {
    private(set) var recap: CodeAwayRecap.Recap
    var onGotIt: (() -> Void)?
    var clock = CodeReadyClock() { didSet { needsDisplay = true } }
    private var hovered = false
    private var pressed = false
    /// Tests: every string drawn.
    var drawnTexts: [String]?

    static let padding: CGFloat = 10
    static let titleHeight: CGFloat = 20
    static let sectionHeight: CGFloat = 19
    static let lineHeight: CGFloat = 16
    static let sectionGap: CGFloat = 4
    static let buttonHeight: CGFloat = 20
    static let cornerRadius: CGFloat = 10

    init(recap: CodeAwayRecap.Recap, frame: CGRect) {
        self.recap = recap
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.accessibilityWords(recap))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ recap: CodeAwayRecap.Recap) {
        guard recap != self.recap else { return }
        self.recap = recap
        setAccessibilityLabel(Self.accessibilityWords(recap))
        needsDisplay = true
    }

    /// The card's height for `recap` at `width`.
    static func height(of recap: CodeAwayRecap.Recap, width: CGFloat) -> CGFloat {
        var height = padding + titleHeight
        for section in recap.sections {
            height += sectionGap + sectionHeight + CGFloat(section.lines.count) * lineHeight
            if section.more > 0 { height += lineHeight }
        }
        return height + 6 + buttonHeight + padding
    }

    /// "While you were away (22:41–23:12)".
    func title() -> String { "While you were away (\(clock.time(recap.from))–\(clock.time(recap.until)))" }

    var gotItRect: CGRect {
        let width = ceil(("Got it" as NSString).size(withAttributes: [.font: CodeReadyFonts.button]).width) + 22
        return CGRect(x: Self.padding, y: bounds.height - Self.padding - Self.buttonHeight, width: width, height: Self.buttonHeight)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let palette = CodeReadyPalette(dark: ThemeColor.isDark(effectiveAppearance))
        let tone = palette.tone(nil)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        CodeReadyPalette.color(tone.background).setFill()
        card.fill()
        palette.neutralOutline.setStroke()
        card.lineWidth = 1
        card.stroke()

        let width = bounds.width - 2 * Self.padding
        var y = Self.padding
        draw(title(), at: CGRect(x: Self.padding, y: y, width: width, height: Self.titleHeight), font: CodeReadyFonts.header,
             color: palette.text)
        y += Self.titleHeight
        for section in recap.sections {
            y += Self.sectionGap
            draw(section.title, at: CGRect(x: Self.padding, y: y, width: width, height: Self.sectionHeight),
                 font: CodeReadyFonts.section, color: Self.sectionColor(section.kind, palette: palette))
            y += Self.sectionHeight
            for line in section.lines {
                let text = NSMutableAttributedString(string: "· " + line.headline,
                                                     attributes: [.font: CodeReadyFonts.title, .foregroundColor: palette.text])
                if let detail = line.detail {
                    text.append(NSAttributedString(string: " " + detail, attributes: [.font: CodeReadyFonts.detail,
                                                                                      .foregroundColor: palette.dim]))
                }
                drawLine(text, in: CGRect(x: Self.padding + 6, y: y, width: width - 6, height: Self.lineHeight))
                y += Self.lineHeight
            }
            if section.more > 0 {
                draw("and \(section.more) more", at: CGRect(x: Self.padding + 6, y: y, width: width - 6, height: Self.lineHeight),
                     font: CodeReadyFonts.detail, color: palette.dim)
                y += Self.lineHeight
            }
        }
        let button = gotItRect
        (pressed ? palette.secondaryHover : (hovered ? palette.secondaryHover : palette.secondaryFill)).setFill()
        NSBezierPath(roundedRect: button, xRadius: 6, yRadius: 6).fill()
        draw("Got it", at: button, font: CodeReadyFonts.button, color: palette.buttonText, centered: true)
    }

    static func sectionColor(_ kind: CodeAwayRecap.Section.Kind, palette: CodeReadyPalette) -> NSColor {
        switch kind {
        case .finished: return CodeReadyPalette.color(palette.tone(.finished).accent)
        case .waiting: return CodeReadyPalette.color(palette.tone(.warning).accent)
        case .running: return CodeReadyPalette.color(palette.dark ? 0x8EC0FF : 0x1F57A8)
        }
    }

    private func draw(_ string: String, at rect: CGRect, font: NSFont, color: NSColor, centered: Bool = false) {
        drawnTexts?.append(string)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = centered ? .center : .left
        let height = CodeMonitorFonts.lineHeight(font)
        let target = CGRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height)
        (string as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private func drawLine(_ text: NSMutableAttributedString, in rect: CGRect) {
        drawnTexts?.append(text.string)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        let height = CodeMonitorFonts.lineHeight(CodeReadyFonts.title)
        text.draw(with: CGRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: gotItRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        pressed = gotItRect.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let hit = pressed && gotItRect.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if hit { onGotIt?() }
    }

    override func accessibilityChildren() -> [Any]? {
        let button = CodeReadyAccessibilityButton(label: "Got it") { [weak self] in self?.onGotIt?() }
        button.setAccessibilityParent(self)
        button.setAccessibilityFrameInParentSpace(gotItRect)
        return [button]
    }

    /// "While you were away: 2 finished, 3 waiting, 1 running" (counts only, no session text).
    static func accessibilityWords(_ recap: CodeAwayRecap.Recap) -> String {
        "While you were away: \(recap.count(.finished)) finished, \(recap.count(.waiting)) waiting, "
            + "\(recap.count(.running)) running"
    }
}

/// A VoiceOver button whose label holds no session text.
final class CodeReadyAccessibilityButton: NSAccessibilityElement {
    private let press: () -> Void

    init(label: String, press: @escaping () -> Void) {
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}
