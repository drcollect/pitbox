import AppKit
import PitboxKit

/// The peek: a panel drawn inside the block over the monitors, two grid columns wide, at the block's height under the
/// header. It shows the full title, the copy (only when several run), where it runs, state · age · model · effort ·
/// permission mode, the whole TL;DR and Ask line, the last 5 steps, the todos, **Commands in the last reply** (number,
/// first line cut in the middle, class and machine chips, Review… and Copy), and the buttons Open window or Park, and
/// Copy link. Run is never here: it exists only on the sheet. With text hidden only the headline, the state and the
/// buttons show. Taller content scrolls; the buttons stay at the bottom.
final class CodeMonitorPeekView: NSView {
    enum Action: Hashable {
        case review(CommandOffer.ID)
        case copy(CommandOffer.ID)
        case window(CodeWindowClick)
        case copyLink
        /// A result button; one that opens something is armed (`resultArming`).
        case result(CodeResultButton)
    }

    struct Button: Equatable {
        var action: Action
        var title: String
        var rect: CGRect
        var enabled: Bool
        var primary: Bool
    }

    enum Element: Equatable {
        case text(String, CGRect, font: NSFont, color: NSColor, lines: Int, middle: Bool)
        case box(CGRect)
        case chip(String, CGRect, tone: CodeOfferLine.Tone)
        case dot(CGRect, CodeMonitorLED)
        case rule(CGRect)
    }

