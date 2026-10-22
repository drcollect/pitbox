import AppKit
import PitboxKit

/// The pills of one tag: opaque, 22 pt tall, radius 11, 12 pt semibold text, a 16 pt dark circle with the app's glyph
/// (`DeskTagTuning.glyph`) at the left, at most 260 pt wide (text cut at the end), 4 pt apart, right-aligned, the main
/// item on top and ▦ under it. Drawn by hand: no text field, no text view, nothing that can take the keyboard.
/// It accepts the first mouse, so one click acts without activating the app; a press counts when it begins and
/// ends on the same pill, and on ▦ only once armed (`DeskTagArming`).
final class DeskTagStackView: NSView {
    struct Colors: Equatable {
        var fill: UInt32
        var text: UInt32
    }

    /// The pill colours: command green, file blue, warning orange, running slate, dashboard pink.
    static func colors(_ kind: DeskTagPill.Kind) -> Colors {
        switch kind {
        case .command: return Colors(fill: 0x57D38C, text: 0x04150B)
        case .file: return Colors(fill: 0x6CB6FF, text: 0x04111F)
        case .warning: return Colors(fill: 0xFFB36B, text: 0x1B1203)
        case .running, .lab: return Colors(fill: 0x2A3242, text: 0xCFE0FF)
        case .dashboard: return Colors(fill: 0xF58AC4, text: 0x2A0B1C)
        }
    }

    static let circleFill: UInt32 = 0x0F1115
    static let circleText: UInt32 = 0xE7E9EE
    static let font = NSFont.systemFont(ofSize: DeskTagTuning.fontSize, weight: .semibold)
    static let circleFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
    /// Everything left of the text, and right of it.
    static let lead = DeskTagTuning.circleInset + DeskTagTuning.circleSize + DeskTagTuning.textGap
    static let trail = DeskTagTuning.textTrailing

    private(set) var content: DeskTagContent?
    private(set) var compact = false
    private(set) var pillRects: [CGRect] = []
    private var arming: [Int: DeskTagArming] = [:]
    private var armedPlaces: [Int: CGRect] = [:]
    private var pressed: (index: Int, counts: Bool)?
    private var trackingArea: NSTrackingArea?
    private var accessibilityPills: [NSAccessibilityElement] = []

    /// A pill was pressed (index in `content.pills`).
    var onPress: ((Int) -> Void)?
    /// The pointer entered (true) or left (false) the tag.
    var onHover: ((Bool) -> Void)?
    /// Monotonic seconds (tests: virtual time).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The pointer in screen coordinates (AppKit, y up).
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    /// Tests: every string drawn.
    var drawnTexts: [String]?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Measuring

    /// A pill's width for `text`: the glyph's circle, the text, the trailing space, at most 260 pt.
    static func width(_ text: String) -> CGFloat {
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return min(DeskTagTuning.pillMaxWidth, lead + textWidth + trail)
    }

    static func naturalWidths(_ content: DeskTagContent) -> [CGFloat] {
        content.pills.map { width(content.textHidden ? $0.short : $0.text) }
    }

    static func compactWidths(_ content: DeskTagContent) -> [CGFloat] {
        content.pills.map { width($0.short) }
    }

    // MARK: Content

    /// New content or form. Pills keep their arming while the tag keeps the same kinds of pills (`noteLayout` re-arms the
    /// ones that moved).
    func configure(_ content: DeskTagContent, compact: Bool) {
        guard content != self.content || compact != self.compact else { return }
        let previous = self.content
        self.content = content
        self.compact = compact
        relayout()
        let previousKinds = previous?.pills.map(\.kind) ?? []
        if previousKinds != content.pills.map(\.kind) { arming = [:]; armedPlaces = [:] }
        needsDisplay = true
        updateAccessibility()
    }

    /// The text a pill shows now.
    func shownText(_ index: Int) -> String? {
        guard let pills = content?.pills, pills.indices.contains(index) else { return nil }
        return compact || content?.textHidden == true ? pills[index].short : pills[index].text
    }

