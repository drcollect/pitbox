import AppKit
import PitboxGuard
import PitboxKit
import PitboxSessions
import PitboxShell

// The status menu's state and actions. `PitboxMenuBar` reads the state when the menu opens and on every
// `refresh()` (for the icon); the slow parts (the login item, the displays) are read in `menuWillOpen()` only.
extension PitboxApp {
    /// Everything the menu shows, from the panel, the block, the guard, the settings and the hotkeys.
    func menuState() -> PitboxMenuState {
        var s = PitboxMenuState()
        guard let panel else { return s }
        s.isVisible = panel.isVisible
        s.hiddenByHost = panel.isHiddenByHost
        s.isFolded = panel.isFolded
        s.columns = panel.settings.columns
        s.isDocked = panel.isDockedNow
        s.dockedAboveWindows = panel.level.isAboveNormalWindows
        s.dockedDisplayUUID = panel.displayID.flatMap { BlockDisplay.uuid(of: $0) }
        s.edge = panel.settings.edge
        s.displays = menuDisplays ?? []
        s.displayUUID = panel.settings.displayUUID
        s.keepAboveWindows = panel.settings.keepAboveWindows
        s.topGap = panel.settings.topGap
        s.bottomGap = panel.settings.bottomGap
        if let block {
            s.hideText = block.hideText
            s.doneOnTrack = block.pitAllDoneCount
            s.inThePit = block.inThePitCount
        }
        let guardMenu = AppWords.guardMenu(windowGuard?.status)
        s.guardState = guardMenu.state
        s.guardDetail = guardMenu.detail
        s.dockEnabled = settings.dock.enabled
        s.hostName = dock.hostName                         // from the host's hello; the menu says "the host app" before
        s.dockStatus = dock.menuLine
        s.accessibilityGranted = windowGuard?.isAccessibilityTrusted ?? false
        s.launchAtLogin = loginStatus ?? .disabled
        s.hotkeys = hotkeys?.registrations ?? [:]
        return s
    }

    /// What each item does.
    func menuActions() -> PitboxMenuActions {
        var a = PitboxMenuActions()
        a.toggleShown = { [weak self] in self?.panel?.toggle() }
        a.toggleFold = { [weak self] in self?.panel?.toggleFold() }
        a.setColumns = { [weak self] columns in self?.panel?.setColumns(columns) }
        a.setEdge = { [weak self] edge in self?.panel?.setEdge(edge) }
        a.setDisplay = { [weak self] uuid in self?.panel?.setDisplay(uuid: uuid) }
        a.setKeepAboveWindows = { [weak self] above in self?.panel?.setKeepAboveWindows(above) }
        a.setTopGap = { [weak self] points in self?.panel?.setGaps(top: points) }
        a.setBottomGap = { [weak self] points in self?.panel?.setGaps(bottom: points) }
        a.setHideText = { [weak self] hidden in self?.block?.setHideText(hidden) }
        a.pitFrontWindow = { [weak self] in self?.pitFrontWindow() }
        a.pitAllDone = { [weak self] in self?.block?.pitAllDone() }
        a.allBackOnTrack = { [weak self] in self?.block?.allBackOnTrack() }
        a.setGuardPaused = { [weak self] paused in
            self?.windowGuard?.setPaused(paused)
            self?.menu?.refresh()
        }
        // The tick writes `dock.enabled`; the hub's change opens or closes the link (`apply` → `DockWiring`).
        a.setDockEnabled = { [weak self] enabled in self?.write(.dockEnabled(enabled)) }
        a.grantAccessibility = { [weak self] in
            self?.windowGuard?.requestAccessibilityPrompt()   // the macOS dialog: lists the app with its signature
            self?.onboarding?.show()
        }
        a.openSettings = { [weak self] in self?.openSettings() }
        a.setLaunchAtLogin = { [weak self] on in self?.setLaunchAtLogin(on) }
        return a
    }
}
