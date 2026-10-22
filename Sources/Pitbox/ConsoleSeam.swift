import AppKit
import PitboxConsole
import PitboxKit
import PitboxSessions

// MARK: - The console seam
//
// Everything the block uses of the command console sits behind `ConsoleSeam`; everything the console needs from the app
// is in `ConsoleSeamInputs`; `ConsoleSeamFactory.make` builds it (PitboxConsole's host, drawer and run sheet, the run
// policy from `commands`, the sandbox policy from the dock hosts' announced folders and the settings). The block never
// runs anything itself: the sheet is its only presenter, and only a real click on the sheet starts a command.

/// What the block and the app use of the console. Main thread.
@MainActor
protocol ConsoleSeam: AnyObject {
    /// The run sheet: the only presenter of command offers and result fetches.
    var presenter: CommandOfferPresenting { get }
    /// The drawer at the bottom of the block.
    var drawerView: NSView? { get }
    /// The drawer's height now (0 while it has no tabs).
    var drawerHeight: CGFloat { get }
    /// The drawer's height changed: the panel lays out (`setDrawerHeight`).
    var onDrawerHeightChanged: ((CGFloat) -> Void)? { get set }
    /// True while a Run tab runs (the rail's pulsing blue dot).
    var commandRunning: Bool { get }
    /// `commandRunning` changed.
    var onCommandRunningChanged: ((Bool) -> Void)? { get set }
    /// A run's result line was clicked: select its tab and open the drawer (never runs anything).
    func revealRun(_ runID: UUID)
    /// The block hid or folded: the drawer's hold ends (a Run still waiting starts nothing) and an open sheet closes as
    /// a Cancel.
    func blockHidden()
    /// The settings changed (`console`, `commands`, `commandShell`, `extraPath`, `sandbox…`).
    func update(settings: CodeSettings)
    /// Quit: hang up the tabs.
    func shutdown()
}

/// What the app gives the console.
struct ConsoleSeamInputs {
    /// True while the block is shown, or folded and able to unfold; false while hidden by the user or a dock host.
    var blockCanShow: @MainActor () -> Bool
    /// "Run unfolds the block": unfold if folded (the panel's order), then `done(true)` on the main thread
    /// once the block shows and is laid out, or `done(false)`.
    var ensureBlockShown: @MainActor (_ done: @escaping @MainActor (Bool) -> Void) -> Void
    /// The panel's non-activating keyboard request.
    var keyboardRequester: @MainActor (Bool) -> Void
    /// The window the sheet sits beside (the block's panel), read when a sheet opens.
    var anchorWindow: @MainActor () -> NSWindow?
    /// Docked: the whole docked area (the host's strip and the block) the sheet sits beside; nil: the anchor window's
    /// frame.
    var anchorFrame: @MainActor () -> CGRect? = { nil }
    /// The settings in force, from any thread (the sandbox policy is read at every spawn).
    var settings: @Sendable () -> CodeSettings
    /// What the dock link's verified hosts announced in this process, from any thread (added to the sandbox memory's
    /// folders at every spawn).
    var announcedFolders: @Sendable () -> AnnouncedFolders.Lists = { AnnouncedFolders.Lists() }
    /// Shows a fetched web document in the script-free preview, beside a frame.
    var previewFetchedFile: @MainActor (URL, CGRect) -> Void
}

/// Builds the console the app runs with.
@MainActor
enum ConsoleSeamFactory {
    /// PitboxConsole's console over `inputs`, with `memory` (one `SandboxMemory` for the app's life).
    static func make(_ inputs: ConsoleSeamInputs, memory: SandboxMemory) -> ConsoleSeam {
        PitboxConsoleSeam(inputs: inputs, memory: memory)
    }

