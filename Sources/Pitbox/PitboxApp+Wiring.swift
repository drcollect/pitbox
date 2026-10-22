import AppKit
import PitboxConsole
import PitboxGuard
import PitboxKit
import PitboxSessions
import PitboxShell

// The launch steps of `PitboxApp`, one function per group of parts.
extension PitboxApp {
    /// The session engine (reading the hub's box: what the app applied last), the memory, the result checks and
    /// derivers, the window parker, the web preview, the console and the block with its result actions.
    func wireSessions() {
        guard let hub else { return }
        memory = CodeMemoryStore()
        let box = hub.box
        engine = CodeSessionsEngine(environment: .live(settings: { box.value }))
        resultChecks = CodeResultFetchChecker(base: engine.freshnessChecker)
        // Dashboard sites are built once, at start: a hand edit of `dashboards` applies after a restart.
        let sites = CodeDashboardSites(settings)
        engine.register(.progress + .dashboards(sites: sites) + .finished + .ready
                        + .results(fetchChecks: resultChecks, dashboardSites: sites) + .warnings, memory: memory)
        // Restored windows are clamped outside the block, and docked outside the host's strip too.
        parker = CodeWindowParker(stripRegions: { [weak self] in self?.dockedRegions ?? [] })
        // Web documents a session made open only here: no scripts, nothing loaded from the internet.
        webPreview = CodeWebPreviewController()
        webPreview.stripFrame = { [weak self] in self?.blockFrameOnScreen }
        sandboxMemory = SandboxMemory()   // once, for the app's life: the dock hosts' announced folders (append-only)
        console = ConsoleSeamFactory.make(consoleInputs(), memory: sandboxMemory)
        block = PitboxBlock(source: engine, parker: parker, presenter: console.presenter, freshness: resultChecks,
                            settings: settings, dashboardOpener: CodeDashboardOpener { _ = NSWorkspace.shared.open($0) })
        wireBlock()
    }

    /// The block's inputs from the app and the shell.
    func wireBlock() {
        block.resultActions = CodeResultActions(hooks: .live(preview: webPreview, presenter: console.presenter,
                                                             freshness: resultChecks, events: { _ in }))
        block.onRevealRun = { [weak self] runID in self?.console?.revealRun(runID) }
        block.keyboardRequester = { [weak self] needs in self?.panel?.setNeedsKeyboard(needs) }
        block.stripWidthProvider = { [weak self] in
            guard let layout = self?.panel?.blockLayout else { return nil }
            return BlockMetrics.stripWidth(for: layout)
        }
        block.onAttentionChanged = { [weak self] counts in
            self?.attention = counts
            self?.updateRail()
            self?.dock.attentionChanged(needsYou: counts.needsYou, finished: counts.finished, running: counts.running)
        }
        // The header's "−": folds like ⌃⌥C and the menu.
        block.onFoldRequested = { [weak self] in self?.panel?.fold() }
        console.onCommandRunningChanged = { [weak self] _ in self?.updateRail() }
    }

    /// The Ready list's presence and speech, the window observer shared by desk tags and drag-to-pit, the desk tags and
    /// drag-to-pit, and the rail's spring-loaded unfold.
    func wireDesk() {
        voice = SpokenLine()
        block.enableReady(memory: memory, environment: ReadyPresence.live(parker: parker, engine: engine, voice: voice,
                                                                          gate: dock.speechGate))
        windowObserver = CodeWindowObserver()
        deskTagActions = DeskTagClosureActions(
            parker: parker,
            openOffer: { [weak self] offer, sessionID, anchor in
                self?.block?.openOffer(offer, sessionID: sessionID, anchor: anchor)
            },
            openResult: { [weak self] resultID, sessionID, anchor in
                self?.block?.openResult(resultID, sessionID: sessionID, anchor: anchor)
            },
            openDashboard: { [weak self] sessionID in self?.block?.openDashboard(sessionID: sessionID) })
        deskTags = DeskTagController(actions: deskTagActions, stripRegions: { [weak self] in self?.dockedRegions ?? [] },
                                     observer: windowObserver)
        block.deskWindowsHaveTags = deskTags.standsInForDeskMonitors
        block.deskTagsActive = deskTags.standsInForDeskMonitors
        deskTags.onStandInChanged = { [weak self] standsIn in
            self?.block?.deskWindowsHaveTags = standsIn
            self?.block?.deskTagsActive = standsIn
        }
        block.onRebuilt = { [weak self] in self?.feedDeskTags() }
        block.onHideTextChanged = { [weak self] hidden in
            self?.deskTags?.setHideText(hidden)
            self?.menu?.refresh()
        }
        block.onReadySuppressionChange = { [weak self] suppressed in self?.deskTags?.setSuppressed(suppressed) }
        deskTags.update(settings: settings)
        drop = CodeDragToPark(claims: dropClaims, parker: parker, source: engine,
                              stripRegions: { [weak self] in self?.panel?.regions ?? [] }, settings: settings)
        block.dragToPark = drop   // before the block's view is made: the view becomes the drop's target
        drop.attach(observer: windowObserver)
        // Spring-loaded unfold: a pop-out held over the rail for 0.6 s unfolds the block for the drop.
        drop.onRailHover = { [weak self] hovering in
            guard let rail = self?.panel?.rail else { return }
            if hovering { rail.hoverBegan() } else { rail.hoverEnded() }
        }
    }

