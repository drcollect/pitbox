import AppKit
import PitboxKit

/// The block: every Claude Code pop-out as a small dark monitor (headline, nickname, TL;DR or "Now", Ask line, offer
/// line, status · age · model) in the user's buckets (Unsorted first, then their own, made with "+ New
/// bucket"; `code-buckets.json`), each bucket in a fixed order (copy, then first seen, kept across restarts); per bucket
/// 1-4 monitors large, 5-9 medium, 10 or more small, 4 / 9 / 12 per page with dots, or slim rows (`look: "rows"`).
/// Monitors are dragged between buckets. A click on a screen pits the window or brings it back on track; resting 1.2 s on
/// a monitor opens its peek; the offer line opens the confirmation sheet through `CommandOfferPresenting` (the block never
/// runs anything). Below the buckets: the Ready list; under the header: the summary line.
///
/// A plain controller: the shell puts `makeView()` into its panel and feeds it the panel's rows, the
/// strip width, visibility, the keyboard and the focus; the app wires presence, speech and the result actions. One
/// model behind every view it makes.
///
/// Privacy: session text goes through one plain-text renderer; an off-screen copy of the view (a PDF, any snapshot)
/// draws only a redaction card; VoiceOver labels and log lines hold no session text; Hide text in the header (and
/// `showText` per copy) blanks the screens to headline and state.
///
/// Wiring (composition root, main thread):
/// ```swift
/// let parker = CodeWindowParker(stripRegions: { panel.regions })
/// let block = PitboxBlock(source: engine, parker: parker, presenter: sheet, freshness: resultChecks, settings: settings,
///                         dashboardOpener: CodeDashboardOpener { NSWorkspace.shared.open($0) })
/// block.rows = panel.rows; block.stripWidthProvider = { panel.cellStripWidth }
/// block.onAttentionChanged = { counts in rail.setDots(counts) }       // at most once a second
/// block.keyboardRequester = { needs in panel.setNeedsKeyboard(needs) }  // a bucket's name field, Escape in a drag
/// panel.content = block.makeView()
/// block.enableReady(memory: memory, environment: ready)               // before start
/// block.start()                                                        // quit: block.stop() (writes buckets)
/// // panel shown/hidden/folded → block.setStripVisible(_:); fold and hide → block.dismissOverlays()
/// // ⌃⌥P → await block.parkFrontmostPopout(); settings watcher → block.update(settings:)
/// ```
@MainActor
public final class PitboxBlock {
    let model: CodeMonitorsModel
    /// Opens a session's dashboard: the composition root's `NSWorkspace.shared.open`.
    let dashboardOpener: CodeDashboardOpener
    private var attention: CodeAttentionThrottle?

    /// - Parameters:
    ///   - source: the sessions (`CodeSessionsEngine`; a fake in tests). The block owns its `onChange`.
    ///   - parker: the window side (`CodeWindowParker`). The block owns its `onChange` and drives `update(sessions:)` and
    ///     `setActive(_:)`.
    ///   - presenter: the console's command sheet. Its `present` is the only thing an offer click does.
    ///   - freshness: the session side's click-time check, handed to the sheet.
    ///   - settings: the settings file (`showText` per copy and the rest are read here; `update(settings:)` for changes).
    ///   - buckets: `code-buckets.json`: the buckets and who sits where; read here, written on change.
    ///   - blockState: `block-state.json` (whether the one-time pit hint was shown); nil keeps it in memory.
    ///   - dashboardOpener: opens a dashboard's rebuilt address.
    public convenience init(source: CodeSessionsSource, parker: CodeWindowParking, presenter: CommandOfferPresenting,
                            freshness: CommandOfferFreshnessChecking, settings: CodeSettings = CodeSettings.loadOrCreate(),
                            buckets: URL = Paths.appSupport.appendingPathComponent("code-buckets.json"),
                            blockState: URL? = Paths.appSupport.appendingPathComponent("block-state.json"),
                            dashboardOpener: CodeDashboardOpener = CodeDashboardOpener { _ in }) {
        let model = CodeMonitorsModel(source: source, parker: parker, presenter: presenter, freshness: freshness,
                                      settings: settings, pasteboard: CodeGeneralPasteboard(),
                                      buckets: CodeBucketStore(url: buckets))
        model.pitHint = CodePitHint(url: blockState)
        self.init(model: model, dashboardOpener: dashboardOpener)
        model.installRunWords()
        model.installDashboardMarks(opener: dashboardOpener)
    }

