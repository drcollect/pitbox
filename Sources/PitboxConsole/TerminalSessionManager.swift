import AppKit
import PitboxKit

/// What kind of tabs the console has.
enum ConsoleMode: Equatable {
    /// Pitbox's console (the app's only mode): command, Type and "Open a terminal on <host>" tabs, and no ordinary shell
    /// tabs. Nothing opens at start, nothing is restored from `console-state.json` (and nothing is written to it), the
    /// last tab closing leaves the console empty (the drawer hides), and there is no "+" or preset menu.
    case pitbox
    /// The terminal the console was moved from: one plain shell at start, the saved tabs restored, a new shell when the
    /// last tab closes, "+" and the preset menu. Kept (and tested) as code, never used by the app.
    case terminal
}

/// Owns the console's tabs: creating, closing, selecting, rotating (by hand and automatically), restoring after a
/// restart. It outlives the console's view: when the view is rebuilt the new view attaches to the same manager and the
/// sessions (and the shells in them) carry on.
///
/// Time goes through an injected `TerminalClock` and processes through an injected `ProcessLauncher`, so every rule here
/// is tested without waiting or forking.
@MainActor
final class TerminalSessionManager {
    struct Dependencies {
        var settings: TerminalSettings
        var environment: TerminalEnvironment
        var launcher: ProcessLauncher
        var stateFile: URL?
        var clock: TerminalClock
        var performLink: (LinkPolicy.Action) -> Void
        var setClipboard: (String) -> Void
        var isDarkAppearance: () -> Bool
        /// Starts command and Type tabs (`Commands/CommandSpawner.swift`), with the strict sandbox policy unless the
        /// host passes its own.
        var commandLauncher: CommandLauncher = CommandSpawner.live(policy: { .standard })
        /// Pitbox's console (no plain shells) unless a test asks for the terminal's behaviour.
        var mode: ConsoleMode = .pitbox
    }

    enum CloseOutcome: Equatable {
        case closed
        /// A program is running: ask again within `TerminalSessionManager.confirmWindow` to close it.
        case needsConfirmation
    }

    static let confirmWindow: TimeInterval = 3
    static let metadataInterval: TimeInterval = 2
    static let saveDelay: TimeInterval = 1.5
    static let rotationCheckInterval: TimeInterval = 1
    static let resizeSettleDelay: TimeInterval = 0.3

    private let deps: Dependencies
    private(set) var sessions: [TerminalSession] = []
    private(set) var selectedID: UUID?
    /// The terminal area's size in points; views are sized to it, processes start once it is known.
    private(set) var contentSize: CGSize = .zero
    /// Sessions that were closed but whose process has not been reaped yet.
    private var retiring: [TerminalSession] = []
    private var palette: TerminalPalette
    private var started = false
    /// Answers "is the console ordered in?" at the moment it is asked (set by the console's view; nil means yes). While it is not,
    /// the timers keep ticking (a 2 s tick costs nothing measurable) but do no work: no polling, no rotation. Asking at
    /// tick time needs no notification that could be missed.
    var visibilityProbe: (() -> Bool)?
    var isVisible: Bool { visibilityProbe?() ?? true }

    /// A tab, the selection, or a tab's state changed. Set by the console view that is attached now.
    var onChange: (() -> Void)?
    /// The same changes, for the console's drawer (tab count, running count). Set by `ConsoleHost`.
    var onTabsChanged: (() -> Void)?
    /// A command tab's bar has new numbers (running time, hidden input): once a second while one runs and the
    /// console is shown. Set by the console view, which redraws only the bar.
    var onCommandTick: (() -> Void)?
    var commandTickToken: ClockToken?
    /// The tab whose close button asked for confirmation, until the confirmation window ends.
    private(set) var closeConfirmationID: UUID?
    private var confirmToken: ClockToken?

    // Auto-rotation
    private(set) var autoRotate: Bool
    private(set) var autoRotateInterval: TimeInterval
    /// True while the user is using the console (keyboard focus or pointer over it): rotation waits.
    var interactionProbe: (() -> Bool)?
    private var lastSelectionChange: Date
    private var rotationToken: ClockToken?
    private var metadataToken: ClockToken?
    private var saveToken: ClockToken?
    private var resizeToken: ClockToken?

    /// The settings the console runs with now (`update(settings:)`).
    private(set) var settings: TerminalSettings

