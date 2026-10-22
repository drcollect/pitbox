import AppKit

/// An accessibility element that presses through a closure (tabs and buttons of the strip).
private final class StripAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}

extension TabStatus {
    /// The bell comes first; a failure beats "new output" (a program that fails in a background tab nearly always prints
    /// something first, and the red dot must still show); a clean end, then a running program, come last.
    init(_ item: TabStripView.Item) {
        if item.needsAttention { self = .attention }
        else if item.hasExited, item.exitFailed { self = .failed }
        else if item.hasActivity { self = .activity }
        else if item.hasExited { self = .exited }
        else if item.isBusy { self = .running }
        else { self = .none }
    }
}

/// The tab strip at the top of the console: one clearly outlined tab per session (its number, its title from the
/// running program or folder, a dot for what it is doing), a close button on the selected and the hovered tab, a "+" button
/// with a presets chevron (only where the console has plain shells: `showsNewTabControls`), and an indicator when
/// auto-rotate is on.
///
/// The selected tab is unmistakable (strong fill, accent outline, accent number badge, accent underline, bold title).
/// When the tabs do not fit they compress (a narrow tab shows only its number) and, beyond that, the strip scrolls sideways
/// with the wheel or trackpad and keeps the selected tab in view.
///
/// Custom-drawn (no subviews): it stays cheap with many tabs and idle. It takes clicks without becoming key, so using
/// it never steals keyboard focus from the app the user is typing in. A tab selects and the chevron opens its menu on
/// mouse-down (as in macOS tab bars and pop-up buttons); close, "+" and the auto-rotate indicator are buttons: they look
/// pressed while the mouse button is down and act on mouse-up over themselves, so a press dragged off them is cancelled.
@MainActor
final class TabStripView: NSView, NSViewToolTipOwner {
    struct Item: Equatable {
        var id: UUID
        var title: String
        var isSelected: Bool
        /// Output arrived while the tab was in the background.
        var hasActivity: Bool
        /// The bell rang while the tab was in the background.
        var needsAttention: Bool
        var hasExited: Bool
        /// The close button was clicked once on a busy tab: the next click closes it.
        var confirmingClose: Bool
        var tooltip: String
        /// A program (not an idle shell) runs in the tab.
        var isBusy = false
        /// The process ended with an error (a non-zero status, a signal, or it could not start).
        var exitFailed = false
    }

    enum Hit: Equatable {
        case tab(UUID)
        case close(UUID)
        case newSession
        case presetMenu
        case autoRotate
    }

    /// `NSAccessibilityTabButtonSubrole` ("AXTabButton"): what the radio buttons of a macOS tab group carry.
    static let tabButtonSubrole = NSAccessibility.Subrole(rawValue: "AXTabButton")
    static let height: CGFloat = 34
    static let pillHeight: CGFloat = 26
    static let pillTop: CGFloat = 4
    static let cornerRadius: CGFloat = 8
    static let titleSize: CGFloat = 13
    private static let plusWidth: CGFloat = 32
    private static let chevronWidth: CGFloat = 22
    private static let controlGap: CGFloat = 8
    private static let closeSize: CGFloat = 18
    private static let fadeWidth: CGFloat = 18
    /// The auto-rotate indicator: as tall as the tabs and the "+" button, so the controls line up.
    private static let rotateWidth: CGFloat = 26

    /// Tooltip tags of the buttons; a tab's tag is its index plus one.
    private enum ToolTipTag {
        static let newTab = 100_001
        static let presets = 100_002
        static let rotate = 100_003
    }

    var items: [Item] = [] {
        didSet {
            guard items != oldValue else { return }
            relayoutTabs()
            needsDisplay = true
        }
    }
    /// Auto-rotation is on: a small indicator (click to turn off) is shown.
    var autoRotateOn = false { didSet { if autoRotateOn != oldValue { relayoutTabs(); needsDisplay = true } } }
    var canCreate = true { didSet { if canCreate != oldValue { rebuildAccessibility(); needsDisplay = true } } }
    /// "+" and the presets chevron. Off in Pitbox's console, which has no plain shells: then neither is drawn, hit,
    /// hovered, described to VoiceOver or given a tooltip, and the tabs take the room.
    var showsNewTabControls = true {
        didSet { if showsNewTabControls != oldValue { relayoutTabs(); needsDisplay = true } }
    }
    /// Where the pointer is now, in the strip's coordinates (nil: unknown). Asked when tabs appear, go away or move under a
    /// pointer that did not move, which produces no enter event: without it, after closing the hovered tab the tab that
    /// slid under the pointer would show neither its hover nor its close button, and a second click there would select it
    /// instead of closing it. Tests replace it.
    var pointerLocation: (() -> CGPoint?)?
    /// The console's corner radius (set by the console view, 0 to 48): the tabs and buttons keep clear of it.
    var consoleCornerRadius: CGFloat = 18 { didSet { if consoleCornerRadius != oldValue { relayoutTabs(); needsDisplay = true } } }
    /// The terminal's palette, which the strip's colors come from. Set by the console view.
    var palette: TerminalPalette = TerminalTheme.dark {
        didSet {
            guard palette != oldValue else { return }
            style = TabStripStyle(palette: palette)
            needsDisplay = true
        }
    }
    private(set) var style = TabStripStyle(palette: TerminalTheme.dark)

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNew: (() -> Void)?
    var onToggleAutoRotate: (() -> Void)?
    /// The menu for the chevron (presets and options), built when it opens.
    var presetMenuProvider: (() -> NSMenu)?
    /// The menu for a right-click on a tab.
    var tabMenuProvider: ((UUID) -> NSMenu)?

