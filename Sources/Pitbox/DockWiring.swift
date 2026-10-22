import AppKit
import PitboxDock
import PitboxKit
import PitboxSessions
import PitboxShell

/// The dock link's guest side wired into the app (docs/DOCK_PROTOCOL.md): the socket, the guest, and what each host
/// message does to the panel, the block, the command sandbox's memory and the menu; and what goes back to the host (the
/// area, the counts, the mirrored drop claims, the speech pause).
///
/// - **Docking on** (`dock.enabled`): the socket is bound at launch right after the single-instance lock and accepts at
///   once (`bind(_:)`); the guest starts once the app is wired (`start`). **Off:** no socket at all; a host's connects
///   fail and it retries at its own pace. Ticking docking on or off (the menu, or a hand edit) opens or closes the link
///   live: off sends `bye` with `settings`, goes alone and removes the socket; on binds a new socket.
/// - **A socket that cannot be bound** (a folder briefly unwritable, a squatter that exits) is tried again while docking
///   stays on: after 1 s, then twice as long each time, at most a minute apart.
/// - **Start order (docs/DOCK_PROTOCOL.md §8):** the panel's first show waits for the guest's first placement: at once
///   when no listed host app runs and none is connected, else within 1 s (docked beside the host, or alone if no
///   `place` came).
/// - **What the host can change** (the link invariant, docs/DOCK_PROTOCOL.md §11): the panel's place, level, visibility
///   and look; fold and unfold (shown at once; `folded` is written at most once a second, the last value winning, so a
///   host that folds and unfolds fast never writes the settings file at its line rate); the block's focus; the words
///   the spoken line avoids; the folders the command sandbox denies (append-only); whether the spoken line may speak
///   now. Nothing else: every target is a plain call with plain values.
/// - **The menu** is told when something it shows changed (the dock line; docked or alone; the host's display, edge,
///   level or visibility), not at every `place` of a host's live width drag.
@MainActor
final class DockWiring {
    /// Cancels a delayed call made by `Factory.after`.
    typealias Cancel = @MainActor () -> Void

    /// How the link's two parts are made: the real socket in the app's folder, or (tests) a temporary socket, fake peer
    /// checks, fake host apps and a manual clock.
    struct Factory {
        var listener: @MainActor () -> DockListener
        var guest: @MainActor (DockListener, DockGuest.Configuration) -> DockGuest
        /// Delayed main-thread calls (the bind retry, the held fold write): the main queue, or (tests) a manual clock.
        var after: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Cancel = Factory.mainQueue

        /// `dock.sock` in the app's private folder, the real peer checks, the workspace's apps and the system clock.
        static var live: Factory {
            Factory(listener: { DockListener() }, guest: { DockGuest(listener: $0, configuration: $1) })
        }

