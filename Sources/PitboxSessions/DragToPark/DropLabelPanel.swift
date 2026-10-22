import AppKit
import PitboxKit

/// Shows drag-to-park's label next to the pointer: "Drop to park in <bucket>" while armed, the park's failure for 3 s.
/// Points are AppKit screen coordinates. Tests use a fake.
@MainActor
protocol CodeDropLabelPresenting: AnyObject {
    func show(_ text: String, failure: Bool, at point: CGPoint)
    func hide()
    /// The label's own window, left out when finding the window under a press.
    var windowNumber: UInt32? { get }
}

/// The label's window, under the rules for the app's small panels outside the block: a borderless non-activating
/// panel that never becomes key or main, so it never takes the user's typing or Claude's focus; key events sent to it
/// are dropped and it has no default button or key equivalent; it ignores the mouse, so the drop itself always reaches
/// the window server; it never moves, hides with no app, joins every Space and stays out of Mission Control. Above the
/// block and the dragged window (status-bar level, under menus). No text field, ever: that is the tell against an
/// imitation (docs/THREAT_MODEL.md).
final class DropLabelPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 160, height: DropLabelView.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    /// Key events never reach the label (it cannot be key, and nothing in it handles keys).
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged: return
        default: super.sendEvent(event)
        }
    }
}

/// The label's pill: opaque, 22 pt tall, radius 11, a 16 pt dark circle with the app's glyph at the left (the desk
/// tags' mark), 12 pt semibold text cut at the end, at most 260 pt wide. Dark in both appearances (like a monitor);
/// text 4.5:1.
final class DropLabelView: NSView {
    static let height: CGFloat = 22
    static let maxWidth: CGFloat = 260
    /// The running desk tag's pair: #2A3242 with #CFE0FF text; failures in the warning orange #FFB36B.
    static let fill: UInt32 = 0x2A3242
    static let text: UInt32 = 0xCFE0FF
    static let failureText: UInt32 = 0xFFB36B
    static let mark: UInt32 = 0x101215
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private(set) var text = ""
    private(set) var failure = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String, failure: Bool) {
        guard text != self.text || failure != self.failure else { return }
        self.text = text
        self.failure = failure
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    /// The pill's size for the current text.
    var pillSize: CGSize {
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
        return CGSize(width: min(Self.maxWidth, 3 + 16 + 6 + textWidth + 10), height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: 0.5, dy: 0.5)
        ThemeColor.srgb(Self.fill).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        let circle = CGRect(x: 3, y: (bounds.height - 16) / 2, width: 16, height: 16)
        ThemeColor.srgb(Self.mark).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let mark = NSAttributedString(string: DeskTagTuning.glyph, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                                                 .foregroundColor: ThemeColor.srgb(Self.text)])
        let markSize = mark.size()
        mark.draw(at: CGPoint(x: circle.midX - markSize.width / 2, y: circle.midY - markSize.height / 2))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let words = NSAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: ThemeColor.srgb(failure ? Self.failureText : Self.text),
            .paragraphStyle: style,
        ])
        let height = words.size().height
        words.draw(with: CGRect(x: circle.maxX + 6, y: (bounds.height - height) / 2,
                                width: max(0, bounds.width - circle.maxX - 6 - 10), height: height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The production label: one panel, made on first use, placed below and right of the pointer (left of it when the
/// screen's edge is near, as it is beside a block at the right-hand edge), inside the pointer's screen.
@MainActor
final class DropLabelPanelController: CodeDropLabelPresenting {
    /// From the pointer to the pill's near corner.
    static let offset = CGPoint(x: 16, y: 20)

    private(set) var panel: DropLabelPanel?
    private let view = DropLabelView()

    var windowNumber: UInt32? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return UInt32(panel.windowNumber)
    }

    func show(_ text: String, failure: Bool, at point: CGPoint) {
        let panel = self.panel ?? makePanel()
        view.update(text: text, failure: failure)
        let size = view.pillSize
        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.frame ?? NSScreen.main?.frame ?? .zero
        panel.setFrame(Self.frame(size: size, near: point, screen: screen), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Below and right of the pointer, or left of it when that would leave the screen; always inside `screen`.
    static func frame(size: CGSize, near point: CGPoint, screen: CGRect) -> CGRect {
        var x = point.x + offset.x
        if x + size.width > screen.maxX { x = point.x - offset.x - size.width }
        var y = point.y - offset.y - size.height
        if y < screen.minY { y = point.y + offset.y }
        x = min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width))
        y = min(max(y, screen.minY), max(screen.minY, screen.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func makePanel() -> DropLabelPanel {
        let panel = DropLabelPanel()
        panel.contentView = view
        self.panel = panel
        return panel
    }
}