    /// The panel's content and callbacks: the block's view, the console's drawer, persisted panel settings, rows from
    /// the height, visibility.
    func wirePanel() {
        panel.setBlockView(block.makeView())
        panel.setDrawerView(console.drawerView)
        panel.setDrawerHeight(console.drawerHeight)
        console.onDrawerHeightChanged = { [weak self] height in
            self?.panel?.setDrawerHeight(height)
            self?.updateRows()
        }
        panel.onSettingsChanged = { [weak self] changed in self?.persist(changed) }
        panel.onLayoutChanged = { [weak self] layout in
            self?.updateRows()
            self?.block?.foldButtonSide = Self.foldButtonSide(layout)
        }
        panel.onAreaChanged = { [weak self] _, _, _ in
            self?.updateRows()
            self?.syncVisibility()
            self?.dock.panelAreaChanged()
        }
        panel.onVisibilityChanged = { [weak self] _ in self?.syncVisibility() }
        panel.onAloneOverrideChanged = { [weak self] on in
            self?.dock.aloneOverrideChanged(on)
            self?.menu?.refresh()
        }
        // The rail's 0.6 s timer fired during a drag: the block unfolded; the drag now arms over it as any other.
        panel.onSpringLoadedUnfold = { [weak self] in
            self?.syncVisibility()
            self?.drop?.refresh()
        }
        block.foldButtonSide = Self.foldButtonSide(panel.blockLayout)
        updateRail()
    }

    /// The window guard over the panel's region, with the drop claims (created after every other `onRegionsChanged`
    /// user, since it chains the handler it finds).
    func wireGuard() {
        windowGuard = WindowGuard(regions: panel, options: GuardOptions.fromEnvironment())
        windowGuard.dropClaims = dropClaims
        dropClaims.onReleasedUnparked = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.windowGuard?.lookAgain() } }
        }
        dock.mirror(dropClaims)   // every claim, mouse-up and release to a docked host's guard (feature guard.claims)
        windowGuard.onStatusChange = { [weak self] status in self?.guardStatusChanged(status) }
        wasTrusted = windowGuard.isAccessibilityTrusted
    }

    /// ⌃⌥P and ⌃⌥C from the settings, each checked for exclusivity first.
    func wireHotkeys() {
        hotkeys = HotkeyManager()
        hotkeys.onRegistrationsChanged = { [weak self] in
            self?.menu?.refresh()
            self?.settingsWindow?.model.refresh()
        }
        hotkeyBinder = HotkeyBinder(hotkeys: hotkeys,
                                    park: { [weak self] in self?.pitFrontWindow() },
                                    fold: { [weak self] in self?.panel?.toggleFold() })
        hotkeyBinder.apply(settings.hotkeys)
    }

    /// The Accessibility onboarding, the settings window and the menu bar item.
    func wireMenu() {
        onboarding = AccessibilityOnboarding(isTrusted: { [weak self] in
            self?.windowGuard?.isAccessibilityTrusted ?? AXIsProcessTrusted()
        })
        onboarding.onTrusted = { [weak self] in self?.noteTrust(true) }
        settingsWindow = SettingsWindowController(model: makeSettingsModel())
        menu = PitboxMenuBar(state: { [weak self] in self?.menuState() ?? PitboxMenuState() }, actions: menuActions())
        menu.onWillOpen = { [weak self] in self?.menuWillOpen() }
        menu.install()
    }

    /// What the console gets from the app (`ConsoleSeamInputs`).
    func consoleInputs() -> ConsoleSeamInputs {
        let box = hub?.box ?? SettingsBox(CodeSettings())
        let announced = dock.announced
        return ConsoleSeamInputs(
            blockCanShow: { [weak self] in self?.blockCanShowConsole ?? false },
            ensureBlockShown: { [weak self] done in
                guard let self else { return done(false) }
                self.ensureBlockShown(done)
            },
            keyboardRequester: { [weak self] needs in self?.panel?.setNeedsKeyboard(needs) },
            anchorWindow: { [weak self] in self?.panel?.isVisible == true ? self?.panel?.window : nil },
            anchorFrame: { [weak self] in self?.dock.dockedAreaFrame },
            settings: { box.value },
            announcedFolders: { announced.lists },
            previewFetchedFile: { [weak self] url, frame in
                self?.webPreview?.show(url, name: url.lastPathComponent, anchor: frame, beside: frame)
            })
    }

    /// The settings window's model over the hub (every write lands in the box before anyone hears of it).
    func makeSettingsModel() -> SettingsWindowModel {
        SettingsWindowModel(
            settings: settings,
            write: { [weak self] change in self?.hub?.write(change) ?? .failure(.writeFailed) },
            displays: { BlockDisplay.current().map { SettingsDisplay(uuid: $0.uuid, name: $0.name) } },
            checkHotkey: { AppWords.hotkeyProblem($0) },
            hotkeyStatus: { [weak self] key in self?.hotkeyBinder?.status(key) },
            showSettingsFile: { NSWorkspace.shared.activateFileViewerSelecting([Paths.settingsFile]) })
    }

    /// The header's "−" corner: the window side alone (at the right screen edge: the left corner), the host's side
    /// docked.
    static func foldButtonSide(_ layout: BlockLayout) -> Edge {
        layout.hostSide ?? layout.windowSide
    }
}