    private(set) var item: CodeMonitorItem
    private(set) var elements: [Element] = []
    /// Buttons in the scrolled content (offer rows) and pinned at the bottom (window, link).
    private(set) var contentButtons: [Button] = []
    private(set) var footerButtons: [Button] = []
    private(set) var contentHeight: CGFloat = 0
    private(set) var scrollOffset: CGFloat = 0
    private var hoveredButton: Action?
    private var pressedButton: Action?
    private var copied: [Action: Date] = [:]
    var onAction: ((Action) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Tests: every string drawn.
    var drawnTexts: [String]?
    var now: () -> Date = { Date() }
    /// The arming of result buttons that open something, on the monotonic clock (tests replace it),
    /// and where the pointer is (nil: unknown).
    private(set) var resultArming = OpenButtonArming()
    var clock: () -> TimeInterval = MonotonicClock.now
    lazy var pointerProbe: () -> CGPoint? = { [weak self] in
        guard let self, let window = self.window, window.isVisible else { return nil }
        return self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }
    private var pressedAt: (time: TimeInterval, point: CGPoint)?

    static let padding: CGFloat = 13
    static let footerHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 12
    static let copiedDuration: TimeInterval = 2

    init(item: CodeMonitorItem, frame: CGRect) {
        self.item = item
        super.init(frame: frame)
        wantsLayer = true
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = CGSize(width: 0, height: -6)
            return shadow
        }()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Monitor details")
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(item: CodeMonitorItem) {
        guard item != self.item else { return }
        self.item = item
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    /// The scrollable area (above the pinned buttons).
    var scrollArea: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.footerHeight))
    }

    var maxScrollOffset: CGFloat { max(0, contentHeight - scrollArea.height) }

    // MARK: Layout

    private func relayout() {
        let p = item.peek
        let pad = Self.padding
        let width = max(40, bounds.width - 2 * pad)
        var y = pad
        var out: [Element] = []
        var buttons: [Button] = []
        let text = CodeMonitorPalette.color(CodeMonitorPalette.text)
        let dim = CodeMonitorPalette.color(CodeMonitorPalette.dim)

        func addText(_ string: String?, font: NSFont, color: NSColor, maxLines: Int, gap: CGFloat = 5, indent: CGFloat = 0,
                     middle: Bool = false) {
            guard let string, !string.isEmpty else { return }
            let lines = min(maxLines, CodeMonitorLayout.lines(string, font, width: width - indent))
            let height = CGFloat(lines) * CodeMonitorFonts.lineHeight(font)
            out.append(.text(string, CGRect(x: pad + indent, y: y, width: width - indent, height: height), font: font,
                             color: color, lines: lines, middle: middle))
            y += height + gap
        }

        // Title with the state dot.
        out.append(.dot(CGRect(x: pad, y: y + 4, width: 9, height: 9), item.led))
        let titleFont = CodeMonitorFonts.peekTitle
        let titleLines = min(2, CodeMonitorLayout.lines(p.title, titleFont, width: width - 16))
        out.append(.text(p.title, CGRect(x: pad + 16, y: y, width: width - 16, height: CGFloat(titleLines) * CodeMonitorFonts.lineHeight(titleFont)),
                         font: titleFont, color: CodeMonitorPalette.color(CodeMonitorPalette.headline), lines: titleLines, middle: false))
        y += CGFloat(titleLines) * CodeMonitorFonts.lineHeight(titleFont) + 4
        let where_ = [p.profile, p.place].compactMap { $0 }.joined(separator: " · ")
        addText(where_.isEmpty ? nil : where_, font: CodeMonitorFonts.peekSmall, color: dim, maxLines: 2, gap: 2)
        addText(p.stateLine, font: CodeMonitorFonts.peekSmall, color: dim, maxLines: 2, gap: 8)

        if p.textHidden {
            addText("Text hidden. Show it with Show text in the header.", font: CodeMonitorFonts.peekSmall, color: dim, maxLines: 2)
        } else {
            // Warnings first (with the last failure's exit code); the statement in orange, its facts below.
            for lines in p.warnings {
                for (index, line) in lines.enumerated() {
                    addText(index == 0 ? "⚠ " + line : line, font: index == 0 ? CodeMonitorFonts.peekText : CodeMonitorFonts.peekSmall,
                            color: CodeWarningPalette.color(index == 0 ? CodeWarningPalette.orange : CodeWarningPalette.detail),
                            maxLines: 2, gap: index == lines.count - 1 ? 8 : 2)
                }
            }
            addText(p.tldr, font: CodeMonitorFonts.peekText, color: text, maxLines: 8, gap: 6)
            addText(p.ask, font: CodeMonitorFonts.peekText, color: CodeMonitorPalette.color(CodeMonitorPalette.askText), maxLines: 6, gap: 8)
            if !p.steps.isEmpty {
                let line = CodeMonitorFonts.lineHeight(CodeMonitorFonts.mono)
                let box = CGRect(x: pad, y: y, width: width, height: CGFloat(p.steps.count) * line + 12)
                out.append(.box(box))
                var stepY = box.minY + 6
                for step in p.steps {
                    let ago = step.ago
                    let agoWidth = ceil((ago as NSString).size(withAttributes: [.font: CodeMonitorFonts.peekSmall]).width)
                    out.append(.text("· " + step.words, CGRect(x: box.minX + 8, y: stepY, width: box.width - agoWidth - 24, height: line),
                                     font: CodeMonitorFonts.mono, color: text, lines: 1, middle: false))
                    out.append(.text(ago, CGRect(x: box.maxX - 8 - agoWidth, y: stepY, width: agoWidth, height: line),
                                     font: CodeMonitorFonts.peekSmall, color: dim, lines: 1, middle: false))
                    stepY += line
                }
                y = box.maxY + 8
            }
            if let title = p.todosTitle {
                addText(title.uppercased(), font: CodeMonitorFonts.peekLabel, color: dim, maxLines: 1, gap: 3)
                for todo in p.todos {
                    let mark: String
                    let color: NSColor
                    switch todo.mark {
                    case .done: mark = "✓"; color = dim
                    case .current: mark = "▸"; color = CodeMonitorPalette.color(CodeMonitorPalette.nowText)
                    case .pending: mark = "·"; color = text
                    }
                    addText(mark + " " + todo.text, font: CodeMonitorFonts.peekSmall, color: color, maxLines: 1, gap: 1, indent: 2)
                }
                y += 6
            }
            if !p.offers.isEmpty {
                addText("COMMANDS IN THE LAST REPLY", font: CodeMonitorFonts.peekLabel, color: dim, maxLines: 1, gap: 4)
                for row in p.offers {
                    let rowHeight: CGFloat = 24
                    let rowRect = CGRect(x: pad, y: y, width: width, height: rowHeight)
                    out.append(.rule(CGRect(x: rowRect.minX, y: rowRect.minY, width: rowRect.width, height: 0.5)))
                    let review = Self.buttonWidth(row.reviewTitle), copy = Self.buttonWidth("Copied")
                    let reviewRect = CGRect(x: rowRect.maxX - copy - review - 6, y: rowRect.minY + 3, width: review, height: 18)
                    let copyRect = CGRect(x: rowRect.maxX - copy, y: rowRect.minY + 3, width: copy, height: 18)
                    let machineWidth = Self.chipWidth(row.machineChip), classWidth = Self.chipWidth(row.classChip)
                    let machineRect = CGRect(x: reviewRect.minX - 8 - machineWidth, y: rowRect.minY + 4, width: machineWidth, height: 16)
                    let classRect = CGRect(x: machineRect.minX - 4 - classWidth, y: rowRect.minY + 4, width: classWidth, height: 16)
                    out.append(.text("\(row.number)", CGRect(x: rowRect.minX, y: rowRect.minY + 4, width: 16, height: 16),
                                     font: CodeMonitorFonts.peekSmall, color: dim, lines: 1, middle: false))
                    out.append(.text(row.firstLine, CGRect(x: rowRect.minX + 18, y: rowRect.minY + 4,
                                                           width: max(20, classRect.minX - 8 - rowRect.minX - 18), height: 16),
                                     font: CodeMonitorFonts.mono, color: text, lines: 1, middle: true))
                    out.append(.chip(row.classChip, classRect, tone: row.classTone))
                    out.append(.chip(row.machineChip, machineRect, tone: .neutral))
                    buttons.append(Button(action: .review(row.id), title: row.reviewTitle, rect: reviewRect, enabled: true, primary: true))
                    buttons.append(Button(action: .copy(row.id), title: "Copy", rect: copyRect, enabled: row.canCopy, primary: false))
                    y = rowRect.maxY
                    if let note = row.ranNote {
                        out.append(.text(note, CGRect(x: rowRect.minX + 18, y: y - 2, width: width - 18, height: 15),
                                         font: CodeMonitorFonts.peekSmall, color: dim, lines: 1, middle: false))
                        y += 14
                    }
                }
                y += 4
                addText(p.offersNote, font: CodeMonitorFonts.peekSmall, color: dim, maxLines: 2)
            }
            // The results, as `CodeResultPeekRows` gives them.
            for row in p.results {
                switch row {
                case .label(let words):
                    addText(words.uppercased(), font: CodeMonitorFonts.peekLabel, color: dim, maxLines: 1, gap: 4)
                case .text(let words, let isDim):
                    addText(words, font: CodeMonitorFonts.peekSmall, color: isDim ? dim : text, maxLines: 2, gap: 4, middle: true)
                case .buttons(let results):
                    var x = pad
                    for (index, result) in results.enumerated() {
                        let w = min(width, Self.buttonWidth(result.title))
                        // One result's buttons stay together (a web document's Preview and Show in Finder).
                        let together = results[index...].prefix { $0.resultID == result.resultID }
                        let run = index > 0 && results[index - 1].resultID == result.resultID ? w
                            : together.map { min(width, Self.buttonWidth($0.title)) + 6 }.reduce(-6, +)
                        if x > pad, x + run > pad + width { x = pad; y += 24 }
                        buttons.append(Button(action: .result(result), title: result.title, rect: CGRect(x: x, y: y, width: w, height: 20),
                                              enabled: true, primary: false))
                        x += w + 6
                    }
                    y += 28
                }
            }
        }
        contentHeight = y + 4
        elements = out
        contentButtons = buttons

        // Pinned at the bottom: the window button and Copy link.
        var footer: [Button] = []
        var x = pad
        let buttonY = bounds.height - Self.footerHeight + 9
        if let title = p.windowButton, p.windowClick != .none {
            let w = Self.buttonWidth(title, wide: true)
            footer.append(Button(action: .window(p.windowClick), title: title, rect: CGRect(x: x, y: buttonY, width: w, height: 22),
                                 enabled: true, primary: true))
            x += w + 8
        }
        if p.link != nil {
            let w = Self.buttonWidth("Copied", wide: true)
            footer.append(Button(action: .copyLink, title: "Copy link", rect: CGRect(x: x, y: buttonY, width: max(w, Self.buttonWidth("Copy link", wide: true)), height: 22),
                                 enabled: true, primary: false))
        }
        footerButtons = footer
        scrollOffset = min(max(0, scrollOffset), maxScrollOffset)
        noteResultArming()
        updateTrackingAreas()
        needsDisplay = true
    }

    /// Result buttons that open something arm when they appear or move (scrolling moves them).
    private func noteResultArming() {
        var rects: [String: CGRect] = [:]
        for button in visibleButtons() {
            if case .result(let result) = button.action, result.arms { rects[result.id] = button.rect }
        }
        resultArming.layout(rects, now: clock(), pointer: rects.isEmpty ? nil : pointerProbe())
    }

    static func buttonWidth(_ title: String, wide: Bool = false) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: CodeMonitorFonts.button]).width) + (wide ? 22 : 16)
    }

    static func chipWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: CodeMonitorFonts.peekLabel]).width) + 12
    }

    /// Every button with its rect in the view's coordinates (content buttons moved by the scroll offset).
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

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        CodeMonitorPalette.color(0x1B1E25).setFill()
        panel.fill()
        CodeMonitorPalette.color(0x3D4352).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: scrollArea).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: -scrollOffset)
        transform.concat()
        for element in elements { draw(element) }
        for button in contentButtons { drawButton(button) }
        NSGraphicsContext.restoreGraphicsState()
        if maxScrollOffset > 0 { drawScrollHint() }
        // The footer band.
        CodeMonitorPalette.color(0x3D4352).setFill()
        CGRect(x: Self.padding, y: bounds.height - Self.footerHeight, width: bounds.width - 2 * Self.padding, height: 0.5).fill()
        for button in footerButtons { drawButton(button) }
    }

    private func draw(_ element: Element) {
        switch element {
        case .text(let string, let rect, let font, let color, let lines, let middle):
            drawText(string, in: rect, font: font, color: color, lines: lines, middle: middle)
        case .box(let rect):
            CodeMonitorPalette.color(CodeMonitorPalette.screen).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        case .chip(let title, let rect, let tone):
            let color = CodeMonitorView.toneColor(tone)
            CodeMonitorPalette.color(color, 0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            drawText(title, in: rect, font: CodeMonitorFonts.peekLabel, color: CodeMonitorPalette.color(tone == .neutral ? 0xC2C7D0 : color),
                     alignment: .center, verticallyCentered: true)
        case .dot(let rect, let led):
            CodeMonitorView.drawLED(led, in: rect)
        case .rule(let rect):
            CodeMonitorPalette.color(0x3D4352, 0.7).setFill()
            rect.fill()
        }
    }

    private func drawButton(_ button: Button) {
        let hovered = hoveredButton == button.action && button.enabled
        let pressed = pressedButton == button.action && button.enabled
        let fill: NSColor
        var ink: UInt32 = button.primary ? 0xBFF3FA : 0xE2E5EA
        if case .result(let result) = button.action, result.tone != .neutral {
            // Result buttons in their kind's colour (result link purple, file blue).
            let tone = result.tone == .file ? CodeResultPalette.file : CodeResultPalette.resultLink
            fill = CodeMonitorPalette.color(tone, pressed ? 0.34 : (hovered ? 0.26 : 0.18))
            ink = result.tone == .file ? CodeResultPalette.fileText : CodeResultPalette.resultText
        } else if button.primary {
            fill = CodeMonitorPalette.color(0x5FD4E6, pressed ? 0.34 : (hovered ? 0.26 : 0.18))
        } else {
            fill = CodeMonitorPalette.color(0xFFFFFF, pressed ? 0.16 : (hovered ? 0.12 : 0.07))
        }
        fill.setFill()
        NSBezierPath(roundedRect: button.rect, xRadius: 6, yRadius: 6).fill()
        let isCopied = copied[button.action].map { now().timeIntervalSince($0) < Self.copiedDuration } ?? false
        let title = isCopied ? "Copied" : button.title
        let color = button.enabled ? CodeMonitorPalette.color(ink) : CodeMonitorPalette.color(0x8A919E, 0.7)
        drawText(title, in: button.rect, font: CodeMonitorFonts.button, color: color, alignment: .center, verticallyCentered: true)
    }

    private func drawScrollHint() {
        let area = scrollArea
        let thumbHeight = max(24, area.height * area.height / max(contentHeight, 1))
        let y = area.minY + 4 + (area.height - 8 - thumbHeight) * min(max(scrollOffset / maxScrollOffset, 0), 1)
        CodeMonitorPalette.color(0xFFFFFF, 0.22).setFill()
        NSBezierPath(roundedRect: CGRect(x: bounds.maxX - 6, y: y, width: 3, height: thumbHeight), xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func drawText(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, lines: Int = 1, middle: Bool = false,
                          alignment: NSTextAlignment = .left, verticallyCentered: Bool = false) {
        guard rect.width > 2, !string.isEmpty else { return }
        drawnTexts?.append(string)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lines > 1 ? .byWordWrapping : (middle ? .byTruncatingMiddle : .byTruncatingTail)
        var target = rect
        if verticallyCentered {
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
        resultArming.pointerMoved(to: convert(event.locationInWindow, from: nil))
        if event.trackingArea?.userInfo?["panel"] != nil { onHover?(true); return }
        guard let index = event.trackingArea?.userInfo?["button"] as? Int else { return }
        let buttons = visibleButtons()
        guard buttons.indices.contains(index) else { return }
        hoveredButton = buttons[index].action
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        resultArming.pointerMoved(to: event.trackingArea?.userInfo?["panel"] != nil ? nil : convert(event.locationInWindow, from: nil))
        if event.trackingArea?.userInfo?["panel"] != nil { onHover?(false); return }
        hoveredButton = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedButton = button(at: point).flatMap { $0.enabled ? $0.action : nil }
        pressedAt = (clock(), point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let pressed = pressedButton
        pressedButton = nil
        needsDisplay = true
        guard let pressed, let button = button(at: point), button.action == pressed, button.enabled else { return }
        if case .result(let result) = button.action, result.arms {
            guard let down = pressedAt, resultArming.accepts(result.id, downAt: down.time, downPoint: down.point, upPoint: point) else { return }
        }
        press(button.action)
    }

    func press(_ action: Action) {
        var copies = false
        switch action {
        case .copy, .copyLink: copies = true
        case .result(let result): copies = result.action == .copyLink
        default: break
        }
        if copies {
            copied[action] = now()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedDuration + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
        }
        needsDisplay = true
        onAction?(action)
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let next = min(max(0, scrollOffset - delta), maxScrollOffset)
        guard next != scrollOffset else { return super.scrollWheel(with: event) }
        scrollOffset = next
        noteResultArming()
        updateTrackingAreas()
        needsDisplay = true
    }

    // MARK: Accessibility (the buttons; the panel's text is session text and stays out of labels)

    override func accessibilityChildren() -> [Any]? {
        visibleButtons().map { button in
            let label: String
            switch button.action {
            case .review(let id): label = "Review command \(id.number)"
            case .copy(let id): label = "Copy command \(id.number)"
            case .window: label = button.title
            case .copyLink: label = "Copy link"
            case .result(let result): label = result.title
            }
            let element = CodeAccessibilityButton(label: label) { [weak self] in
                if button.enabled { self?.press(button.action) }
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(button.rect)
            element.setAccessibilityEnabled(button.enabled)
            return element
        }
    }
}
