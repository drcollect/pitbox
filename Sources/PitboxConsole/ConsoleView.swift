import AppKit
import PitboxKit

/// Draws the ring that shows the terminal has the keyboard (or a drag is over it). Never takes clicks.
private final class FocusRingView: NSView {
    var color: NSColor = PitboxTheme.accent.nsColor { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 18 { didSet { needsDisplay = true } }
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }
    var dropTarget = false { didSet { if dropTarget != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard focused || dropTarget else { return }
        let width: CGFloat = dropTarget ? 2.5 : 1.5
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: cornerRadius, yRadius: cornerRadius)
        path.lineWidth = width
        color.withAlphaComponent(dropTarget ? 0.95 : 0.85).setStroke()
        path.stroke()
    }
}

/// Covers the terminal area in snapshot renders: an opaque card with a short notice instead of the terminal's contents.
private final class RedactionView: NSView {
    let background: NSColor
    let foreground: NSColor
    init(frame: NSRect, background: NSColor, foreground: NSColor) {
        self.background = background
        self.foreground = foreground
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        let text = "Terminal contents are not included in snapshots"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                         .foregroundColor: foreground.withAlphaComponent(0.7)]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// The area under the tab strip that holds the terminal views. A click in the padding around a terminal goes to it.
private final class TerminalHostView: NSView {
    var onBackgroundClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onBackgroundClick?() }
}

/// The console's content: a tab strip over the selected terminal, tinted so the glass shows through, with a ring when the
/// terminal has the keyboard.
///
/// It owns no sessions. The `TerminalSessionManager` does, and it outlives this view: when the console is rebuilt a new
/// `ConsoleView` attaches to the same manager and re-parents the same terminal views, so shells keep running.
///
/// Keyboard: clicks in a terminal make the block's panel key by themselves (the Shell treats a text-input view as
/// wanting typing). What this view adds is `keyboardRequester`, called with `true` when the terminal should take the
/// keyboard without a click on it (a new tab, `focusTerminal()`) and with `false` for Cmd-Escape, which hands the
/// keyboard back to the app that had it.
@MainActor
final class ConsoleView: NSView {
    static let sidePadding: CGFloat = 10
    /// The tab strip is 34 pt tall; the bottom padding is 8 (was 10) so the terminal keeps its rows: a 618 x 636 pt console is still 72x37.
    static let bottomPadding: CGFloat = 8
    static let topGap: CGFloat = 2

    let manager: TerminalSessionManager
    let strip = TabStripView(frame: .zero)
    private let host = TerminalHostView(frame: .zero)
    private let ring = FocusRingView(frame: .zero)
    private let keyboardRequester: (Bool) -> Void
    private let cornerRadius: CGFloat
    private let padding: (side: CGFloat, bottom: CGFloat)
    private var focusObservation: NSKeyValueObservation?
    private var windowObservers: [NSObjectProtocol] = []
    private(set) var isFocused = false
    /// The native bars of command and Type tabs, by session; only the selected one is in the view hierarchy.
    private var bars: [UUID: CommandTabBar] = [:]

    override var isFlipped: Bool { true }

