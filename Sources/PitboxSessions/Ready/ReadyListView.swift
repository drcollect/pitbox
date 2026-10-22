import AppKit
import PitboxKit

/// Ready for you, drawn: the header "Ready for you · 4" with "kept until you act
/// or dismiss" (or "Dismissed · Undo" for 5 s), the recap card, 60 pt cards (a header line, one text line, the buttons;
/// radius 10, a 1 pt border in the kind's colour), 28 pt result and Later rows, "N more ▾" and the line for items hidden
/// by the cap. It sits on the block's glass below the buckets; with no items it has no height at all.
///
/// - Buttons act on mouse-up inside, on the button the press began on. Buttons that open something (↗, ▤, ▦, Open after
///   a fetch, Show in Finder) count only once armed (`CodeReadyArming`: 0.8 s after they appeared or moved, never under
///   the pointer that was there when they appeared). Later, Dismiss, OK, Show, Open window, ▶ Run…, … act at once.
/// - Never first responder, no text field, no key equivalent (no card of the app has a text field).
/// - Snapshots and other off-screen copies draw a redaction card; VoiceOver labels hold no session text.
final class CodeReadyListView: NSView {
    let list: CodeReadyList
    private(set) var layout = CodeReadyLayout(CodeReadySnapshot(), width: 0)
    private(set) var arming = CodeReadyArming()
    private var recapView: CodeAwayRecapView?
    private var hovered: String?
    private var pressed: (id: String, at: Date)?
    private var armRedraw: Int = 0
    /// Tests: every string drawn in the last pass.
    var drawnTexts: [String]?
    /// Tests: let an off-screen render show the cards.
    var testsRenderUnredacted = false
    /// The clock of the arming (real time; tests replace it).
    var now: () -> Date = { Date() }
    /// Tests: where the pointer is, in this view's coordinates (nil: unknown). Production reads the window.
    var pointerProbe: (() -> CGPoint?)?
    /// The pressed card's frame in screen coordinates, for the sheet's anchor (tests replace it).
    var screenFrame: (CGRect, NSView) -> CGRect = { rect, view in
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    init(list: CodeReadyList) {
        self.list = list
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Ready for you")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The list's height at `width` for its current snapshot.
    static func height(of snapshot: CodeReadySnapshot, width: CGFloat) -> CGFloat {
        CodeReadyLayout.height(of: snapshot, width: width)
    }

    /// The height the band needs at `width`; 0 hides it. This is `CodeTileAccessory`'s requirement (the Ready slot,
    /// `CodeMonitorsTileView.readyAccessory`): the block asks it on every layout and places the view.
    func accessoryHeight(forWidth width: CGFloat) -> CGFloat {
        Self.height(of: list.snapshot, width: width)
    }

    /// Called when the list's height changed on its own (a new item, Later, Dismiss, the recap): the block lays itself
    /// out again (`CodeMonitorsTileView.accessoriesChanged()`).
    var onHeightChange: (() -> Void)?
    private var reportedHeight: CGFloat?

    // MARK: Layout

    /// Takes the list's snapshot (`CodeReadyForYou` calls it on every change).
    func refresh() {
        relayout()
        let height = accessoryHeight(forWidth: bounds.width > 0 ? bounds.width : 992)
        if height != reportedHeight {
            reportedHeight = height
            onHeightChange?()
        }
    }

    /// The block was shown or hidden: every open button appears anew.
    func stripVisibilityChanged() {
        arming = CodeReadyArming()
        relayout()
    }

    /// The block moved the list in its stack (the list follows the buckets, so a bucket that grows or shrinks moves
    /// it): its buttons moved under a pointer that did not, so every open button appears anew.
    func movedInStack() {
        arming = CodeReadyArming()
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    private func relayout() {
        let snapshot = list.snapshot
        layout = CodeReadyLayout(snapshot, width: bounds.width, fetchedOpens: list.fetchedFileOpens)
        let open = Dictionary(layout.buttons.filter(\.opensSomething).map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
        arming.layout(open, pointer: pointerLocation(), now: now())
        if let pressed, !layout.buttons.contains(where: { $0.id == pressed.id }) { self.pressed = nil }
        placeRecap(snapshot.recap)
        scheduleArmRedraw()
        updateTrackingAreas()
        needsDisplay = true
    }

    private func placeRecap(_ recap: CodeAwayRecap.Recap?) {
        let frame = layout.blocks.compactMap { block -> CGRect? in
            if case .recap(let rect) = block { return rect }
            return nil
        }.first
        guard let recap, let frame else {
            recapView?.removeFromSuperview()
            recapView = nil
            return
        }
        if let recapView {
            recapView.update(recap)
            recapView.frame = frame
        } else {
            let view = CodeAwayRecapView(recap: recap, frame: frame)
            view.clock = list.clock
            view.onGotIt = { [weak self] in self?.list.press(.gotIt) }
            addSubview(view)
            recapView = view
        }
    }

    /// One redraw when the next open button arms (so it is drawn at full strength).
    private func scheduleArmRedraw() {
        guard let next = arming.nextArming(after: now()) else { return }
        armRedraw += 1
        let token = armRedraw
        list.schedule(max(0.01, next.timeIntervalSince(now()) + 0.02)) { [weak self] in
            guard let self, self.armRedraw == token else { return }
            self.needsDisplay = true
        }
    }

    func pointerLocation() -> CGPoint? {
        if let pointerProbe { return pointerProbe() }
        guard let window, window.isVisible else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) ? point : nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawnTexts = drawnTexts.map { _ in [] }
        let dark = ThemeColor.isDark(effectiveAppearance)
        let palette = CodeReadyPalette(dark: dark)
        let glass = CodeMonitorPalette(dark: dark)
        for block in layout.blocks {
            switch block {
            case .header(let rect): drawHeader(rect, palette: palette, glass: glass)
            case .recap: break
            case .card(let entry, let rect): drawCard(entry.item, rect, palette: palette)
            case .later(let entry, let rect): drawLater(entry.item, rect, palette: palette)
            case .result(let entry, let row, let rect): drawResult(entry.item, row: row, rect, palette: palette)
            }
        }
        for button in layout.buttons { drawButton(button, palette: palette, glass: glass) }
    }

    private func drawHeader(_ rect: CGRect, palette: CodeReadyPalette, glass: CodeMonitorPalette) {
        guard let header = list.snapshot.header else { return }
        let title = header.count > 0 ? "\(CodeReadyWords.listTitle) · \(header.count)" : CodeReadyWords.listTitle
        let titleWidth = CodeReadyLayout.textWidth(title, CodeReadyFonts.header)
        text(title, CGRect(x: rect.minX + 2, y: rect.minY, width: min(rect.width, titleWidth + 4), height: rect.height),
             font: CodeReadyFonts.header, color: glass.headerTitle)
        var notes: [String] = []
        if let follow = header.followNote { notes.append(follow) }
        notes.append(header.undoShown ? "Dismissed ·" : CodeReadyWords.keptNote)
        let note = notes.joined(separator: " · ")
        let undo = layout.buttons.first { $0.id == "list|undo" }?.rect.width ?? 0
        let width = CodeReadyLayout.textWidth(note, CodeReadyFonts.headerNote) + 2
        let x = max(rect.minX + titleWidth + 16, rect.maxX - undo - width)
        text(note, CGRect(x: x, y: rect.minY, width: rect.maxX - undo - x, height: rect.height), font: CodeReadyFonts.headerNote,
             color: glass.headerFaint)
    }

    private func drawCard(_ item: CodeReadyItem, _ rect: CGRect, palette: CodeReadyPalette) {
        let tone = palette.tone(item.kind)
        let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        CodeReadyPalette.color(tone.background).setFill()
        card.fill()
        CodeReadyPalette.color(tone.accent).setStroke()
        card.lineWidth = 1
        card.stroke()
        let pad = CodeReadyLayout.cardPadding
        let inner = rect.insetBy(dx: pad, dy: 0)
        // The header line: kind, note, from.
        let head = NSMutableAttributedString(string: item.title, attributes: [.font: CodeReadyFonts.title,
                                                                               .foregroundColor: CodeReadyPalette.color(tone.accent)])
        if let note = item.titleNote {
            head.append(NSAttributedString(string: " · " + note, attributes: [.font: CodeReadyFonts.detail,
                                                                               .foregroundColor: palette.text]))
        }
        head.append(NSAttributedString(string: "   " + item.detail, attributes: [.font: CodeReadyFonts.detail,
                                                                                  .foregroundColor: palette.dim]))
        attributed(head, CGRect(x: inner.minX, y: rect.minY + 5, width: inner.width, height: 16))
        // The text line, with the class chip on its right.
        var lineWidth = inner.width
        if let chip = item.chip {
            let w = CodeReadyLayout.textWidth(chip, CodeReadyFonts.chip) + 14
            let chipRect = CGRect(x: inner.maxX - w, y: rect.minY + 22, width: w, height: 16)
            let chipTone = chip == "Risky" || chip == "Blocked" ? palette.tone(.warning) : palette.tone(nil)
            CodeReadyPalette.color(chipTone.accent, 0.2).setFill()
            NSBezierPath(roundedRect: chipRect, xRadius: 8, yRadius: 8).fill()
            text(chip, chipRect, font: CodeReadyFonts.chip, color: CodeReadyPalette.color(chipTone.accent), centered: true)
            lineWidth -= w + 8
        }
        if let line = item.line {
            text(line, CGRect(x: inner.minX, y: rect.minY + 21, width: lineWidth, height: 17),
                 font: item.lineIsCommand ? CodeReadyFonts.command : CodeReadyFonts.line, color: palette.text,
                 middle: item.lineIsCommand)
        }
    }

    private func drawLater(_ item: CodeReadyItem, _ rect: CGRect, palette: CodeReadyPalette) {
        let tone = palette.tone(item.kind)
        let row = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        CodeReadyPalette.color(tone.background).setFill()
        row.fill()
        palette.neutralOutline.setStroke()
        row.lineWidth = 1
        row.stroke()
        let sign = item.kind == .file ? "⤓ " : "▶ "
        let text = NSMutableAttributedString(string: sign, attributes: [.font: CodeReadyFonts.title,
                                                                         .foregroundColor: CodeReadyPalette.color(tone.accent)])
        text.append(NSAttributedString(string: item.headline, attributes: [.font: CodeReadyFonts.title, .foregroundColor: palette.text]))
        text.append(NSAttributedString(string: " · " + item.whereText, attributes: [.font: CodeReadyFonts.detail,
                                                                                     .foregroundColor: palette.dim]))
        let right = layout.buttons.filter { $0.id.hasPrefix(item.id + "|") && $0.style != .area }.map(\.rect.minX).min()
            ?? rect.maxX - CodeReadyLayout.cardPadding
        attributed(text, CGRect(x: rect.minX + CodeReadyLayout.cardPadding, y: rect.minY + 6,
                                width: right - rect.minX - 2 * CodeReadyLayout.cardPadding, height: 16))
    }

    private func drawResult(_ item: CodeReadyItem, row: CodeReadySnapshot.ResultRow, _ rect: CGRect, palette: CodeReadyPalette) {
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        CodeReadyPalette.color(palette.tone(nil).background).setFill()
        shape.fill()
        palette.neutralOutline.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let (words, good) = Self.resultWords(row.state)
        let color: NSColor
        switch good {
        case true?: color = CodeReadyPalette.color(palette.tone(.finished).accent)
        case false?: color = CodeReadyPalette.color(palette.dark ? 0xFF8A8A : 0xB3261E)
        case nil: color = palette.text
        }
        let text = NSMutableAttributedString(string: words, attributes: [.font: CodeReadyFonts.title, .foregroundColor: color])
        text.append(NSAttributedString(string: " · " + item.headline, attributes: [.font: CodeReadyFonts.detail,
                                                                                    .foregroundColor: palette.dim]))
        attributed(text, CGRect(x: rect.minX + CodeReadyLayout.cardPadding, y: rect.minY + 6,
                                width: layout.resultTextWidth(rect, item: item), height: 16))
    }

    /// "✓ exit 0 · 3 s", "✕ exit 1 · 12 s", "stopped · 4 s", "running…", "Typed, not run", "Fetched draft.md · 42 KB",
    /// and whether it is good news (nil: neither).
    static func resultWords(_ state: CodeReadySnapshot.ResultRow.State) -> (String, Bool?) {
        switch state {
        case .running: return ("running…", nil)
        case .finished(let status, let seconds):
            let time = CodeOfferWords.duration(seconds)
            return status == 0 ? ("✓ exit 0 · \(time)", true) : ("✕ exit \(status) · \(time)", false)
        case .stopped(let seconds): return ("stopped · \(CodeOfferWords.duration(seconds))", false)
        case .typed: return ("Typed, not run", nil)
        case .fetched(let name, let bytes):
            let file = CodePlainText.line(name, limit: 48) ?? "file"
            return ("Fetched \(file) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", true)
        case .fetchFailed(let reason):
            return ("✕ fetch failed: " + (CodePlainText.line(reason, limit: 60) ?? "error"), false)
        }
    }

    private func drawButton(_ button: CodeReadyLayout.Button, palette: CodeReadyPalette, glass: CodeMonitorPalette) {
        let armed = !button.opensSomething || arming.isArmed(button.id, now: now())
        let hot = (hovered == button.id || pressed?.id == button.id) && armed
        switch button.style {
        case .area:
            return
        case .link:
            text(button.title, button.rect, font: CodeReadyFonts.button,
                 color: hot ? glass.headerTitle : glass.headerText, centered: false)
            return
        case .primary, .secondary:
            break
        }
        let tone = palette.tone(button.kind)
        let accent: UInt32
        let accentWords: UInt32
        switch button.color {
        case .kind:
            (accent, accentWords) = (tone.accent, tone.words)
        case .dashboard:
            (accent, accentWords) = palette.dark ? (CodeReadyPalette.dashboardDark, CodeReadyPalette.dashboardWordsDark)
                : (CodeReadyPalette.dashboardLight, CodeReadyPalette.dashboardWordsLight)
        case .link:
            (accent, accentWords) = palette.dark ? (CodeReadyPalette.linkDark, CodeReadyPalette.linkWordsDark)
                : (CodeReadyPalette.linkLight, CodeReadyPalette.linkWordsLight)
        }
        let fill: NSColor
        let words: NSColor
        if button.style == .primary || button.color != .kind {
            fill = CodeReadyPalette.color(accent, tone.fillAlpha + (hot ? 0.12 : 0))
            words = CodeReadyPalette.color(accentWords)
        } else {
            fill = hot ? palette.secondaryHover : palette.secondaryFill
            words = palette.buttonText
        }
        (armed ? fill : fill.withAlphaComponent(fill.alphaComponent * 0.5)).setFill()
        NSBezierPath(roundedRect: button.rect, xRadius: 6, yRadius: 6).fill()
        text(button.title, button.rect, font: CodeReadyFonts.button, color: armed ? words : palette.disabledText, centered: true)
    }

    private func text(_ string: String, _ rect: CGRect, font: NSFont, color: NSColor, centered: Bool = false,
                      middle: Bool = false) {
        guard rect.width > 2, !string.isEmpty else { return }
        drawnTexts?.append(string)
        let style = NSMutableParagraphStyle()
        style.alignment = centered ? .center : .left
        style.lineBreakMode = middle ? .byTruncatingMiddle : .byTruncatingTail
        let height = CodeMonitorFonts.lineHeight(font)
        let target = CGRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height)
        (string as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private func attributed(_ string: NSMutableAttributedString, _ rect: CGRect) {
        guard rect.width > 2 else { return }
        drawnTexts?.append(string.string)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        string.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: string.length))
        let height = CodeMonitorFonts.lineHeight(CodeReadyFonts.title)
        string.draw(with: CGRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    func button(at point: CGPoint) -> CodeReadyLayout.Button? {
        layout.buttons.last { $0.rect.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerMoved(to: nil) }

    /// The pointer moved to `point` (nil: it left the list): hover, and buttons it left may arm.
    func pointerMoved(to point: CGPoint?) {
        arming.pointerMoved(to: point)
        let next = point.flatMap { button(at: $0)?.id }
        if next != hovered {
            hovered = next
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        pressDown(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard event.type == .leftMouseUp else { return }
        pressUp(at: convert(event.locationInWindow, from: nil))
    }

    /// A left press began at `point`.
    func pressDown(at point: CGPoint) {
        pressed = button(at: point).map { ($0.id, now()) }
        needsDisplay = true
    }

    /// The press ended at `point`: the button acts when the press began and ended on it (and it was armed).
    func pressUp(at point: CGPoint) {
        defer {
            pressed = nil
            needsDisplay = true
        }
        guard let pressed, let button = button(at: point), button.id == pressed.id else { return }
        if button.opensSomething, !arming.counts(button.id, downAt: pressed.at) {
            CodeTileLog.info("ready press ignored reason=unarmed")
            return
        }
        list.press(button.action, anchor: anchor(for: button))
    }

    /// The frame of the card a button sits on, in screen coordinates.
    private func anchor(for button: CodeReadyLayout.Button) -> CGRect {
        for block in layout.blocks {
            switch block {
            case .card(_, let rect), .later(_, let rect), .result(_, _, let rect):
                if rect.contains(button.rect.origin) { return screenFrame(rect, self) }
            case .header, .recap:
                continue
            }
        }
        return screenFrame(button.rect, self)
    }

    // MARK: Snapshots: one redaction card

    override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {
        let cover = redactionCover()
        if let cover { addSubview(cover, positioned: .above, relativeTo: nil) }
        super.cacheDisplay(in: rect, to: bitmapImageRep)
        cover?.removeFromSuperview()
    }

    override func dataWithPDF(inside rect: NSRect) -> Data {
        let cover = redactionCover()
        if let cover { addSubview(cover, positioned: .above, relativeTo: nil) }
        let data = super.dataWithPDF(inside: rect)
        cover?.removeFromSuperview()
        return data
    }

    private func redactionCover() -> NSView? {
        guard !testsRenderUnredacted else { return nil }
        return CodeReadyRedactionView(frame: bounds, dark: ThemeColor.isDark(effectiveAppearance))
    }

    // MARK: Accessibility (labels without session text)

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = layout.buttons.map { button in
            let element = CodeReadyAccessibilityButton(label: Self.accessibilityLabel(button)) { [weak self] in
                guard let self else { return }
                if button.opensSomething, !self.arming.counts(button.id, downAt: self.now()) { return }
                self.list.press(button.action, anchor: self.anchor(for: button))
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(button.rect)
            return element
        }
        if let recapView { children.insert(recapView, at: 0) }
        return children
    }

    static func accessibilityLabel(_ button: CodeReadyLayout.Button) -> String {
        switch button.action {
        case .openSheet: return button.title.contains("Fetch") ? "Fetch file" : (button.title.contains("Run") ? "Run command" : "Review command")
        case .fetchResult: return "Fetch file"
        case .showWindow: return "Show window"
        case .showMonitor: return "Show monitor"
        case .openWindow: return "Back on track"
        case .openInClaude: return "Open in Claude"
        case .openResult: return "Open result"
        case .openDashboard: return "Open dashboard"
        case .revealRun: return "Show output"
        case .openFetched: return "Open fetched file"
        case .showFetchedInFinder: return "Show fetched file in Finder"
        case .later: return "Later"
        case .unfold: return "Unfold"
        case .dismiss: return "Dismiss"
        case .undoDismiss: return "Undo"
        case .ok: return "OK"
        case .gotIt: return "Got it"
        case .showMore: return "Show more"
        case .showHidden: return "Show items of sessions not opened recently"
        }
    }
}

/// What an off-screen copy of the list shows instead of its cards: opaque, with the block's notice.
final class CodeReadyRedactionView: NSView {
    private let dark: Bool
    static let text = "Code monitors are not included in snapshots"

    init(frame: NSRect, dark: Bool) {
        self.dark = dark
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        CodeReadyPalette.color(dark ? 0x1B1E25 : 0xF4F2FB).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: CodeReadyPalette.color(dark ? 0xC9C4DA : 0x4A4560),
        ]
        let size = (Self.text as NSString).size(withAttributes: attributes)
        (Self.text as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                     withAttributes: attributes)
    }
}