    init(model: CodeMonitorsModel, dashboardOpener: CodeDashboardOpener = CodeDashboardOpener { _ in }) {
        self.model = model
        self.dashboardOpener = dashboardOpener
    }

    // MARK: Inputs from the shell

    /// The block's rows, derived from the panel's height by the shell (default 10). From
    /// `CodeTuning.readyTallTileRows` (12) on, the Ready list shows 6 cards instead of 3.
    public var rows: Int {
        get { model.tileRows }
        set { model.setRows(newValue) }
    }

    /// The strip width the monitors' column width is read from (`GridMetrics.cellWidth(forStripWidth:)`): the shell
    /// supplies it (alone: `2 × cell + gutter + 2 × padding`). Nil, or a width whose cell does not fit the view: the
    /// view's own width decides (the columns fill it, at least `GridMetrics.minCellWidth` each).
    public var stripWidthProvider: (@MainActor () -> CGFloat?)?

    /// The block's root view: the header (counts, Hide text, Pit all done, + New bucket), the summary line, the buckets
    /// and the Ready list below them. Every view shares the block's model; make one per panel.
    public func makeView() -> NSView {
        let view = CodeMonitorsTileView(model: model)
        view.stripWidthProbe = { [weak self] in self?.stripWidthProvider?() }
        view.foldButtonSide = { [weak self] in self?.onFoldRequested == nil ? nil : self?.foldButtonSide }
        view.onFold = { [weak self] in self?.onFoldRequested?() }
        let summary = CodeSummaryAccessory(model: model, opener: dashboardOpener)
        if let ready = model.ready {
            // The Ready list in the block view's Ready slot, one list view per root view; the summary line counts
            // from it.
            let list = ready.makeView()
            list.onHeightChange = { [weak view] in view?.accessoriesChanged() }
            view.readyAccessory = list
            summary.justFinished = { [weak ready] sessions in ready?.justFinished(in: sessions) ?? 0 }
            summary.ownActivityOnly = { [weak ready] in ready?.ownActivityOnly ?? [] }
        }
        view.summaryAccessory = summary
        dragToPark?.attach(tile: view)
        return view
    }

    /// The block became visible or hidden (shown, hidden, folded to the rail). Hidden: no window pass, the source's
    /// timers stop, peeks close and an open command sheet closes as a Cancel; drag-to-park follows.
    public func setStripVisible(_ visible: Bool) {
        model.setStripVisible(visible)
        dragToPark?.setStripVisible(visible)
    }

    /// The header's "−" was pressed (⌃⌥C and the menu fold the panel too): the app folds the panel. Nil: the header
    /// shows no "−".
    public var onFoldRequested: (@MainActor () -> Void)? {
        didSet { if (onFoldRequested == nil) != (oldValue == nil) { model.notify() } }
    }

    /// The header corner the "−" sits in: the block's window side (alone at the right screen edge: the left corner;
    /// docked: the host's side). Default left.
    public var foldButtonSide: Edge = .left {
        didSet { if foldButtonSide != oldValue { model.notify() } }
    }

    /// Closes peeks, the dashboards list and the sheet (as a Cancel): the shell calls it on fold and on hide.
    public func dismissOverlays() { model.closeOverlays() }

    /// Asks the panel for the keyboard (`true`) and hands it back (`false`): a bucket's name field while the user types
    /// it, and Escape during a drag between buckets. Nil: the field still works once the panel has the keyboard.
    public var keyboardRequester: ((Bool) -> Void)? {
        get { model.keyboardRequester }
        set { model.keyboardRequester = newValue }
    }

