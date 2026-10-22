import AppKit
import PitboxGuard
import PitboxKit
import PitboxSessions
import PitboxShell

// What `PitboxApp` does while it runs: visibility, the console's block, rows and rail, settings in and out, ⌃⌥P,
// Accessibility.
extension PitboxApp {
    // MARK: Visibility

    /// Hands the panel's state to the parts that follow it. The block's content counts as shown while the panel is on
    /// screen and not the rail: hidden or folded, the block stops its window pass, closes its peeks and the sheet (as a
    /// Cancel), the console's drawer ends its hold, the web preview and the desk peek close. Drag-to-pit arms over the
    /// shown block and only watches drags over the rail while folded (spring-loaded unfold). Desk tags follow the panel
    /// itself: they stay while folded (folding stops nothing) and go while hidden.
    func syncVisibility() {
        guard launched, let panel, let block else { return }   // not before the launch, not during the teardown
        let visible = panel.isVisible
        let content = visible && !panel.blockLayout.showsRail
        if content != contentShown {
            contentShown = content
            block.setStripVisible(content)
            if !content {
                block.dismissOverlays()
                console?.blockHidden()
                webPreview?.close()
                deskTags?.dismissOverlays()
            }
        }
        drop?.setRailShown(visible && panel.blockLayout.showsRail && panel.rail.canUnfold)
        if visible != panelVisible {
            panelVisible = visible
            deskTags?.setStripVisible(visible)
        }
        // The menu's icon shows the edge, shown and folded: redrawn when one of them changed, not at every move of a
        // host's live width drag.
        let icon = MenuIconState(visible: visible, folded: panel.isFolded, edge: panel.settings.edge)
        if icon != menuIcon, let menu {
            menuIcon = icon
            menu.refresh()
        }
    }

    /// The block's frame (AppKit space) while it is on screen, docked the whole docked area (the host's strip and the
    /// block): where previews and the settings window sit beside.
    var blockFrameOnScreen: CGRect? {
        guard let panel, panel.isVisible, panel.frame.width > 0 else { return nil }
        return dock.dockedAreaFrame ?? panel.frame
    }

    // MARK: The console's view of the block

    /// The block is shown, or folded and able to unfold; false while hidden (by the user, or a dock host).
    var blockCanShowConsole: Bool {
        guard let panel, panel.isVisible else { return false }
        return !panel.blockLayout.showsRail || panel.rail.canUnfold
    }

