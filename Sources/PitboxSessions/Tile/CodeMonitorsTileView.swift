import AppKit
import PitboxKit

/// A band another feature adds to the block (top to bottom the block is header, summary line, buckets, Ready list):
/// the summary line goes in `summaryAccessory` (fixed under the header), the Ready list in `readyAccessory` (in the
/// scrolling area, after the buckets). The block asks for the height at its width on every layout and places the
/// view; the view draws itself and may observe the model. Call `CodeMonitorsTileView.accessoriesChanged()` when the
/// height changes for another reason.
@MainActor
protocol CodeTileAccessory: NSView {
    /// The height the band needs at `width`; 0 hides it.
    func accessoryHeight(forWidth width: CGFloat) -> CGFloat
    /// The block moved the band to another place in its stack (a bucket above it grew or shrank; never a scroll).
    func movedInStack()
}

extension CodeTileAccessory {
    func movedInStack() {}
}

/// The block's root view (`PitboxBlock.makeView()`): a 24 pt header band ("4 in the pit · 2 on track · 1 needs you",
/// Hide text, Pit all done (n), + New bucket), banner lines, the summary slot, and a scrolling stack: the user's
/// buckets, Unsorted first, then the Ready slot, each bucket a header and a body of monitors on the panel's grid
/// columns. With Unsorted alone the block looks as it does without buckets (one body, no bucket header). The block
/// draws no card (`background: none`): each monitor is its own dark object. When the stack is taller than the block,
/// the area under the header scrolls (the wheel goes on to the enclosing view at the ends).
///
/// Peek: after `dwellDelay` (1.2 s) on a monitor, its panel opens inside the block, two grid columns wide from the
/// hovered column toward the side with room, at most 450 pt tall at the hovered monitor's row (inside the visible
/// part); it closes `closeDelay` (0.25 s) after the pointer left both the monitor and the panel, when the block hides
/// or folds (`dismissOverlays`), when the area scrolls, during a drag, and when the monitor goes.
///
/// Keyboard: never first responder; the one text input is a bucket's name field while the user renames it (it asks
/// for the keyboard and hands it back). Clicks act on mouse-up inside. Hover uses enter/exit tracking only.
///
/// Privacy: rendered for a snapshot, a PDF or any other off-screen copy, the whole block is one redaction card: "Code
/// monitors are not included in snapshots". VoiceOver labels hold no session text.
final class CodeMonitorsTileView: NSView {
    let model: CodeMonitorsModel
    /// The area under the header: clips the stack and the peek, and scrolls.
    let content = CodeMonitorsContentView(frame: .zero)
    /// Unsorted's body (the only one until the user makes a bucket).
    let folder = CodeMonitorFolderView(frame: .zero)
    /// The other buckets' bodies, by bucket id.
    var otherFolders: [String: CodeMonitorFolderView] = [:]
    /// Every bucket's header in bucket mode, by bucket id.
    var bucketHeaders: [String: CodeBucketHeaderView] = [:]
    /// Where the buckets are in the scrolling area, before scrolling (drop targets, the outline, reveal).
    private(set) var placedBuckets: [CodeBucketLayout.Placed] = []
    private(set) var stackHeight: CGFloat = 0
    /// The summary line, fixed under the header (and the banner lines).
    var summaryAccessory: CodeTileAccessory? {
        didSet {
            oldValue?.removeFromSuperview()
            if let summaryAccessory { addSubview(summaryAccessory) }
            layoutContent()
        }
    }
    /// The Ready list, in the scrolling area after the buckets.
    var readyAccessory: CodeTileAccessory? {
        didSet {
            oldValue?.removeFromSuperview()
            if let readyAccessory { content.addSubview(readyAccessory, positioned: .below, relativeTo: folder) }
            readyY = nil
            layoutContent()
        }
    }
    /// Where the Ready list starts in the stack, before scrolling (nil until laid out): when it changes, the list hears
    /// `movedInStack()`, so a button moved under a still pointer is not armed.
    private var readyY: CGFloat?
    private(set) var peekView: CodeMonitorPeekView?
    private(set) var peekFor: String?
    private(set) var snapshot = CodeMonitorsSnapshot()
    private(set) var hoveredMonitor: String?
    /// How far the area under the header is scrolled.
    private(set) var scrollOffset: CGFloat = 0
    var dwellWork: DispatchWorkItem?
    var closeWork: DispatchWorkItem?
    private var overlayGeneration = 0
    private var timer: Timer?
    private weak var observedWindow: NSWindow?
    private weak var observedClip: NSClipView?
    private(set) var reportedVisible = false
    // Header interaction (CodeMonitorsTileView+Header.swift).
    var pressedHeader: HeaderButton?
    var hoveredHeader: HeaderButton?
    // Buckets (Buckets/TileBuckets.swift): the name field, Delete's question, the reveal handled last.
    var renaming: (bucketID: String, isNew: Bool, field: CodeBucketNameField)?
    /// Undoes the rename's click monitor and keyboard observer.
    var renameCleanup: [() -> Void] = []
    var confirmingDelete: String?
    var handledReveal = 0
    // A drag between buckets (Buckets/MonitorDrag+Tile.swift).
    var drag: CodeMonitorDrag?
    var dragCard: CodeMonitorDragCard?
    var dragKeyMonitor: Any?
    let dropOutline = CodeBucketDropOutline(frame: .zero)
    /// A bucket outlined from outside the block (drag-to-park: a window dragged over a bucket).
    var externalDropTarget: String? { didSet { if externalDropTarget != oldValue { placeDropOutline() } } }

