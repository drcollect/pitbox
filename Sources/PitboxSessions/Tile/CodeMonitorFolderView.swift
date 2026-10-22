import AppKit
import QuartzCore
import PitboxKit

/// The body of one bucket, sized like an iPhone folder: 1-4 monitors large, 5-9 medium, 10 or more small, or slim rows
/// (`look: "rows"`), a page at a time with page dots (and ‹ ›) below when there is more than one page; a dot whose page
/// holds a monitor in Needs you or with a warning gets an amber ring, so attention on another page shows without moving
/// anything. The order is the items' order: fixed, never by attention. An empty bucket in bucket mode shows "Drop
/// windows or monitors here".
///
/// Its height is its natural height (`naturalHeight(…)`): the block stacks the buckets and scrolls when they are taller
/// than the block. It reuses one `CodeMonitorView` per session on the current page and forwards their clicks, hovers
/// and drags. Never first responder; the dots act on mouse-up inside.
final class CodeMonitorFolderView: NSView {
    private(set) var items: [CodeMonitorItem] = []
    private(set) var showsProfiles = false
    private(set) var stripColumn: CGFloat = 322.67
    private(set) var look: CodeSettings.Look = .monitors
    /// Bucket mode and no monitor: the drop hint instead of monitors.
    private(set) var showsEmptyHint = false
    private(set) var grid = CodeMonitorGrid.layout(count: 0, width: 992, stripColumn: 322.67)
    private(set) var page = 0
    private(set) var monitorViews: [String: CodeMonitorView] = [:]
    var onMonitorClick: ((CodeMonitorView, CodeMonitorView.Target) -> Void)?
    var onMonitorHover: ((CodeMonitorView, Bool) -> Void)?
    /// Bucket mode: a monitor's press that moves becomes a drag between buckets; nil keeps plain clicks.
    var onMonitorDrag: ((CodeMonitorView, CodeMonitorView.DragPhase, NSEvent) -> Void)? {
        didSet { for view in monitorViews.values { wireDrag(view) } }
    }
    /// The page changed by the user (dots, arrows, a swipe) or `show(page:)`: the block closes a peek of a monitor that
    /// left the page and remembers the page.
    var onPageChange: (() -> Void)?
    private var pressedControl: Control?
    /// Reduce Motion (tests replace it); monitor views follow.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } {
        didSet { for view in monitorViews.values { view.reduceMotion = reduceMotion } }
    }

    static let emptyHint = "Drop windows or monitors here"

    /// The height a bucket of `count` monitors needs at `width` (`rows`: slim rows; `emptyHint`: an empty bucket shows
    /// the 48 pt drop hint).
    static func naturalHeight(count: Int, width: CGFloat, stripColumn: CGFloat, rows: Bool = false, emptyHint: Bool = false) -> CGFloat {
        if count == 0, emptyHint { return CodeBucketLayout.emptyHeight }
        return CodeMonitorGrid.layout(count: count, width: width, stripColumn: stripColumn, rows: rows).height
    }

    enum Control: Equatable {
        case previous, next, dot(Int)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// New monitors (already filtered and ordered), the grid's column width, the look and whether an empty bucket shows
    /// the drop hint, and the page to show (nil: the page stays where it was when it still exists); clamped.
    func update(items: [CodeMonitorItem], showsProfiles: Bool, stripColumn: CGFloat, look: CodeSettings.Look = .monitors,
                emptyHint: Bool = false, page: Int? = nil) {
        self.items = items
        self.showsProfiles = showsProfiles
        self.stripColumn = stripColumn
        self.look = look
        showsEmptyHint = emptyHint
        if let page { self.page = max(0, page) }
        relayout()
    }

    /// Shows the page holding `id`, if it is in the bucket.
    func reveal(_ id: String) {
        guard let position = items.firstIndex(where: { $0.id == id }) else { return }
        show(page: grid.page(of: position))
    }

    /// Turns to `newPage` (clamped) with a 0.2 s slide (none with Reduce Motion), and reports it.
    func show(page newPage: Int) {
        let clamped = min(max(newPage, 0), grid.pages - 1)
        guard clamped != page else { return }
        let forward = clamped > page
        page = clamped
        relayout()
        if !reduceMotion() { slideIn(fromTrailing: forward) }
        onPageChange?()
    }

    /// The page's monitors slide in from the side it was turned toward: a layer animation of their translation (their
    /// frames stay put), clipped to the bucket while it runs.
    private func slideIn(fromTrailing: Bool) {
        guard let layer, window != nil else { return }
        let distance = (fromTrailing ? 1 : -1) * min(bounds.width, 120)
        layer.masksToBounds = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.layer?.masksToBounds = false }
        for view in monitorViews.values {
            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = distance
            animation.toValue = 0
            animation.duration = Self.pageSlide
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer?.add(animation, forKey: "page")
        }
        CATransaction.commit()
    }

    /// A page turn's slide.
    static let pageSlide: TimeInterval = 0.2

    /// Sets the remembered page without reporting it (the block restores a bucket's page); clamped at layout.
    func setPage(_ newPage: Int) {
        let clamped = min(max(newPage, 0), grid.pages - 1)
        guard clamped != page else { return }
        page = clamped
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    private func relayout() {
        grid = CodeMonitorGrid.layout(count: items.count, width: bounds.width, stripColumn: stripColumn, rows: look == .rows)
        page = min(max(page, 0), grid.pages - 1)
        let range = grid.range(ofPage: page)
        let shown = range.isEmpty ? [] : Array(items[range])
        let ids = Set(shown.map(\.id))
        for (id, view) in monitorViews where !ids.contains(id) {
            view.removeFromSuperview()
            monitorViews[id] = nil
        }
        let rows = grid.isRows
        for (slot, item) in shown.enumerated() {
            let frame = grid.frame(ofSlot: slot)
            if let view = monitorViews[item.id] {
                view.frame = frame
                view.configure(item: item, size: grid.size, showsProfile: showsProfiles, isRow: rows)
            } else {
                let view = CodeMonitorView(item: item, size: grid.size, showsProfile: showsProfiles, isRow: rows, frame: frame)
                view.reduceMotion = reduceMotion
                view.onClick = { [weak self] view, target in self?.onMonitorClick?(view, target) }
                view.onHover = { [weak self] view, inside in self?.onMonitorHover?(view, inside) }
                wireDrag(view)
                addSubview(view)
                monitorViews[item.id] = view
            }
        }
        needsDisplay = true
    }

    private func wireDrag(_ view: CodeMonitorView) {
        view.onDrag = onMonitorDrag == nil ? nil : { [weak self] view, phase, event in self?.onMonitorDrag?(view, phase, event) }
    }

    /// The monitor view of a session on the current page.
    func monitorView(_ id: String) -> CodeMonitorView? { monitorViews[id] }

    // MARK: Pager

    /// The dots and arrows, centred in the pager band.
    func controls() -> [(control: Control, rect: CGRect)] {
        guard grid.pages > 1 else { return [] }
        let band = grid.pagerRect(width: bounds.width)
        let dot: CGFloat = 7, spacing: CGFloat = 8, arrow: CGFloat = 22
        let dotsWidth = CGFloat(grid.pages) * dot + CGFloat(grid.pages - 1) * spacing
        let total = arrow + 6 + dotsWidth + 6 + arrow
        var x = (band.midX - total / 2).rounded()
        var out: [(Control, CGRect)] = [(.previous, CGRect(x: x, y: band.minY, width: arrow, height: band.height))]
        x += arrow + 6
        for index in 0..<grid.pages {
            out.append((.dot(index), CGRect(x: x - 3, y: band.minY, width: dot + 6, height: band.height)))
            x += dot + spacing
        }
        x += 6 - spacing
        out.append((.next, CGRect(x: x, y: band.minY, width: arrow, height: band.height)))
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = CodeMonitorPalette(dark: ThemeColor.isDark(effectiveAppearance))
        if items.isEmpty, showsEmptyHint { drawEmptyHint(palette) }
        guard grid.pages > 1 else { return }
        for (control, rect) in controls() {
            switch control {
            case .dot(let index):
                let dot = CGRect(x: rect.midX - 3.5, y: rect.midY - 3.5, width: 7, height: 7)
                (index == page ? palette.dotOn : palette.dotOff).setFill()
                NSBezierPath(ovalIn: dot).fill()
                if pageAsksForAttention(index) {
                    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -2.25, dy: -2.25))
                    ring.lineWidth = 1.5
                    CodeMonitorPalette.color(CodeMonitorPalette.amber).setStroke()
                    ring.stroke()
                }
            case .previous, .next:
                let enabled = control == .previous ? page > 0 : page < grid.pages - 1
                let text = control == .previous ? "‹" : "›"
                let color = enabled ? palette.headerText : palette.dotOff
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                                 .foregroundColor: pressedControl == control ? palette.headerTitle : color]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                        withAttributes: attributes)
            }
        }
    }

    /// "Drop windows or monitors here": 12 pt grey in a dashed outline, the bucket's whole body (48 pt).
    private func drawEmptyHint(_ palette: CodeMonitorPalette) {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        palette.headerFaint.withAlphaComponent(0.55).setStroke()
        outline.stroke()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let font = CodeMonitorFonts.headerDetail
        let height = CodeMonitorFonts.lineHeight(font)
        (Self.emptyHint as NSString).draw(with: CGRect(x: rect.minX + 8, y: (rect.midY - height / 2).rounded(),
                                                       width: max(0, rect.width - 16), height: height),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                          attributes: [.font: font, .foregroundColor: palette.headerFaint, .paragraphStyle: style])
    }

    /// A monitor on page `index` is in Needs you or has a warning.
    func pageAsksForAttention(_ index: Int) -> Bool {
        items[grid.range(ofPage: index)].contains { $0.state == .needsYou || $0.hasWarning }
    }

    private func control(at point: CGPoint) -> Control? {
        controls().first { $0.rect.contains(point) }?.control
    }

    override func mouseDown(with event: NSEvent) {
        pressedControl = control(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = pressedControl
        pressedControl = nil
        needsDisplay = true
        guard let pressed, control(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        perform(pressed)
    }

    func perform(_ control: Control) {
        switch control {
        case .previous: show(page: page - 1)
        case .next: show(page: page + 1)
        case .dot(let index): show(page: index)
        }
    }

    /// A horizontal two-finger swipe turns one page per gesture (a mouse's horizontal wheel one per tick); vertical
    /// scrolling goes on to the enclosing view.
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard grid.pages > 1, abs(dx) > abs(dy) else { return super.scrollWheel(with: event) }
        if event.momentumPhase != [] { return }
        if !event.hasPreciseScrollingDeltas {
            if abs(dx) > 0 { show(page: page + (dx < 0 ? 1 : -1)) }
            return
        }
        if event.phase == .began { swipe = 0; swipeTurned = false }
        swipe += dx
        if !swipeTurned, abs(swipe) > 40 {
            swipeTurned = true
            show(page: page + (swipe < 0 ? 1 : -1))
        }
        if event.phase == .ended || event.phase == .cancelled { swipe = 0; swipeTurned = false }
    }

    private var swipe: CGFloat = 0
    private var swipeTurned = false

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = items[grid.range(ofPage: page)].compactMap { monitorViews[$0.id] }
        for (control, rect) in controls() {
            let label: String
            switch control {
            case .previous: label = "Previous page"
            case .next: label = "Next page"
            case .dot(let index): label = "Page \(index + 1) of \(grid.pages)" + (index == page ? ", current" : "")
            }
            let element = CodeAccessibilityButton(label: label) { [weak self] in self?.perform(control) }
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect)
            children.append(element)
        }
        return children
    }
}

/// A clickable area of a custom-drawn view, for VoiceOver.
final class CodeAccessibilityButton: NSAccessibilityElement {
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