    /// "Run unfolds the block": unfold in the panel's order (widen, publish the region, report the area),
    /// lay the window out, then answer on the next main-queue turn; `false` when the block cannot show its content.
    func ensureBlockShown(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let panel, blockCanShowConsole else { return done(false) }
        if panel.blockLayout.showsRail { panel.unfold() }
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let panel = self?.panel else { return done(false) }
                done(panel.isVisible && !panel.blockLayout.showsRail)
            }
        }
    }

    // MARK: Rows, rail, desk tags

    /// The block's rows from the panel's height (kept while the rail shows).
    func updateRows() {
        guard let panel, let block, !panel.blockLayout.showsRail, panel.frame.height > 0 else { return }
        let rows = BlockMetrics.rows(panelHeight: panel.frame.height, drawerHeight: panel.drawerHeight,
                                     verticalPadding: panel.verticalPadding)
        if block.rows != rows { block.rows = rows }
    }

    /// The rail's dots: the block's counts and a running command (the blue dot pulses while one runs).
    func updateRail() {
        guard let panel else { return }
        panel.rail.counts = RailCounts(needsYou: attention.needsYou, finished: attention.finished,
                                       running: attention.running, commandRunning: console?.commandRunning ?? false)
    }

    /// Feeds the desk tags after every rebuild of the block (the sessions and the desk windows the join holds).
    func feedDeskTags() {
        guard let parker, let engine, let deskTags else { return }
        let desk = parker.deskWindows.map {
            DeskTagDeskWindow(sessionID: $0.key, pid: $0.value.pid, windowNumber: $0.value.windowNumber)
        }
        deskTags.update(sessions: engine.sessions, deskWindows: desk)
    }

    // MARK: Settings in and out

    /// The panel changed a setting (fold, columns, edge, display, gaps, level): each changed key goes through the hub.
    func persist(_ changed: BlockSettings) {
        for change in SettingsBridge.changes(from: SettingsBridge.blockSettings(settings), to: changed) { write(change) }
    }

    /// Writes one change through the hub (which applies it before returning). A failure beeps and logs a label.
    @discardableResult
    func write(_ change: CodeSettings.MenuChange) -> Bool {
        guard let hub else { return false }
        switch hub.write(change) {
        case .success:
            return true
        case .failure(let failure):
            Log.warn("settings: not written (\(failure.message))", "settings")
            NSSound.beep()
            return false
        }
    }

    /// The settings in force changed (an app write or a hand edit; the hub has deduplicated it and the box already holds
    /// `new`): each part gets what concerns it (the block, and through it drag-to-pit and the engine, and the desk tags
    /// only when their keys changed; the console when its keys changed; the hotkeys when their text changed; the dock
    /// link when `dock` changed: on/off opens or closes it); the panel, the login item (a hand edit of
    /// `launchAtLogin`), the settings window and the menu follow.
    func apply(old: CodeSettings, new: CodeSettings) {
        if SettingsBridge.sessionsPart(new) != SettingsBridge.sessionsPart(old) {
            block?.update(settings: new)
            deskTags?.update(settings: new)
            if new.focusProfiles != old.focusProfiles { dock.focusProfilesChanged() }
        }
        if new.dock != old.dock { dock.settingsChanged(new.dock) }
        if SettingsBridge.consolePart(new) != SettingsBridge.consolePart(old) { console?.update(settings: new) }
        if new.hotkeys != old.hotkeys { hotkeyBinder?.apply(new.hotkeys) }
        var block = SettingsBridge.blockSettings(new)
        // A host's fold that is shown but not yet written stays shown, unless the file's own `folded` changed.
        if dock.foldWritePending, new.folded == old.folded, let panel { block.folded = panel.isFolded }
        panel?.apply(block)
        if new.launchAtLogin != old.launchAtLogin { reconcileLoginItem(new.launchAtLogin) }
        settingsWindow?.model.update(settings: new)
        menu?.refresh()
    }

    // MARK: Launch at Login

    /// The menu's "Launch at Login": the file is written, and the system's login item is made to match right away, also
    /// when the file already said so (it may have been removed in System Settings), so the click never does nothing.
    func setLaunchAtLogin(_ on: Bool) {
        let fileSaid = settings.launchAtLogin
        guard write(.launchAtLogin(on)) else { return }
        // A changed value was reconciled by `apply`; an unchanged one is reconciled here.
        if fileSaid == on { reconcileLoginItem(on) }
        menu?.refresh()
    }

    /// Makes the system's login item match `wanted` and keeps the state it reports.
    func reconcileLoginItem(_ wanted: Bool) {
        loginStatus = loginItem.reconcile(wanted)
        loginStatusReadAt = MonotonicClock.now()
    }

    /// The menu is about to open: failed hotkeys are retried; the login item's state is read again at most once a
    /// second, and the displays once per opening.
    func menuWillOpen() {
        hotkeys?.retryFailed()
        let now = MonotonicClock.now()
        if loginStatus == nil || now - loginStatusReadAt >= 1 {
            loginStatus = loginItem.status()
            loginStatusReadAt = now
        }
        menuDisplays = BlockDisplay.current().map { MenuDisplay(uuid: $0.uuid, name: $0.name) }
    }

    // MARK: Actions

    /// ⌃⌥P and the menu's "Pit front window": pits the front Claude pop-out. A refusal beeps and logs a label (never a
    /// title). Never runs or confirms anything.
    func pitFrontWindow() {
        Task { @MainActor [weak self] in
            guard let block = self?.block else { return }
            let result = await block.parkFrontmostPopout()
            if !result.succeeded {
                NSSound.beep()
                Log.info("park hotkey: \(AppWords.parkLabel(result))", "app")
            }
        }
    }

    /// "Settings…": the window beside the block, never taking the keyboard on its own.
    func openSettings() {
        guard let settingsWindow else { return }
        settingsWindow.model.update(settings: settings)
        settingsWindow.show(avoiding: blockFrameOnScreen)
    }

    // MARK: Accessibility

    /// The guard's status changed: the menu follows, and a fresh Accessibility grant starts the window features.
    func guardStatusChanged(_ status: GuardStatus) {
        noteTrust(status.trusted)
        menu?.refresh()
    }

    /// Accessibility as seen now (the guard's status or the onboarding): a change to granted starts every AX feature.
    func noteTrust(_ trusted: Bool) {
        guard trusted != wasTrusted else { return }
        wasTrusted = trusted
        if trusted { accessibilityGranted() }
    }

    /// Each Accessibility feature starts when the grant arrives: the guard, drag-to-pit's observer, the desk tags; the
    /// parker checks the grant at every pass. Without it the monitors and the Ready list work from Claude's files.
    func accessibilityGranted() {
        Log.info("accessibility granted: window features start", "app")
        windowGuard?.start()
        drop?.refresh()
        deskTags?.update(settings: settings)
        engine?.refresh()
        menu?.refresh()
    }
}