    /// `console {fontSize, theme}` mapped by hand onto the console's settings (the rest stays at the console's defaults).
    nonisolated static func terminalSettings(_ settings: CodeSettings) -> TerminalSettings {
        var terminal = TerminalSettings.standard
        let range = TerminalSettings.fontSizeRange
        terminal.fontSize = min(max(settings.console.fontSize, range.lowerBound), range.upperBound)
        switch settings.console.theme {
        case .system: terminal.appearance = .system
        case .light: terminal.appearance = .light
        case .dark: terminal.appearance = .dark
        }
        return terminal
    }

    /// The sandbox policy for one spawn: the announced folders the dock hosts gave (the append-only memory, plus what
    /// the verified hosts of this process announced, so a full memory never leaves a connected host's folders open) and
    /// the settings' `sandboxDenyFolders` and `sandboxAllowSocketFolders`. Pitbox's own folder and the Application
    /// Support tree are the console's fixed rules, not inputs.
    nonisolated static func sandboxPolicy(_ settings: CodeSettings, memory: SandboxMemory,
                                          announced: AnnouncedFolders.Lists = AnnouncedFolders.Lists()) -> CommandSandbox.Policy {
        CommandSandbox.Policy(announcedFolders: memory.folders(adding: announced.folders),
                              announcedSocketFolders: memory.socketFolders(adding: announced.socketFolders),
                              denyFolders: settings.sandboxDenyFolders, allowSocketFolders: settings.sandboxAllowSocketFolders)
    }

    /// `commands` as the sheet reads it (anything but "run" is Copy only).
    nonisolated static func runPolicy(_ settings: CodeSettings) -> CommandRunPolicy {
        CommandRunPolicy(settingsValue: settings.commands.rawValue)
    }

    /// `CodeResultFiles`' rule as the console's type.
    nonisolated static func fetchedOpening(fileName: String) -> FetchedFileOpening {
        FetchedFileOpening(rawValue: CodeResultFiles.fetchedOpening(fileName: fileName).rawValue) ?? .showInFinderOnly
    }
}

/// PitboxConsole wired for the block: `ConsoleHost` (Pitbox mode: no plain shells), its `ConsoleDrawer` (the console's
/// hooks: reveal and hold, the 0.35 s rule, release) and the `CommandSheetController` with the run policy, behind a
/// presenter that only forwards (and notices runs starting and ending, for the rail's dot).
@MainActor
final class PitboxConsoleSeam: ConsoleSeam {
    let host: ConsoleHost
    let drawer: ConsoleDrawer
    let sheet: CommandSheetController
    let memory: SandboxMemory
    private let watcher: RunWatchingPresenter
    private var lastRunning = false

    var presenter: CommandOfferPresenting { watcher }
    var drawerView: NSView? { drawer.view }
    var drawerHeight: CGFloat { drawer.height }
    var onDrawerHeightChanged: ((CGFloat) -> Void)?
    var commandRunning: Bool { host.runningCommandCount > 0 }
    var onCommandRunningChanged: ((Bool) -> Void)?

    init(inputs: ConsoleSeamInputs, memory: SandboxMemory) {
        self.memory = memory
        let settings = inputs.settings
        let announced = inputs.announcedFolders
        let keyboard = inputs.keyboardRequester
        host = ConsoleHost(settings: ConsoleSeamFactory.terminalSettings(settings()),
                           sandboxPolicy: { ConsoleSeamFactory.sandboxPolicy(settings(), memory: memory, announced: announced()) },
                           keyboardRequester: { needs in Self.onMain { keyboard(needs) } })
        let canShow = inputs.blockCanShow
        let ensure = inputs.ensureBlockShown
        drawer = ConsoleDrawer(console: host,
                               blockCanShow: { MainActor.assumeIsolated { canShow() } },
                               ensureBlockShown: { done in
                                   Self.onMain { ensure { shown in done(shown) } }
                               })
        let preview = inputs.previewFetchedFile
        sheet = CommandSheetController(console: host,
                                       commandShell: { settings().commandShell == .login ? .login : .clean },
                                       extraPath: { settings().usableExtraPath() },
                                       runPolicy: { ConsoleSeamFactory.runPolicy(settings()) },
                                       fetchedFileOpening: { ConsoleSeamFactory.fetchedOpening(fileName: $0) },
                                       previewFetchedFile: { url, frame in preview(url, frame) })
        watcher = RunWatchingPresenter(sheet: sheet)
        let anchor = inputs.anchorWindow
        watcher.beforePresent = { [weak sheet] in sheet?.anchorWindow = anchor() }
        let anchorFrame = inputs.anchorFrame
        sheet.anchorFrame = { MainActor.assumeIsolated { anchorFrame() } }
        watcher.onRunEvent = { [weak self] in self?.runningMayHaveChanged() }
        drawer.onHeightChanged = { [weak self] height in
            self?.onDrawerHeightChanged?(height)
            self?.runningMayHaveChanged()
        }
        Log.info("console: wired (drawer, run sheet, run policy, sandbox policy)", "console")
    }

