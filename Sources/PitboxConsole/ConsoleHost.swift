import AppKit
import PitboxKit

/// The console: the tabs where an approved command runs (command and Type tabs) and "Open a terminal on <host>" tabs,
/// with their tab strip and terminal views. It has no ordinary shell tabs: it starts empty, restores nothing, and
/// offers no "+" or preset menu.
///
/// One host owns one session manager for the app's lifetime. The drawer that shows the console (`ConsoleDrawer`) asks
/// `makeView()` for its content; a new view attaches to the same manager, so a rebuilt drawer gets a new view over the
/// same running shells.
///
/// Wiring (in the app):
/// ```swift
/// let console = ConsoleHost(settings: consoleSettings,
///                           sandboxPolicy: { CommandSandbox.Policy(announcedFolders: memory.folders,
///                                                                  announcedSocketFolders: memory.socketFolders,
///                                                                  denyFolders: settings.sandboxDenyFolders,
///                                                                  allowSocketFolders: settings.sandboxAllowSocketFolders) },
///                           keyboardRequester: { panel.setNeedsKeyboard($0) })
/// let drawer = ConsoleDrawer(console: console, blockCanShow: { … }, ensureBlockShown: { done in … })
/// console.commandHooks = drawer.commandHooks
/// // the settings file changed: console.update(settings: newConsoleSettings)
/// ```
/// Shells get SIGHUP when the app quits: the host observes `NSApplication.willTerminateNotification` itself, and
/// `shutdown()` does the same on demand.
///
/// Security (docs/THREAT_MODEL.md, "The run path as built"): the console is security-critical. It registers no control
/// command and has no public method that writes into a session; input comes only from its own views (keyboard, paste,
/// drag and drop). What its own tabs run comes from the `TerminalSettings` value the app hands it, never from a
/// session. The one other way in is the command sheet (`Commands/`): its internal handlers open a command or Type tab
/// only after the user's real click on the sheet; the public command API here only selects a tab, counts tabs and takes
/// the composition hooks.
public final class ConsoleHost {
    /// The panel's non-activating keyboard request (the drawer gives the keyboard back through it when it folds).
    let keyboardRequester: (Bool) -> Void
    private let paths: TerminalPaths
    /// Pitbox's console (no plain shells); tests may ask for the terminal's behaviour.
    let mode: ConsoleMode
    private let launcher: ProcessLauncher
    /// The settings the console runs with (`update(settings:)` replaces them).
    private(set) var settings: TerminalSettings
    let clock: TerminalClock
    let environment: TerminalEnvironment?
    /// The console's tabs: created with the first view, kept for the app's lifetime.
    private(set) var manager: TerminalSessionManager?
    /// A tab came or went or changed its state (for the drawer: hidden without tabs, the counts on its bar).
    var onTabsChanged: (@MainActor () -> Void)?
    private weak var view: ConsoleView?
    private var terminationObserver: NSObjectProtocol?
    /// Starts command and Type tabs (`Commands/CommandSpawner.swift`; tests pass fakes or the helper SwiftPM built).
    let commandLauncher: CommandLauncher
    /// Nil when the command spawn path can start commands as their own app; else why not (the helper is missing or
    /// failed its check). Run and Type are off with that reason.
    let commandPathProblem: () -> String?

    /// What the composition root provides for command tabs: whether the console can be shown, reveal and
    /// hold, release. The defaults fail closed (the console is never visible: Run and Type stay off).
    public var commandHooks = ConsoleCommandHooks()
    /// The 2 s limits on reveal-and-hold answers, by run id, until answered.
    var revealTimeouts: [UUID: ClockToken] = [:]
    /// The pending end of the console's hold: 25 s (the console's linger) after the last Run finished.
    var holdRelease: ClockToken?
    /// "Open a terminal on <alias>": whether the alias is an exact `Host` of the SSH config (alias, home). Called on
    /// `sshConfigQueue`, never on the main thread (it reads up to 64 files); tests replace it.
    var exactAliasCheck: @Sendable (String, String) -> Bool = { SSHConfigHosts.isExactAlias($0, home: $1) }

    /// - Parameters:
    ///   - settings: how the console's tabs look and behave (font, size, appearance, limits). The app builds it from its
    ///     settings file and hands a new value to `update(settings:)` when that file changes.
    ///   - sandboxPolicy: what the command sandbox denies besides its fixed rules (Pitbox's own folder, sockets under
    ///     `~/Library/Application Support`): the dock hosts' announced folders from `SandboxMemory` and the settings'
    ///     `sandboxDenyFolders` and `sandboxAllowSocketFolders`. Called at every command spawn, so a settings change
    ///     applies to the next Run. The default is the fixed rules alone.
    ///   - keyboardRequester: called with `true` when the console wants typing focus without being clicked (`focus()`)
    ///     and with `false` when it gives the keyboard back (Cmd-Escape, the drawer folding). Wire it to the panel's
    ///     non-activating keyboard request.
    public convenience init(settings: TerminalSettings = .standard,
                            sandboxPolicy: @escaping () -> CommandSandbox.Policy = { .standard },
                            keyboardRequester: @escaping (Bool) -> Void) {
        self.init(settings: settings, keyboardRequester: keyboardRequester, paths: .live, launcher: nil, clock: nil,
                  environment: nil, commandLauncher: CommandSpawner.live(policy: sandboxPolicy))
    }