    /// The tabs' frames in the strip's coordinates (scrolled; a tab can be partly or wholly outside `viewport`).
    private(set) var tabFrames: [(id: UUID, frame: CGRect)] = []
    private(set) var newFrame = CGRect.zero
    private(set) var menuFrame = CGRect.zero
    private(set) var rotateFrame = CGRect.zero
    /// Where the tabs are visible: between the left margin and the controls.
    private(set) var viewport = CGRect.zero
    /// How far the tabs are scrolled to the left (0 when they all fit).
    private(set) var scrollOffset: CGFloat = 0
    private(set) var contentWidth: CGFloat = 0
    private(set) var hoverID: UUID?
    private(set) var hoverCloseID: UUID?
    private(set) var hoverButton: Hit?
    /// The button (a close button, "+" or the auto-rotate indicator) the left mouse button went down on; nil when no
    /// press is in progress. It acts when the mouse button comes up over it.
    private(set) var pressedTarget: Hit?
    /// The pointer is over `pressedTarget`: it looks pressed, and letting go acts.
    private(set) var pressedInside = false
    /// Posts a VoiceOver notification. Tests replace it to see what is posted.
    var postAccessibilityNotification: @MainActor (Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]?) -> Void = {
        NSAccessibility.post(element: $0, notification: $1, userInfo: $2)
    }
    private var contentFrames: [CGRect] = []
    private var itemTrackingAreas: [NSTrackingArea] = []
    private var accessibilityElements: [StripAccessibilityElement] = []
    private var tabAccessibilityElements: [UUID: StripAccessibilityElement] = [:]
    private var buttonAccessibilityElements: [String: StripAccessibilityElement] = [:]
    private var revealedSelection: UUID?
    private var revealedViewportWidth: CGFloat = -1
    /// Where the selected tab was (content coordinates) when it was last brought into view: when closing a tab before it
    /// moves it, it is brought into view again.
    private var revealedFrame: CGRect?
    /// The tabs and controls of the last layout, to notice when they moved under a still pointer.
    private var laidOutIDs: [UUID] = []
    private var laidOutRotate = false
    private var fadeMaskCache: (key: String, image: CGImage)?
    /// What the first click of the current click sequence hit (see `clickTarget`).
    private var firstClickHit: Hit?
    /// The tab the first click of the current click sequence selected (see `clickTarget`).
    private var tabSelectedByFirstClick: UUID?
    /// The tab whose close button the first click of the current click sequence hit (see `clickTarget`).
    private var closeRequestedByFirstClick: UUID?
    /// The tab frames of the last layout, to notice tabs that moved under a still pointer.
    private var laidOutFrames: [CGRect] = []
    /// The selection and the tabs VoiceOver was last told about.
    private var announcedSelection: UUID?
    private var announcedIDs: [UUID] = []

    /// The tabs do not fit and the strip scrolls.
    var isOverflowing: Bool { contentWidth > viewport.width + 0.5 }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // An element of its own (a plain NSView is not, and its role and label would be ignored): VoiceOver hears a tab
        // group named "Terminal tabs" holding the tabs and the buttons.
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Terminal tabs")
        pointerLocation = { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return nil }
            return self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    override func layout() {
        super.layout()
        relayoutTabs()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// How far the tabs and the buttons stay from the sides of the strip: 8 pt, or more when the console's corners are so round
    /// that they would cut into the first tab and the chevron (they sit only `pillTop` below the console's top edge).
    static func sideInset(consoleCornerRadius radius: CGFloat) -> CGFloat {
        let r = cornerRadius, standard: CGFloat = 8
        guard radius > pillTop + r else { return standard }
        // A pill's corner (centre (s + r, pillTop + r), radius r) inside the console's corner (centre (R, R), radius R), plus
        // 2 pt because a continuous corner starts curving earlier than a circular one.
        let dy = radius - pillTop - r
        let s = radius - r - ((radius - r) * (radius - r) - dy * dy).squareRoot() + 2
        return max(standard, s.rounded(.up))
    }

    private func relayoutTabs() {
        let inset = Self.sideInset(consoleCornerRadius: consoleCornerRadius)
        let right = (bounds.width - inset).rounded(.down)
        var limit: CGFloat
        if showsNewTabControls {
            menuFrame = CGRect(x: right - Self.chevronWidth, y: Self.pillTop, width: Self.chevronWidth, height: Self.pillHeight)
            newFrame = CGRect(x: menuFrame.minX - Self.plusWidth, y: Self.pillTop, width: Self.plusWidth, height: Self.pillHeight)
            limit = newFrame.minX - Self.controlGap
        } else {
            menuFrame = .zero
            newFrame = .zero
            limit = right
        }
        if autoRotateOn {
            rotateFrame = CGRect(x: limit - Self.rotateWidth, y: Self.pillTop, width: Self.rotateWidth, height: Self.pillHeight)
            limit = rotateFrame.minX - 6
        } else {
            rotateFrame = .zero
        }
        viewport = CGRect(x: inset, y: 0, width: max(0, limit - inset), height: bounds.height)

        let selectedIndex = items.firstIndex { $0.isSelected }
        let widths = TabLayout.widths(count: items.count, selectedIndex: selectedIndex, available: viewport.width)
        contentWidth = TabLayout.contentWidth(of: widths)
        var cursor: CGFloat = 0
        contentFrames = widths.map { width in
            defer { cursor += width + TabLayout.spacing }
            return CGRect(x: cursor, y: Self.pillTop, width: width, height: Self.pillHeight)
        }
        // Bring the selected tab into view when it changed, the room changed or the tab itself moved (a tab before it
        // closed), but leave a scroll the user did alone: title refreshes move nothing.
        let selectedID = selectedIndex.map { items[$0].id }
        let selectedFrame = selectedIndex.map { contentFrames[$0] }
        if let selectedIndex, let selectedFrame,
           selectedID != revealedSelection || abs(viewport.width - revealedViewportWidth) > 0.5 || selectedFrame != revealedFrame {
            scrollOffset = TabLayout.offset(revealing: contentFrames[selectedIndex], current: scrollOffset,
                                            content: contentWidth, viewport: viewport.width)
        }
        revealedSelection = selectedID
        revealedViewportWidth = viewport.width
        revealedFrame = selectedFrame
        if let id = hoverID, !items.contains(where: { $0.id == id }) { hoverID = nil }
        if let id = hoverCloseID, !items.contains(where: { $0.id == id }) { hoverCloseID = nil }
        positionTabs()
        // Tabs came, went, were resized (a crowded strip widens the selected tab) or the controls moved: what is under a
        // pointer that did not move changed without an enter event.
        let ids = items.map(\.id)
        let frames = tabFrames.map(\.frame)
        if ids != laidOutIDs || frames != laidOutFrames || autoRotateOn != laidOutRotate, let point = pointerLocation?() {
            if bounds.contains(point) { refreshHover(at: point) } else { setHover(id: nil, button: nil) }
        }
        laidOutIDs = ids
        laidOutFrames = frames
        laidOutRotate = autoRotateOn
    }

    /// Places the tabs for the current scroll offset and rebuilds what depends on their frames.
    private func positionTabs() {
        scrollOffset = TabLayout.clampedOffset(scrollOffset, content: contentWidth, viewport: viewport.width)
        tabFrames = zip(items, contentFrames).map { item, frame in
            (item.id, frame.offsetBy(dx: (viewport.minX - scrollOffset).rounded(), dy: 0))
        }
        removeAllToolTips()
        for (index, entry) in tabFrames.enumerated() {
            let visible = entry.frame.intersection(viewport)
            if !visible.isNull, visible.width > 0 { addToolTip(visible, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1)) }
        }
        if showsNewTabControls {
            addToolTip(newFrame, owner: self, userData: UnsafeMutableRawPointer(bitPattern: ToolTipTag.newTab))
            addToolTip(menuFrame, owner: self, userData: UnsafeMutableRawPointer(bitPattern: ToolTipTag.presets))
        }
        if autoRotateOn { addToolTip(rotateFrame, owner: self, userData: UnsafeMutableRawPointer(bitPattern: ToolTipTag.rotate)) }
        rebuildTrackingAreas()
        rebuildAccessibility()
    }

    /// Scrolls the tabs sideways by `delta` points (positive: towards the later tabs). Clamped to the content.
    func scroll(by delta: CGFloat) {
        let target = TabLayout.clampedOffset(scrollOffset + delta, content: contentWidth, viewport: viewport.width)
        guard abs(target - scrollOffset) > 0.01 else { return }
        scrollOffset = target
        positionTabs()
        needsDisplay = true
    }

    /// Each tab is a radio button (tab subrole, selected or not) that selects on press and has a "Close Tab" action (the
    /// close button itself is not an element), followed by "New Tab" and "Presets" buttons and, while auto-rotate is on,
    /// its indicator; the buttons carry their tooltips as help. Every element says it is enabled: `NSAccessibilityElement`
    /// defaults to disabled, which VoiceOver reads as "dimmed".
    ///
    /// The elements are kept per tab and per button and only updated: this runs on every title refresh and every scroll
    /// step, and a new object each time would pull the VoiceOver cursor off the tab it is on. VoiceOver is told when the
    /// selection changes (by a click, a shortcut or auto-rotate) and when tabs come or go; nothing is posted otherwise.
    private func rebuildAccessibility() {
        var elements: [StripAccessibilityElement] = []
        var kept: [UUID: StripAccessibilityElement] = [:]
        for (index, entry) in tabFrames.enumerated() where index < items.count {
            let item = items[index]
            let id = entry.id
            let element = tabAccessibilityElements[id] ?? makeTabAccessibilityElement(id: id)
            element.setAccessibilityLabel(item.confirmingClose ? "\(item.title), \(TabStripHelp.killLabel)" : item.title)
            element.setAccessibilityValue(item.isSelected ? 1 : 0)
            var help = ["Tab \(index + 1) of \(items.count)"] + TabStripHelp.tabLines(index: index, count: items.count, status: TabStatus(item))
            if item.confirmingClose { help.insert(TabStripHelp.killHelp, at: 0) }
            element.setAccessibilityHelp(help.joined(separator: ". "))
            element.setAccessibilityFrameInParentSpace(Self.accessibilityFrame(ofTab: entry.frame, in: viewport))
            kept[id] = element
            elements.append(element)
        }
        tabAccessibilityElements = kept
        var buttons: [(String, CGRect, Bool, String, () -> Void)] = []
        if showsNewTabControls {
            buttons.append((ButtonLabel.newTab, newFrame, canCreate, toolTip(forTag: ToolTipTag.newTab),
                            { [weak self] in if self?.canCreate == true { self?.onNew?() } }))
            buttons.append((ButtonLabel.menu, menuFrame, true, TabStripHelp.presets,
                            { [weak self] in self?.activate(.presetMenu, at: .zero) }))
        }
        if autoRotateOn {
            buttons.append((ButtonLabel.rotate, rotateFrame, true, TabStripHelp.rotate, { [weak self] in self?.onToggleAutoRotate?() }))
        }
        let shown = Set(buttons.map(\.0))
        buttonAccessibilityElements = buttonAccessibilityElements.filter { shown.contains($0.key) }
        for (label, frame, enabled, help, action) in buttons {
            let element = buttonAccessibilityElements[label] ?? {
                let created = StripAccessibilityElement()
                created.setAccessibilityParent(self)
                created.setAccessibilityRole(.button)
                created.setAccessibilityLabel(label)
                created.onPress = action
                buttonAccessibilityElements[label] = created
                return created
            }()
            element.setAccessibilityEnabled(enabled)
            element.setAccessibilityHelp(help)
            element.setAccessibilityFrameInParentSpace(frame)
            elements.append(element)
        }
        accessibilityElements = elements
        announceAccessibilityChanges()
    }

    /// Tells VoiceOver what changed since it was last told: the old and the new selected tab changed their value and the
    /// group its selected child; tabs that came or went change the group's layout.
    private func announceAccessibilityChanges() {
        let selected = items.first(where: \.isSelected)?.id
        let ids = items.map(\.id)
        if selected != announcedSelection {
            for id in [announcedSelection, selected].compactMap({ $0 }) {
                if let element = tabAccessibilityElements[id] { postAccessibilityNotification(element, .valueChanged, nil) }
            }
            postAccessibilityNotification(self, .selectedChildrenChanged, nil)
        }
        if ids != announcedIDs { postAccessibilityNotification(self, .layoutChanged, nil) }
        announcedSelection = selected
        announcedIDs = ids
    }

    /// Asks VoiceOver to say `text` now, for a change the VoiceOver cursor would not notice (a tab asking "Kill?").
    func announce(_ text: String) {
        var element: Any = self
        if let application = NSApp { element = application } else if let window { element = window }
        postAccessibilityNotification(element, .announcementRequested,
                                      [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func makeTabAccessibilityElement(id: UUID) -> StripAccessibilityElement {
        let element = StripAccessibilityElement()
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.radioButton)
        element.setAccessibilitySubrole(TabStripView.tabButtonSubrole)
        element.setAccessibilityEnabled(true)
        element.onPress = { [weak self] in self?.onSelect?(id) }
        element.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Close Tab") { [weak self] in
            guard let self, let onClose = self.onClose else { return false }
            onClose(id)
            return true
        }])
        return element
    }

    override func accessibilityChildren() -> [Any]? { accessibilityElements }

    /// The tabs of the tab group, and the selected one (what `selectedChildrenChanged` refers to).
    override func accessibilityTabs() -> [Any]? { tabFrames.compactMap { tabAccessibilityElements[$0.id] } }
    override func accessibilitySelectedChildren() -> [Any]? {
        items.first(where: \.isSelected).flatMap { tabAccessibilityElements[$0.id] }.map { [$0] } ?? []
    }

    /// The VoiceOver labels of the buttons.
    enum ButtonLabel {
        static let newTab = "New Tab"
        static let menu = "Presets"
        static let rotate = "Auto-rotate Is On"
    }

    /// A tab's frame for VoiceOver: the part of it that is in view. A tab scrolled wholly out of view gets a 1 pt sliver
    /// at the edge it is hidden behind, so its outline never covers "+" or the chevron (nor lies outside the console);
    /// VoiceOver still reaches it in the tab group, and pressing it selects it and brings it into view.
    static func accessibilityFrame(ofTab frame: CGRect, in viewport: CGRect) -> CGRect {
        let visible = frame.intersection(viewport)
        if !visible.isNull, visible.width >= 1 { return visible }
        let x = frame.minX >= viewport.maxX ? max(viewport.minX, viewport.maxX - 1) : viewport.minX
        return CGRect(x: x, y: frame.minY, width: 1, height: frame.height)
    }

    /// What VoiceOver finds under a point is what a click there would hit: a tab scrolled out of view (under "+" and
    /// the chevron, or past the strip's edge) never answers for the control drawn there.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return self }
        let element: StripAccessibilityElement?
        switch hit(at: convert(window.convertPoint(fromScreen: point), from: nil)) {
        case .tab(let id)?, .close(let id)?: element = tabAccessibilityElements[id]
        case .newSession?: element = buttonAccessibilityElements[ButtonLabel.newTab]
        case .presetMenu?: element = buttonAccessibilityElements[ButtonLabel.menu]
        case .autoRotate?: element = buttonAccessibilityElements[ButtonLabel.rotate]
        case nil: element = nil
        }
        return element ?? self
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTip(forTag: Int(bitPattern: data))
    }

    /// The tooltip text for a tag: a tab (its index plus one) or one of the buttons.
    func toolTip(forTag value: Int) -> String {
        switch value {
        case ToolTipTag.newTab: return canCreate ? TabStripHelp.newTab : TabStripHelp.newTabDisabled
        case ToolTipTag.presets: return TabStripHelp.presets
        case ToolTipTag.rotate: return TabStripHelp.rotate
        default:
            let index = value - 1
            guard items.indices.contains(index) else { return "" }
            let item = items[index]
            // A number-only tab has no room for "Kill? click again": the tooltip says it instead.
            let kill = item.confirmingClose ? [TabStripHelp.killHelp] : []
            let extra = TabStripHelp.tabLines(index: index, count: items.count, status: TabStatus(item))
            return (kill + [item.tooltip] + extra).joined(separator: "\n")
        }
    }

    /// One enter/exit tracking area per visible tab, close button and button. `.mouseMoved` is deliberately not requested: on
    /// macOS 26 a tracking area that asks for mouse-moved events can synthesize left-mouse-down events (SwiftTerm documents
    /// the same workaround), which here would click tabs by themselves.
    private func rebuildTrackingAreas() {
        for area in itemTrackingAreas { removeTrackingArea(area) }
        itemTrackingAreas = []
        func add(_ rect: CGRect, _ info: [String: String]) {
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
            let area = NSTrackingArea(rect: rect, options: [.activeAlways, .mouseEnteredAndExited], owner: self, userInfo: info)
            addTrackingArea(area)
            itemTrackingAreas.append(area)
        }
        for entry in tabFrames {
            add(entry.frame.intersection(viewport), ["tab": entry.id.uuidString])
            if !TabLayout.isCompact(entry.frame.width) {
                add(closeHitFrame(in: entry.frame).intersection(viewport), ["close": entry.id.uuidString])
            }
        }
        if showsNewTabControls {
            add(newHitFrame, ["button": "new"])
            add(menuHitFrame, ["button": "menu"])
        }
        if autoRotateOn { add(rotateHitFrame, ["button": "rotate"]) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingAreas()
    }

    // MARK: Hit testing

    /// Where a click counts for each control: at least 24 x 24 pt although the chevron is drawn 22 pt wide (its area runs
    /// on to the strip's right edge) and the auto-rotate indicator 22 pt round.
    var newHitFrame: CGRect { showsNewTabControls ? newFrame.insetBy(dx: 0, dy: -Self.pillTop) : .zero }
    var menuHitFrame: CGRect {
        guard showsNewTabControls else { return .zero }
        return CGRect(x: menuFrame.minX, y: menuFrame.minY - Self.pillTop, width: max(menuFrame.width, bounds.width - menuFrame.minX),
                      height: menuFrame.height + 2 * Self.pillTop)
    }
    var rotateHitFrame: CGRect { autoRotateOn ? rotateFrame.insetBy(dx: -2, dy: -2) : .zero }

    func hit(at point: CGPoint) -> Hit? {
        if newHitFrame.contains(point) { return .newSession }
        if menuHitFrame.contains(point) { return .presetMenu }
        if autoRotateOn, rotateHitFrame.contains(point) { return .autoRotate }
        guard viewport.contains(point) else { return nil }
        for entry in tabFrames where entry.frame.contains(point) {
            if showsClose(entry.id, width: entry.frame.width), closeHitFrame(in: entry.frame).contains(point) {
                return .close(entry.id)
            }
            return .tab(entry.id)
        }
        return nil
    }

    private func closeFrame(in tab: CGRect) -> CGRect {
        CGRect(x: tab.maxX - 7 - Self.closeSize, y: tab.midY - Self.closeSize / 2, width: Self.closeSize, height: Self.closeSize)
    }

    /// Where the close button takes clicks (24 x 24 pt around the 18 pt circle). Its hover highlight covers the same area,
    /// so the highlight always says what a click there does.
    func closeHitFrame(in tab: CGRect) -> CGRect { closeFrame(in: tab).insetBy(dx: -3, dy: -3) }

    // Where a tab's parts go. Whole points, so on the 1x display their edges land on pixels, and the same line in every
    // state, so numbers and titles do not jump when the selection moves.

    /// The number badge: at the leading edge, or centred in a number-only tab.
    static func badgeFrame(in tab: CGRect, digits: Int, compact: Bool) -> CGRect {
        let width: CGFloat = digits > 1 ? 23 : 18
        let x = compact ? (tab.midX - width / 2).rounded(.down) : tab.minX + 6
        return CGRect(x: x, y: (tab.midY - 9).rounded(.down), width: width, height: 18)
    }

    /// The status dot, on the badge's top trailing corner, and the ring of `halo` around it.
    static func dotFrame(on badge: CGRect) -> CGRect { CGRect(x: badge.maxX - 5, y: badge.minY - 4, width: 8, height: 8) }
    static let dotHalo: CGFloat = 2

    /// The selected tab's accent bar: it thickens the straight part of the tab's bottom edge (below the badge and the
    /// title's descenders, so nothing has to move up to make room for it).
    static func underlineFrame(in tab: CGRect) -> CGRect {
        CGRect(x: tab.minX + cornerRadius, y: tab.maxY - 3, width: max(0, tab.width - 2 * cornerRadius), height: 2)
    }

    /// The close button is on the selected tab, the hovered one, the one asking "Kill?" and the one being pressed, unless
    /// the tab is too narrow (then a middle click, the context menu and Cmd-W close it).
    private func showsClose(_ id: UUID, width: CGFloat) -> Bool {
        guard !TabLayout.isCompact(width), let item = items.first(where: { $0.id == id }) else { return false }
        return item.isSelected || hoverID == id || item.confirmingClose || pressedTarget == .close(id)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Control-click is the secondary click on a Mac: it opens the menu, it must not select or close a tab.
        if Self.isContextClick(event) {
            if let menu = contextMenu(for: hit(at: point)) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        let target = clickTarget(hit(at: point), clickCount: event.clickCount)
        switch target {
        case .close?, .newSession?, .autoRotate?:
            // A button: it looks pressed now and acts on mouse-up over itself (an idle shell is not closed, and no shell
            // is started, the moment the mouse button goes down).
            setPressed(target, inside: true)
        case .tab?, .presetMenu?, nil:
            // A tab selects and the chevron opens its menu at once, as in macOS tab bars and pop-up buttons.
            activate(target, at: point)
        }
    }

    /// A press dragged off its button no longer looks pressed, and one dragged back on does again.
    override func mouseDragged(with event: NSEvent) {
        guard let pressed = pressedTarget else { return }
        setPressed(pressed, inside: hit(at: convert(event.locationInWindow, from: nil)) == pressed)
    }

    /// The pressed button acts when the mouse button comes up over it; released anywhere else, the press is cancelled.
    override func mouseUp(with event: NSEvent) {
        guard let pressed = pressedTarget else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inside = hit(at: point) == pressed
        setPressed(nil, inside: false)
        if inside { activate(pressed, at: point) }
    }

    private func setPressed(_ target: Hit?, inside: Bool) {
        guard target != pressedTarget || inside != pressedInside else { return }
        pressedTarget = target
        pressedInside = inside
        needsDisplay = true
    }

    /// What a click on `hit` does, given its place in a click sequence (the later clicks of a double- or triple-click land
    /// where the first one did). Evaluated on mouse-down.
    ///
    /// - Selecting a tab can move the tabs under the pointer: a narrow tab widens (the selected tab keeps
    ///   `TabLayout.selectedMinWidth`), which can slide its close button there, and a tab partly hidden at the edge of an
    ///   overflowing strip scrolls into view, which can slide a neighbour there. The rest of the sequence stays on the tab
    ///   the first click selected: a double-click never closes that tab, nor selects the one next to it.
    /// - Turning auto-rotate off removes its indicator and the tabs widen into its place: the rest of a sequence that
    ///   started on the indicator is ignored, so a double-click there never closes the tab that slid under the pointer.
    /// - "Kill? click again" asks for a deliberate second click: the second click of a double-click on the close button of
    ///   a tab whose program the first click asked to end is ignored (a held Cmd-W is ignored the same way). A later single
    ///   click there closes it.
    /// - Otherwise each click counts: a double-click on the close button of an idle tab closes it and then the tab that
    ///   slid under the pointer, as clicking twice does in a browser.
    func clickTarget(_ hit: Hit?, clickCount: Int) -> Hit? {
        if clickCount > 1 {
            if firstClickHit == .autoRotate { return nil }
            if let id = tabSelectedByFirstClick, items.contains(where: { $0.id == id }) { return hit == nil ? nil : .tab(id) }
            if case .close(let id)? = hit, id == closeRequestedByFirstClick { return nil }
            return hit
        }
        firstClickHit = hit
        tabSelectedByFirstClick = nil
        closeRequestedByFirstClick = nil
        switch hit {
        case .tab(let id)? where items.first(where: { $0.id == id })?.isSelected == false: tabSelectedByFirstClick = id
        case .close(let id)?: closeRequestedByFirstClick = id
        default: break
        }
        return hit
    }

    /// A left click with Control held, which macOS treats as a right click.
    static func isContextClick(_ event: NSEvent) -> Bool {
        event.type == .leftMouseDown && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
    }

    /// The menu for a secondary click on `hit`: the tab's menu on a tab or its close button, the presets on "+" and the
    /// chevron, nothing elsewhere.
    func contextMenu(for hit: Hit?) -> NSMenu? {
        switch hit {
        case .tab(let id), .close(let id): return tabMenuProvider?(id)
        case .presetMenu, .newSession: return showsNewTabControls ? presetMenuProvider?() : nil
        default: return nil
        }
    }

    /// The tab a middle click at `point` closes: anywhere on a tab, its close button included.
    func middleClickTarget(at point: CGPoint) -> UUID? {
        switch hit(at: point) {
        case .tab(let id), .close(let id): return id
        default: return nil
        }
    }

    /// Performs what a click on `hit` does (on mouse-down for a tab and the chevron, on mouse-up for the buttons).
    /// Separate from the mouse events so tests can click without them.
    func activate(_ hit: Hit?, at point: CGPoint) {
        switch hit {
        case .tab(let id): onSelect?(id)
        case .close(let id): onClose?(id)
        case .newSession:
            guard showsNewTabControls else { return }
            if canCreate { onNew?() } else { NSSound.beep() }
        case .autoRotate: onToggleAutoRotate?()
        case .presetMenu:
            guard showsNewTabControls else { return }
            if let menu = presetMenuProvider?() { menu.popUp(positioning: nil, at: CGPoint(x: newFrame.minX, y: bounds.height - 1), in: self) }
        case nil: break
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle click closes the tab, also on its close button (a hovered tab shows one, so that is where it often lands).
        if event.buttonNumber == 2, let id = middleClickTarget(at: convert(event.locationInWindow, from: nil)) { onClose?(id) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenu(for: hit(at: convert(event.locationInWindow, from: nil))) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    /// Wheel and trackpad: sideways scrolling when the tabs overflow. A plain vertical trackpad scroll is left to whatever
    /// is behind the strip; a mouse wheel scrolls the tabs sideways.
    override func scrollWheel(with event: NSEvent) {
        guard isOverflowing else { super.scrollWheel(with: event); return }
        let precise = event.hasPreciseScrollingDeltas
        let (dx, dy) = (event.scrollingDeltaX, event.scrollingDeltaY)
        let horizontal = abs(dx) > abs(dy)
        guard horizontal || !precise else { super.scrollWheel(with: event); return }
        let delta = (horizontal ? dx : dy) * (precise ? 1 : 10)
        scroll(by: -delta)
        refreshHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard let info = event.trackingArea?.userInfo as? [String: String] else { return }
        if let id = info["tab"].flatMap(UUID.init(uuidString:)) {
            setHover(id: id, button: nil, close: false)
        } else if let id = info["close"].flatMap(UUID.init(uuidString:)) {
            setHover(id: id, button: nil, close: true)
        } else if let button = info["button"].flatMap(Self.button(named:)) {
            setHover(id: nil, button: button, close: false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard let info = event.trackingArea?.userInfo as? [String: String] else { return }
        if let id = info["close"].flatMap(UUID.init(uuidString:)) {
            if hoverCloseID == id { setHover(id: hoverID, button: hoverButton, close: false) }
        } else if let id = info["tab"].flatMap(UUID.init(uuidString:)) {
            if hoverID == id { setHover(id: nil, button: nil, close: false) }
        } else if let button = info["button"].flatMap(Self.button(named:)), hoverButton == button {
            // Only the button that was left: "+" and the chevron touch, and the enter of one can arrive before the exit
            // of the other.
            setHover(id: nil, button: nil, close: false)
        }
    }

    private static func button(named name: String) -> Hit? {
        switch name {
        case "new": return .newSession
        case "menu": return .presetMenu
        case "rotate": return .autoRotate
        default: return nil
        }
    }

    /// Sets what the pointer is over. `close` says it is over the close button of tab `id`.
    func setHover(id: UUID?, button: Hit?, close: Bool = false) {
        let closeID = close ? id : nil
        guard id != hoverID || button != hoverButton || closeID != hoverCloseID else { return }
        hoverID = id
        hoverButton = button
        hoverCloseID = closeID
        needsDisplay = true
    }

    /// Recomputes the hover state from a pointer position (after the tabs moved under a still pointer).
    private func refreshHover(at point: CGPoint) {
        if newHitFrame.contains(point) { setHover(id: nil, button: .newSession); return }
        if menuHitFrame.contains(point) { setHover(id: nil, button: .presetMenu); return }
        if autoRotateOn, rotateHitFrame.contains(point) { setHover(id: nil, button: .autoRotate); return }
        guard viewport.contains(point), let entry = tabFrames.first(where: { $0.frame.contains(point) }) else {
            setHover(id: nil, button: nil)
            return
        }
        setHover(id: entry.id, button: nil, close: !TabLayout.isCompact(entry.frame.width) && closeHitFrame(in: entry.frame).contains(point))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let style = style
        style.band.setFill()
        bounds.fill()
        style.separator.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        drawTabs(style, dirtyRect: dirtyRect)
        if autoRotateOn { drawRotateIndicator(style) }
        if showsNewTabControls { drawControls(style) }
    }

    private func drawTabs(_ style: TabStripStyle, dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: viewport).addClip()
        if isOverflowing, let context = NSGraphicsContext.current?.cgContext {
            let fadeLeft = scrollOffset > 0.5
            let fadeRight = scrollOffset < contentWidth - viewport.width - 0.5
            if let mask = fadeMask(width: viewport.width, left: fadeLeft, right: fadeRight) { context.clip(to: viewport, mask: mask) }
        }
        for (index, entry) in tabFrames.enumerated() where index < items.count {
            guard entry.frame.intersects(dirtyRect), entry.frame.intersects(viewport) else { continue }
            drawTab(items[index], index: index, frame: entry.frame, style: style)
        }
    }

    private func drawTab(_ item: Item, index: Int, frame: CGRect, style: TabStripStyle) {
        // A tab whose close button is being pressed stays hovered even if AppKit reports the pointer leaving it mid-drag.
        let hovered = hoverID == item.id || pressedTarget == .close(item.id)
        let state: TabStripStyle.TabState = item.confirmingClose ? .warning : (item.isSelected ? .active : (hovered ? .hovered : .inactive))
        let colors = style.colors(for: state)
        let compact = TabLayout.isCompact(frame.width)
        let radius = Self.cornerRadius
        if item.isSelected, let shadow = style.activeShadow {
            shadow.setFill()
            NSBezierPath(roundedRect: frame.offsetBy(dx: 0, dy: 1), xRadius: radius, yRadius: radius).fill()
        }
        let shape = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        colors.fill.setFill()
        shape.fill()
        colors.outline.setStroke()
        shape.lineWidth = item.isSelected ? 1.25 : 1
        shape.stroke()
        if item.isSelected, !item.confirmingClose {
            style.accent.setFill()
            NSBezierPath(roundedRect: Self.underlineFrame(in: frame), xRadius: 1, yRadius: 1).fill()
        }

        // Number badge, with the status dot on its corner.
        let number = String(TabNumbering.badge(index: index))
        let badge = Self.badgeFrame(in: frame, digits: number.count, compact: compact)
        colors.badgeFill.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5.5, yRadius: 5.5).fill()
        let digits: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                                                     .foregroundColor: colors.badgeText]
        let digitSize = number.size(withAttributes: digits)
        number.draw(at: CGPoint(x: badge.midX - digitSize.width / 2, y: badge.midY - digitSize.height / 2), withAttributes: digits)
        if let dot = style.dotColor(for: TabStatus(item)) {
            let rect = Self.dotFrame(on: badge)
            style.halo.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -Self.dotHalo, dy: -Self.dotHalo)).fill()
            dot.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        guard !compact else { return }

        // Title, then the close button.
        let closeVisible = showsClose(item.id, width: frame.width)
        let textLeft = badge.maxX + 7
        let textRight = frame.maxX - (closeVisible ? 8 + Self.closeSize + 2 : 11)
        if textRight - textLeft > 10 {
            let weight: NSFont.Weight = item.isSelected ? .semibold : .medium
            let font = NSFont.systemFont(ofSize: Self.titleSize, weight: weight)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let color = item.hasExited && !item.isSelected ? colors.title.withAlphaComponent(style.exitedTitleAlpha) : colors.title
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            var title = item.title
            if item.confirmingClose {
                title = TabStripHelp.killLabel
                if title.size(withAttributes: attributes).width > textRight - textLeft { title = "Kill?" }
            }
            let size = title.size(withAttributes: attributes)
            let rect = CGRect(x: textLeft, y: frame.midY - size.height / 2, width: textRight - textLeft, height: size.height)
            title.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
        if closeVisible { drawClose(in: closeFrame(in: frame), item: item, colors: colors) }
    }

    private func drawClose(in rect: CGRect, item: Item, colors: TabStripStyle.TabColors) {
        // Pressed: a stronger circle. A press dragged off the button shows it plain, like a standard macOS button.
        let pressing = pressedTarget == .close(item.id)
        let pressed = pressing && pressedInside
        let hovered = !pressing && hoverCloseID == item.id
        if pressed || hovered {
            colors.title.withAlphaComponent(pressed ? TabStripStyle.closePressedAlpha : TabStripStyle.closeHoverAlpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        colors.title.withAlphaComponent(pressed || hovered ? 1 : 0.8).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        let inset: CGFloat = 5.6
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.stroke()
    }

    /// The "+" and the presets chevron as one split button.
    private func drawControls(_ style: TabStripStyle) {
        let group = newFrame.union(menuFrame)
        let shape = NSBezierPath(roundedRect: group.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius - 0.5, yRadius: Self.cornerRadius - 0.5)
        style.buttonFill.setFill()
        shape.fill()
        let plusPressing = pressedTarget == .newSession
        let plusPressed = plusPressing && pressedInside && canCreate
        let plusHovered = !plusPressing && hoverButton == .newSession && canCreate
        let chevronHovered = hoverButton == .presetMenu
        if plusPressed || plusHovered || chevronHovered {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            if plusPressed || plusHovered {
                (plusPressed ? style.buttonPressedFill : style.buttonHoverFill).setFill()
                newFrame.fill()
            }
            if chevronHovered {
                style.buttonHoverFill.setFill()
                menuFrame.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        style.buttonOutline.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let divider = NSBezierPath()
        divider.lineWidth = 1
        divider.move(to: CGPoint(x: menuFrame.minX, y: group.minY + 5))
        divider.line(to: CGPoint(x: menuFrame.minX, y: group.maxY - 5))
        divider.stroke()

        // Plus. Hover shows in the fill; the glyph keeps its full contrast (an accent glyph on the hover fill fell below 3:1).
        (canCreate ? style.glyph : style.glyphDisabled).setStroke()
        let plus = NSBezierPath()
        plus.lineWidth = 1.9
        plus.lineCapStyle = .round
        let c = CGPoint(x: newFrame.midX, y: newFrame.midY)
        plus.move(to: CGPoint(x: c.x - 5.5, y: c.y)); plus.line(to: CGPoint(x: c.x + 5.5, y: c.y))
        plus.move(to: CGPoint(x: c.x, y: c.y - 5.5)); plus.line(to: CGPoint(x: c.x, y: c.y + 5.5))
        plus.stroke()

        // Chevron
        style.glyph.setStroke()
        let chevron = NSBezierPath()
        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        let m = CGPoint(x: menuFrame.midX, y: menuFrame.midY + 0.5)
        chevron.move(to: CGPoint(x: m.x - 4, y: m.y - 2.2)); chevron.line(to: CGPoint(x: m.x, y: m.y + 2.2)); chevron.line(to: CGPoint(x: m.x + 4, y: m.y - 2.2))
        chevron.stroke()
    }

    private func drawRotateIndicator(_ style: TabStripStyle) {
        // An "on" toggle, painted like the active tab's number badge (an accent glyph over a translucent accent circle
        // measured 2.5:1 on the light theme).
        let fill: NSColor
        if pressedTarget == .autoRotate {
            fill = pressedInside ? style.togglePressedFill : style.toggleFill
        } else {
            fill = hoverButton == .autoRotate ? style.toggleHoverFill : style.toggleFill
        }
        fill.setFill()
        NSBezierPath(roundedRect: rotateFrame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
        guard let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Auto-rotate is on") else { return }
        let configured = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)) ?? image
        let glyph = style.toggleGlyph
        let tinted = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect)
            glyph.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        tinted.draw(in: CGRect(x: rotateFrame.midX - size.width / 2, y: rotateFrame.midY - size.height / 2, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Edge fade

    /// A gray mask that fades the tabs out at the edges where more of them are hidden (in a Quartz gray-image mask white
    /// lets the drawing through and black blocks it).
    private func fadeMask(width: CGFloat, left: Bool, right: Bool) -> CGImage? {
        guard left || right, width > 2 * Self.fadeWidth else { return nil }
        let pixels = Int((width * 2).rounded())
        let key = "\(pixels)-\(left)-\(right)"
        if let cached = fadeMaskCache, cached.key == key { return cached.image }
        let fade = Double(Self.fadeWidth * 2)
        var data = [UInt8](repeating: 0, count: pixels)
        for x in 0..<pixels {
            var alpha = 1.0
            if left { alpha = min(alpha, Double(x) / fade) }
            if right { alpha = min(alpha, Double(pixels - 1 - x) / fade) }
            data[x] = UInt8(max(0, min(1, alpha)) * 255)
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let image = CGImage(width: pixels, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: pixels,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        fadeMaskCache = (key, image)
        return image
    }
}