    init(_ deps: Dependencies) {
        self.deps = deps
        let settings = deps.settings
        self.settings = settings
        autoRotate = settings.autoRotate
        autoRotateInterval = settings.autoRotateSeconds
        palette = TerminalTheme.palette(isDark: deps.isDarkAppearance())
        lastSelectionChange = deps.clock.now
    }

    /// The manager's clock (command tabs' bar ticks and timeouts).
    var clock: TerminalClock { deps.clock }
    /// The environment child processes are built from.
    var environment: TerminalEnvironment { deps.environment }
    var selectedSession: TerminalSession? { sessions.first { $0.id == selectedID } }
    var selectedIndex: Int? { sessions.firstIndex { $0.id == selectedID } }
    var canCreateSession: Bool { sessions.count < settings.maxSessions }
    /// What kind of tabs this console has.
    var mode: ConsoleMode { deps.mode }
    /// Whether the user can open plain shell tabs ("+", the preset menu, Cmd-T): only in the terminal mode.
    var offersPlainShells: Bool { deps.mode == .terminal }
    var home: String { deps.environment.home }
    /// The presets for the "+" menu, from the settings the console has now (none in Pitbox's mode).
    func presetsForMenu() -> [TerminalPreset] { offersPlainShells ? settings.enabledPresets : [] }

    /// New settings from the app. New tabs and every value read live (limits, `onExit`, `newTabLocation`, background
    /// opacity) use them from now on; open tabs keep their font and scrollback. The rotation interval follows at once;
    /// rotation on or off follows a change of the setting, and otherwise keeps the user's own choice (the strip's toggle).
    func update(settings: TerminalSettings) {
        guard settings != self.settings else { return }
        let rotationChanged = settings.autoRotate != self.settings.autoRotate
        self.settings = settings
        autoRotateInterval = settings.autoRotateSeconds
        if rotationChanged {
            autoRotate = settings.autoRotate
            lastSelectionChange = deps.clock.now
        }
        scheduleRotation()
        notify()
    }

    // MARK: Starting