    private func relayout() {
        guard let content else { pillRects = []; return }
        let widths = compact ? Self.compactWidths(content) : Self.naturalWidths(content)
        let total = bounds.width
        var y: CGFloat = 0
        pillRects = widths.map { width in
            defer { y += DeskTagTuning.pillHeight + DeskTagTuning.pillGap }
            return CGRect(x: max(0, total - width), y: y, width: min(width, total), height: DeskTagTuning.pillHeight)
        }
        for (index, element) in accessibilityPills.enumerated() where pillRects.indices.contains(index) {
            element.setAccessibilityFrameInParentSpace(pillRects[index])
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    // MARK: Arming

    /// After every placement: a pill that opens something arms again from `time` when it appeared or its place on the
    /// screen changed (a layout change re-arms only the buttons it moved), blocked while the pointer is over it.
    func noteLayout(at time: TimeInterval) {
        guard let pills = content?.pills else { return }
        var places: [Int: CGRect] = [:]
        for (index, pill) in pills.enumerated() where pill.needsArming {
            let place = screenRect(index)
            places[index] = place
            let inside = !place.isNull && place.contains(pointer())
            if arming[index] == nil {
                arming[index] = DeskTagArming(appearedAt: time, pointerInside: inside)
            } else if armedPlaces[index] != place {
                arming[index]?.moved(at: time, pointerInside: inside)
            }
        }
        let moved = places != armedPlaces
        armedPlaces = places
        arming = arming.filter { places[$0.key] != nil }
        if moved { updateTrackingAreas() }
    }

    /// The tag was hidden: showing it again counts as appearing.
    func noteHidden() {
        arming = [:]
        armedPlaces = [:]
        pressed = nil
    }

    func arming(of index: Int) -> DeskTagArming? { arming[index] }

    /// A pill's place on the screen (AppKit coordinates); `.null` when the view is in no window.
    private func screenRect(_ index: Int) -> CGRect {
        guard pillRects.indices.contains(index), let window else { return .null }
        return window.convertToScreen(convert(pillRects[index], to: nil))
    }

    // MARK: Mouse

    func pillIndex(at point: CGPoint) -> Int? {
        pillRects.firstIndex { rect in
            // The rounded ends: inside the capsule only.
            let path = NSBezierPath(roundedRect: rect, xRadius: DeskTagTuning.pillRadius, yRadius: DeskTagTuning.pillRadius)
            return path.contains(point)
        }
    }

    /// Only the pills take clicks; the gaps and corners are not part of the tag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return pillIndex(at: point) == nil ? nil : self }
        let local = convert(point, from: superview)
        return pillIndex(at: local) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = pillIndex(at: point), let pill = content?.pills[index] else { pressed = nil; return }
        let counts = !pill.needsArming || (arming[index]?.allowsPress(at: now()) ?? false)
        pressed = (index, counts)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let press = pressed, press.counts, pillIndex(at: point) == press.index else { return }
        onPress?(press.index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if let window, window.isVisible, bounds.contains(convert(window.convertPoint(fromScreen: pointer()), from: nil)) {
            options.insert(.assumeInside)
        }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }

    override func mouseExited(with event: NSEvent) {
        for index in arming.keys { arming[index]?.pointerExited() }
        onHover?(false)
    }

    /// The pointer left (tests, and the controller after a hover check).
    func notePointerLeft() {
        for index in arming.keys { arming[index]?.pointerExited() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        if drawnTexts != nil { drawnTexts = [] }
        for (index, pill) in content.pills.enumerated() where pillRects.indices.contains(index) {
            draw(pill, text: shownText(index) ?? pill.short, in: pillRects[index])
        }
    }

    private func draw(_ pill: DeskTagPill, text: String, in rect: CGRect) {
        let colors = Self.colors(pill.kind)
        ThemeColor.srgb(colors.fill).setFill()
        NSBezierPath(roundedRect: rect, xRadius: DeskTagTuning.pillRadius, yRadius: DeskTagTuning.pillRadius).fill()
        let circle = CGRect(x: rect.minX + DeskTagTuning.circleInset, y: rect.midY - DeskTagTuning.circleSize / 2,
                            width: DeskTagTuning.circleSize, height: DeskTagTuning.circleSize)
        ThemeColor.srgb(Self.circleFill).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let glyph = NSAttributedString(string: DeskTagTuning.glyph, attributes: [.font: Self.circleFont,
                                                                                .foregroundColor: ThemeColor.srgb(Self.circleText)])
        let glyphSize = glyph.size()
        glyph.draw(at: CGPoint(x: circle.midX - glyphSize.width / 2, y: circle.midY - glyphSize.height / 2))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ThemeColor.srgb(colors.text),
                                                         .paragraphStyle: style]
        let lineHeight = ceil(Self.font.ascender - Self.font.descender)
        let textRect = CGRect(x: rect.minX + Self.lead, y: rect.midY - lineHeight / 2,
                              width: max(0, rect.width - Self.lead - Self.trail + 2), height: lineHeight)
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: attributes)
        drawnTexts?.append(text)
    }

    // MARK: Accessibility (VoiceOver: "The app for “<headline>”: <tag text>")

    private func updateAccessibility() {
        guard let content else { accessibilityPills = []; setAccessibilityChildren([]); return }
        accessibilityPills = content.pills.enumerated().map { index, pill in
            let element = DeskTagAccessiblePill(index: index) { [weak self] in self?.onPress?(index) }
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(content.accessibilityLabel(for: pill))
            element.setAccessibilityParent(self)
            if pillRects.indices.contains(index) { element.setAccessibilityFrameInParentSpace(pillRects[index]) }
            return element
        }
        setAccessibilityElement(false)
        setAccessibilityChildren(accessibilityPills)
    }

    /// The VoiceOver labels, top pill first.
    var accessibilityLabels: [String] { accessibilityPills.compactMap { $0.accessibilityLabel() } }
}

/// One pill for VoiceOver; pressing it does what a click does.
final class DeskTagAccessiblePill: NSAccessibilityElement {
    let index: Int
    private let press: () -> Void

    init(index: Int, press: @escaping () -> Void) {
        self.index = index
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}
