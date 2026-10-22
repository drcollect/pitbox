import AppKit
import Carbon.HIToolbox
import Testing
import PitboxKit
@testable import PitboxShell

/// The status menu as built, never shown: titles, order, enabled states, ticks, the items hidden while docked, the
/// hotkey lines and the actions.
@Suite @MainActor struct PitboxMenuBarTests {
    private static func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private static func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    private func aloneState() -> PitboxMenuState {
        var s = PitboxMenuState()
        s.isVisible = true
        s.displays = [MenuDisplay(uuid: "AAAA-NOTEBOOK", name: "Built-in Display"),
                      MenuDisplay(uuid: "BBBB-ULTRAWIDE", name: "Acme Ultrawide")]
        s.doneOnTrack = 3
        s.inThePit = 2
        s.guardState = .on
        s.dockStatus = "Not connected"
        s.launchAtLogin = .disabled
        s.version = "1.0 (7)"
        return s
    }

    @Test func aloneMenuInTheSpecOrder() {
        let bar = PitboxMenuBar(state: { self.aloneState() })
        let menu = bar.buildMenu()
        #expect(Self.titles(menu) == [
            "Hide Pitbox", "Fold", "-",
            "Columns", "Edge", "Display", "Keep Above Windows", "Top Gap", "Bottom Gap", "-",
            "Hide text", "Pit front window", "Pit all done (3)", "All back on track (2)", "-",
            "Window guard: on", "Dock with the host app", "Not connected", "-",
            "Grant Accessibility…", "Settings…", "Show the settings file", "Launch at Login", "-",
            "About Pitbox", "Quit Pitbox",
        ])
        #expect(!menu.autoenablesItems)
        #expect(Self.item(menu, "Fold")?.isEnabled == true)
        #expect(Self.item(menu, "Keep Above Windows")?.state == .on)
        #expect(Self.item(menu, "Hide text")?.state == .off)
        #expect(Self.item(menu, "Window guard: on")?.state == .on)
        #expect(Self.item(menu, "Dock with the host app")?.state == .on)
        let dockLine = Self.item(menu, "Not connected")
        #expect(dockLine?.isEnabled == false && dockLine?.indentationLevel == 1)
        #expect(Self.item(menu, "Pit all done (3)")?.isEnabled == true)
        #expect(Self.item(menu, "Quit Pitbox")?.keyEquivalent == "q")
        #expect(Self.item(menu, "Settings…")?.keyEquivalent == ",")
        // Submenus.
        #expect(Self.titles(Self.item(menu, "Columns")?.submenu ?? NSMenu()) == ["2", "1"])
        #expect(Self.item(menu, "Columns")?.submenu?.items.map(\.state) == [.on, .off])
        #expect(Self.titles(Self.item(menu, "Edge")?.submenu ?? NSMenu()) == ["Right", "Left"])
        #expect(Self.item(menu, "Edge")?.submenu?.items.map(\.state) == [.on, .off])
        #expect(Self.titles(Self.item(menu, "Display")?.submenu ?? NSMenu())
            == ["Main display", "Built-in Display", "Acme Ultrawide"])
        #expect(Self.item(menu, "Display")?.submenu?.items.first?.state == .on)
        #expect(Self.titles(Self.item(menu, "Top Gap")?.submenu ?? NSMenu()) == ["None", "100 pt", "200 pt", "300 pt", "400 pt"])
        #expect(Self.item(menu, "Top Gap")?.submenu?.items.first?.state == .on)
    }

    @Test func dockedHidesEdgeAndGapsAndNamesTheHost() {
        var s = aloneState()
        s.isDocked = true
        s.hostName = "Desk\nHost\u{200B} App"
        s.dockStatus = "Docked"
        s.accessibilityGranted = true
        s.isFolded = true
        let menu = PitboxMenuBar(state: { s }).buildMenu()
        let titles = Self.titles(menu)
        for hidden in ["Edge", "Top Gap", "Bottom Gap", "Grant Accessibility…"] {
            #expect(!titles.contains(hidden), "\(hidden) is hidden")
        }
        #expect(titles.contains("Display") && titles.contains("Keep Above Windows"))
        // The host's display and level win: shown, not editable.
        let display = Self.item(menu, "Display")
        #expect(display?.isEnabled == false && display?.subtitle == "The host's display")
        let above = Self.item(menu, "Keep Above Windows")
        #expect(above?.isEnabled == false && above?.state == .on && above?.subtitle == "The host's level while docked")
        s.dockedDisplayUUID = "bbbb-ultrawide"
        s.dockedAboveWindows = false
        s.keepAboveWindows = true
        let named = PitboxMenuBar(state: { s }).buildMenu()
        #expect(Self.item(named, "Display")?.subtitle == "Acme Ultrawide, the host's display")
        #expect(Self.item(named, "Keep Above Windows")?.state == .off, "the host's level, not the alone setting")
        #expect(titles.contains("Dock with Desk Host App"), "one clean line from the handshake's name")
        #expect(titles.contains("Docked"))
        #expect(titles.contains("Unfold"))
        // A very long host name is cut.
        s.hostName = String(repeating: "x", count: 300)
        let long = PitboxMenuBar(state: { s }).buildMenu()
        #expect(long.items.contains { $0.title.hasPrefix("Dock with ") && $0.title.count <= "Dock with ".count + 40 })
    }

    @Test func hiddenBlockAndEmptyCounts() {
        var s = PitboxMenuState()
        s.isVisible = false
        s.guardState = .needsAccessibility
        let menu = PitboxMenuBar(state: { s }).buildMenu()
        #expect(Self.item(menu, "Show Pitbox") != nil)
        #expect(Self.item(menu, "Show Unfolded")?.isEnabled == true, "⌃⌥C shows a hidden block unfolded")
        #expect(Self.item(menu, "Show Pitbox")?.subtitle == nil)
        #expect(Self.item(menu, "Pit all done")?.isEnabled == false)
        #expect(Self.item(menu, "All back on track")?.isEnabled == false)
        #expect(Self.item(menu, "Window guard: needs Accessibility")?.isEnabled == false)
        #expect(!Self.titles(menu).contains("Not connected") && !Self.titles(menu).contains(""), "no empty dock line")
        s.guardState = .paused
        s.guardDetail = "3 windows kept clear"
        let paused = PitboxMenuBar(state: { s }).buildMenu()
        #expect(Self.item(paused, "Window guard: paused (3 windows kept clear)")?.state == .off)
        s.guardState = .off
        #expect(Self.item(PitboxMenuBar(state: { s }).buildMenu(), "Window guard: off (3 windows kept clear)")?.isEnabled
            == false)
    }

    @Test func takenAndRegisteredHotkeysShowNextToTheirItems() throws {
        var s = aloneState()
        let fold = try #require(try? KeyCombo.parse("ctrl+opt+c").get())
        s.hotkeys = [
            PitboxMenuBar.parkHotkeyID: HotkeyManager.Registration(
                id: "park", spec: "ctrl+opt+p", result: .failure(.registrationFailed(Int32(eventHotKeyExistsErr))),
                warning: nil),
            PitboxMenuBar.foldHotkeyID: HotkeyManager.Registration(id: "fold", spec: "ctrl+opt+c", result: .success(fold),
                                                                   warning: nil),
        ]
        let menu = PitboxMenuBar(state: { s }).buildMenu()
        let pit = try #require(Self.item(menu, "Pit front window"))
        #expect(pit.subtitle == "⌃⌥P is taken by another app")
        #expect(pit.keyEquivalent.isEmpty, "a taken key is not shown as the item's shortcut")
        let foldItem = try #require(Self.item(menu, "Fold"))
        #expect(foldItem.keyEquivalent == "c")
        #expect(foldItem.keyEquivalentModifierMask == [.control, .option])
        #expect(foldItem.subtitle == nil)
        // Other failures and macOS clashes say what they are.
        s.hotkeys[PitboxMenuBar.parkHotkeyID] = HotkeyManager.Registration(
            id: "park", spec: "ctrl+opt+ü", result: .failure(.notOnKeyboard("ü")), warning: nil)
        s.hotkeys[PitboxMenuBar.foldHotkeyID] = HotkeyManager.Registration(
            id: "fold", spec: "ctrl+opt+c", result: .success(fold), warning: "⌃⌥C is also the macOS shortcut “X”")
        let other = PitboxMenuBar(state: { s }).buildMenu()
        #expect(Self.item(other, "Pit front window")?.subtitle == "⌃⌥Ü unavailable: 'ü' is not on the current keyboard layout")
        #expect(Self.item(other, "Fold")?.subtitle == "⌃⌥C is also the macOS shortcut “X”")
        // Function keys render as their key equivalents.
        let f15 = try #require(try? KeyCombo.parse("hyper+f15").get())
        let item = NSMenuItem()
        PitboxMenuBar.setKeyEquivalent(f15, on: item)
        #expect(item.keyEquivalent == String(Character(Unicode.Scalar(NSF15FunctionKey)!)))
        #expect(item.keyEquivalentModifierMask == [.control, .option, .shift, .command])
    }

    /// Shown but hidden by the host: the first item offers Show (alone at the edge), never Hide.
    @Test func hiddenByTheHostOffersShowAlone() {
        var s = aloneState()
        s.isVisible = false
        s.hiddenByHost = true
        s.isDocked = true
        s.hostName = "Desk"
        let menu = PitboxMenuBar(state: { s }).buildMenu()
        #expect(Self.titles(menu).first == "Show Pitbox")
        #expect(Self.item(menu, "Show Pitbox")?.subtitle == "Hidden with Desk; shows it alone at the screen edge")
        #expect(Self.item(menu, "Show Unfolded")?.isEnabled == true)
        #expect(!Self.titles(menu).contains("Hide Pitbox"))
    }

    @Test func displayAndGapSubmenusMarkWhatIsInForce() {
        var s = aloneState()
        s.displayUUID = "bbbb-ultrawide"
        s.topGap = 130
        s.displays.append(MenuDisplay(uuid: "EEEE", name: "Acme Ultrawide"))
        let menu = PitboxMenuBar(state: { s }).buildMenu()
        let displays = Self.item(menu, "Display")?.submenu
        #expect(displays.map(Self.titles) == ["Main display", "Built-in Display", "Acme Ultrawide", "Acme Ultrawide (2)"])
        #expect(displays?.items.map(\.state) == [.off, .off, .on, .off])
        let top = Self.item(menu, "Top Gap")?.submenu
        #expect(top?.items.last?.title == "Custom: 130 pt")
        #expect(top?.items.last?.state == .on && top?.items.last?.isEnabled == false)
        // A remembered display that is not connected.
        s.displayUUID = "GONE"
        let gone = Self.item(PitboxMenuBar(state: { s }).buildMenu(), "Display")?.submenu
        #expect(gone?.items.last?.title == "A display that is not connected (main display meanwhile)")
        #expect(gone?.items.last?.state == .on && gone?.items.last?.isEnabled == false)
        #expect(gone?.items.first?.state == .off)
    }

    @Test func loginItemStates() {
        var s = aloneState()
        s.launchAtLogin = .enabled
        #expect(Self.item(PitboxMenuBar(state: { s }).buildMenu(), "Launch at Login")?.state == .on)
        s.launchAtLogin = .requiresApproval
        let approve = Self.item(PitboxMenuBar(state: { s }).buildMenu(), "Launch at Login: approve in System Settings…")
        #expect(approve?.state == .mixed && approve?.isEnabled == true)
        s.launchAtLogin = .unavailable("not running from an app bundle")
        let off = Self.item(PitboxMenuBar(state: { s }).buildMenu(), "Launch at Login (not running from an app bundle)")
        #expect(off?.isEnabled == false)
    }

    @Test func itemsCallTheirActions() throws {
        // `performActionForItem` sends each action through the application object. Without one (no other test of
        // this process made it yet), every click is lost and the log stays empty: the old flake, which depended on
        // which suite ran first. The app has one, so the test makes sure it exists too.
        _ = NSApplication.shared
        var log: [String] = []
        var actions = PitboxMenuActions()
        actions.toggleShown = { log.append("shown") }
        actions.toggleFold = { log.append("fold") }
        actions.setColumns = { log.append("columns \($0)") }
        actions.setEdge = { log.append("edge \($0.rawValue)") }
        actions.setDisplay = { log.append("display \($0 ?? "main")") }
        actions.setKeepAboveWindows = { log.append("above \($0)") }
        actions.setTopGap = { log.append("top \($0)") }
        actions.setBottomGap = { log.append("bottom \($0)") }
        actions.setHideText = { log.append("hide text \($0)") }
        actions.pitFrontWindow = { log.append("pit") }
        actions.pitAllDone = { log.append("pit all") }
        actions.allBackOnTrack = { log.append("back") }
        actions.setGuardPaused = { log.append("guard paused \($0)") }
        actions.setDockEnabled = { log.append("dock \($0)") }
        actions.grantAccessibility = { log.append("grant") }
        actions.openSettings = { log.append("settings") }
        actions.showSettingsFile = { log.append("file") }
        actions.setLaunchAtLogin = { log.append("login \($0)") }
        actions.about = { log.append("about \($0)") }
        actions.quit = { log.append("quit") }
        let bar = PitboxMenuBar(state: { self.aloneState() }, actions: actions)
        let menu = bar.buildMenu()
        func click(_ title: String, in menu: NSMenu) throws {
            let index = menu.indexOfItem(withTitle: title)
            try #require(index >= 0, "\(title)")
            menu.performActionForItem(at: index)
        }
        for title in ["Hide Pitbox", "Fold", "Keep Above Windows", "Hide text", "Pit front window", "Pit all done (3)",
                      "All back on track (2)", "Window guard: on", "Dock with the host app", "Grant Accessibility…",
                      "Settings…", "Show the settings file", "Launch at Login", "About Pitbox", "Quit Pitbox"] {
            try click(title, in: menu)
        }
        try click("1", in: try #require(Self.item(menu, "Columns")?.submenu))
        try click("Left", in: try #require(Self.item(menu, "Edge")?.submenu))
        try click("Acme Ultrawide", in: try #require(Self.item(menu, "Display")?.submenu))
        try click("Main display", in: try #require(Self.item(menu, "Display")?.submenu))
        try click("200 pt", in: try #require(Self.item(menu, "Top Gap")?.submenu))
        try click("None", in: try #require(Self.item(menu, "Bottom Gap")?.submenu))
        #expect(log == ["shown", "fold", "above false", "hide text true", "pit", "pit all", "back", "guard paused true",
                        "dock false", "grant", "settings", "file", "login true", "about 1.0 (7)", "quit",
                        "columns 1", "edge left", "display BBBB-ULTRAWIDE", "display main", "top 200.0", "bottom 0.0"])
    }

    @Test func willOpenRunsBeforeTheStateIsRead() {
        var order: [String] = []
        let bar = PitboxMenuBar(state: {
            order.append("state")
            return PitboxMenuState()
        })
        bar.onWillOpen = { order.append("will open") }
        let menu = NSMenu()
        bar.menuNeedsUpdate(menu)
        #expect(order.prefix(2) == ["will open", "state"])
        #expect(menu.items.count > 10)
    }

    @Test func iconIsATemplateDrawnForTheEdge() throws {
        let image = PitboxMenuIcon.image(edge: .right, folded: false, description: "Pitbox")
        #expect(image.isTemplate && image.size == NSSize(width: 18, height: 16))
        #expect(image.accessibilityDescription == "Pitbox")
        func alpha(edge: Edge, folded: Bool, x: Int, y: Int) throws -> CGFloat {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 16, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            PitboxMenuIcon.draw(in: CGRect(x: 0, y: 0, width: 18, height: 16), edge: edge, folded: folded)
            NSGraphicsContext.restoreGraphicsState()
            return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
        }
        #expect(try alpha(edge: .right, folded: false, x: 12, y: 8) > 0.5, "columns at the right")
        #expect(try alpha(edge: .right, folded: false, x: 5, y: 8) < 0.1)
        #expect(try alpha(edge: .left, folded: false, x: 5, y: 8) > 0.5, "columns at the left")
        #expect(try alpha(edge: .left, folded: false, x: 12, y: 8) < 0.1)
        #expect(try alpha(edge: .right, folded: true, x: 10, y: 8) < 0.1, "folded: only the thin rail")
        #expect(try alpha(edge: .right, folded: true, x: 13, y: 8) > 0.5)
        #expect(PitboxMenuIcon.description(shown: true, folded: true) == "Pitbox, folded")
        #expect(PitboxMenuIcon.description(shown: false, folded: false) == "Pitbox, hidden")
        let bar = PitboxMenuBar(state: { PitboxMenuState() })
        bar.refresh()
        #expect(bar.iconDescription == "Pitbox, hidden")
    }

    @Test func aboutCarriesTheVersionAndThePrivacyParagraph() throws {
        let options = AboutPanel.options(version: "1.0 (7)")
        #expect(options[.applicationName] as? String == "Pitbox")
        #expect(options[.applicationVersion] as? String == "1.0 (7)")
        let credits = try #require(options[.credits] as? NSAttributedString)
        #expect(credits.string == AboutPanel.privacyParagraph)
        for phrase in ["Nothing leaves your Mac: no telemetry, no update check, no AI.", "it runs none of them",
                       "Pitbox reads all this only to show you status", "\"status unknown\"",
                       "the window guard also reads the position, size, kind and minimized and full-screen state of other "
                           + "apps' windows (never their titles or contents) and moves those that cover the block",
                       "AXManualAccessibility", "VS Code may switch to its screen-reader mode", "PITBOX_GUARD_EXEMPT",
                       "pause the guard from the menu"] {
            #expect(AboutPanel.privacyParagraph.contains(phrase), "\(phrase)")
        }
        #expect(!AboutPanel.privacyParagraph.contains("  "), "the line continuations leave single spaces")
        #expect(!PitboxMenuState.bundleVersion.isEmpty)
    }

    @Test func menuTextIsOneShortLine() {
        #expect(MenuText.oneLine("  a\n\tb\u{202E}c  ") == "a bc")
        #expect(MenuText.oneLine(String(repeating: "y", count: 50), maxLength: 10) == "yyyyyyyyy…")
        #expect(MenuText.oneLine("") == "")
        var s = PitboxMenuState()
        s.hostName = " \n "
        #expect(s.hostDisplayName == "the host app")
    }
}