    /// Internal initializer for tests: private files, fake processes, a manual clock, a command launcher, and the
    /// terminal's behaviour (`mode: .terminal`) for the tests of the plain-shell code.
    init(settings: TerminalSettings = .standard, keyboardRequester: @escaping (Bool) -> Void, paths: TerminalPaths,
         launcher: ProcessLauncher?, clock: TerminalClock?, environment: TerminalEnvironment?,
         commandLauncher: CommandLauncher? = nil, commandPathProblem: (() -> String?)? = nil, mode: ConsoleMode = .pitbox) {
        self.settings = settings
        self.keyboardRequester = keyboardRequester
        self.paths = paths
        self.mode = mode
        self.launcher = launcher ?? { spec, size in try PTYProcess(spec: spec, size: size) }
        self.clock = clock ?? SystemClock()
        self.environment = environment
        self.commandLauncher = commandLauncher ?? CommandSpawner.live(policy: { .standard })
        self.commandPathProblem = commandPathProblem ?? CommandSpawner.liveProblem
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                     queue: .main) { [weak self] _ in self?.shutdown() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    private func dependencies() -> TerminalSessionManager.Dependencies {
        TerminalSessionManager.Dependencies(
            settings: settings, environment: environment ?? .live, launcher: launcher,
            stateFile: paths.stateFile, clock: clock,
            performLink: { action in
                switch action {
                case .open(let url): NSWorkspace.shared.open(url)
                case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
                case .ignore: break
                case .misleading: NSSound.beep()
                }
            },
            setClipboard: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            isDarkAppearance: { [weak self] in
                MainActor.assumeIsolated {
                    let appearance: NSAppearance? = self?.view?.effectiveAppearance ?? NSApp?.effectiveAppearance
                    return appearance.map { TerminalTheme.isDark($0) } ?? true
                }
            },
            commandLauncher: commandLauncher, mode: mode)
    }

    /// The console's newest view, while it exists.
    @MainActor
    func consoleView() -> ConsoleView? { view }

    // MARK: The view

    /// Creates the console's view over its sessions (created on first use, restored from the last run). Each call makes
    /// a new view; the newest one receives the manager's changes. Call from the main thread.
    public func makeView() -> NSView {
        MainActor.assumeIsolated { makeConsoleView() }
    }

    /// The view, with a corner radius clamped to 0...48 pt (tests try others; the app takes the default).
    @MainActor
    func makeConsoleView(cornerRadius: CGFloat = 18) -> ConsoleView {
        let manager = self.manager ?? {
            let created = TerminalSessionManager(dependencies())
            created.onTabsChanged = { [weak self] in self?.onTabsChanged?() }
            self.manager = created
            return created
        }()
        let view = ConsoleView(manager: manager, cornerRadius: min(max(cornerRadius, 0), 48), keyboardRequester: keyboardRequester)
        applyFixedAppearance(to: view)
        self.view = view
        manager.startIfNeeded()
        return view
    }

    /// A fixed appearance (`TerminalSettings.appearance`) overrides the system's for the whole console, so the palette,
    /// the tab strip and every palette lookup that reads `effectiveAppearance` follow it.
    @MainActor
    private func applyFixedAppearance(to view: ConsoleView) {
        switch settings.appearance {
        case .system: view.appearance = nil
        case .dark: view.appearance = NSAppearance(named: .darkAqua)
        case .light: view.appearance = NSAppearance(named: .aqua)
        }
    }

    // MARK: Settings

    /// Replaces the console's settings. New tabs and every value read live (the limits, what happens when a program
    /// ends, the background opacity, the fixed appearance) follow at once; tabs that are already open keep their font
    /// and scrollback until they close.
    public func update(settings: TerminalSettings) {
        onMain {
            guard settings != self.settings else { return }
            self.settings = settings
            manager?.update(settings: settings)
            if let view {
                applyFixedAppearance(to: view)
                view.applyAppearance()
            }
        }
    }

    // MARK: The app's API

    /// Runs `body` on the main actor: directly when already on the main thread, otherwise by hopping there (so a status
    /// query from another thread is safe). Never call it while the main thread waits for the caller.
    func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    /// Takes the keyboard for the console: asks for typing focus and makes the selected terminal first responder (never
    /// a command or Type tab: those take the keyboard only from a click inside them).
    public func focus() {
        onMain {
            if let view { view.focusTerminal() } else { keyboardRequester(true) }
        }
    }

    /// Saves the tab list and hangs up every shell (SIGHUP). Also runs when the app is about to terminate; calling it
    /// again is harmless.
    public func shutdown() {
        onMain { manager?.shutdown() }
    }

    /// How many tabs are open (for a status display).
    public var sessionCount: Int {
        onMain { manager?.sessions.count ?? 0 }
    }

    /// How many tabs are running something (a program, not an idle shell). Quitting would end them: worth a line in a
    /// confirmation.
    public var busySessionCount: Int {
        onMain {
            guard let manager else { return 0 }
            for session in manager.sessions { session.refreshMetadata() }
            return manager.sessions.filter(\.isBusy).count
        }
    }
}