    /// The fold rail's dots: counts of monitors that need you, open Finished items and running sessions under the
    /// current focus, handed out when they change, at most once a second (the first at once). Set it before `start()`.
    public var onAttentionChanged: (@MainActor ((needsYou: Int, finished: Int, running: Int)) -> Void)? {
        didSet {
            guard let handler = onAttentionChanged else {
                attention = nil
                model.onAttentionCounts = nil
                return
            }
            let throttle = CodeAttentionThrottle { counts in handler(counts.tuple) }
            attention = throttle
            model.onAttentionCounts = { [weak throttle] counts in throttle?.note(counts) }
            if model.isStarted { model.rebuild() }
        }
    }

    /// The focus (which copies show while several run): nil or `.all` shows every copy.
    public func setFocus(_ focus: MonitorFocus?) { model.setFocus(focus ?? .all) }

    /// The focus a dock host names, mapped through the settings file's `focusProfiles` (unknown names show all).
    public func setFocus(named name: String) { model.setFocus(MonitorFocus.named(name, in: model.settings)) }

    /// The focus now.
    public var focus: MonitorFocus { model.focus }

    // MARK: Wiring from the app

    /// Ready for you, the Finished alerts and While you were away. Call once, before
    /// `makeView()` and `start()`, with the store the engine's derivers write (`engine.register(…, memory:)`) and the
    /// app's presence, sound and speech (`CodeReadyEnvironment`). Without it the block shows monitors only.
    public func enableReady(memory: CodeMemoryStore, environment: CodeReadyEnvironment) {
        guard model.ready == nil else { return }
        let model = self.model
        let opener = dashboardOpener
        let ready = CodeReadyForYou(memory: memory, settings: model.settings, environment: environment)
        ready.alerts.hostWakeWords = model.hostWakeWords
        ready.runWords = { session, now in
            RunText.isRunning(session) ? RunText.tag(session, now: now, clock: .system) ?? "Running" : nil
        }
        model.ready = ready
        // The bucket badges count the list's items; the unread dot sits in the monitors' chip slot.
        model.readyCounts = { [weak ready] session in
            let counts = ready?.counts(for: session.id) ?? (commands: 0, files: 0)
            return CodeReadyCounts(commands: counts.commands, files: counts.files)
        }
        model.itemDecorators.append { [weak model] session, item in
            guard let model, CodeUnreadMarks.showsDot(session, status: model.parker.statuses[session.id],
                                                      parked: model.parker.parkedSessionIDs) else { return }
            item.marks.append(CodeMonitorMark(id: nil, place: .cornerDot, text: "", short: "", fill: CodeUnreadMarks.dotFill,
                                              ink: 0x0F1115, label: CodeUnreadMarks.dotLabel, opens: false))
        }
        ready.onChange = { [weak self, weak model, weak ready] in
            guard let ready else { return }
            model?.readyChanged()
            self?.onReadySuppressionChange?(DeskTagSuppressed(offers: ready.list.snapshot.suppressedOffers,
                                                              warnings: ready.list.snapshot.okWarnings))
        }
        ready.onAction = { [weak model] action, anchor in
            guard let model else { return }
            Self.perform(action, anchor: anchor, model: model, opener: opener)
        }
        // A fetched document gets Open in its result row (a web document keeps Show in Finder there; the sheet offers
        // its Preview). OK on a warning silences it for the rest of the work, or the pair and file for 2 hours, through
        // the store the engine reads.
        ready.list.fetchedFileOpens = { CodeResultFiles.fetchedOpening(fileName: $0) == .open }
        ready.list.onWarningOK = { sessionID, warning in CodeWarningSilencer.silence(warning, of: sessionID, memory: memory) }
    }

    /// What the Ready list no longer shows (dismissed or run offers, warnings OK'd there), for the desk tags:
    /// `block.onReadySuppressionChange = { deskTags.setSuppressed($0) }`.
    public var onReadySuppressionChange: ((DeskTagSuppressed) -> Void)?