    func revealRun(_ runID: UUID) { host.selectCommandTab(runID: runID) }

    func blockHidden() {
        drawer.blockHidden()
        sheet.dismissSheet()
    }

    func update(settings: CodeSettings) {
        host.update(settings: ConsoleSeamFactory.terminalSettings(settings))
        memory.reload()
    }

    func shutdown() { host.shutdown() }

    /// A run started or ended, or the drawer changed: the rail's dot follows (now and once more on the next main-queue
    /// turn, after the console has counted the tab).
    private func runningMayHaveChanged() {
        report()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.report() } }
    }

    private func report() {
        let running = commandRunning
        guard running != lastRunning else { return }
        lastRunning = running
        onCommandRunningChanged?(running)
    }

    /// Runs `body` on the main actor: at once on the main thread, else on the next turn of the main queue.
    nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(body) } else { DispatchQueue.main.async { MainActor.assumeIsolated(body) } }
    }
}

/// The block's presenter: forwards everything to the run sheet unchanged (it never presents, starts, copies or types
/// anything itself), sets the sheet's anchor window just before a sheet opens, and notices the events of a run starting
/// or ending.
@MainActor
final class RunWatchingPresenter: CommandOfferPresenting {
    private let sheet: CommandOfferPresenting
    /// Called before each sheet opens.
    var beforePresent: () -> Void = {}
    /// A run started, finished or was stopped.
    var onRunEvent: () -> Void = {}

    init(sheet: CommandOfferPresenting) { self.sheet = sheet }

    func present(_ offer: CommandOffer, anchor: CGRect, freshness: CommandOfferFreshnessChecking,
                 events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        beforePresent()
        sheet.present(offer, anchor: anchor, freshness: freshness, events: watched(events))
    }

    func presentFetch(_ request: FetchFileRequest, source: CommandOffer.Source, sessionIndex: Int, anchor: CGRect,
                      freshness: CommandOfferFreshnessChecking, events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        beforePresent()
        sheet.presentFetch(request, source: source, sessionIndex: sessionIndex, anchor: anchor, freshness: freshness,
                           events: watched(events))
    }

    func offerWentStale(_ offer: CommandOffer.ID) { sheet.offerWentStale(offer) }

    func offerWasSuperseded(_ offer: CommandOffer.ID, supersession: CommandOffer.Supersession) {
        sheet.offerWasSuperseded(offer, supersession: supersession)
    }

    func dismissSheet() { sheet.dismissSheet() }

    func revealRun(_ runID: UUID) { sheet.revealRun(runID) }

    /// The block's events, unchanged and in order; a run's start and end also reach `onRunEvent`, after the block.
    private func watched(_ events: @escaping @MainActor (CommandOfferEvent) -> Void) -> @MainActor (CommandOfferEvent) -> Void {
        { [weak self] event in
            events(event)
            if Self.isRunEvent(event) { self?.onRunEvent() }
        }
    }

    nonisolated static func isRunEvent(_ event: CommandOfferEvent) -> Bool {
        switch event {
        case .started, .finished, .stopped: return true
        case .copied, .typed, .fetched, .cancelled, .refused: return false
        }
    }
}
