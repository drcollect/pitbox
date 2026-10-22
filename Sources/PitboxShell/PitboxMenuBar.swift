import AppKit
import PitboxKit

/// The menu bar status item and its menu, built from `PitboxMenuState` and `PitboxMenuActions` each time it
/// opens, so it never holds stale state and imports nothing of the sessions, the console, the guard or the dock link:
///
/// Show / Hide · Fold / Unfold (⌃⌥C) · Columns ▸ 2 · 1 · Edge ▸ Right · Left (alone only) · Display ▸ … · Keep Above
/// Windows · Top Gap ▸ · Bottom Gap ▸ (alone only) · Hide text · Pit front window (⌃⌥P) · Pit all done · All back on
/// track · Window guard: on / paused · Dock with <host> (and its state line) · Grant Accessibility… · Settings… · Show
/// the settings file · Launch at Login · About Pitbox · Quit Pitbox.
///
/// A shortcut that could not be registered says so under its item ("⌃⌥P is taken by another app") instead of sharing
/// the keys silently.
@MainActor
public final class PitboxMenuBar: NSObject, NSMenuDelegate {
    /// The hotkey ids the menu shows next to "Pit front window" and "Fold".
    public static let parkHotkeyID = "park"
    public static let foldHotkeyID = "fold"
    /// Top and bottom gap suggestions in points (0 is "None").
    public static let gapPresets: [Double] = [0, 100, 200, 300, 400]

    /// Read each time the menu opens and on `refresh()`.
    public var state: () -> PitboxMenuState
    /// What the items do.
    public var actions: PitboxMenuActions
    /// Called when the menu is about to open, before `state` is read (for example `hotkeys.retryFailed()`).
    public var onWillOpen: (() -> Void)?

    private var statusItem: NSStatusItem?
    /// The words `refresh()` last gave the status item (kept without an installed item too, for tests).
    private(set) var iconDescription = AppIdentity.displayName

    /// `actions` nil: the defaults (About, Quit, Login Items and Show the settings file work; the rest do nothing).
    public init(state: @escaping () -> PitboxMenuState, actions: PitboxMenuActions? = nil) {
        self.state = state
        self.actions = actions ?? PitboxMenuActions()
        super.init()
    }