    static let headerHeight: CGFloat = 24
    static let bannerHeight: CGFloat = 18
    /// The peek's height at most.
    static let peekMaxHeight: CGFloat = 450
    static let dwellDelay: TimeInterval = 1.2
    static let closeDelay: TimeInterval = 0.25
    /// Relative ages ("in the pit 12 min") are redrawn this often while visible.
    static let redrawInterval: TimeInterval = 30

    /// Tests: lets an off-screen render show the monitors. Production never sets it.
    var testsRenderUnredacted = false
    /// Tests: replaces the visibility rule.
    var visibilityProbe: (NSView) -> Bool = CodeMonitorsTileView.isEffectivelyVisible
    /// Tests: where the pointer is, in this view's coordinates (nil: unknown). Production reads the window.
    var pointerProbe: (() -> CGPoint?)?
    /// Tests and `PitboxBlock`: the strip width (nil: the window's width, which is the panel's in production).
    var stripWidthProbe: (() -> CGFloat?)?
    /// The side of the header's fold "−" (the block's window side; nil: no button). Set by `PitboxBlock.makeView()`.
    var foldButtonSide: (() -> Edge?)?
    /// The fold "−" was pressed (or chosen with VoiceOver).
    var onFold: (() -> Void)?
    /// Runs `work` on the main queue after `seconds` (tests replace it to see the delays and run the work themselves).
    var delay: (TimeInterval, @escaping @MainActor () -> Void) -> DispatchWorkItem = { seconds, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
    /// The anchor handed to the sheet: a monitor's frame in screen coordinates (tests replace it).
    var screenFrame: (NSView) -> CGRect = { view in
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
    /// Shows a bucket's colour menu at a point of a view (tests replace it: `NSMenu.popUp` runs its own loop).
    var menuPresenter: (NSMenu, NSView, CGPoint) -> Void = { menu, view, point in
        menu.popUp(positioning: nil, at: point, in: view)
    }

    init(model: CodeMonitorsModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 992, height: 474))
        wantsLayer = true
        addSubview(content)
        content.addSubview(folder)
        content.onScroll = { [weak self] event in self?.scroll(with: event) ?? false }
        wire(folder, bucketID: CodeBucket.unsortedID)
        dropOutline.isHidden = true
        content.addSubview(dropOutline)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Code monitors")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Data and layout

    /// Takes the model's snapshot. A peek follows its monitor, or closes when the monitor went away, when the model
    /// closed every overlay (block hidden or folded); the same ends a drag (as a cancel), a rename (the
    /// typed name is kept) and Delete's question.
    func refresh() {
        snapshot = model.snapshot
        if model.overlayGeneration != overlayGeneration {
            overlayGeneration = model.overlayGeneration
            closePeek()
            endTransientBucketUI()
        }
        if let drag, !snapshot.monitors.contains(where: { $0.id == drag.sessionID }) { cancelDrag() }
        if let renaming, !snapshot.sections.contains(where: { $0.id == renaming.bucketID }) || !snapshot.bucketMode {
            finishRename(commit: false)
        }
        if let id = confirmingDelete, !snapshot.sections.contains(where: { $0.id == id }) { confirmingDelete = nil }
        layoutContent()
        if let id = peekFor {
            if let item = snapshot.monitors.first(where: { $0.id == id }), monitorView(id) != nil {
                peekView?.update(item: item)
            } else {
                closePeek()
            }
        }
        if let request = model.revealRequest, request.serial != handledReveal {
            handledReveal = request.serial
            reveal(sessionID: request.sessionID)
        }
        needsDisplay = true
    }

    /// The banner lines under the header: the source's (session files changed) and the buckets file's note.
    var bannerLines: [String] { [snapshot.banner, snapshot.bucketNote, snapshot.hint].compactMap { $0 } }

    /// The area under the header, the banner lines and the summary line.
    var contentFrame: CGRect {
        var top = Self.headerHeight + CGFloat(bannerLines.count) * Self.bannerHeight
        if let summary = summaryAccessory, !summary.isHidden { top += summary.frame.height }
        return CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }

    /// The grid's column width for this block.
    var stripColumn: CGFloat {
        CodeMonitorGrid.stripColumn(tileWidth: bounds.width, stripWidth: stripWidthProbe?() ?? window?.frame.width)
    }

    var maxScrollOffset: CGFloat { max(0, stackHeight - content.bounds.height) }

    /// Every bucket's body, Unsorted's first.
    var allFolders: [(id: String, view: CodeMonitorFolderView)] {
        [(CodeBucket.unsortedID, folder)] + snapshot.sections.compactMap { section in otherFolders[section.id].map { (section.id, $0) } }
    }

    /// The monitor view of a session on its bucket's current page.
    func monitorView(_ id: String) -> CodeMonitorView? {
        for (_, body) in allFolders { if let view = body.monitorView(id) { return view } }
        return nil
    }

    /// Every monitor view shown.
    var allMonitorViews: [CodeMonitorView] { allFolders.flatMap { Array($0.view.monitorViews.values) } }

    func layoutContent() {
        let width = bounds.width
        var top = Self.headerHeight + CGFloat(bannerLines.count) * Self.bannerHeight
        if let summary = summaryAccessory {
            let height = max(0, summary.accessoryHeight(forWidth: width))
            summary.frame = CGRect(x: 0, y: top, width: width, height: height)
            summary.isHidden = height == 0
            top += height
        }
        content.frame = CGRect(x: 0, y: top, width: width, height: max(0, bounds.height - top))
        let inner = content.bounds.width
        let flat = !snapshot.bucketMode
        let readyHeight = readyAccessory.map { max(0, $0.accessoryHeight(forWidth: inner)) } ?? 0
        content.isHidden = flat && snapshot.monitors.isEmpty && readyHeight == 0
        let column = stripColumn
        let rows = snapshot.look == .rows
        let sections = flat ? Array(snapshot.sections.prefix(1)) : snapshot.sections
        let specs = sections.map { section in
            (id: section.id, folded: !flat && section.bucket.folded,
             bodyHeight: CodeMonitorFolderView.naturalHeight(count: section.monitors.count, width: inner, stripColumn: column,
                                                             rows: rows, emptyHint: !flat))
        }
        let stack = CodeBucketLayout.stack(width: inner, readyHeight: readyHeight, flat: flat, buckets: specs)
        (placedBuckets, stackHeight) = (stack.placed, stack.height)
        scrollOffset = min(max(0, scrollOffset), maxScrollOffset)
        if let readyAccessory {
            readyAccessory.frame = CGRect(x: 0, y: stack.readyY - scrollOffset, width: inner, height: readyHeight)
            readyAccessory.isHidden = readyHeight == 0
            let moved = readyY.map { $0 != stack.readyY } ?? false
            readyY = stack.readyY
            if moved { readyAccessory.movedInStack() }
        }
        layoutBuckets(sections, flat: flat, column: column)
        placeDropOutline()
        content.scrollFraction = maxScrollOffset > 0
            ? (scrollOffset / maxScrollOffset, content.bounds.height / max(stackHeight, 1)) : nil
        if let peekView, let frame = peekFrame(for: peekFor) { peekView.frame = frame }
        updateGlowSuppression()
        updateTrackingAreas()
    }

    /// The scrolling area's coordinates of a point in the stack (before scrolling).
    func scrolledStackFrame(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 0, dy: -scrollOffset) }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        closePeek()
        layoutContent()
        refreshVisibility()
    }

    /// Lays the block out again (an accessory's height changed).
    func accessoriesChanged() {
        layoutContent()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        for (_, body) in allFolders { body.needsDisplay = true }
        for header in bucketHeaders.values { header.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHeader()
        drawBanner()
        if !snapshot.bucketMode, snapshot.monitors.isEmpty { drawEmpty() }
    }

    // MARK: Scrolling (only when the stack is taller than the block; the enclosing view gets the wheel at the ends)

    /// Returns true when the wheel moved the area.
    private func scroll(with event: NSEvent) -> Bool {
        guard maxScrollOffset > 0, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return false }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let next = min(max(0, scrollOffset - delta), maxScrollOffset)
        guard next != scrollOffset else { return false }
        scroll(to: next)
        return true
    }

    func scroll(to offset: CGFloat) {
        closePeek()
        scrollOffset = min(max(0, offset), maxScrollOffset)
        layoutContent()
        if snapshot.emptyTitle != nil { needsDisplay = true }   // the empty text keeps to the area above the moving list
    }

    // MARK: Monitors

    /// Wires one bucket's body: clicks, hovers, pages and (in bucket mode) drags.
    func wire(_ body: CodeMonitorFolderView, bucketID: String) {
        body.onMonitorClick = { [weak self] view, target in self?.monitorClicked(view, target) }
        body.onMonitorHover = { [weak self] view, inside in self?.monitorHovered(view, inside: inside) }
        body.onPageChange = { [weak self, weak body] in
            guard let self, let body else { return }
            self.model.setPage(body.page, of: bucketID)
            self.closePeek()
            self.layoutContent()
        }
    }

    private func monitorClicked(_ view: CodeMonitorView, _ target: CodeMonitorView.Target) {
        let item = view.item
        switch target {
        case .screen:
            model.clickScreen(item.id)
        case .offer:
            guard let action = view.offerAction else { return model.clickScreen(item.id) }
            switch action {
            case .openSheet(let id): model.openSheet(id, sessionID: item.id, anchor: screenFrame(view))
            case .openPeek: openPeek(item.id)
            case .revealRun(let runID): model.revealRun(runID)
            case .none: break
            }
        case .mark(let index):
            guard item.marks.indices.contains(index), let markID = item.marks[index].id else { return }
            model.onMarkClick?(item.id, markID)
        case .result:
            guard let line = item.resultLine else { return }
            model.clickResult(line.button, sessionID: item.id, anchor: screenFrame(view))
        }
    }

    private func monitorHovered(_ view: CodeMonitorView, inside: Bool) {
        let id = view.item.id
        if inside {
            // No peek during a drag; a monitor under the open panel does not start a peek of its own.
            guard drag == nil else { return }
            if let peekView, peekFor != id, peekView.frame.intersects(content.convert(view.bounds, from: view)) { return }
            hoveredMonitor = id
            closeWork?.cancel()
            closeWork = nil
            guard peekFor != id else { return }
            dwellWork?.cancel()
            dwellWork = delay(Self.dwellDelay) { [weak self] in self?.dwellElapsed(on: id) }
        } else {
            if hoveredMonitor == id {
                hoveredMonitor = nil
                dwellWork?.cancel()
                dwellWork = nil
            }
            if peekFor != nil { scheduleClose() }
        }
    }

    /// The pointer rested `dwellDelay` on monitor `id`.
    func dwellElapsed(on id: String) {
        dwellWork = nil
        guard hoveredMonitor == id, drag == nil, reportedVisible || pointerProbe != nil else { return }
        openPeek(id)
    }

    func openPeek(_ id: String) {
        guard drag == nil, let item = snapshot.monitors.first(where: { $0.id == id }), let frame = peekFrame(for: id) else { return }
        closeWork?.cancel()
        closeWork = nil
        if let peekView, peekFor == id { peekView.update(item: item); return }
        peekView?.removeFromSuperview()
        let panel = CodeMonitorPeekView(item: item, frame: frame)
        panel.onAction = { [weak self] action in self?.peekAction(action) }
        panel.onHover = { [weak self] inside in
            guard let self else { return }
            if inside { closeWork?.cancel(); closeWork = nil } else { scheduleClose() }
        }
        content.addSubview(panel, positioned: .above, relativeTo: nil)
        peekView = panel
        peekFor = id
        updateGlowSuppression()
        model.ready?.markSeen(id)   // the peek is looking (the unread dot goes)
        CodeTileLog.info("peek opened session=#\(item.index)")
        updateTrackingAreas()
    }

    func closePeek() {
        dwellWork?.cancel()
        dwellWork = nil
        closeWork?.cancel()
        closeWork = nil
        guard let peekView else { return }
        peekView.removeFromSuperview()
        self.peekView = nil
        peekFor = nil
        updateGlowSuppression()
    }

    private func scheduleClose() {
        closeWork?.cancel()
        closeWork = delay(Self.closeDelay) { [weak self] in self?.closeElapsed() }
    }

    /// `closeDelay` after the pointer left: closes unless the pointer is back on the panel or its monitor.
    func closeElapsed() {
        closeWork = nil
        guard let peekView, let id = peekFor else { return }
        if let point = pointerLocation() {
            let panel = convert(peekView.bounds, from: peekView)
            let monitor = monitorView(id).map { convert($0.bounds, from: $0) } ?? .null
            if panel.contains(point) || monitor.contains(point) { return }
        }
        closePeek()
    }

    /// In the content area's coordinates: two grid columns wide (or the whole block when narrower), from the hovered
    /// monitor's column toward the side with room; at most 450 pt tall, at the hovered monitor's row, inside the visible
    /// part.
    func peekFrame(for id: String?) -> CGRect? {
        guard let id, let view = monitorView(id) else { return nil }
        let monitor = content.convert(view.bounds, from: view)
        let area = content.bounds
        let width = min((2 * stripColumn + CodeMonitorGrid.gap).rounded(.down), area.width)
        var x = monitor.minX
        if x + width > area.maxX { x = monitor.maxX - width }
        x = min(max(area.minX, x), area.maxX - width)
        let height = min(Self.peekMaxHeight, area.height)
        let y = min(max(area.minY, monitor.minY), area.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height)
    }

    /// Monitors under the open panel draw no glow (it would bleed out around the panel).
    private func updateGlowSuppression() {
        let panel = peekView?.frame
        for view in allMonitorViews {
            let frame = content.convert(view.bounds, from: view)
            view.suppressGlow = panel.map { $0.insetBy(dx: -16, dy: -16).intersects(frame) } ?? false
        }
    }

    private func peekAction(_ action: CodeMonitorPeekView.Action) {
        guard let id = peekFor else { return }
        switch action {
        case .review(let offerID):
            let anchor = monitorView(id).map(screenFrame) ?? peekView.map(screenFrame) ?? .zero
            model.openSheet(offerID, sessionID: id, anchor: anchor)
        case .copy(let offerID):
            model.copyOffer(offerID, sessionID: id)
        case .window(let click):
            model.perform(click, id)
            closePeek()
        case .copyLink:
            model.copyLink(sessionID: id)
        case .result(let button):
            model.clickResult(button, sessionID: id, anchor: peekView.map(screenFrame) ?? .zero)
        }
    }

    func pointerLocation() -> CGPoint? {
        if let pointerProbe { return pointerProbe() }
        guard let window, window.isVisible else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    // MARK: Header clicks and hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        removeAllToolTips()
        for (index, button) in headerButtons().enumerated() {
            addTrackingArea(NSTrackingArea(rect: button.rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self,
                                           userInfo: ["header": index]))
            if headerToolTip(button) != nil { addToolTip(button.rect, owner: self, userData: nil) }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?["header"] as? Int else { return }
        let buttons = headerButtons()
        guard buttons.indices.contains(index) else { return }
        hoveredHeader = buttons[index].kind
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["header"] != nil else { return }
        hoveredHeader = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedHeader = headerButton(at: point).flatMap { $0.enabled ? $0.kind : nil }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = pressedHeader
        pressedHeader = nil
        needsDisplay = true
        guard let pressed, let button = headerButton(at: convert(event.locationInWindow, from: nil)), button.kind == pressed,
              button.enabled else { return }
        activateHeader(pressed)
    }

    // MARK: Window, timer and visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        observeWindow()
        observeClipView()
        guard window != nil else {
            closePeek()
            endTransientBucketUI()
            refreshVisibility()
            model.stopObserving(self)
            return
        }
        model.observe(self) { [weak self] in self?.refresh() }
        let timer = Timer(timeInterval: Self.redrawInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.tick()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
        refreshVisibility()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeClipView()
        refreshVisibility()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshVisibility()
    }

    /// Every `redrawInterval` while in a window: re-check visibility and, when visible, redraw the relative ages.
    private func tick() {
        refreshVisibility()
        if reportedVisible { model.rebuild() }
    }

    func refreshVisibility() {
        let visible = window != nil && visibilityProbe(self)
        guard visible != reportedVisible else { return }
        reportedVisible = visible
        model.setViewVisible(visible, owner: self)
        if !visible {
            closePeek()
            cancelDrag()
        }
    }

    /// On screen, not occluded, not hidden, not scrolled out of an enclosing scroll view.
    static func isEffectivelyVisible(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else { return false }
        guard window.occlusionState.contains(.visible) else { return false }
        return !view.visibleRect.isEmpty
    }

    private func observeWindow() {
        guard observedWindow !== window else { return }
        let center = NotificationCenter.default
        if let old = observedWindow {
            center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: old)
            center.removeObserver(self, name: NSWindow.willCloseNotification, object: old)
        }
        observedWindow = window
        guard let window else { return }
        center.addObserver(self, selector: #selector(windowStateChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification,
                           object: window)
        center.addObserver(self, selector: #selector(windowStateChanged(_:)), name: NSWindow.willCloseNotification, object: window)
    }

    private func observeClipView() {
        let clip = enclosingScrollView?.contentView
        guard clip !== observedClip else { return }
        if let old = observedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
        }
        observedClip = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(stripScrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func windowStateChanged(_ note: Notification) { refreshVisibility() }

    /// An enclosing scroll view scrolled: the panel would no longer sit on its monitor.
    @objc private func stripScrolled(_ note: Notification) {
        closePeek()
        refreshVisibility()
    }

    // MARK: Snapshots and other off-screen copies: one redaction card

    override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {
        let cover = redactionCover()
        if let cover { addSubview(cover, positioned: .above, relativeTo: nil) }
        super.cacheDisplay(in: rect, to: bitmapImageRep)
        cover?.removeFromSuperview()
    }

    override func displayIgnoringOpacity(_ rect: NSRect, in context: NSGraphicsContext) {
        let cover = redactionCover()
        if let cover { addSubview(cover, positioned: .above, relativeTo: nil) }
        super.displayIgnoringOpacity(rect, in: context)
        cover?.removeFromSuperview()
    }

    override func dataWithPDF(inside rect: NSRect) -> Data {
        let cover = redactionCover()
        if let cover { addSubview(cover, positioned: .above, relativeTo: nil) }
        let data = super.dataWithPDF(inside: rect)
        cover?.removeFromSuperview()
        return data
    }

    override func dataWithEPS(inside rect: NSRect) -> Data {
        let cover = redactionCover()
        if let cover { addSubview(cover, positioned: .above, relativeTo: nil) }
        let data = super.dataWithEPS(inside: rect)
        cover?.removeFromSuperview()
        return data
    }

    private func redactionCover() -> NSView? {
        guard !testsRenderUnredacted else { return nil }
        return CodeRedactionView(frame: bounds, dark: ThemeColor.isDark(effectiveAppearance))
    }

    // MARK: Accessibility (no session text)

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = headerButtons().map { button in
            let element = CodeAccessibilityButton(label: accessibilityLabel(for: button.kind)) { [weak self] in
                self?.activateHeader(button.kind)
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(button.rect)
            element.setAccessibilityEnabled(button.enabled)
            return element
        }
        if let summaryAccessory, !summaryAccessory.isHidden { children.append(summaryAccessory) }
        if !content.isHidden {
            for placed in placedBuckets {
                if placed.header != nil, let header = bucketHeaders[placed.id] { children.append(header) }
                if placed.body != nil, let body = placed.id == CodeBucket.unsortedID ? folder : otherFolders[placed.id] {
                    children.append(body)
                }
            }
            if let readyAccessory, !readyAccessory.isHidden { children.append(readyAccessory) }
        }
        if let peekView { children.append(peekView) }
        return children
    }
}

/// The area under the block's header: it clips the stack and the peek, takes the wheel when the stack is taller than
/// the block (handing it to the enclosing view at the ends), and draws a thin scroll indicator.
final class CodeMonitorsContentView: NSView {
    /// Returns true when the wheel was used.
    var onScroll: ((NSEvent) -> Bool)?
    /// The thumb's position (0...1) and its share of the track, nil when nothing scrolls.
    var scrollFraction: (position: CGFloat, share: CGFloat)? { didSet { placeIndicator() } }
    private let indicator = CodeScrollIndicatorView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        addSubview(indicator)
        placeIndicator()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        if onScroll?(event) == true { return }
        super.scrollWheel(with: event)
    }

    /// The indicator stays above the stack and the peek.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview !== indicator { addSubview(indicator, positioned: .above, relativeTo: nil) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeIndicator()
    }

    private func placeIndicator() {
        guard let scroll = scrollFraction else {
            indicator.isHidden = true
            return
        }
        let height = max(24, bounds.height * min(1, scroll.share))
        let y = (bounds.height - height) * min(max(scroll.position, 0), 1)
        indicator.frame = CGRect(x: bounds.maxX - 4, y: y, width: 3, height: height)
        indicator.isHidden = false
    }
}

/// The scroll indicator's thumb (never takes clicks).
final class CodeScrollIndicatorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dark = ThemeColor.isDark(effectiveAppearance)
        (dark ? NSColor.white.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.3)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill()
    }
}

/// The card a snapshot of the block shows instead of the monitors: opaque, with a short notice.
final class CodeRedactionView: NSView {
    private let dark: Bool
    static let text = "Code monitors are not included in snapshots"

    init(frame: NSRect, dark: Bool) {
        self.dark = dark
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opaque edge to edge: nothing of a monitor shows anywhere, corners included.
    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        (dark ? CodeMonitorPalette.color(0x1B1E25) : CodeMonitorPalette.color(0xF4F2FB)).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: dark ? CodeMonitorPalette.color(0xC9C4DA) : CodeMonitorPalette.color(0x4A4560),
        ]
        let size = (Self.text as NSString).size(withAttributes: attributes)
        (Self.text as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                     withAttributes: attributes)
    }
}
