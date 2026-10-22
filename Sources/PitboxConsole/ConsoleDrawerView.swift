import AppKit
import PitboxKit

/// The drawer's view: its bar on top and the console's view under it, always at the open size (`contentHeight`): while
/// the drawer folds, opens or is animated by the panel it is clipped, never reflowed, so the terminals keep their rows
/// and columns and a command starts at the size it is shown at.
@MainActor
final class ConsoleDrawerView: NSView {
    let bar = ConsoleDrawerBar(frame: .zero)
    let content: NSView
    /// The console's height under the bar (the held height less the bar).
    let contentHeight: CGFloat
    private(set) var shownState: ConsoleDrawer.State = .hidden

    override var isFlipped: Bool { true }

    init(content: NSView, contentHeight: CGFloat) {
        self.content = content
        self.contentHeight = contentHeight
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(content)
        addSubview(bar)
        content.isHidden = true
        bar.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Console")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the bar and the console for `state`.
    func show(_ state: ConsoleDrawer.State) {
        shownState = state
        bar.isHidden = state == .hidden
        bar.isOpen = state == .open
        content.isHidden = state != .open
        needsLayout = true
    }

    override func layout() {
        super.layout()
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: ConsoleDrawer.barHeight)
        let frame = CGRect(x: 0, y: ConsoleDrawer.barHeight, width: bounds.width, height: contentHeight)
        if content.frame != frame { content.frame = frame }
    }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        if !bar.isHidden { children.append(bar) }
        if !content.isHidden { children.append(content) }
        return children
    }
}

/// The drawer's bar: "Console · 2 tabs · 1 running" and a chevron. A click opens a folded drawer and folds an open one.
/// Counts only, never a tab's title (titles can carry a session's headline). It takes clicks without becoming key.
@MainActor
final class ConsoleDrawerBar: NSView {
    struct Counts: Equatable {
        var tabs: Int
        var running: Int
    }

    var counts = Counts(tabs: 0, running: 0) { didSet { if counts != oldValue { refreshAccessibility(); needsDisplay = true } } }
    var isOpen = false { didSet { if isOpen != oldValue { refreshAccessibility(); needsDisplay = true } } }
    var palette: TerminalPalette = TerminalTheme.dark { didSet { if palette != oldValue { needsDisplay = true } } }
    var tintOpacity: Double = 0.65 { didSet { if tintOpacity != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    /// The left button went down here and the pointer is still over the bar.
    private(set) var isPressed = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Console")
        refreshAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "2 tabs · 1 running" (no running part when nothing runs).
    var summary: String {
        var parts = [counts.tabs == 1 ? "1 tab" : "\(counts.tabs) tabs"]
        if counts.running > 0 { parts.append("\(counts.running) running") }
        return parts.joined(separator: " · ")
    }

    private func refreshAccessibility() {
        setAccessibilityValue(summary.replacingOccurrences(of: " · ", with: ", "))
        setAccessibilityHelp(isOpen ? "Folds the console to this bar" : "Opens the console")
        setAccessibilityExpanded(isOpen)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != isPressed {
            isPressed = inside
            needsDisplay = true
        }
    }

    /// Acts on mouse-up over the bar, like a button: a press dragged off it is cancelled.
    override func mouseUp(with event: NSEvent) {
        let act = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        if act { onClick?() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let style = TabStripStyle(palette: palette)
        palette.tint(opacity: tintOpacity).setFill()
        bounds.fill()
        (isPressed ? style.buttonPressedFill : style.band).setFill()
        bounds.fill()
        style.separator.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        // The chevron: up on a folded drawer (it opens upwards), down on an open one.
        let chevron = NSBezierPath()
        chevron.lineWidth = 1.6
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        let c = CGPoint(x: 18, y: bounds.midY)
        let dy: CGFloat = isOpen ? 2 : -2
        chevron.move(to: CGPoint(x: c.x - 4.5, y: c.y - dy))
        chevron.line(to: CGPoint(x: c.x, y: c.y + dy))
        chevron.line(to: CGPoint(x: c.x + 4.5, y: c.y - dy))
        style.glyph.setStroke()
        chevron.stroke()

        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                    .foregroundColor: palette.foreground]
        let detail: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                     .foregroundColor: palette.foreground.withAlphaComponent(0.72)]
        let text = NSMutableAttributedString(string: "Console", attributes: title)
        text.append(NSAttributedString(string: "  ·  " + summary, attributes: detail))
        let size = text.size()
        var x: CGFloat = 32
        if counts.running > 0 {
            // A running command: the blue dot of the block's running state.
            let dot = CGRect(x: x, y: (bounds.midY - 3.5).rounded(), width: 7, height: 7)
            palette.ansi[12].setFill()
            NSBezierPath(ovalIn: dot).fill()
            x += 13
        }
        text.draw(at: CGPoint(x: x, y: (bounds.midY - size.height / 2).rounded()))
    }
}