    init(manager: TerminalSessionManager, cornerRadius: CGFloat, keyboardRequester: @escaping (Bool) -> Void) {
        self.manager = manager
        self.cornerRadius = cornerRadius
        padding = Self.terminalPadding(consoleCornerRadius: cornerRadius)
        self.keyboardRequester = keyboardRequester
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(host)
        addSubview(strip)
        addSubview(ring)
        ring.cornerRadius = cornerRadius
        strip.consoleCornerRadius = cornerRadius
        host.onBackgroundClick = { [weak self] in self?.focusTerminal(byClick: true) }
        wireStrip()
        manager.onChange = { [weak self] in self?.syncFromManager() }
        manager.onCommandTick = { [weak self] in self?.refreshCommandBar() }
        manager.interactionProbe = { [weak self] in self?.isUserPresent ?? false }
        // Shown: its window is on screen and nothing hides the console (the drawer folded to its bar hides it).
        manager.visibilityProbe = { [weak self] in
            guard let self, let window = self.window else { return false }
            return window.isVisible && !self.isHiddenOrHasHiddenAncestor
        }
        setAccessibilityElement(true)   // without it the role and label below are ignored (a plain NSView is not an element)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal")
        applyAppearance()
        syncFromManager()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Layout

    /// The padding around the terminal: `sidePadding` and `bottomPadding`, or more when the console's corners (`cornerRadius`,
    /// up to 48) are so round that they would cut off the corner cells of the bottom row (a block cursor,
    /// box drawing). The terminal's bottom corners stay inside the console's corner arc, 1 pt clear of it for antialiasing;
    /// from about 29 pt both paddings grow together. The default 18 pt corner keeps 10 and 8.
    static func terminalPadding(consoleCornerRadius radius: CGFloat) -> (side: CGFloat, bottom: CGFloat) {
        var side = sidePadding, bottom = bottomPadding
        let limit = max(0, radius - 1)
        while side < radius, bottom < radius,
              (radius - side) * (radius - side) + (radius - bottom) * (radius - bottom) > limit * limit {
            side += 1
            bottom += 1
        }
        return (side, bottom)
    }

    /// Where the terminals go, in `host` coordinates (not flipped: y up).
    private func terminalFrame(in hostBounds: CGRect) -> CGRect {
        CGRect(x: padding.side, y: padding.bottom, width: max(0, hostBounds.width - 2 * padding.side),
               height: max(0, hostBounds.height - padding.bottom - Self.topGap))
    }

    override func layout() {
        super.layout()
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TabStripView.height)
        host.frame = CGRect(x: 0, y: TabStripView.height, width: bounds.width, height: max(0, bounds.height - TabStripView.height))
        ring.frame = bounds
        let target = terminalFrame(in: host.bounds)
        manager.setContentSize(target.size)   // sizes: the selected tab now, the others when the size settles
        for case let view as ConsoleTerminalView in host.subviews where view.frame.origin != target.origin { view.setFrameOrigin(target.origin) }
        layoutCommandBar(in: target)
    }

    /// The selected command tab's bar sits above its terminal view, inside the terminal area (host is not flipped).
    private func layoutCommandBar(in target: CGRect) {
        for case let bar as CommandTabBar in host.subviews {
            let frame = CGRect(x: target.minX, y: target.maxY - CommandTabBar.height, width: target.width, height: CommandTabBar.height)
            if bar.frame != frame { bar.frame = frame }
        }
    }

    // MARK: Sync with the manager

    private func wireStrip() {
        // Pitbox's console has no plain shells: no "+", no preset menu.
        strip.showsNewTabControls = manager.offersPlainShells
        strip.onSelect = { [weak self] id in self?.manager.select(id: id) }
        strip.onClose = { [weak self] id in self?.requestClose(id) }
        strip.onNew = { [weak self] in self?.newSession(preset: nil) }
        strip.onToggleAutoRotate = { [weak self] in
            guard let self else { return }
            manager.setAutoRotate(!manager.autoRotate)
        }
        strip.presetMenuProvider = { [weak self] in self?.makePresetMenu() ?? NSMenu() }
        strip.tabMenuProvider = { [weak self] id in self?.makeTabMenu(for: id) ?? NSMenu() }
    }

    /// Brings the strip, the visible terminal and the focus ring in line with the manager.
    ///
    /// Only the selected tab's terminal view is in the view hierarchy; the others are detached (their processes and
    /// emulators keep running). A hidden-but-attached view would still receive events that AppKit and SwiftTerm broadcast
    /// to every terminal view of a window (mouse-moved reports for programs that track the mouse, key equivalents).
    func syncFromManager() {
        let sessions = manager.sessions
        let wasFocused = isTerminalFocused
        let target = terminalFrame(in: host.bounds)
        for case let view as ConsoleTerminalView in host.subviews where view.superview === host {
            if !(sessions.contains { $0.view === view && $0.id == manager.selectedID }) { view.removeFromSuperview() }
        }
        if let selectedSession = manager.selectedSession, selectedSession.view.superview !== host {
            let selected = selectedSession.view
            if !target.isEmpty { selected.frame = CGRect(origin: target.origin, size: manager.viewSize(for: selectedSession)) }
            selected.isHidden = false
            host.addSubview(selected)
            selected.needsDisplay = true
        }
        syncCommandBar(sessions: sessions, target: target)
        for session in sessions {
            wire(session.view)
            session.view.setAccessibilityLabel("Terminal, \(session.title)")
        }
        strip.items = sessions.map(item(for:))
        strip.autoRotateOn = manager.autoRotate
        strip.canCreate = manager.canCreateSession

        // Typing focus follows the selection: switching tabs while typing keeps typing. Never into a command or Type
        // tab: the keyboard reaches one only through a click inside it.
        if wasFocused, let selected = manager.selectedSession, selected.preset.kind != .command,
           !isFirstResponder(inside: selected.view) {
            window?.makeFirstResponder(selected.view)
        }
        applyAppearance()
        updateFocusState()
    }

