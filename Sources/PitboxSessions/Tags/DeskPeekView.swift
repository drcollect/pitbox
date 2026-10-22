import AppKit
import PitboxKit

/// The desk peek's content: opaque, 360 pt wide, drawn by hand like the block's
/// peek (no text field, no text view, nothing that takes the keyboard), with its clickable rows: the command rows
/// (▶ Run… or Review…, which only open the sheet), the result buttons (↗, ▤), "▦ Open dashboard", and Park and Copy link
/// pinned at the bottom. ↗ ▤ ▦ count a press only once armed (0.8 s after they appeared or moved, never under the
/// pointer). No default button, no key equivalent. Taller content scrolls.
final class DeskPeekView: NSView {
    enum Style: Equatable { case primary, link, dashboard, neutral }

    struct Button: Equatable {
        var model: DeskPeekModel.Button
        var rect: CGRect
        var style: Style
        var action: DeskPeekModel.Action { model.action }
    }

    enum Element: Equatable {
        case text(String, CGRect, font: NSFont, color: UInt32, lines: Int, middle: Bool)
        case dot(CGRect, UInt32)
        case box(CGRect)
        case bar(CGRect, fraction: Double, late: Bool)
        case chip(String, CGRect, risky: Bool)
        case rule(CGRect)
    }

    static let padding: CGFloat = 13
    static let footerHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 12
    static let rowHeight: CGFloat = 24

    private(set) var model: DeskPeekModel
    private(set) var elements: [Element] = []
    private(set) var contentButtons: [Button] = []
    private(set) var footerButtons: [Button] = []
    private(set) var contentHeight: CGFloat = 0
    private(set) var scrollOffset: CGFloat = 0
    private(set) var anchors: [DeskPeekFocus: CGFloat] = [:]
    private var arming: [DeskPeekModel.Action: DeskTagArming] = [:]
    private var armedPlaces: [DeskPeekModel.Action: CGRect] = [:]
    private var pressed: (action: DeskPeekModel.Action, counts: Bool)?
    private var hovered: DeskPeekModel.Action?

    var onAction: ((DeskPeekModel.Action, CGRect) -> Void)?
    var onHover: ((Bool) -> Void)?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    /// Tests: every string drawn.
    var drawnTexts: [String]?

