import AppKit
import QuartzCore
import PitboxKit

/// One monitor (the original design's look) at one of the three bucket sizes, or as a slim row: a graphite bezel with
/// the LED, a near-black screen with the headline, nickname and window chip, TL;DR / "Now" / Ask line, the offer line
/// and the bottom bar, then a short stand. Its own class so buckets, the Ready list and desk tags can reuse it:
/// configure it with an item, a size, whether profile marks show and whether it is a row.
///
/// Clicks act on mouse-up inside the same part: the offer line (or a small monitor's badge, or a row's button) reports
/// `.offer`, a mark `.mark(index)`, anything else on the bezel or screen `.screen`. While an operation is in flight the
/// screen shows a spinner and the click does nothing (the item's `click` is `.none`). In bucket mode (`onDrag` set) a
/// press that moves 5 pt becomes a drag between buckets instead: no click, and the block dims the monitor to
/// 35 %. Hover is reported through enter/exit tracking only. Never first responder.
final class CodeMonitorView: NSView {
    enum Target: Equatable { case screen, offer, mark(Int), result }
    /// A drag's steps, reported to `onDrag` with the mouse event.
    enum DragPhase: Equatable { case began, moved, ended }

    private(set) var item: CodeMonitorItem
    private(set) var size: CodeMonitorSize
    private(set) var showsProfile: Bool
    /// A slim row instead of a monitor.
    private(set) var isRow: Bool
    private(set) var layoutInfo: CodeMonitorLayout
    var onClick: ((CodeMonitorView, Target) -> Void)?
    var onHover: ((CodeMonitorView, Bool) -> Void)?
    /// Set in bucket mode: presses that move become drags.
    var onDrag: ((CodeMonitorView, DragPhase, NSEvent) -> Void)?
    private(set) var hovered = false
    /// The block's open peek covers this monitor: its glow would bleed out around the panel.
    var suppressGlow = false { didSet { if suppressGlow != oldValue { needsDisplay = true } } }
    /// Drawn at 35 % while it is dragged.
    var dimmed = false {
        didSet {
            guard dimmed != oldValue else { return }
            pulse.alphaValue = dimmed ? Self.draggedOpacity : 1
            spinner?.alphaValue = dimmed ? Self.draggedOpacity : 1
            needsDisplay = true
        }
    }
    /// What the offer line (large, medium), the corner badge (small) or the row's button opens.
    var offerAction: CodeOfferLine.Action? { size == .small && !isRow ? item.pip?.action : item.offer?.action }
    private(set) var pressed: Target?
    private var pressedInside = false
    private var downPoint: CGPoint?
    /// A drag is under way (the mouse-up ends it, never clicks).
    private(set) var isDragging = false
    /// The block cancelled the drag of this press: the rest of the press does nothing.
    private var pressCancelled = false
    private let pulse = CodeLEDView()
    private var spinner: NSProgressIndicator?
    /// Marks that open something: when each appeared or moved, and whether the pointer was on it then.
    private var markArming: [String: (rect: CGRect, since: TimeInterval, underPointer: Bool)] = [:]
    /// Reduce Motion: no pulse, no scanlines (tests replace it).
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var increaseContrast: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    /// The clock of mark arming (tests replace it).
    var clock: () -> TimeInterval = MonotonicClock.now
    /// Where the pointer is in this view (nil: unknown; tests replace it).
    lazy var pointerProbe: () -> CGPoint? = { [weak self] in
        guard let self, let window = self.window, window.isVisible else { return nil }
        return self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }
    /// Tests: when set, every string drawn is appended.
    var drawnTexts: [String]?
    /// A press must move this far to become a drag.
    static let dragThreshold: CGFloat = 5
    /// Opacity of a monitor being dragged.
    static let draggedOpacity: CGFloat = 0.35