    /// Adds the status item to the menu bar.
    public func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = Self.menu(AppIdentity.displayName)
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refresh()
    }

    /// Removes the status item.
    public func uninstall() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    /// Updates the icon (edge and fold) and its words. The menu itself is rebuilt when it opens.
    public func refresh() {
        let s = state()
        let description = PitboxMenuIcon.description(shown: s.isVisible, folded: s.isFolded)
        iconDescription = description
        guard let button = statusItem?.button else { return }
        button.image = PitboxMenuIcon.image(edge: s.edge, folded: s.isFolded, description: description)
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    // MARK: NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        onWillOpen?()
        menu.removeAllItems()
        for item in makeItems(state()) { menu.addItem(item) }
        refresh()
    }

    /// The menu as it would open now (tests read it without showing it).
    public func buildMenu() -> NSMenu {
        let menu = Self.menu(AppIdentity.displayName)
        for item in makeItems(state()) { menu.addItem(item) }
        return menu
    }

    // MARK: Items

    private func makeItems(_ s: PitboxMenuState) -> [NSMenuItem] {
        let a = actions
        let name = AppIdentity.displayName
        var items: [NSMenuItem] = []

        let show = Self.item(s.isVisible ? "Hide \(name)" : "Show \(name)") { a.toggleShown() }
        if !s.isVisible, s.hiddenByHost {
            show.subtitle = "Hidden with \(s.hostDisplayName); shows it alone at the screen edge"
        }
        items.append(show)
        // ⌃⌥C shows an off-screen block unfolded, so the item stays enabled and says so.
        let foldTitle = s.isVisible ? (s.isFolded ? "Unfold" : "Fold") : "Show Unfolded"
        let fold = Self.item(foldTitle) { a.toggleFold() }
        applyHotkey(Self.foldHotkeyID, to: fold, s)
        items.append(fold)
        items.append(.separator())

        let columns = Self.menu("Columns")
        for n in [2, 1] {
            columns.addItem(Self.item("\(n)", state: s.columns == n ? .on : .off) { a.setColumns(n) })
        }
        items.append(Self.submenu("Columns", columns))
        if !s.isDocked {
            let edges = Self.menu("Edge")
            for edge in [Edge.right, .left] {
                edges.addItem(Self.item(edge == .right ? "Right" : "Left", state: s.edge == edge ? .on : .off) {
                    a.setEdge(edge)
                })
            }
            items.append(Self.submenu("Edge", edges))
        }
        let display = Self.submenu("Display", displayMenu(s))
        let above = Self.item("Keep Above Windows", state: s.keepAboveWindows ? .on : .off) {
            a.setKeepAboveWindows(!s.keepAboveWindows)
        }
        if s.isDocked {
            // The host's display and level win while docked: show them, not editable.
            display.isEnabled = false
            display.subtitle = s.dockedDisplayUUID.flatMap { uuid in
                s.displays.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
            }.map { "\(MenuText.oneLine($0.name, maxLength: 60)), the host's display" } ?? "The host's display"
            above.isEnabled = false
            above.state = s.dockedAboveWindows ? .on : .off
            above.subtitle = "The host's level while docked"
        }
        items.append(display)
        items.append(above)
        if !s.isDocked {
            items.append(Self.submenu("Top Gap", gapMenu("Top Gap", current: s.topGap) { a.setTopGap($0) }))
            items.append(Self.submenu("Bottom Gap", gapMenu("Bottom Gap", current: s.bottomGap) { a.setBottomGap($0) }))
        }
        items.append(.separator())

        items.append(Self.item("Hide text", state: s.hideText ? .on : .off) { a.setHideText(!s.hideText) })
        let pit = Self.item("Pit front window") { a.pitFrontWindow() }
        applyHotkey(Self.parkHotkeyID, to: pit, s)
        items.append(pit)
        items.append(Self.item(s.doneOnTrack > 0 ? "Pit all done (\(s.doneOnTrack))" : "Pit all done",
                               enabled: s.doneOnTrack > 0) { a.pitAllDone() })
        items.append(Self.item(s.inThePit > 0 ? "All back on track (\(s.inThePit))" : "All back on track",
                               enabled: s.inThePit > 0) { a.allBackOnTrack() })
        items.append(.separator())

        items.append(guardItem(s))
        items.append(Self.item("Dock with \(s.hostDisplayName)", state: s.dockEnabled ? .on : .off) {
            a.setDockEnabled(!s.dockEnabled)
        })
        let dockLine = MenuText.oneLine(s.dockStatus)
        if !dockLine.isEmpty {
            let line = Self.line(dockLine)
            line.indentationLevel = 1
            items.append(line)
        }
        items.append(.separator())

        if !s.accessibilityGranted { items.append(Self.item("Grant Accessibility…") { a.grantAccessibility() }) }
        let settings = Self.item("Settings…") { a.openSettings() }
        settings.keyEquivalent = ","
        items.append(settings)
        items.append(Self.item("Show the settings file") { a.showSettingsFile() })
        items.append(loginItem(s))
        items.append(.separator())

        let version = s.version
        items.append(Self.item("About \(name)") { a.about(version) })
        let quit = Self.item("Quit \(name)") { a.quit() }
        quit.keyEquivalent = "q"
        items.append(quit)
        return items
    }

    /// "Main display", then each connected display by name (a tick on the remembered one). A remembered display that is
    /// not connected gets a disabled, ticked line: the block uses the main display until it comes back.
    private func displayMenu(_ s: PitboxMenuState) -> NSMenu {
        let a = actions
        let menu = Self.menu("Display")
        let main = BlockDisplay.meansMain(s.displayUUID)
        menu.addItem(Self.item("Main display", state: main ? .on : .off) { a.setDisplay(nil) })
        var matched = main
        var seen: [String: Int] = [:]
        for display in s.displays where !display.uuid.isEmpty {
            var title = MenuText.oneLine(display.name, maxLength: 60)
            if title.isEmpty { title = "Display" }
            let count = (seen[title] ?? 0) + 1
            seen[title] = count
            if count > 1 { title += " (\(count))" }
            let on = !main && display.uuid.caseInsensitiveCompare(s.displayUUID ?? "") == .orderedSame
            if on { matched = true }
            let uuid = display.uuid
            menu.addItem(Self.item(title, state: on ? .on : .off) { a.setDisplay(uuid) })
        }
        if !matched {
            let line = Self.line("A display that is not connected (main display meanwhile)")
            line.state = .on
            menu.addItem(line)
        }
        return menu
    }

    /// One item per preset (0 is "None"), a tick on the current value, or a disabled "Custom: N pt" line for a value
    /// that is not a preset (a hand-edited file).
    private func gapMenu(_ title: String, current: Double, choose: @escaping @MainActor (Double) -> Void) -> NSMenu {
        let menu = Self.menu(title)
        let value = BlockGeometry.clampedGap(current)
        var matched = false
        for preset in Self.gapPresets {
            let on = abs(preset - value) < 0.5
            if on { matched = true }
            menu.addItem(Self.item(preset == 0 ? "None" : "\(Int(preset)) pt", state: on ? .on : .off) { choose(preset) })
        }
        if !matched {
            let line = Self.line("Custom: \(Int(value.rounded())) pt")
            line.state = .on
            menu.addItem(line)
        }
        return menu
    }

    private func guardItem(_ s: PitboxMenuState) -> NSMenuItem {
        let detail = s.guardDetail.map { MenuText.oneLine($0, maxLength: 60) }.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        let a = actions
        switch s.guardState {
        case .on:
            let item = Self.item("Window guard: on\(detail)", state: .on) { a.setGuardPaused(true) }
            item.toolTip = "Click to pause the window guard"
            return item
        case .paused:
            let item = Self.item("Window guard: paused\(detail)") { a.setGuardPaused(false) }
            item.toolTip = "Click to turn the window guard back on"
            return item
        case .needsAccessibility:
            return Self.line("Window guard: needs Accessibility")
        case .off:
            return Self.line("Window guard: off\(detail)")
        }
    }

    private func loginItem(_ s: PitboxMenuState) -> NSMenuItem {
        let a = actions
        switch s.launchAtLogin {
        case .enabled, .disabled:
            let on = s.launchAtLogin == .enabled
            return Self.item("Launch at Login", state: on ? .on : .off) { a.setLaunchAtLogin(!on) }
        case .requiresApproval:
            let item = Self.item("Launch at Login: approve in System Settings…") { a.openLoginItemsSettings() }
            item.state = .mixed
            return item
        case .unavailable(let why):
            return Self.line("Launch at Login (\(MenuText.oneLine(why, maxLength: 60)))")
        }
    }

    // MARK: Shortcuts

    /// Shows the registered shortcut on the item, or why there is none under it: "⌃⌥P is taken by another app",
    /// "⌃⌥P unavailable: …", or a macOS shortcut on the same keys.
    private func applyHotkey(_ id: String, to item: NSMenuItem, _ s: PitboxMenuState) {
        guard let registration = s.hotkeys[id] else { return }
        switch registration.result {
        case .success(let combo):
            Self.setKeyEquivalent(combo, on: item)
            if let warning = registration.warning { item.subtitle = MenuText.oneLine(warning) }
        case .failure(let error):
            let keys = (try? KeyCombo.parse(registration.spec).get())?.description
                ?? MenuText.oneLine(registration.spec, maxLength: 30)
            item.subtitle = error.isTakenByAnotherApp ? "\(keys) is taken by another app" : "\(keys) unavailable: \(error)"
        }
    }

    /// Displays a combo as the item's key equivalent (display only; the hotkey itself is global).
    static func setKeyEquivalent(_ combo: KeyCombo, on item: NSMenuItem) {
        switch combo.key {
        case .character(let c): item.keyEquivalent = c
        case .named(let named):
            guard let scalar = functionKeyScalar(named) else { return }
            item.keyEquivalent = String(Character(scalar))
        }
        item.keyEquivalentModifierMask = combo.modifierFlags
    }

    private static func functionKeyScalar(_ key: NamedKey) -> Unicode.Scalar? {
        let value: Int
        switch key {
        case .space: return " "
        case .return: return "\r"
        case .tab: return "\t"
        case .escape: return "\u{1B}"
        case .delete: return "\u{8}"
        case .forwardDelete: value = NSDeleteFunctionKey
        case .left: value = NSLeftArrowFunctionKey
        case .right: value = NSRightArrowFunctionKey
        case .up: value = NSUpArrowFunctionKey
        case .down: value = NSDownArrowFunctionKey
        case .home: value = NSHomeFunctionKey
        case .end: value = NSEndFunctionKey
        case .pageUp: value = NSPageUpFunctionKey
        case .pageDown: value = NSPageDownFunctionKey
        default:
            guard key.isFunctionKey, let n = Int(key.rawValue.dropFirst()) else { return nil }
            value = NSF1FunctionKey + n - 1
        }
        return Unicode.Scalar(value)
    }

    // MARK: Builders

    /// A menu that keeps the enabled states the builder sets (no automatic validation).
    static func menu(_ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        return menu
    }

    static func item(_ title: String, enabled: Bool = true, state: NSControl.StateValue = .off,
                     _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let handler = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
        item.target = handler
        item.representedObject = handler   // the target is weak; this keeps the handler alive
        item.isEnabled = enabled
        item.state = state
        return item
    }

    static func line(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// A menu item's closure, as its target.
@MainActor
final class MenuAction: NSObject {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init()
    }

    @objc func fire(_ sender: Any?) { run() }
}