    init(model: DeskPeekModel, frame: CGRect) {
        self.model = model
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(AppIdentity.displayName) session details")
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(model: DeskPeekModel) {
        guard model != self.model else { return }
        self.model = model
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    /// The height the content wants, footer included.
    var preferredHeight: CGFloat { contentHeight + Self.footerHeight }

    var scrollArea: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.footerHeight)) }
    var maxScrollOffset: CGFloat { max(0, contentHeight - scrollArea.height) }

    /// Scrolls so that a section starts at the top (the commands or the warnings).
    func scroll(to focus: DeskPeekFocus) {
        guard let y = anchors[focus] else { return }
        scrollOffset = min(max(0, y - Self.padding), maxScrollOffset)
        needsDisplay = true
    }

    // MARK: Layout

    private func relayout() {
        let pad = Self.padding
        let width = max(40, bounds.width - 2 * pad)
        var y = pad
        var out: [Element] = []
        var buttons: [Button] = []
        anchors = [:]
        let palette = CodeMonitorPalette.self

        func text(_ string: String?, font: NSFont, color: UInt32, maxLines: Int, gap: CGFloat = 5, indent: CGFloat = 0) {
            guard let string, !string.isEmpty else { return }
            let lines = min(maxLines, Self.lines(string, font, width: width - indent))
            let height = CGFloat(lines) * CodeMonitorFonts.lineHeight(font)
            out.append(.text(string, CGRect(x: pad + indent, y: y, width: width - indent, height: height), font: font,
                             color: color, lines: lines, middle: false))
            y += height + gap
        }

        func label(_ string: String) {
            text(string, font: CodeMonitorFonts.peekLabel, color: palette.dim, maxLines: 1, gap: 4)
        }

        func rowButton(_ model: DeskPeekModel.Button, style: Style) {
            let rect = CGRect(x: pad, y: y, width: width, height: Self.rowHeight - 2)
            buttons.append(Button(model: model, rect: rect, style: style))
            y += Self.rowHeight
        }

        // Title and state.
        out.append(.dot(CGRect(x: pad, y: y + 5, width: 9, height: 9), Self.stateColor(model.state)))
        let titleFont = CodeMonitorFonts.peekTitle
        let titleLines = min(2, Self.lines(model.title, titleFont, width: width - 16))
        out.append(.text(model.title, CGRect(x: pad + 16, y: y, width: width - 16,
                                             height: CGFloat(titleLines) * CodeMonitorFonts.lineHeight(titleFont)),
                         font: titleFont, color: palette.headline, lines: titleLines, middle: false))
        y += CGFloat(titleLines) * CodeMonitorFonts.lineHeight(titleFont) + 4
        for (index, line) in model.detailLines.enumerated() {
            text(line, font: CodeMonitorFonts.peekSmall, color: palette.dim, maxLines: 2,
                 gap: index == model.detailLines.count - 1 ? 8 : 2)
        }
        if model.textHidden {
            text("Text hidden. Show it with Show text in the Code monitors header.", font: CodeMonitorFonts.peekSmall,
                 color: palette.dim, maxLines: 2, gap: 8)
        }

        // Run block.
        text(model.now, font: CodeMonitorFonts.peekText, color: palette.nowText, maxLines: 2, gap: 3)
        text(model.runLine, font: CodeMonitorFonts.peekSmall, color: model.late ? 0xFFB36B : 0xA9C8FF, maxLines: 2, gap: 2)
        text(model.zoneNote, font: CodeMonitorFonts.peekSmall, color: palette.dim, maxLines: 1, gap: 2)
        if let fraction = model.progress {
            out.append(.bar(CGRect(x: pad, y: y + 2, width: width, height: 3), fraction: fraction, late: model.late))
            y += 11
        } else if model.runLine != nil {
            y += 6
        }

        // Warnings.
        if !model.warnings.isEmpty {
            anchors[.warnings] = y
            for line in model.warnings {
                text("⚠ " + line, font: CodeMonitorFonts.peekText, color: 0xFFB36B, maxLines: 2, gap: 3)
            }
            y += 5
        }

        text(model.tldr, font: CodeMonitorFonts.peekText, color: palette.text, maxLines: 6, gap: 6)
        text(model.ask, font: CodeMonitorFonts.peekText, color: palette.askText, maxLines: 4, gap: 8)

        // Steps, newest last.
        if !model.steps.isEmpty {
            let line = CodeMonitorFonts.lineHeight(CodeMonitorFonts.mono)
            let box = CGRect(x: pad, y: y, width: width, height: CGFloat(model.steps.count) * line + 12)
            out.append(.box(box))
            var stepY = box.minY + 6
            for step in model.steps {
                let agoWidth = ceil((step.ago as NSString).size(withAttributes: [.font: CodeMonitorFonts.peekSmall]).width)
                out.append(.text("· " + step.words, CGRect(x: box.minX + 8, y: stepY, width: box.width - agoWidth - 24, height: line),
                                 font: CodeMonitorFonts.mono, color: palette.text, lines: 1, middle: false))
                out.append(.text(step.ago, CGRect(x: box.maxX - 8 - agoWidth, y: stepY, width: agoWidth, height: line),
                                 font: CodeMonitorFonts.peekSmall, color: palette.dim, lines: 1, middle: false))
                stepY += line
            }
            y = box.maxY + 8
        }

        // Todos.
        if let title = model.todosTitle {
            label(title)
            for todo in model.todos {
                let mark: String
                let color: UInt32
                switch todo.mark {
                case .done: mark = "✓"; color = palette.dim
                case .current: mark = "▸"; color = palette.nowText
                case .pending: mark = "·"; color = palette.text
                }
                text(mark + " " + todo.text, font: CodeMonitorFonts.peekSmall, color: color, maxLines: 1, gap: 1, indent: 2)
            }
            y += 6
        }

        // Results and the dashboard.
        if !model.results.isEmpty || !model.resultNotes.isEmpty || model.dashboard != nil {
            label("RESULTS")
            for result in model.results { rowButton(result, style: .link) }
            for note in model.resultNotes { text(note, font: CodeMonitorFonts.peekSmall, color: palette.dim, maxLines: 2, gap: 2) }
            if let dashboard = model.dashboard { rowButton(dashboard, style: .dashboard) }
            y += 4
        }

        // Commands.
        func commandRows(_ rows: [DeskPeekModel.Command]) {
            for row in rows {
                let rect = CGRect(x: pad, y: y, width: width, height: Self.rowHeight)
                out.append(.rule(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.5)))
                let buttonWidth = Self.buttonWidth(row.button.title)
                let buttonRect = CGRect(x: rect.maxX - buttonWidth, y: rect.minY + 3, width: buttonWidth, height: 18)
                let chipWidth = Self.chipWidth(row.chip)
                let chipRect = CGRect(x: buttonRect.minX - 8 - chipWidth, y: rect.minY + 4, width: chipWidth, height: 16)
                out.append(.text("\(row.number)", CGRect(x: rect.minX, y: rect.minY + 4, width: 16, height: 16),
                                 font: CodeMonitorFonts.peekSmall, color: palette.dim, lines: 1, middle: false))
                out.append(.text(row.preview, CGRect(x: rect.minX + 18, y: rect.minY + 4,
                                                     width: max(20, chipRect.minX - 8 - rect.minX - 18), height: 16),
                                 font: CodeMonitorFonts.mono, color: palette.text, lines: 1, middle: true))
                out.append(.chip(row.chip, chipRect, risky: row.risky))
                buttons.append(Button(model: row.button, rect: buttonRect, style: .primary))
                y = rect.maxY
                if let note = row.note {
                    out.append(.text(note, CGRect(x: rect.minX + 18, y: y - 2, width: width - 18, height: 15),
                                     font: CodeMonitorFonts.peekSmall, color: palette.dim, lines: 1, middle: false))
                    y += 14
                }
            }
            y += 4
        }
        if !model.commands.isEmpty {
            anchors[.commands] = y
            label("COMMANDS IN THE LAST REPLY")
            commandRows(model.commands)
        }
        if !model.earlierCommands.isEmpty {
            if anchors[.commands] == nil { anchors[.commands] = y }
            label("EARLIER REPLIES")
            commandRows(model.earlierCommands)
        }

        contentHeight = y + 4
        elements = out
        contentButtons = buttons

        // Pinned at the bottom: Park and Copy link.
        var footer: [Button] = []
        var x = pad
        let buttonY = bounds.height - Self.footerHeight + 9
        for (index, item) in model.footer.enumerated() {
            let w = Self.buttonWidth(item.title, wide: true)
            footer.append(Button(model: item, rect: CGRect(x: x, y: buttonY, width: w, height: 22),
                                 style: index == 0 ? .primary : .neutral))
            x += w + 8
        }
        footerButtons = footer
        scrollOffset = min(max(0, scrollOffset), maxScrollOffset)
        updateTrackingAreas()
        needsDisplay = true
    }

    static func lines(_ string: String, _ font: NSFont, width: CGFloat) -> Int {
        guard width > 1, !string.isEmpty else { return 1 }
        let rect = (string as NSString).boundingRect(with: CGSize(width: width, height: 10_000),
                                                     options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return max(1, Int(ceil(rect.height / CodeMonitorFonts.lineHeight(font) - 0.01)))
    }

    static func buttonWidth(_ title: String, wide: Bool = false) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: CodeMonitorFonts.button]).width) + (wide ? 22 : 16)
    }

    static func chipWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: CodeMonitorFonts.peekLabel]).width) + 12
    }

    static func stateColor(_ state: CodeSessionState) -> UInt32 {
        switch state {
        case .working: return CodeMonitorPalette.working
        case .needsYou, .maybeNeedsYou: return CodeMonitorPalette.amber
        case .problem: return CodeMonitorPalette.red
        case .reviewReady: return CodeMonitorPalette.green
        case .done, .doneNoSummary: return CodeMonitorPalette.white
        case .quietUnfinished, .unknown: return CodeMonitorPalette.grey
        }
    }

    /// Every button with its rect in the view (content buttons moved by the scroll offset and clipped to the area).
    func visibleButtons() -> [Button] {
        let area = scrollArea
        let content = contentButtons.compactMap { button -> Button? in
            var moved = button
            moved.rect = button.rect.offsetBy(dx: 0, dy: -scrollOffset)
            return area.contains(moved.rect) ? moved : nil
        }
        return content + footerButtons
    }

    func button(at point: CGPoint) -> Button? {
        visibleButtons().first { $0.rect.contains(point) }
    }

    // MARK: Arming

    /// After every placement or scroll: armed buttons that appeared or moved on the screen arm again from `time`,
    /// blocked while the pointer is over them.
    func noteLayout(at time: TimeInterval) {
        var places: [DeskPeekModel.Action: CGRect] = [:]
        for button in visibleButtons() where button.model.needsArming {
            let place = window.map { $0.convertToScreen(convert(button.rect, to: nil)) } ?? .null
            places[button.action] = place
            let inside = !place.isNull && place.contains(pointer())
            if arming[button.action] == nil {
                arming[button.action] = DeskTagArming(appearedAt: time, pointerInside: inside)
            } else if armedPlaces[button.action] != place {
                arming[button.action]?.moved(at: time, pointerInside: inside)
            }
        }
        armedPlaces = places
        arming = arming.filter { places[$0.key] != nil }
    }

    func arming(of action: DeskPeekModel.Action) -> DeskTagArming? { arming[action] }

    /// The pointer left the peek: no button is under it any more.
    func notePointerLeft() {
        for action in arming.keys { arming[action]?.pointerExited() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if drawnTexts != nil { drawnTexts = [] }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius,
                                 yRadius: Self.cornerRadius)
        CodeMonitorPalette.color(0x1B1E25).setFill()
        shape.fill()
        CodeMonitorPalette.color(0x3D4352).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: scrollArea).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: -scrollOffset)
        transform.concat()
        for element in elements { draw(element) }
        for button in contentButtons { draw(button) }
        NSGraphicsContext.restoreGraphicsState()
        if maxScrollOffset > 0 { drawScrollHint() }
        CodeMonitorPalette.color(0x3D4352).setFill()
        CGRect(x: Self.padding, y: bounds.height - Self.footerHeight, width: bounds.width - 2 * Self.padding, height: 0.5).fill()
        for button in footerButtons { draw(button) }
    }

    private func draw(_ element: Element) {
        switch element {
        case .text(let string, let rect, let font, let color, let lines, let middle):
            drawText(string, in: rect, font: font, color: CodeMonitorPalette.color(color), lines: lines, middle: middle)
        case .dot(let rect, let color):
            CodeMonitorPalette.color(color).setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .box(let rect):
            CodeMonitorPalette.color(CodeMonitorPalette.screen).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        case .bar(let rect, let fraction, let late):
            CodeMonitorPalette.color(0x22262F).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            CodeMonitorPalette.color(late ? 0xFFB36B : CodeMonitorPalette.working).setFill()
            let filled = CGRect(x: rect.minX, y: rect.minY, width: rect.width * min(1, max(0, fraction)), height: rect.height)
            NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
        case .chip(let title, let rect, let risky):
            let color: UInt32 = risky ? CodeMonitorPalette.red : 0xC2C7D0
            CodeMonitorPalette.color(color, 0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            drawText(title, in: rect, font: CodeMonitorFonts.peekLabel, color: CodeMonitorPalette.color(risky ? 0xFF8A8A : color),
                     alignment: .center, centered: true)
        case .rule(let rect):
            CodeMonitorPalette.color(0x3D4352, 0.7).setFill()
            rect.fill()
        }
    }

    private func draw(_ button: Button) {
        let isHovered = hovered == button.action
        let isPressed = pressed?.action == button.action
        let base: UInt32
        let textColor: UInt32
        switch button.style {
        case .primary: base = CodeMonitorPalette.cyan; textColor = 0xBFF3FA
        case .link: base = 0x9B7BFF; textColor = 0xD4C2FF
        case .dashboard: base = 0xF58AC4; textColor = 0xFFC3E2
        case .neutral: base = 0xFFFFFF; textColor = 0xE2E5EA
        }
        let alpha: CGFloat = button.style == .neutral ? (isPressed ? 0.16 : (isHovered ? 0.12 : 0.07))
            : (isPressed ? 0.34 : (isHovered ? 0.26 : 0.18))
        CodeMonitorPalette.color(base, alpha).setFill()
        NSBezierPath(roundedRect: button.rect, xRadius: 6, yRadius: 6).fill()
        let alignment: NSTextAlignment = button.style == .link || button.style == .dashboard ? .left : .center
        let inset = alignment == .left ? button.rect.insetBy(dx: 9, dy: 0) : button.rect
        drawText(button.model.title, in: inset, font: CodeMonitorFonts.button, color: CodeMonitorPalette.color(textColor),
                 alignment: alignment, centered: true)
    }

    private func drawScrollHint() {
        let area = scrollArea
        let thumb = max(24, area.height * area.height / max(contentHeight, 1))
        let y = area.minY + 4 + (area.height - 8 - thumb) * min(max(scrollOffset / maxScrollOffset, 0), 1)
        CodeMonitorPalette.color(0xFFFFFF, 0.22).setFill()
        NSBezierPath(roundedRect: CGRect(x: bounds.maxX - 6, y: y, width: 3, height: thumb), xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func drawText(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, lines: Int = 1, middle: Bool = false,
                          alignment: NSTextAlignment = .left, centered: Bool = false) {
        guard rect.width > 2, !string.isEmpty else { return }
        drawnTexts?.append(string)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lines > 1 ? .byWordWrapping : (middle ? .byTruncatingMiddle : .byTruncatingTail)
        var target = rect
        if centered {
            let height = CodeMonitorFonts.lineHeight(font)
            target = CGRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height)
        }
        (string as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self,
                                       userInfo: ["panel": true]))
        for (index, button) in visibleButtons().enumerated() {
            addTrackingArea(NSTrackingArea(rect: button.rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self,
                                           userInfo: ["button": index]))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["panel"] != nil { onHover?(true); return }
        guard let index = event.trackingArea?.userInfo?["button"] as? Int else { return }
        let buttons = visibleButtons()
        guard buttons.indices.contains(index) else { return }
        hovered = buttons[index].action
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["panel"] != nil {
            notePointerLeft()
            onHover?(false)
            return
        }
        if let index = event.trackingArea?.userInfo?["button"] as? Int {
            let buttons = visibleButtons()
            if buttons.indices.contains(index) { arming[buttons[index].action]?.pointerExited() }
        }
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        press(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        release(at: convert(event.locationInWindow, from: nil))
    }

    /// A left press at `point` (view coordinates): it counts only on a button, and on ↗ ▤ ▦ only once armed.
    func press(at point: CGPoint) {
        guard let button = button(at: point) else { pressed = nil; return }
        let counts = !button.model.needsArming || (arming[button.action]?.allowsPress(at: now()) ?? false)
        pressed = (button.action, counts)
        needsDisplay = true
    }

    /// The release: the button acts when the press began on it and counted.
    func release(at point: CGPoint) {
        defer { pressed = nil; needsDisplay = true }
        guard let press = pressed, press.counts, let button = button(at: point), button.action == press.action else { return }
        let screen = window.map { $0.convertToScreen(convert(button.rect, to: nil)) } ?? button.rect
        onAction?(button.action, screen)
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let next = min(max(0, scrollOffset - delta), maxScrollOffset)
        guard next != scrollOffset else { return super.scrollWheel(with: event) }
        scrollOffset = next
        updateTrackingAreas()
        noteLayout(at: now())
        needsDisplay = true
    }

    // MARK: Accessibility (host words only)

    override func accessibilityChildren() -> [Any]? {
        visibleButtons().map { button in
            let element = DeskTagAccessiblePill(index: 0) { [weak self] in
                guard let self else { return }
                let screen = self.window.map { $0.convertToScreen(self.convert(button.rect, to: nil)) } ?? button.rect
                self.onAction?(button.action, screen)
            }
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(button.model.accessibilityLabel)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(button.rect)
            return element
        }
    }
}