        /// `DispatchQueue.main.asyncAfter` with a cancellable work item.
        static func mainQueue(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Cancel {
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay.isFinite ? delay : 0), execute: item)
            return { item.cancel() }
        }
    }

    /// What the link drives besides the panel: plain calls into the block, the command sandbox's memory and the menu.
    struct Targets {
        /// The host's focus: a focus name (the block maps it through `focusProfiles`), or nil for everything.
        var setFocus: @MainActor (_ name: String?) -> Void = { _ in }
        /// Words the spoken line must never say (the host's wake words); empty when the host leaves.
        var setHostWakeWords: @MainActor (Set<String>) -> Void = { _ in }
        /// A verified host's private folders, for the sandbox memory (append-only; it refuses broad folders itself).
        var rememberPrivateFolders: @MainActor (_ folders: [String], _ socketFolders: [String]) -> Void = { _, _ in }
        /// Something the menu shows changed (the dock line, docked or alone, the host's display, edge, level or
        /// visibility): refresh the menu.
        var stateChanged: @MainActor () -> Void = {}
        /// Writes `folded` after a host's fold (held to at most one write per `foldWriteInterval`).
        var persistFolded: @MainActor (_ folded: Bool) -> Void = { _ in }
    }

    /// After a failed bind, the first retry waits this long; each further one twice as long, up to `bindRetryMax`.
    static let bindRetryFirst: TimeInterval = 1
    static let bindRetryMax: TimeInterval = 60
    /// A host's fold is written at most once per this many seconds (the last value wins).
    static let foldWriteInterval: TimeInterval = 1

    /// The build sent in `hello.build` (the bundle's short version, or "dev").
    nonisolated static var buildVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? "dev"
    }

    private let factory: Factory
    private let build: String
    /// The socket, while docking is on.
    private(set) var listener: DockListener?
    /// The guest, while docking is on.
    private(set) var guest: DockGuest?
    /// `dock.enabled` and `dock.hosts` in force.
    private(set) var settings = CodeSettings.Dock()
    /// The panel the link places (set by `start`).
    private(set) weak var panel: BlockPanelController?
    var targets = Targets()
    /// The flip reference for the host's region (`ScreenSpace.primaryHeight`; tests: a fixed one).
    var primaryHeight: @MainActor () -> CGFloat = { ScreenSpace.primaryHeight }
    /// True once `start` ran: a guest made later (docking ticked on) starts at once.
    private(set) var isStarted = false
    private var whenPlaced: (@MainActor () -> Void)?
    /// True until the first placement showed the panel: no area goes out for a panel that was never on screen.
    var awaitingFirstShow: Bool { whenPlaced != nil }
    /// The block's latest counts, kept for a guest made later (`attentionChanged`).
    var attention: (needsYou: Int, finished: Int, running: Int)?
    /// The host's latest focus name (nil: all), applied again when `focusProfiles` change.
    private(set) var hostFocus: String?
    /// What the verified hosts of this process announced (`hello.private`), for the sandbox policy at every spawn: kept
    /// for the process's life, read from any thread.
    let announced = AnnouncedFolders()
    /// Failed binds in a row while docking is on (a bound socket or docking off resets it).
    private(set) var bindFailures = 0
    private var bindRetry: Cancel?
    /// What the menu was last told (`menuMayHaveChanged`).
    private var menuKey: MenuKey?
    /// A host's fold is shown but not yet written; the app keeps the panel's fold over the file's meanwhile.
    private(set) var foldWritePending = false
    private var foldWriteHold: Cancel?

    /// What the menu shows of the link: its line, the host's name ("Dock with <host>"), and the host's display, edge,
    /// level and visibility while docked.
    private struct MenuKey: Equatable {
        var line: String
        var hostName: String?
        var displayID: CGDirectDisplayID?
        var edge: Edge?
        var level: HostPlace.Level?
        var visible: Bool?
    }

    init(factory: Factory = .live, build: String = DockWiring.buildVersion) {
        self.factory = factory
        self.build = build
    }

    // MARK: Launch, settings, quit

    /// Launch, right after the single-instance lock and before any window: with docking on, the socket is bound and
    /// accepts at once (a host that connects while the app starts gets its `hello` and waits); off, no socket.
    func bind(_ dock: CodeSettings.Dock) {
        settings = dock
        if dock.enabled { open() }
    }

    /// The app is wired: the guest takes over (and a host that connected meanwhile), the link drives `panel` and
    /// `targets`, and `whenPlaced` runs once at the first placement (the panel's first show): at once without a guest,
    /// or when the guest places the panel (at once, or within 1 s while a listed host app runs).
    func start(panel: BlockPanelController, targets: Targets, whenPlaced: @escaping @MainActor () -> Void) {
        guard !isStarted else { return }
        isStarted = true
        self.panel = panel
        self.targets = targets
        self.whenPlaced = whenPlaced
        if let guest {
            guest.start()
            pushAttention()
        } else {
            placementDone()
        }
    }

    /// `dock` changed (the menu's tick, the settings window or a hand edit): on/off opens or closes the link at once;
    /// a new `hosts` list applies to the next connection (and closes a connected host that is no longer listed).
    func settingsChanged(_ dock: CodeSettings.Dock) {
        let old = settings
        settings = dock
        if dock.hosts != old.hosts { guest?.setHosts(dock.hosts) }
        guard dock.enabled != old.enabled else { return }
        if dock.enabled {
            open()
        } else {
            close()
        }
        menuMayHaveChanged()
    }

    /// At quit, before anything else is taken down: a held fold written, `bye` with `quit`, the listener closed,
    /// `dock.sock` removed. The callbacks are dropped first, so the quit never moves the panel to the screen edge on
    /// its way out.
    func stop() {
        flushFoldWrite()
        cancelBindRetry()
        guard let guest else { return }
        release(guest)
        guest.stop()
    }

    // MARK: Opening and closing the link

    /// Binds a socket and makes a guest with the settings in force (the guest starts now if the app is wired).
    private func open() {
        guard guest == nil else { return }
        let listener = factory.listener()
        bindSocket(listener)
        let guest = factory.guest(listener, configuration)
        self.listener = listener
        self.guest = guest
        connect(guest)
        guard isStarted else { return }
        guest.start()
        pushAttention()
    }

    private var configuration: DockGuest.Configuration {
        DockGuest.Configuration(enabled: true, hosts: settings.hosts, build: build)
    }

    /// Binds `listener`. A failure is logged (labels and an errno only; the first tries, then every tenth) and tried
    /// again later while docking stays on.
    private func bindSocket(_ listener: DockListener) {
        do {
            try listener.bind(configuration: configuration)
            if bindFailures > 0 { Log.info("dock: socket bound after \(bindFailures) failed tries", "dock") }
            bindFailures = 0
        } catch {
            bindFailures += 1
            if bindFailures <= 6 || bindFailures % 10 == 0 {
                Log.warn("dock: socket not bound (\(error)), try \(bindFailures)", "dock")
            }
            let delay = min(Self.bindRetryMax, Self.bindRetryFirst * pow(2, Double(min(bindFailures - 1, 16))))
            cancelBindRetry()
            bindRetry = factory.after(delay) { [weak self] in self?.retryBind() }
        }
    }

    /// The retry's time: while docking is on and the socket is still not bound, bind again. A guest that already
    /// started decided its start without a socket (and told the menu so), so a new socket and guest take over; the old
    /// one never placed the panel beside a host, and its callbacks are dropped first.
    private func retryBind() {
        bindRetry = nil
        guard settings.enabled, let listener, let guest, !listener.isBound else { return }
        guard isStarted else { return bindSocket(listener) }   // the guest starts with it later
        release(guest)
        guest.stop()
        open()
        menuMayHaveChanged()
    }

    private func cancelBindRetry() {
        bindRetry?()
        bindRetry = nil
    }

    /// Docking turned off: a held fold written, the host gets `bye` with `settings`, the block goes alone (its look,
    /// focus and wake words reset), the socket is removed.
    private func close() {
        flushFoldWrite()
        cancelBindRetry()
        bindFailures = 0
        guard let guest else { return }
        guest.setEnabled(false)
        guest.stop()
        release(guest)
    }

    private func release(_ old: DockGuest) {
        old.onStateChanged = nil
        old.onPlace = nil
        old.onAppearance = nil
        old.onFocus = nil
        old.onFold = nil
        old.onHostWakeWords = nil
        old.onHostPrivateFolders = nil
        old.onHostAnnouncement = nil
        guest = nil
        listener = nil
    }

    // MARK: Host → guest

    private func connect(_ guest: DockGuest) {
        guest.onStateChanged = { [weak self] _ in self?.menuMayHaveChanged() }
        guest.onPlace = { [weak self] place in self?.placed(place) }
        guest.onAppearance = { [weak self] look in self?.panel?.apply(appearance: Self.blockAppearance(look)) }
        guest.onFocus = { [weak self] focus in self?.focused(focus) }
        guest.onFold = { [weak self] folded in self?.hostFolded(folded) }
        guest.onHostWakeWords = { [weak self] words in self?.targets.setHostWakeWords(Set(words)) }
        guest.onHostAnnouncement = { [weak self] whole in
            self?.announced.add(folders: whole.folders, socketFolders: whole.socketFolders)   // uncapped: denied for the run
        }
        guest.onHostPrivateFolders = { [weak self] remembered in
            self?.targets.rememberPrivateFolders(remembered.folders, remembered.socketFolders)
        }
    }

    /// A placement: beside the host, or alone at the screen edge (nil). The panel moves first; the first placement
    /// shows it; then the area answers the `place`.
    private func placed(_ place: HostPlace?) {
        guard let panel else { return }
        panel.setPlacement(place.map { .docked(Self.dockPlace($0)) } ?? .alone)
        placementDone()
        if let place { sendArea(seq: place.seq) }
        menuMayHaveChanged()
    }

    /// Tells the menu when something it shows changed. A host's live width drag (up to 30 places a second) moves the
    /// frame only, which the menu does not show.
    private func menuMayHaveChanged() {
        let place = guest?.state.place
        let key = MenuKey(line: menuLine, hostName: hostName, displayID: place?.displayID, edge: place?.edge,
                          level: place?.level, visible: place?.visible)
        guard key != menuKey else { return }
        menuKey = key
        targets.stateChanged()
    }

    // MARK: The host's fold

    /// The host folded or unfolded the block: shown at once (the panel's own fold, without its settings write), then
    /// `folded` is written at once or, within `foldWriteInterval` of the last write, when that interval ends.
    private func hostFolded(_ folded: Bool) {
        guard let panel, panel.isFolded != folded else { return }
        var shown = panel.settings
        shown.folded = folded
        panel.apply(shown)
        if foldWriteHold == nil { writeFold() } else { foldWritePending = true }
    }

    /// Writes the panel's fold (the last value wins) and holds the next write for `foldWriteInterval`.
    private func writeFold() {
        foldWritePending = false
        if let panel { targets.persistFolded(panel.isFolded) }
        foldWriteHold = factory.after(Self.foldWriteInterval) { [weak self] in
            guard let self else { return }
            self.foldWriteHold = nil
            if self.foldWritePending { self.writeFold() }
        }
    }

    /// Docking off or quit: a held fold is written now, so the file says what the panel shows.
    private func flushFoldWrite() {
        foldWriteHold?()
        foldWriteHold = nil
        guard foldWritePending else { return }
        foldWritePending = false
        if let panel { targets.persistFolded(panel.isFolded) }
    }

    private func placementDone() {
        guard let show = whenPlaced else { return }
        whenPlaced = nil
        show()
    }

    private func focused(_ focus: DockFocus) {
        switch focus {
        case .all: hostFocus = nil
        case .named(let name): hostFocus = name
        }
        targets.setFocus(hostFocus)
    }

    /// `focusProfiles` changed: the host's focus is mapped again (a docked focus name may now show other letters).
    func focusProfilesChanged() {
        guard hostFocus != nil else { return }
        targets.setFocus(hostFocus)
    }

    // MARK: Conversions (pure)

    /// The shell's docked placement for a host's `place`: the host's frame, display and edge, its level as a window
    /// level (above normal windows, or behind them; the panel clamps it), visibility, live drag, cell width and limit.
    static func dockPlace(_ place: HostPlace) -> DockPlace {
        let level = place.level == .above ? PanelLevel.aboveWindows : PanelLevel.desktop
        return DockPlace(hostFrame: place.host, displayID: place.displayID, edge: place.edge,
                         level: level.windowLevel.rawValue, visible: place.visible, live: place.live,
                         cell: place.cell.width, maxWidth: place.maxWidth)
    }

    /// The shell's look for a host's `appearance` (the same words on both sides).
    static func blockAppearance(_ look: DockAppearance) -> BlockAppearance {
        BlockAppearance(scheme: BlockAppearance.Scheme(rawValue: look.scheme.rawValue) ?? .system,
                        backdrop: BlockAppearance.Backdrop(rawValue: look.backdrop.rawValue) ?? .glass)
    }
}