    /// Drag-to-park: set by the composition root before any view is made; each root view becomes
    /// the drop's target (its buckets, their outline, the move after a pit stop).
    public var dragToPark: CodeDragToPark? {
        didSet { model.needsWindowPassOffTile = dragToPark != nil || deskTagsActive }
    }

    /// Desk tags are shown (lab mode, or once their window-ordering check passed): the window pass keeps running while
    /// the block shows.
    public var deskTagsActive = false {
        didSet { model.needsWindowPassOffTile = dragToPark != nil || deskTagsActive }
    }

    /// `deskWindows: "tags"` takes desk pop-outs out of the buckets only once desk tags stand in for them. Set it to
    /// true when the desk tags run (and their window-ordering check passed); until then desk pop-outs keep their
    /// monitors.
    public var deskWindowsHaveTags: Bool {
        get { model.deskWindowsHaveTags }
        set { model.deskWindowsHaveTags = newValue }
    }

    /// What a press on a result does: the monitors' result lines, the peek's result buttons, the
    /// Ready cards' results, ⤓ Fetch… and fetched files, and the desk tags' results (`openResult`) go here, already
    /// armed. Set by the composition root (`CodeResultActions` over NSWorkspace, the web preview and the sheet); nil:
    /// result buttons do nothing.
    public var resultActions: CodeResultActions? {
        didSet {
            let actions = resultActions
            let model = self.model
            model.onResultClick = { [weak model] session, button, anchor in
                actions?.perform(button, session: session, anchor: anchor,
                                 severalCopies: (model?.source.runningProfiles.count ?? 1) > 1)
            }
            model.onFetchedFile = { name, open, anchor in
                if open { actions?.openFetched(fileName: name, anchor: anchor) } else { actions?.showFetchedInFinder(fileName: name) }
            }
        }
    }

    /// A click on a run's result line ("✓ exit 0 · 3 s"): the app selects that console tab and opens the console.
    /// Nil: the click does nothing.
    public var onRevealRun: (@MainActor (UUID) -> Void)? {
        get { model.onRevealRun }
        set { model.onRevealRun = newValue }
    }

    /// After every rebuild of the block's model (the composition root feeds the desk tags from here).
    public var onRebuilt: (() -> Void)? {
        get { model.onRebuilt }
        set { model.onRebuilt = newValue }
    }

    /// Hide text flipped in the header (the desk tags follow it).
    public var onHideTextChanged: ((Bool) -> Void)? {
        get { model.onHideTextChanged }
        set { model.onHideTextChanged = newValue }
    }

    /// Wake words a dock host announced: the spoken line never says them, like the settings file's `neverSay`.
    /// Empty while alone.
    public func setHostWakeWords(_ words: Set<String>) {
        model.hostWakeWords = words
        model.ready?.alerts.hostWakeWords = words
    }

    // MARK: Lifecycle and settings

    /// Starts the source and the window side. Call once, after wiring.
    public func start() { model.start() }

    /// Stops the source and the window pass, and writes pending bucket changes (quit).
    public func stop() {
        model.stop()
        model.buckets.flush()
    }

    /// The settings file changed (`CodeSettingsWatcher`, or a menu write's result): the monitors, the Ready list,
    /// drag-to-park and the engine follow at once. The desk tags have their own `update(settings:)`. Dashboard sites
    /// (`dashboards`) are built at start and apply after a restart.
    public func update(settings: CodeSettings) {
        model.update(settings: settings)
        dragToPark?.update(settings: settings)
        (model.source as? CodeSettingsReloading)?.reloadSettings()
    }

    /// The settings the block uses now.
    public var settings: CodeSettings { model.settings }

    // MARK: Actions

    /// Opens one result of a session after its click-time checks (desk tags' ↗ and ▤): its first button, as on the
    /// monitor's result line (Open, Preview or Show in Finder). Nothing happens without `resultActions`.
    public func openResult(_ resultID: String, sessionID: String, anchor: CGRect) {
        guard let session = model.source.sessions.first(where: { $0.id == sessionID }),
              let result = session.results.first(where: { $0.id == resultID }),
              let button = CodeResultWords.buttons(for: result).first else { return }
        model.onResultClick?(session, button, anchor)
    }

