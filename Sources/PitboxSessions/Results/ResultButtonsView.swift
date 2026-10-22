import AppKit
import PitboxKit

/// A row of result buttons: pills that wrap onto more lines when the width runs out, an optional
/// trailing note ("+2 more"), and the arming for buttons that open something (`OpenButtonArming`): a press
/// counts only when the left button goes down and up on the pill, 0.8 s after it appeared or moved, never while the
/// pointer was already there. Self-contained, for surfaces that host views (the Finished card shows the first result,
/// `CodeResultWords.firstLine`; the results section and the web preview use it); a monitor draws its result line itself
/// (`CodeMonitorResultLine`). `onPress` goes to `CodeResultActions`. It never takes the keyboard.
final class CodeResultButtonsView: NSView {
    static let pillHeight: CGFloat = 24
    static let gap: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let noteFont = NSFont.systemFont(ofSize: 12)

    private(set) var buttons: [CodeResultButton]
    private(set) var note: String?
    var palette: CodeResultPalette { didSet { needsDisplay = true } }
    /// A press that counted (arming passed), on the main thread.
    var onPress: ((CodeResultButton) -> Void)?
    /// The clock of the arming (tests move it by hand).
    var clock: () -> TimeInterval = MonotonicClock.now
    /// The pointer in this view's coordinates, when it is over the view (tests set it).
    var pointerLocation: () -> CGPoint? = { nil }

    private(set) var arming = OpenButtonArming()
    private(set) var frames: [String: CGRect] = [:]
    private var pressed: (id: String, at: TimeInterval, point: CGPoint)?
    private var hovered: String?

