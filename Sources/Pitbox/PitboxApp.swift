import AppKit
import PitboxConsole
import PitboxDock
import PitboxGuard
import PitboxKit
import PitboxSessions
import PitboxShell

/// The composition root: builds every part at launch, wires them through their public seams,
/// and takes them down in order at quit. Nothing here decides what a monitor shows, what runs or what the guard moves;
/// it only connects the block (PitboxSessions), the panel, menu, hotkeys and onboarding (PitboxShell), the window guard
/// (PitboxGuard), the console (PitboxConsole, `ConsoleSeam`) and the dock link (PitboxDock, `DockWiring`).
///
/// Launch order (`launch()`): app-support folders → single-instance lock (a second Pitbox quits) → the settings file
/// (the hub) → the dock socket, when docking is on (it accepts at once, before any window) → Edit menu → the panel →
/// sessions (engine, memory, parker, console, block) → desk (Ready presence and speech, window observer, desk tags,
/// drag-to-pit) → panel wiring → window guard → hotkeys → onboarding, settings window and menu → the settings watcher →
/// login item → block and desk tags start → the dock link starts (the panel shows at its first placement: at once, or
/// within 1 s while a listed host app runs) → guard starts (and the onboarding shows while Accessibility is not
/// granted).
@MainActor
final class PitboxApp {
    // MARK: Launch state and seams

    /// True between a complete `launch()` and `terminate()`.
    private(set) var launched = false
    private var lock: SingleInstanceLock?
    /// The folder of the single-instance lock (tests: a scratch folder).
    var lockFolder: URL = Paths.appSupport
    /// Creates the app-support folders (tests: nothing).
    var prepareFolders: () throws -> Void = { try Paths.ensureDirs() }
    /// Quits the app: on the next main-queue turn, so a second instance never quits from inside its own launch callback.
    var quit: @MainActor () -> Void = { DispatchQueue.main.async { NSApp.terminate(nil) } }
    /// The system's login item (tests: a recorder; nothing reaches `SMAppService`).
    var loginItem = LoginItemControl()

    // MARK: Settings

    /// The one source of truth for `settings.json` (`SettingsHub`).
    var hub: SettingsHub?
    /// The settings in force.
    var settings: CodeSettings { hub?.current ?? CodeSettings() }

    // MARK: Sessions, console and desk

    var engine: CodeSessionsEngine!
    var memory: CodeMemoryStore!
    var resultChecks: CodeResultFetchChecker!
    var parker: CodeWindowParker!
    var webPreview: CodeWebPreviewController!
    var sandboxMemory: SandboxMemory!
    var console: ConsoleSeam!
    var block: PitboxBlock!
    var voice: SpokenLine!
    var windowObserver: CodeWindowObserver!
    var deskTagActions: DeskTagClosureActions!
    var deskTags: DeskTagController!
    let dropClaims = WindowDropClaims()
    var drop: CodeDragToPark!

    // MARK: Dock link

    /// The dock link's guest side (tests: a factory over a temporary socket and fakes).
    var dock = DockWiring()

    // MARK: Shell

    var panel: BlockPanelController!
    var windowGuard: WindowGuard!
    var hotkeys: HotkeyManager!
    var hotkeyBinder: HotkeyBinder!
    var onboarding: AccessibilityOnboarding!
    var settingsWindow: SettingsWindowController!
    var menu: PitboxMenuBar!

    // MARK: What was last handed out or read

    /// The block's content shows (on screen and not the rail), as last told to the block and the console.
    var contentShown: Bool?
    /// The panel is on screen, as last told to the desk tags.
    var panelVisible: Bool?
    /// The block's latest attention counts (the rail's dots).
    var attention = (needsYou: 0, finished: 0, running: 0)
    /// Accessibility as last seen (the features start when it turns true).
    var wasTrusted = false
    /// The login item's state as last read (an XPC query: read when the menu opens, at most once a second, and after a
    /// toggle).
    var loginStatus: LoginItem.Status?
    var loginStatusReadAt: TimeInterval = -.infinity
    /// The displays as last read for the menu (when it opens).
    var menuDisplays: [MenuDisplay]?
    /// What the menu's icon showed when `syncVisibility` last refreshed it.
    var menuIcon: MenuIconState?