    /// Keeps the bar of the selected command or Type tab above its view, and drops the bars of closed tabs.
    private func syncCommandBar(sessions: [TerminalSession], target: CGRect) {
        let live = Set(sessions.compactMap { $0.command == nil ? nil : $0.id })
        for id in bars.keys where !live.contains(id) {
            bars[id]?.removeFromSuperview()
            bars[id] = nil
        }
        let selected = manager.selectedSession
        for case let bar as CommandTabBar in host.subviews where bars.first(where: { $0.value === bar })?.key != selected?.id {
            bar.removeFromSuperview()
        }
        guard let selected, selected.command != nil else { return }
        let bar = bars[selected.id] ?? makeBar(for: selected)
        if bar.superview !== host {
            host.addSubview(bar)
            layoutCommandBar(in: target)
        }
        refreshCommandBar()
    }

    private func makeBar(for session: TerminalSession) -> CommandTabBar {
        let bar = CommandTabBar(frame: .zero)
        let id = session.id
        bar.onClickToType = { [weak self] in
            guard let self, self.manager.selectedID == id else { return }
            self.focusTerminal(byClick: true)
        }
        bar.onStop = { [weak self] in self?.manager.sessions.first { $0.id == id }?.stopCommand() }
        bars[id] = bar
        return bar
    }

    /// Redraws the selected command tab's bar (state, running time, who has the keyboard).
    func refreshCommandBar() {
        guard let session = manager.selectedSession, let command = session.command, let bar = bars[session.id] else { return }
        command.keyboardHere = isFocused
        bar.palette = manager.currentPalette
        bar.content = CommandBarContent.make(command, now: manager.clock.now)
    }

    /// The bar of the selected command tab (tests).
    var selectedCommandBar: CommandTabBar? {
        manager.selectedSession.flatMap { bars[$0.id] }.flatMap { $0.superview === host ? $0 : nil }
    }

    private func item(for session: TerminalSession) -> TabStripView.Item {
        TabStripView.Item(id: session.id, title: session.title, isSelected: session.id == manager.selectedID,
                          hasActivity: session.hasUnseenActivity, needsAttention: session.needsAttention,
                          hasExited: session.hasExited, confirmingClose: manager.closeConfirmationID == session.id,
                          tooltip: session.tooltip, isBusy: session.isBusy, exitFailed: session.exitFailed)
    }

    private func wire(_ view: ConsoleTerminalView) {
        view.shortcutHandler = { [weak self] shortcut in self?.handle(shortcut) ?? false }
        view.onDropTargetChange = { [weak self] over in self?.ring.dropTarget = over }
        view.contextMenuExtras = { [weak self, weak view] in
            guard let self, let view else { return [] }
            return self.contextMenuExtras(for: view)
        }
    }

    // MARK: Actions

    private func newSession(preset: TerminalPreset?) {
        guard manager.offersPlainShells else { return }
        guard manager.newSession(preset: preset) != nil else { NSSound.beep(); return }
        focusTerminal()
    }

    /// Closes a tab from the close button, Cmd-W, the tab's menu or VoiceOver's "Close Tab" action. A tab that runs a
    /// program asks first ("Kill? click again"); VoiceOver hears the question, which the cursor would not notice.
    private func requestClose(_ id: UUID) {
        guard manager.requestClose(id) == .needsConfirmation else { return }
        let title = manager.sessions.first { $0.id == id }?.title ?? "Tab"
        strip.announce(TabStripHelp.killAnnouncement(title: title))
    }