    init(buttons: [CodeResultButton], note: String? = nil, palette: CodeResultPalette = CodeResultPalette(dark: true),
         width: CGFloat) {
        self.buttons = buttons
        self.note = note
        self.palette = palette
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.pillHeight))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Results")
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// New buttons: those whose place changed re-arm.
    func update(buttons: [CodeResultButton], note: String?) {
        guard buttons != self.buttons || note != self.note else { return }
        self.buttons = buttons
        self.note = note
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Appearing in a window is appearing: every button arms again from now.
        arming.rearmAll(now: clock(), pointer: currentPointer())
    }

    /// The height at `width` (the shape of the block's `CodeTileAccessory`).
    func accessoryHeight(forWidth width: CGFloat) -> CGFloat { Self.height(of: buttons, note: note, width: width) }

    /// The width the buttons take on one line.
    static func naturalWidth(of buttons: [CodeResultButton]) -> CGFloat {
        buttons.map { pillWidth($0.title) }.reduce(0, +) + gap * CGFloat(max(0, buttons.count - 1))
    }

    /// The height the buttons need at `width`.
    static func height(of buttons: [CodeResultButton], note: String?, width: CGFloat) -> CGFloat {
        let rows = layout(buttons, note: note, width: width).rows
        return CGFloat(max(1, rows)) * pillHeight + CGFloat(max(0, rows - 1)) * gap
    }

    // MARK: Layout

    private static func pillWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + 20
    }

    /// The pills' frames: one result's buttons stay on one line together (a web document's Preview and Show in Finder),
    /// lines wrap between results.
    private static func layout(_ buttons: [CodeResultButton], note: String?,
                               width: CGFloat) -> (frames: [String: CGRect], note: CGRect?, rows: Int) {
        var frames: [String: CGRect] = [:]
        var x: CGFloat = 0, y: CGFloat = 0, rows = buttons.isEmpty ? 0 : 1
        var groups: [[CodeResultButton]] = []
        for button in buttons {
            if let last = groups.last?.last, last.resultID == button.resultID { groups[groups.count - 1].append(button) } else { groups.append([button]) }
        }
        for group in groups {
            let widths = group.map { min(pillWidth($0.title), width) }
            let groupWidth = widths.reduce(0, +) + gap * CGFloat(max(0, group.count - 1))
            if x > 0, x + groupWidth > width {
                x = 0
                y += pillHeight + gap
                rows += 1
            }
            for (button, w) in zip(group, widths) {
                if x > 0, x + w > width {
                    x = 0
                    y += pillHeight + gap
                    rows += 1
                }
                frames[button.id] = CGRect(x: x, y: y, width: w, height: pillHeight)
                x += w + gap
            }
        }
        var noteFrame: CGRect?
        if let note {
            let w = ceil((note as NSString).size(withAttributes: [.font: noteFont]).width) + 2
            if x > 0, x + w > width {
                x = 0
                y += pillHeight + gap
                rows += 1
            }
            noteFrame = CGRect(x: x, y: y, width: min(w, width), height: pillHeight)
            rows = max(rows, 1)
        }
        return (frames, noteFrame, rows)
    }

    private var noteFrame: CGRect?

    private func relayout() {
        let laid = Self.layout(buttons, note: note, width: bounds.width)
        frames = laid.frames
        noteFrame = laid.note
        arming.layout(laid.frames.filter { key, _ in buttons.first { $0.id == key }?.arms ?? false }, now: clock(),
                      pointer: currentPointer())
        let height = Self.height(of: buttons, note: note, width: bounds.width)
        if abs(frame.height - height) > 0.5 { super.setFrameSize(CGSize(width: frame.width, height: height)) }
        updateAccessibility()
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityChildren(buttons.compactMap { button -> NSAccessibilityElement? in
            guard let rect = frames[button.id] else { return nil }
            let element = NSAccessibilityElement.resultButton(button.title, frame: rect, in: self)
            return element
        })
    }

    private func currentPointer() -> CGPoint? {
        if let point = pointerLocation() { return point }
        guard let window else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) ? point : nil
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointer(at: nil) }

    /// The pointer moved to `point` (nil: it left the view).
    func pointer(at point: CGPoint?) {
        arming.pointerMoved(to: point)
        let over = point.flatMap { p in buttons.first { frames[$0.id]?.contains(p) == true }?.id }
        if over != hovered {
            hovered = over
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) { press(down: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { release(up: convert(event.locationInWindow, from: nil)) }

    /// The left button went down at `point`.
    func press(down point: CGPoint) {
        guard let button = buttons.first(where: { frames[$0.id]?.contains(point) == true }) else { pressed = nil; return }
        pressed = (button.id, clock(), point)
    }

    /// The left button came up at `point`: the press counts when it began and ended on one button that was armed.
    func release(up point: CGPoint) {
        defer { pressed = nil }
        guard let pressed, let button = buttons.first(where: { $0.id == pressed.id }),
              let rect = frames[button.id], rect.contains(point) else { return }
        if button.arms {
            guard arming.accepts(button.id, downAt: pressed.at, downPoint: pressed.point, upPoint: point) else { return }
        }
        onPress?(button)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let now = clock()
        for button in buttons {
            guard let rect = frames[button.id] else { continue }
            let armed = !button.arms || arming.isArmed(button.id, now: now)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            CodeResultPalette.color(palette.fill(button.tone), hovered == button.id && armed ? 0.85 : 1).setFill()
            path.fill()
            CodeResultPalette.color(palette.outline(button.tone)).setStroke()
            path.lineWidth = 1
            path.stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font, .paragraphStyle: paragraph,
                .foregroundColor: CodeResultPalette.color(palette.text(button.tone), armed ? 1 : 0.75),
            ]
            let textHeight = ceil(Self.font.ascender - Self.font.descender)
            (button.title as NSString).draw(in: CGRect(x: rect.minX + 8, y: rect.midY - textHeight / 2, width: rect.width - 16,
                                                       height: textHeight), withAttributes: attributes)
        }
        if let note, let frame = noteFrame {
            let textHeight = ceil(Self.noteFont.ascender - Self.noteFont.descender)
            (note as NSString).draw(in: CGRect(x: frame.minX, y: frame.midY - textHeight / 2, width: frame.width, height: textHeight),
                                    withAttributes: [.font: Self.noteFont, .foregroundColor: CodeResultPalette.color(palette.dim)])
        }
    }
}

private extension NSAccessibilityElement {
    /// A button element for VoiceOver (the press itself still needs a real click: no accessibility press action).
    static func resultButton(_ title: String, frame: CGRect, in parent: NSView) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.button)
        element.setAccessibilityLabel(title)
        element.setAccessibilityParent(parent)
        element.setAccessibilityFrameInParentSpace(frame)
        return element
    }
}