    /// The inputs of the menu's icon.
    struct MenuIconState: Equatable {
        var visible: Bool
        var folded: Bool
        var edge: Edge
    }

    // MARK: Lifecycle

    /// Builds and starts everything, in the order above.
    func launch() {
        do { try prepareFolders() } catch { Log.error("cannot prepare the app-support folders", "app") }
        switch SingleInstanceLock.acquire(in: lockFolder) {
        case .success(let held):
            lock = held
        case .failure(let failure):
            Log.warn(Self.lockFailureWords(failure), "app")
            quit()
            return
        }
        Log.info("\(AppIdentity.displayName) starting", "app")
        loadHub()
        // The dock socket, right after the lock and before any window (docs/DOCK_PROTOCOL.md §2.1): a host may connect
        // from here on.
        dock.bind(settings.dock)
        EditMenu.install()
        loadPanel()
        wireSessions()
        wireDesk()
        wirePanel()
        wireGuard()
        wireHotkeys()
        wireMenu()
        hub?.start()
        loginStatus = loginItem.reconcile(settings.launchAtLogin)
        loginStatusReadAt = MonotonicClock.now()
        launched = true
        block.start()
        deskTags.start()
        // The panel's first show waits for the first placement, so it does not jump from the edge to a host
        // (docs/DOCK_PROTOCOL.md §8).
        dock.start(panel: panel, targets: dockTargets(), whenPlaced: { [weak self] in self?.showBlock() })
        windowGuard.start()   // idempotent; without Accessibility it polls and starts when the grant arrives
        if !windowGuard.isAccessibilityTrusted {
            windowGuard.requestAccessibilityPrompt()   // registers the app in the Accessibility list
            onboarding.show()
        }
        Log.info("\(AppIdentity.displayName) started", "app")
    }

    /// Takes everything down: the dock link first (`bye` with `quit`, the socket removed), then the source's order:
    /// drag-to-pit → desk tags → window observer → block (writes pending bucket changes) → memory → console → guard →
    /// panel → settings watcher; then the keys, windows and menu.
    func terminate() {
        guard launched else { return }
        launched = false
        dock.stop()
        drop?.stop()
        deskTags?.stop()
        windowObserver?.stop()
        block?.stop()
        memory?.flush()
        console?.shutdown()
        windowGuard?.stop()
        panel?.invalidate()
        hub?.stop()
        hotkeyBinder?.unbindAll()
        settingsWindow?.close()
        onboarding?.close()
        menu?.uninstall()
        Log.info("\(AppIdentity.displayName) stopped", "app")
        // The lock stays held until the process exits, so no second Pitbox starts during the teardown.
    }

    /// The log line when the lock is not ours: another Pitbox, or a lock file that cannot be used.
    static func lockFailureWords(_ failure: SingleInstanceLock.Failure) -> String {
        switch failure {
        case .taken: return "lock taken by another \(AppIdentity.displayName); quitting"
        case .unusable(let why): return "cannot create the lock file (\(why)); quitting"
        }
    }

    // MARK: Settings at launch

    /// Reads the settings file (writing the defaults once when it is missing) into the hub.
    private func loadHub() {
        let hub = hub ?? SettingsHub.load()
        self.hub = hub
        hub.onChange = { [weak self] old, new in self?.apply(old: old, new: new) }
    }

    /// Makes the panel from the settings (never shown here: the dock link's first placement shows it).
    private func loadPanel() {
        panel = BlockPanelController(settings: SettingsBridge.blockSettings(settings))
        panel.apply(appearance: .system)   // alone the block follows the system; docked, the host's look (DockWiring)
    }
}

/// The system's login item as the app uses it (a seam: tests record instead of registering anything).
@MainActor
struct LoginItemControl {
    /// The state as the system sees it (`SMAppService`, an XPC query).
    var status: @MainActor () -> LoginItem.Status = { LoginItem.status }
    /// Makes the system match `wanted`; returns the resulting state.
    var reconcile: @MainActor (_ wanted: Bool) -> LoginItem.Status = { LoginItem.reconcile(wanted: $0) }
}