    init(item: CodeMonitorItem, size: CodeMonitorSize, showsProfile: Bool, isRow: Bool = false, frame: CGRect) {
        self.item = item
        self.size = size
        self.showsProfile = showsProfile
        self.isRow = isRow
        let bounds = CGRect(origin: .zero, size: frame.size)
        layoutInfo = isRow ? CodeMonitorLayout.computeRow(item, bounds: bounds, showsProfile: showsProfile)
            : CodeMonitorLayout.compute(item, size: size, bounds: bounds, showsProfile: showsProfile)
        super.init(frame: frame)
        wantsLayer = true
        addSubview(pulse)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        syncSubviews()
        updateAccessibility()
        noteMarks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// New content, size or look. Redraws only when something changed.
    func configure(item: CodeMonitorItem, size: CodeMonitorSize, showsProfile: Bool, isRow: Bool = false) {
        guard item != self.item || size != self.size || showsProfile != self.showsProfile || isRow != self.isRow else { return }
        self.item = item
        self.size = size
        self.showsProfile = showsProfile
        self.isRow = isRow
        relayout()
        updateAccessibility()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    private func relayout() {
        layoutInfo = isRow ? CodeMonitorLayout.computeRow(item, bounds: bounds, showsProfile: showsProfile)
            : CodeMonitorLayout.compute(item, size: size, bounds: bounds, showsProfile: showsProfile)
        syncSubviews()
        updateTrackingAreas()
        noteMarks()
        needsDisplay = true
    }

    /// The LED's pulse (a layer animation: no timer, no main-thread work) and the spinner of an operation in flight.
    private func syncSubviews() {
        pulse.frame = layoutInfo.led.insetBy(dx: -1, dy: -1)
        pulse.led = item.led
        pulse.setPulsing(item.led.pulses && !reduceMotion())
        if item.busy {
            let indicator = spinner ?? {
                let view = NSProgressIndicator()
                view.style = .spinning
                view.controlSize = .small
                view.isDisplayedWhenStopped = false
                view.appearance = NSAppearance(named: .darkAqua)
                addSubview(view)
                spinner = view
                return view
            }()
            indicator.frame = layoutInfo.spinner
            indicator.startAnimation(nil)
        } else if let spinner {
            spinner.stopAnimation(nil)
            spinner.removeFromSuperview()
            self.spinner = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let context = NSGraphicsContext.current?.cgContext
        if dimmed {
            context?.saveGState()
            context?.setAlpha(Self.draggedOpacity)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if isRow { drawRow() } else { drawMonitor() }
        drawMarks()
        if dimmed {
            context?.endTransparencyLayer()
            context?.restoreGState()
        }
    }

    // MARK: Hover and clicks

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // Enter/exit only: a tracking area that asks for mouse-moved can synthesize mouse-downs on macOS 26.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ value: Bool) {
        guard value != hovered else { return }
        hovered = value
        needsDisplay = true
        onHover?(self, value)
    }

    /// The part at `point` (the monitor's coordinates), nil outside the bezel (or the row).
    func target(at point: CGPoint) -> Target? {
        for (index, rect) in layoutInfo.marks.enumerated() where rect != .zero && item.marks.indices.contains(index) {
            if item.marks[index].id != nil, rect.insetBy(dx: -2, dy: -2).contains(point) { return .mark(index) }
        }
        if let offer = layoutInfo.offer, offer.contains(point) { return item.offer == nil && item.resultLine != nil ? .result : .offer }
        if let pip = layoutInfo.pip, pip.insetBy(dx: -4, dy: -4).contains(point) { return .offer }
        return layoutInfo.bezel.contains(point) ? .screen : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressed = target(at: point)
        pressedInside = pressed != nil
        downPoint = pressed == nil ? nil : point
        isDragging = false
        pressCancelled = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, !pressCancelled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if isDragging {
            onDrag?(self, .moved, event)
            return
        }
        if onDrag != nil, let start = downPoint, hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold {
            isDragging = true
            pressedInside = false
            needsDisplay = true
            onDrag?(self, .began, event)
            return
        }
        let inside = target(at: point) == pressed
        if inside != pressedInside { pressedInside = inside; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let target = pressed
        let wasDragging = isDragging
        let cancelled = pressCancelled
        let inside = target != nil && self.target(at: convert(event.locationInWindow, from: nil)) == target
        pressed = nil
        pressedInside = false
        downPoint = nil
        isDragging = false
        pressCancelled = false
        needsDisplay = true
        if wasDragging {
            if !cancelled { onDrag?(self, .ended, event) }
            return
        }
        guard inside, !cancelled, let target else { return }
        if case .mark(let index) = target, !markClickCounts(index) { return }
        if target == .result, !resultClickCounts() { return }
        onClick?(self, target)
    }

    /// The block ended the drag of the current press as a cancel (block hidden or folded, Escape): the rest of the
    /// press does nothing.
    func cancelPress() {
        guard pressed != nil else { return }
        pressCancelled = true
        isDragging = false
        pressedInside = false
        needsDisplay = true
    }

    var isPressedScreen: Bool { pressed == .screen && pressedInside }
    var isPressedOffer: Bool { pressed == .offer && pressedInside }
    var isPressedResult: Bool { pressed == .result && pressedInside }

    // MARK: Marks (arming)

    /// Notes when each opening mark appeared or moved, and whether the pointer was on it then.
    private func noteMarks() {
        let now = clock()
        var next: [String: (rect: CGRect, since: TimeInterval, underPointer: Bool)] = [:]
        // The result line opens something too: it is armed under its own key, like an opening mark.
        var opening: [(id: String, rect: CGRect)] = item.marks.enumerated().compactMap { index, mark in
            guard mark.opens, let id = mark.id, layoutInfo.marks.indices.contains(index) else { return nil }
            return (id, layoutInfo.marks[index])
        }
        if item.offer == nil, let line = item.resultLine, line.button.arms, let rect = layoutInfo.offer {
            opening.append((CodeMonitorResultLine.armingKey, rect))
        }
        let pointer = opening.isEmpty ? nil : pointerProbe()
        for (id, rect) in opening {
            if let known = markArming[id], known.rect == rect {
                next[id] = known
            } else {
                next[id] = (rect, now, pointer.map { rect.insetBy(dx: -2, dy: -2).contains($0) } ?? false)
            }
        }
        markArming = next
    }

    /// A click on the result line counts like one on an opening mark (a line whose button opens nothing acts at once).
    private func resultClickCounts() -> Bool {
        guard let line = item.resultLine else { return false }
        guard line.button.arms else { return true }
        guard let arming = markArming[CodeMonitorResultLine.armingKey] else { return false }
        if arming.underPointer {
            markArming[CodeMonitorResultLine.armingKey]?.underPointer = false
            return false
        }
        return clock() - arming.since >= CodeTuning.openButtonArmDelay
    }

    /// A click on an opening mark counts only `openButtonArmDelay` after it appeared or moved, and never the first
    /// press when it appeared under the pointer (that press is swallowed).
    private func markClickCounts(_ index: Int) -> Bool {
        guard item.marks.indices.contains(index) else { return false }
        let mark = item.marks[index]
        guard mark.opens, let id = mark.id else { return mark.id != nil }
        guard let arming = markArming[id] else { return false }
        if arming.underPointer {
            markArming[id]?.underPointer = false
            return false
        }
        return clock() - arming.since >= CodeTuning.openButtonArmDelay
    }

    // MARK: Accessibility (no session text: state and window words only)

    private func updateAccessibility() {
        var parts = ["Code monitor \(item.position) of \(item.total)", item.stateWord]
        if !item.chip.isEmpty { parts.append(item.chip) }
        if let offer = item.offer, offer.count > 0 { parts.append(offer.count == 1 ? "1 command offered" : "\(offer.count) commands offered") }
        parts += item.marks.map(\.label).filter { !$0.isEmpty }
        if let warning = item.warningLine { parts.append(warning.label) }
        setAccessibilityLabel(parts.joined(separator: ", "))
        setAccessibilityHelp(item.tooltip ?? Self.clickHelp(item.click))
        toolTip = item.tooltip
        var actions: [NSAccessibilityCustomAction] = []
        if item.offer?.count ?? 0 > 0 {
            actions.append(NSAccessibilityCustomAction(name: "Review commands") { [weak self] in
                guard let self else { return false }
                self.onClick?(self, .offer)
                return true
            })
        }
        for (index, mark) in item.marks.enumerated() where mark.id != nil && !mark.label.isEmpty {
            actions.append(NSAccessibilityCustomAction(name: mark.label) { [weak self] in
                guard let self else { return false }
                self.onClick?(self, .mark(index))
                return true
            })
        }
        if item.offer == nil, let line = item.resultLine {
            actions.append(NSAccessibilityCustomAction(name: line.label) { [weak self] in
                guard let self else { return false }
                self.onClick?(self, .result)
                return true
            })
        }
        setAccessibilityCustomActions(actions)
    }

    static func clickHelp(_ click: CodeWindowClick) -> String {
        switch click {
        case .park: return "Click to pit the window"
        case .restore: return "Click to go back on track"
        case .activate: return "Click to switch to its Space"
        case .openInMainWindow: return "Click to open the session in Claude's main window"
        case .none: return ""
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(self, .screen)
        return true
    }
}

/// The LED of a working session: drawn like the static one, and faded by a layer animation (1.6 s cycle), which
/// costs no main-thread time. Off-screen copies draw it steady.
final class CodeLEDView: NSView {
    var led = CodeMonitorLED(color: CodeMonitorPalette.working, form: .filled, pulses: true) { didSet { needsDisplay = true } }
    private(set) var isPulsing = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setPulsing(_ on: Bool) {
        guard on != isPulsing else { return }
        isPulsing = on
        isHidden = !on
        guard let layer else { return }
        if on {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0.25
            animation.duration = 0.8
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "pulse")
        } else {
            layer.removeAnimation(forKey: "pulse")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        CodeMonitorView.drawLED(led, in: bounds.insetBy(dx: 1, dy: 1))
    }
}