    /// Opens the sheet of an offer of any followed session, earlier replies included: the Ready list's path, so the
    /// sheet's events reach the run book and the list (desk tags call it).
    public func openOffer(_ offer: CommandOffer.ID, sessionID: String, anchor: CGRect) {
        model.openSheet(offer, sessionID: sessionID, anchor: anchor)
    }

    /// Opens a session's dashboard (desk tags' ▦): the URL is rebuilt from the site and handle, nothing is
    /// fetched.
    public func openDashboard(sessionID: String) {
        guard let session = model.source.sessions.first(where: { $0.id == sessionID }), let dashboard = session.dashboard
        else { return }
        _ = dashboardOpener.open(dashboard, sessionIndex: session.index)
    }

    /// ⌃⌥P (`hotkeys.park`): pits the frontmost Claude pop-out. The result's `hudLine` is the short line to show.
    /// A hotkey never runs a command and never confirms anything.
    public func parkFrontmostPopout() async -> CodeParkFrontmostResult {
        let result = await model.parker.parkFrontmostPopout()
        CodeTileLog.info("park front pop-out result=\(result.succeeded ? "parked" : "not parked")")
        return result
    }

    /// Counts only (monitors, in the pit, need you, offers, running commands), for the menu or a status line.
    public func status() -> CodeMonitorsStatus { model.status() }

    /// What a Ready card's button does in the block (the list handles Later, Dismiss, OK, Undo, Got it itself).
    static func perform(_ action: CodeReadyAction, anchor: CGRect, model: CodeMonitorsModel, opener: CodeDashboardOpener) {
        let session = { (id: String) in model.source.sessions.first { $0.id == id } }
        switch action {
        case .openSheet(let offerID, let sessionID):
            model.openSheet(offerID, sessionID: sessionID, anchor: anchor)
        case .showWindow(let sessionID):
            model.perform(.activate, sessionID)   // gap: raise one window without moving it
        case .showMonitor(let sessionID):
            model.revealMonitor(sessionID)
        case .openWindow(let sessionID):
            // In the pit: back on track; closed: Claude's main window; on the desk: activate. The list already closed
            // the Finished item and marked the session seen.
            guard let click = model.parker.statuses[sessionID]?.click, click != .none else { return }
            model.perform(click == .park ? .activate : click, sessionID)
        case .openInClaude(let sessionID):
            guard let found = session(sessionID) else { return }
            CodeReadyOpener.openInClaude(sessionID, profile: found.profile, processes: model.source.runningProcesses)
        case .openDashboard(let sessionID):
            model.openDashboard(sessionID: sessionID, opener: opener)
        case .revealRun(let runID):
            model.revealRun(runID)
        case .fetchResult(let sessionID, let result):
            // The Fetch file sheet (`presentFetch`) with the result's click-time check.
            guard let found = session(sessionID),
                  let fetch = CodeResultWords.buttons(for: result).first(where: { $0.action == .fetch }) else { return }
            model.onResultClick?(found, fetch, anchor)
        case .openResult(let sessionID, let result):
            // The first result's button (Open, Preview or Show in Finder), checked again at the click.
            guard let found = session(sessionID), let button = CodeResultWords.buttons(for: result).first else { return }
            model.onResultClick?(found, button, anchor)
        case .openFetched(let name):
            model.onFetchedFile?(name, true, anchor)
        case .showFetchedInFinder(let name):
            model.onFetchedFile?(name, false, anchor)
        case .later, .unfold, .dismiss, .undoDismiss, .ok, .gotIt, .showMore, .showHidden:
            break   // the list's own
        }
    }
}

/// A source that can be told the settings file changed (`CodeSessionsEngine.reloadSettings()`).
@MainActor
public protocol CodeSettingsReloading: AnyObject {
    func reloadSettings()
}

extension CodeSessionsEngine: CodeSettingsReloading {}

/// The Ready list fills the block view's Ready slot (`CodeMonitorsTileView.readyAccessory`).
extension CodeReadyListView: CodeTileAccessory {}