    /// Brings the previous tab list back (fresh processes in their last folders), or opens one shell. Idempotent. In
    /// Pitbox's mode it opens nothing and restores nothing: the console starts empty.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        guard offersPlainShells else {
            scheduleMetadataPolling()
            notify()
            return
        }
        let saved = deps.stateFile.flatMap { SavedState.load(from: $0) }
        let plan = RestorePlanner.plan(saved: saved, settings: settings, isDirectory: deps.environment.isDirectory)
        for planned in plan.sessions { _ = addSession(preset: planned.preset, directory: planned.cwd, select: false) }
        if plan.selected < sessions.count { select(id: sessions[plan.selected].id, userInitiated: false) }
        scheduleMetadataPolling()
        scheduleRotation()
        notify()
    }

    /// Tells the manager how big the terminal area is. The selected tab is resized at once (its program gets SIGWINCH);
    /// the other tabs follow shortly after the size has stopped changing (reflowing 10,000 lines of scrollback in every tab
    /// on each step of a live drag would make the drag stutter), and a tab is brought to size when it is selected.
    /// Sessions that were waiting for a size start.
    func setContentSize(_ size: CGSize) {
        guard size.width > 20, size.height > 20 else { return }
        let first = contentSize == .zero
        contentSize = size
        if let selected = selectedSession { fit(selected) }
        if first {
            for session in sessions where session.state == .notStarted {
                fit(session)
                session.start()
            }
        }
        if sessions.contains(where: { $0.view.frame.size != viewSize(for: $0) }) {
            resizeToken?.cancel()
            resizeToken = deps.clock.schedule(after: Self.resizeSettleDelay) { [weak self] in
                guard let self else { return }
                for session in self.sessions { self.fit(session) }
            }
        }
    }

    /// The terminal view's size for `session`: the whole area, less the native bar above command and Type tabs.
    func viewSize(for session: TerminalSession) -> CGSize {
        guard session.command != nil else { return contentSize }
        return CGSize(width: contentSize.width, height: max(20, contentSize.height - CommandTabBar.height))
    }

    private func fit(_ session: TerminalSession) {
        let size = viewSize(for: session)
        guard contentSize != .zero, session.view.frame.size != size else { return }
        session.view.setFrameSize(size)
    }

    // MARK: Creating and closing

    /// Opens a tab. Plain shells start in `$HOME` (or the selected tab's folder with `newTabLocation: current`).
    /// Returns nil at the `maxSessions` limit, and always in Pitbox's mode (it has no plain shell tabs).
    @discardableResult
    func newSession(preset: TerminalPreset? = nil, select: Bool = true) -> TerminalSession? {
        guard offersPlainShells, canCreateSession else { return nil }
        let chosen = preset ?? settings.defaultPreset
        var directory: String?
        if settings.newTabLocation == .current, let current = selectedSession?.directory { directory = current }
        return addSession(preset: chosen, directory: directory, select: select)
    }

    private func addSession(preset: TerminalPreset, directory: String?, select: Bool) -> TerminalSession? {
        addSession(preset: preset, directory: directory, select: select, command: nil)
    }

    /// Adds a tab. A command or Type tab (`command`) is selected like any new tab but never focused: the keyboard stays
    /// where it was; its view is sized below the bar before its shell starts.
    func addSession(preset: TerminalPreset, directory: String?, select: Bool, command: CommandTab?) -> TerminalSession? {
        guard sessions.count < settings.maxSessions else { return nil }
        let context = SessionContext(settings: settings, environment: deps.environment, launcher: deps.launcher,
                                     performLink: deps.performLink, setClipboard: deps.setClipboard,
                                     commandLauncher: deps.commandLauncher, clock: deps.clock)
        let base = contentSize == .zero ? CGSize(width: 640, height: 400) : contentSize
        let size = command == nil ? base : CGSize(width: base.width, height: max(20, base.height - CommandTabBar.height))
        let session = TerminalSession(preset: preset, startDirectory: directory, context: context, palette: palette,
                                      frame: CGRect(origin: .zero, size: size), command: command)
        session.onChange = { [weak self] in self?.sessionChanged() }
        session.onExit = { [weak self] session, status in self?.sessionExited(session, status) }
        session.onUserInput = { [weak self] in self?.noteUserActivity() }
        sessions.append(session)
        if contentSize != .zero { session.start() }
        if select || selectedID == nil { self.select(id: session.id, userInitiated: true) }
        notify()
        persistSoon()
        scheduleRotation()
        if command != nil { scheduleCommandTick() }
        return session
    }

    /// Closes a tab. A tab that runs a program (anything but an idle shell) needs a second request within
    /// `confirmWindow` seconds; an idle shell or an exited tab closes at once.
    @discardableResult
    func requestClose(_ id: UUID) -> CloseOutcome {
        guard let session = sessions.first(where: { $0.id == id }) else { return .closed }
        session.refreshMetadata()
        guard session.isBusy else {
            closeNow(id)
            return .closed
        }
        if closeConfirmationID == id {
            closeNow(id)
            return .closed
        }
        closeConfirmationID = id
        confirmToken = deps.clock.schedule(after: Self.confirmWindow) { [weak self] in
            guard let self, self.closeConfirmationID == id else { return }
            self.closeConfirmationID = nil
            self.notify()
        }
        notify()
        return .needsConfirmation
    }

    /// Closes a tab without asking. Its process is hung up now and killed after a grace period.
    func closeNow(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        if closeConfirmationID == id { closeConfirmationID = nil; confirmToken = nil }
        retire(session)
        if selectedID == id {
            selectedID = nil
            if !sessions.isEmpty { select(id: sessions[min(index, sessions.count - 1)].id, userInitiated: true) }
        }
        if sessions.isEmpty, offersPlainShells { _ = addSession(preset: settings.defaultPreset, directory: nil, select: true) }
        notify()
        persistSoon()
        scheduleRotation()
    }

    private func retire(_ session: TerminalSession) {
        session.isSelected = false
        // The view stays where it is: the console view removes it on its next sync, and moves typing focus if it had it.
        if session.isRunning {
            retiring.append(session)
            session.terminate()
        }
    }

    private func sessionExited(_ session: TerminalSession, _ status: ProcessExit) {
        retiring.removeAll { $0 === session }
        guard sessions.contains(where: { $0 === session }) else { return }
        // A command or Type tab keeps its output whatever `onExit` says.
        if session.preset.kind != .command {
            switch settings.onExit {
            case .close: closeNow(session.id)
            case .closeIfClean: if status.isClean { closeNow(session.id) }
            case .keep: break
            }
        }
        notify()
    }

    func restart(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }), session.isRestartable else { return }
        session.restart()
    }

    // MARK: Selecting and rotating

    /// Selects a tab. Only a selection the user made (a click, a shortcut, a new or closed tab) is saved soon; the start-up
    /// restore and automatic rotation are not, so an auto-rotating strip does not rewrite `console-state.json` every few
    /// seconds while idle (`shutdown` still saves the last selection).
    func select(id: UUID, userInitiated: Bool = true) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        if selectedID != id {
            selectedSession?.isSelected = false
            selectedID = id
            lastSelectionChange = deps.clock.now
            if closeConfirmationID != id { closeConfirmationID = nil }
        }
        selectedSession?.isSelected = true
        if let selected = selectedSession { fit(selected) }
        notify()
        if userInitiated { persistSoon() }
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(id: sessions[index].id)
    }

    func selectLast() { if let last = sessions.last { select(id: last.id) } }

    /// The next tab, wrapping around.
    func selectNext() { rotate(by: 1) }
    func selectPrevious() { rotate(by: -1) }

    private func rotate(by step: Int, userInitiated: Bool = true) {
        guard sessions.count > 1, let index = selectedIndex else { return }
        let next = (index + step + sessions.count) % sessions.count
        select(id: sessions[next].id, userInitiated: userInitiated)
    }

    // MARK: Auto-rotation

    func setAutoRotate(_ enabled: Bool) {
        autoRotate = enabled
        lastSelectionChange = deps.clock.now
        scheduleRotation()
        notify()
    }

    /// The user typed or otherwise used the console: restart the rotation countdown.
    func noteUserActivity() {
        lastSelectionChange = deps.clock.now
    }

    private func scheduleRotation() {
        rotationToken?.cancel()
        rotationToken = nil
        guard autoRotate, sessions.count > 1, started else { return }
        rotationToken = deps.clock.schedule(after: Self.rotationCheckInterval) { [weak self] in
            self?.rotationTick()
        }
    }

    /// Rotates when the interval has passed since the selection last changed and the user is not using the console.
    func rotationTick() {
        rotationToken = nil
        defer { scheduleRotation() }
        guard autoRotate, sessions.count > 1 else { return }
        let now = deps.clock.now
        if !isVisible || interactionProbe?() == true {
            lastSelectionChange = now   // the user is here: start the countdown again when they leave
            return
        }
        guard now.timeIntervalSince(lastSelectionChange) >= autoRotateInterval else { return }
        rotate(by: 1, userInitiated: false)
    }

    // MARK: Metadata, persistence, appearance

    private func scheduleMetadataPolling() {
        metadataToken?.cancel()
        metadataToken = deps.clock.schedule(after: Self.metadataInterval) { [weak self] in
            self?.pollMetadata()
        }
    }

    /// Refreshes titles and folders; saves the tab list when a folder changed.
    func pollMetadata() {
        guard isVisible else {
            scheduleMetadataPolling()
            return
        }
        let before = sessions.map(\.directory)
        for session in sessions { session.refreshMetadata() }
        if before != sessions.map(\.directory) { persistSoon() }
        scheduleMetadataPolling()
    }

    private func persistSoon() {
        guard offersPlainShells, deps.stateFile != nil, started else { return }
        saveToken?.cancel()
        saveToken = deps.clock.schedule(after: Self.saveDelay) { [weak self] in self?.persistNow() }
    }

    /// Writes the tab list. Pitbox's mode has nothing to save (its tabs are never saved), so it writes no file.
    func persistNow() {
        guard offersPlainShells, let url = deps.stateFile, started else { return }
        saveToken?.cancel()
        saveToken = nil
        for session in sessions { session.refreshMetadata() }   // the last folders, even if polling was paused
        // Tabs from a command sheet (Run, Type, server) are never saved: restarting the app never runs a command again
        // or brings its tab back.
        let kept = sessions.filter { !$0.preset.isFromCommandSheet }
        let tabs = kept.map { SavedState.Tab(preset: $0.preset.id, cwd: $0.directory) }
        let selected = selectedSession.flatMap { chosen in kept.firstIndex { $0 === chosen } } ?? 0
        SavedState(selected: selected, tabs: tabs).save(to: url)
    }

    /// Recolors every tab for the current appearance.
    func appearanceChanged() {
        let new = TerminalTheme.palette(isDark: deps.isDarkAppearance())
        guard new != palette else { return }
        palette = new
        for session in sessions { session.view.apply(palette: new) }
        notify()
    }

    var currentPalette: TerminalPalette { palette }

    // MARK: Shutdown

    /// Saves the tab list and hangs up every shell (SIGHUP, no waiting). For the app quitting.
    func shutdown() {
        persistNow()
        rotationToken?.cancel(); metadataToken?.cancel(); saveToken?.cancel()
        for session in sessions + retiring { session.hangUp() }
    }

    // MARK: Change notifications

    private func sessionChanged() { notify() }

    private func notify() {
        onChange?()
        onTabsChanged?()
    }
}