    /// Makes the selected terminal the first responder and asks for the keyboard. A command or Type tab takes the
    /// keyboard only from the user's click inside the tab (`byClick`: its bar or the padding around its terminal; a click
    /// in the terminal view itself does it on its own): never from a new tab, a hotkey or a selection.
    func focusTerminal(byClick: Bool = false) {
        if let selected = manager.selectedSession, selected.preset.kind == .command, !byClick {
            updateFocusState()
            return
        }
        keyboardRequester(true)
        if let view = manager.selectedSession?.view { window?.makeFirstResponder(view) }
        updateFocusState()
    }

    /// Shortcuts from the terminal view. Returns true when handled.
    func handle(_ shortcut: TerminalShortcut) -> Bool {
        switch shortcut {
        case .newSession:
            // Cmd-T opens a plain shell only in the terminal's mode; in Pitbox's console the key is not taken.
            guard manager.offersPlainShells else { return false }
            newSession(preset: nil)
        case .closeSession: if let id = manager.selectedID { requestClose(id) }
        case .nextSession: manager.selectNext()
        case .previousSession: manager.selectPrevious()
        case .selectSession(let index): manager.select(index: index)
        case .selectLastSession: manager.selectLast()
        case .releaseKeyboard: keyboardRequester(false)
        case .find:
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            manager.selectedSession?.view.performFindPanelAction(item)
        case .deleteToLineStart: return false
        }
        return true
    }

    // MARK: Menus

    /// The chevron's menu (the terminal's mode only; Pitbox's console shows no chevron): the presets and auto-rotate.
    /// The presets come from the settings value the app hands the console; there is no file to edit them in.
    private func makePresetMenu() -> NSMenu {
        let menu = NSMenu(title: "New Tab")
        menu.autoenablesItems = true
        for preset in manager.presetsForMenu() {
            let item = NSMenuItem(title: preset.name, action: #selector(newFromPreset(_:)), keyEquivalent: "")
            item.representedObject = preset.id
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let rotate = NSMenuItem(title: "Auto-rotate Tabs", action: #selector(toggleAutoRotate(_:)), keyEquivalent: "")
        rotate.target = self
        rotate.state = manager.autoRotate ? .on : .off
        menu.addItem(rotate)
        return menu
    }

    private func makeTabMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu(title: "Tab")
        menu.autoenablesItems = true
        if let session = manager.sessions.first(where: { $0.id == id }), session.hasExited, session.isRestartable {
            let restart = NSMenuItem(title: "Restart", action: #selector(restartTab(_:)), keyEquivalent: "")
            restart.representedObject = id
            restart.target = self
            menu.addItem(restart)
        }
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "")
        close.representedObject = id
        close.target = self
        menu.addItem(close)
        return menu
    }

    private func contextMenuExtras(for view: ConsoleTerminalView) -> [NSMenuItem] {
        guard let session = manager.sessions.first(where: { $0.view === view }), session.hasExited, session.isRestartable else { return [] }
        let restart = NSMenuItem(title: "Restart", action: #selector(restartTab(_:)), keyEquivalent: "")
        restart.representedObject = session.id
        restart.target = self
        return [restart]
    }

    @objc private func newFromPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let preset = manager.presetsForMenu().first(where: { $0.id == id }) else { return }
        newSession(preset: preset)
    }

    @objc private func toggleAutoRotate(_ sender: Any?) { manager.setAutoRotate(!manager.autoRotate) }
    @objc private func closeTab(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { requestClose(id) } }
    @objc private func restartTab(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { manager.restart(id) } }

    // MARK: Appearance and focus

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        manager.appearanceChanged()
        applyAppearance()
    }

    /// Paints the tint (the palette's background at the configured opacity) and colors the ring.
    func applyAppearance() {
        let palette = manager.currentPalette
        layer?.backgroundColor = palette.tint(opacity: manager.settings.backgroundOpacity).cgColor
        ring.color = palette.accent
        strip.palette = palette
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservation = nil
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        guard let window else { updateFocusState(); return }
        focusObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateFocusState() }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFocusState() }
            })
        }
        manager.appearanceChanged()
        applyAppearance()
        updateFocusState()
    }

    private func isFirstResponder(inside view: NSView) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// The first responder is (inside) a terminal view of this console, including one that was just closed.
    private var isTerminalFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: host)
    }

    /// Recomputes whether the terminal has the keyboard: the window is key and the selected terminal is first responder.
    func updateFocusState() {
        var focused = false
        if let window, window.isKeyWindow, let selected = manager.selectedSession?.view { focused = isFirstResponder(inside: selected) }
        guard focused != isFocused else { return }
        isFocused = focused
        ring.focused = focused
        refreshCommandBar()   // "Keyboard: here" or "elsewhere, click here to type"
    }

    /// The user is here: the terminal has the keyboard, or the pointer is over the console and nothing covers it. Used to
    /// pause auto-rotation.
    var isUserPresent: Bool {
        if isFocused { return true }
        guard let window, window.isVisible else { return false }
        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint),
              NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber else { return false }
        return bounds.contains(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// VoiceOver reads the console top to bottom: the tab strip, then the terminal of the selected tab.
    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = [strip]
        if let view = manager.selectedSession?.view, view.superview === host { children.append(view) }
        return children
    }

    // MARK: Snapshots

    /// Anything that renders the console with `cacheDisplay` or `dataWithPDF` (a screenshot helper, a PDF export) gets a
    /// notice in place of the terminal unless `allowSnapshots` is on in the console's settings (which only the user
    /// sets): a terminal can show secrets. The cover is added for the duration of the render, so the first
    /// responder and everything else stay as they are.
    override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {
        let cover = redactionCover()
        if let cover { addSubview(cover, positioned: .above, relativeTo: host) }
        let restoreTitles = redactCommandTitles()
        super.cacheDisplay(in: rect, to: bitmapImageRep)
        restoreTitles()
        cover?.removeFromSuperview()
    }

    override func dataWithPDF(inside rect: NSRect) -> Data {
        let cover = redactionCover()
        if let cover { addSubview(cover, positioned: .above, relativeTo: host) }
        let restoreTitles = redactCommandTitles()
        let data = super.dataWithPDF(inside: rect)
        restoreTitles()
        cover?.removeFromSuperview()
        return data
    }

    /// The terminal area is covered unless `allowSnapshots` is on, and always while a command or Type tab is the one
    /// shown, also after it finished: its output, its bar and the approved text are the user's and can carry what a
    /// session wrote.
    private func redactionCover() -> NSView? {
        guard snapshotCoversTerminal else { return nil }
        let palette = manager.currentPalette
        return RedactionView(frame: host.frame, background: palette.background, foreground: palette.foreground)
    }

    /// Whether a snapshot covers the terminal area now.
    var snapshotCoversTerminal: Bool {
        !manager.settings.allowSnapshots || manager.selectedSession?.preset.kind == .command
    }

    /// Tests: the strip's titles as a snapshot draws them.
    var onSnapshotTitles: (([String]) -> Void)?

    /// Tests: the tab menu and the terminal's context-menu extras.
    func tabMenu(for id: UUID) -> NSMenu { makeTabMenu(for: id) }
    func contextMenuItems(for view: ConsoleTerminalView) -> [NSMenuItem] { contextMenuExtras(for: view) }

    /// Command and Type tabs are titled after a session's headline (session text): in a snapshot their tabs read
    /// "▶ Command" and "▶ Typed" instead. Returns the undo.
    private func redactCommandTitles() -> () -> Void {
        let original = strip.items
        let sessions = manager.sessions
        guard sessions.contains(where: { $0.preset.kind == .command }) else {
            onSnapshotTitles?(original.map(\.title))
            return {}
        }
        strip.items = original.map { item in
            guard let session = sessions.first(where: { $0.id == item.id }), let command = session.command else { return item }
            var redacted = item
            redacted.title = command.role == .typeIntoTerminal ? "▶ Typed" : "▶ Command"
            redacted.tooltip = ""
            return redacted
        }
        strip.layoutSubtreeIfNeeded()
        onSnapshotTitles?(strip.items.map(\.title))
        return { [weak self] in self?.strip.items = original }
    }
}

extension ConsoleView: NSMenuItemValidation {
    /// At the tab limit the presets in the chevron menu are disabled, like "+" (choosing one could only beep).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(newFromPreset(_:)) ? manager.canCreateSession : true
    }
}
