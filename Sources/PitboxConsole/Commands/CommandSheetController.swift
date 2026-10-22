import AppKit
import PitboxKit

/// The command sheet: the only place a command from a Claude session can start, and only after the user's real click
/// on it.
///
/// `present(_:anchor:freshness:events:)` only shows the sheet. The sheet classifies the text again itself (it never
/// takes a class from the caller), binds the folder by descriptor and freezes what would run, all when it opens. Run
/// and Type start something only from a real left click on their button that began after the button armed, while the
/// sheet is fully visible, after a click-time check of the session (`freshness`), the files and the folder; then the
/// frozen copy is consumed once and handed to the terminal's internal command-tab path. The sheet never takes the
/// keyboard. It closes as a Cancel when the block hides (`dismissSheet()`), and after 10 minutes untouched.
///
/// `presentFetch(_:source:sessionIndex:anchor:freshness:events:)` shows the same sheet as the Fetch file sheet for a file
/// a session handed over or wrote on the server: no command text, nothing read, typed or run; Fetch
/// file only, after `freshness(ofResultFetch:toolUseID:path:)` answered `fresh` at the click.
///
/// Wiring (in the app):
/// ```swift
/// let sheet = CommandSheetController(console: console, commandShell: { codeSettings.commandShell },
///                                    extraPath: { codeSettings.extraPath },
///                                    runPolicy: { CommandRunPolicy(settingsValue: settings.commands) },
///                                    fetchedFileOpening: { FetchedFileOpening(rawValue:
///                                        CodeResultFiles.fetchedOpening(fileName: $0).rawValue) ?? .showInFinderOnly },
///                                    previewFetchedFile: { url, frame in webPreview.show(url, name: url.lastPathComponent,
///                                                                                        anchor: frame, beside: frame) })
/// sheet.anchorWindow = panel.window      // placement beside the block, level, appearance; hides with it
/// sheet.anchorFrame = { dock.isDocked ? dock.areaFrame : nil }   // docked: beside the whole docked area
/// codeMonitors.presenter = sheet        // CommandOfferPresenting
/// // the block hidden or folded: sheet.dismissSheet()
/// ```
@MainActor
public final class CommandSheetController: CommandOfferPresenting {
    /// The block's window the sheet sits beside (its frame, screen, level and appearance), on its window side; the sheet
    /// closes as a Cancel when this window hides. Nil places it by the anchor.
    public weak var anchorWindow: NSWindow? {
        didSet { observeAnchorWindow() }
    }

    /// The frame (screen coordinates) to sit beside instead of `anchorWindow`'s, read when a sheet opens: the docked
    /// area when the block is docked with a host (nil: the window's frame).
    public var anchorFrame: (() -> CGRect?)?

    /// How long an untouched sheet stays open.
    static let untouchedLimit: TimeInterval = 600
    /// How long "Copied" and "Opened" show.
    static let confirmationTime: TimeInterval = 2
    /// How often the sheet checks it is still fully visible while open.
    static let coverageInterval: TimeInterval = 0.25

    let host: CommandTabHost
    let classify: (String, CommandContext, CommandClassifierOptions) -> CommandAssessment
    let fetchRunner: FetchRunning?
    let commandShell: () -> CommandExecutionDescriptor.Shell
    let extraPath: () -> [String]
    /// The run policy (`commands` in the settings file): read when a sheet opens, again at every check while it is
    /// open, and again at the click; `copyOnly` (the default) shows no Run button and starts no Run tab. Tests replace
    /// it.
    var runPolicy: () -> CommandRunPolicy = { .copyOnly }
    let clock: () -> TimeInterval
    let pasteboard: NSPasteboard
    let home: String
    let userName: String
    /// File lookups for the second pass and the setuid note; tests replace them.
    var lookUpFacts: ([String]) async -> [String: CommandPathFact] = { await CommandFiles.lookUp($0) }
    /// The lookups for the session's folder (`folder(for:)`, the binding) and the network check they run under (the
    /// mount table now); tests replace them with a recording fake.
    var pathFileSystem: LocalPathFileSystem = LiveLocalPathFileSystem()
    var pathGuard: () -> NetworkPathGuard = { .current() }
    var setuidPrograms: ([String], String) async -> [String] = { await CommandFiles.setuidPrograms($0, path: $1) }
    /// Whether an alias is an exact `Host` token of `~/.ssh/config`; read off the main thread.
    var isExactAlias: (String) async -> Bool
    /// Whether the sheet is fully visible now; tests replace it (off-screen windows are never "visible").
    var isFullyVisible: (NSWindow) -> Bool = { CommandSheetCoverage.isFullyVisible($0) }
    /// Puts the panel on screen without making it key; tests replace it so no window appears.
    var present: (NSPanel) -> Void = { $0.orderFrontRegardless() }
    var hide: (NSPanel) -> Void = { $0.orderOut(nil) }
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Show in Finder after a fetch: reveals, never opens.
    var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// After a saved fetch: Open, Preview or nothing beside Show in Finder, by the saved name. Given
    /// at construction (the rule is PitboxSessions' `CodeResultFiles.fetchedOpening`).
    var fetchedFileOpening: (String) -> FetchedFileOpening = { _ in .showInFinderOnly }
    /// Open: the quarantined file in its default app, as a double-click in Finder would; tests replace it.
    var openFetchedFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Preview: Pitbox's script-free preview of a web document, beside the sheet's frame; nil offers no Preview.
    var previewFetchedFile: (@MainActor (URL, CGRect) -> Void)?
    /// The visible frame the sheet is placed in; nil means the anchor window's screen (tests give a small one).
    var screenFrame: (() -> CGRect)?

    /// The open sheet, if any (one at a time).
    private(set) var sheet: OpenSheet?
    /// Fetches that keep running after their sheet was dismissed by the system (the block hidden).
    var backgroundFetches: [UUID: FetchHandle] = [:]
    private var anchorObservers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - console: the console; command tabs open in it while its hooks say it can be shown (`commandHooks`).
    ///   - commandShell: from `code-settings.json`: `.clean` (default) or `.login`. Read when a sheet opens.
    ///   - extraPath: `extraPath` from `code-settings.json`: folders added to the clean shell's PATH (checked here too).
    ///   - runPolicy: `commands` from the settings file: `.copyOnly` (the default) or `.run`. Read when a sheet
    ///     opens and again at the click: a policy switched to `copyOnly` while a sheet is open refuses the click.
    ///   - fetchedFileOpening: after a saved fetch, what the saved name gets beside Show in Finder:
    ///     Open (documents), Preview (web documents) or nothing more. Default: Show in Finder only.
    ///   - previewFetchedFile: the script-free preview of a web document (PitboxSessions' `CodeWebPreviewController`),
    ///     beside the sheet's frame; nil offers no Preview.
    public convenience init(console: ConsoleHost,
                            commandShell: @escaping () -> CommandExecutionDescriptor.Shell = { .clean },
                            extraPath: @escaping () -> [String] = { [] },
                            runPolicy: @escaping () -> CommandRunPolicy = { .copyOnly },
                            fetchedFileOpening: @escaping (String) -> FetchedFileOpening = { _ in .showInFinderOnly },
                            previewFetchedFile: (@MainActor (URL, CGRect) -> Void)? = nil) {
        let environment = console.environment ?? .live
        self.init(host: console, classify: { CommandClassifier.assess(text: $0, context: $1, options: $2) },
                  fetchRunner: CommandSheetController.defaultFetchRunner(), commandShell: commandShell, extraPath: extraPath,
                  clock: MonotonicClock.now, pasteboard: .general, home: environment.home, userName: environment.userName)
        self.runPolicy = runPolicy
        self.fetchedFileOpening = fetchedFileOpening
        self.previewFetchedFile = previewFetchedFile
    }

    /// Internal initializer: every dependency injected (tests use fakes, never the real pasteboard or window server).
    init(host: CommandTabHost, classify: @escaping (String, CommandContext, CommandClassifierOptions) -> CommandAssessment,
         fetchRunner: FetchRunning?, commandShell: @escaping () -> CommandExecutionDescriptor.Shell, extraPath: @escaping () -> [String],
         clock: @escaping () -> TimeInterval, pasteboard: NSPasteboard, home: String, userName: String) {
        self.host = host
        self.classify = classify
        self.fetchRunner = fetchRunner
        self.commandShell = commandShell
        self.extraPath = extraPath
        self.clock = clock
        self.pasteboard = pasteboard
        self.home = home
        self.userName = userName
        isExactAlias = { alias in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: SSHConfigHosts.isExactAlias(alias, home: home))
                }
            }
        }
    }

    // MARK: CommandOfferPresenting

    public func present(_ offer: CommandOffer, anchor: CGRect, freshness: CommandOfferFreshnessChecking,
                        events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        if sheet != nil { close(reason: .replaced) }
        let shell = commandShell()
        let checked = pathGuard()
        // The session's folder on a refused root, by the session side's word or decided again now (a mount-table point
        // may have appeared since the offer was made): shown, never bound.
        let refusedFolder = Self.refusedWorkFolder(for: offer, guard: checked, fs: pathFileSystem)
        let folderInfo = refusedFolder.map { (path: $0, fallback: false) }
            ?? Self.folder(for: offer, home: home, guard: checked, fs: pathFileSystem)
        let binding: FolderBinding?
        var folderProblem: String?
        if refusedFolder != nil {
            // A session on an external or network volume: its folder is shown, never looked up or bound, so nothing can
            // start (the model keeps Run and Type off; Copy stays).
            binding = nil
            folderProblem = CommandSheetModel.refusedVolumeFolderWords
        } else {
            switch FolderBinding.bind(folderInfo.path, fs: pathFileSystem, guard: pathGuard) {
            case .success(let bound): binding = bound
            case .failure(let problem): binding = nil; folderProblem = problem.words
            }
        }
        let (path, ignored) = shell == .clean ? CommandEnvironmentRules.cleanPath(extraPath: extraPath())
            : (CommandEnvironmentRules.loginPath(environment: .live), [])
        for problem in ignored { CommandLog.code("extraPath entry ignored", ["reason": .label(problem)]) }
        let first = assess(offer.text, offer: offer, folder: folderInfo.path, facts: [:],
                           options: Self.options(shell: shell, offer: offer, mode: .ordinary(fromFetch: false)))
        let names = CommandEnvironmentRules.names(shell: shell, sshAgent: CommandEnvironmentRules.usesSSHAgent(first))
        let frozen = FrozenCommand(offerID: offer.id, text: offer.text, shell: shell, path: path, environmentNames: names,
                                   folder: binding)
        let mode: CommandSheetState.Mode
        if first.commandClass == .fetchFile, first.fetch != nil, fetchRunner != nil {
            mode = .fetch
        } else if first.commandClass == .fetchFile, fetchRunner == nil {
            mode = .ordinary(fromFetch: true)
        } else {
            mode = .ordinary(fromFetch: false)
        }
        var state = CommandSheetState(
            subject: .offer(offer), assessment: first, assessmentReady: false, mode: mode,
            folder: .init(path: folderInfo.path, shortPath: FolderBinding.shortPath(folderInfo.path, home: home),
                          isHomeFallback: folderInfo.fallback, problem: folderProblem),
            shell: shell)
        state.supersession = offer.supersession
        state.workFolderRefused = refusedFolder != nil
        state.runPolicy = runPolicy()
        state.typedText = frozen.typedText
        state.terminalBlocker = host.commandBlocker(role: .run)
        state.typeBlocker = host.commandBlocker(role: .typeIntoTerminal)
        state.howItRuns = Self.howItRuns(frozen: frozen, folder: folderInfo.path)
        if mode == .fetch { state.fetch = CommandSheetState.Fetch() }

        openSheet(state, frozen: frozen, anchor: anchor, freshness: freshness, events: events)
        CommandLog.code("sheet opened", ["offer": .offer(offer.id), "class": .label(first.commandClass),
                                         "flags": .number(first.flags.count), "complete": .flag(offer.replyReadCompletely)])
        reassess()
        checkServerAlias()
        if mode == .fetch { planFetch(loginUser: nil) }
    }

    /// A result fetch: the Fetch file sheet for a file a session handed over or wrote on the
    /// server, with the same rules, gates and arming as an offer's Fetch file, and no command text: nothing is read,
    /// typed or run, there is no Copy command and no "Run in terminal instead". The plan is made when the sheet opens
    /// (it reads the SSH config; nothing connects before the click on Fetch file). At the click
    /// `freshness.freshness(ofResultFetch:toolUseID:path:)` must answer `fresh` within 300 ms, else nothing starts. A
    /// request without `sourceToolUseID` cannot be checked, so it is never fetched. `events` gets what an offer's Fetch
    /// file gives: `fetched` once a fetch ends, `cancelled` when the sheet closes without one.
    public func presentFetch(_ request: FetchFileRequest, source: CommandOffer.Source, sessionIndex: Int, anchor: CGRect,
                             freshness: CommandOfferFreshnessChecking, events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        if sheet != nil { close(reason: .replaced) }
        let subject = ResultFetchSubject(request: request, source: source, sessionIndex: sessionIndex)
        var state = CommandSheetState(
            subject: .resultFetch(subject), assessment: CommandSheetState.noReading, assessmentReady: true, mode: .fetch,
            folder: .init(path: home, shortPath: "~", isHomeFallback: false, problem: Self.nothingRunsHere),
            shell: commandShell())
        state.fetch = CommandSheetState.Fetch()
        openSheet(state, frozen: nil, anchor: anchor, freshness: freshness, events: events)
        CommandLog.code("fetch sheet opened", ["offer": .resultFile(sessionIndex), "checkable": .flag(request.sourceToolUseID != nil)])
        if request.sourceToolUseID == nil {
            sheet?.state.fetch?.phase = .refused(Self.uncheckableWords)
            refresh()
        } else {
            planFetch(loginUser: nil)
        }
    }

    /// A result fetch's folder problem: its sheet has no run folder (nothing runs from it).
    static let nothingRunsHere = "nothing runs from this sheet"
    /// Why a result without its tool_use is never fetched: the click-time check could not find it again.
    static let uncheckableWords = "\(AppIdentity.displayName) can't tell which step of the session's work this file came from, so it can't fetch it."

    /// Shows a new sheet for `state`: the panel, the view, placement, arming, observers and timers.
    private func openSheet(_ state: CommandSheetState, frozen: FrozenCommand?, anchor: CGRect,
                           freshness: CommandOfferFreshnessChecking, events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        let panel = CommandSheetPanel()
        let open = OpenSheet(state: state, frozen: frozen, freshness: freshness, events: events, panel: panel,
                             anchor: anchor, clock: clock)
        let view = CommandSheetView(palette: CommandSheetPalette(anchorWindow?.effectiveAppearance ?? NSApp.effectiveAppearance),
                                    arming: { [weak open] in open?.arming ?? CommandArming() }, clock: clock)
        open.view = view
        panel.contentView = view
        panel.appearance = anchorWindow?.effectiveAppearance
        panel.onActivity = { [weak self] in self?.touched() }
        sheet = open
        wire(view)
        refresh()
        place()
        present(panel)
        open.fullyVisible = isFullyVisible(panel)
        rearm(reassess: false)
        startObservers(for: open)
        open.untouched = schedule(after: Self.untouchedLimit) { [weak self] in self?.close(reason: .timeout) }
        open.coverage = repeating(every: Self.coverageInterval) { [weak self] in self?.checkCoverage() }
    }

    public func offerWentStale(_ offer: CommandOffer.ID) {
        guard let sheet, sheet.state.offer?.id == offer else { return }
        markStale()
    }

    public func offerWasSuperseded(_ offer: CommandOffer.ID, supersession: CommandOffer.Supersession) {
        guard let sheet, sheet.state.offer?.id == offer, !sheet.state.stale else { return }
        sheet.state.supersession = supersession
        sheet.state.supersededWithoutDetails = false
        sheet.state.ticked.remove("R22")
        sheet.state.message = .init(text: "The session has moved on since you opened this. Tick the new line to run it anyway.",
                                    tone: .warning)
        CommandLog.code("sheet superseded", ["offer": .offer(offer)])
        refresh()
        rearm(reassess: true)
    }

    public func dismissSheet() {
        close(reason: .dismissed)
    }

    /// Selects the command tab of run `runID` and expands the terminal (a click on a result line). It never runs,
    /// types or focuses anything. (Call it on this class, or through the protocol once `revealRun` is a protocol
    /// requirement.)
    public func revealRun(_ runID: UUID) {
        _ = host.revealRun(runID)
    }

    /// The session side's answer at the click was `superseded(s)`: unless the sheet already showed exactly these facts
    /// under a ticked R22, nothing starts; R22 is (re)set with `s`, unticked, and the sheet re-arms.
    /// Returns true when the click may go on.
    func acceptSuperseded(_ s: CommandOffer.Supersession, verb: String) -> Bool {
        guard let sheet else { return false }
        let shownBefore = sheet.state.supersession != nil || sheet.state.supersededWithoutDetails
        if shownBefore, CommandSheetModel.r22Digest(sheet.state.supersession) == CommandSheetModel.r22Digest(s),
           sheet.state.ticked.contains("R22") {
            return true
        }
        sheet.state.supersession = s
        sheet.state.supersededWithoutDetails = false
        sheet.state.ticked.remove("R22")
        sheet.state.message = .init(text: "The session has moved on since you opened this. Tick the new line to \(verb) it anyway.",
                                    tone: .warning)
        CommandLog.code("click refused", ["offer": sheet.state.logSubject, "reason": .label(CommandLogWord.superseded)])
        refresh()
        rearm(reassess: false)
        return false
    }

    // MARK: State changes

    /// Re-renders the sheet from its state (content changes re-arm through `contentChanged`).
    func refresh() {
        guard let sheet, let view = sheet.view else { return }
        let model = CommandSheetModel(sheet.state, now: clock(), home: home, userName: userName)
        let changed = model != sheet.model
        sheet.model = model
        view.apply(model, text: sheet.state.offer?.text ?? "", displayLines: sheet.state.offer?.displayLines ?? [],
                   flags: sheet.state.assessment.flags)
        if changed { place() }
    }

    /// Arming starts again: presses in progress are dropped; the buttons redraw when they arm. With `reassess`, the
    /// sheet also reads the command again with fresh file facts.
    func rearm(reassess again: Bool, byChoice: Bool = false) {
        guard let sheet, let view = sheet.view else { return }
        sheet.arming.rearm(now: clock(), byChoice: byChoice)
        for button in view.armedControls { button.dropPress() }
        view.needsDisplay = true
        for control in view.armedControls { control.needsDisplay = true }
        sheet.armRedraw = [CommandArming.delay, CommandArming.riskyDelay].map { delay in
            schedule(after: delay + 0.02) { [weak self] in
                guard let view = self?.sheet?.view else { return }
                for control in view.armedControls { control.needsDisplay = true }
            }
        }
        if again { reassess() }
    }

    func touched() {
        guard let sheet else { return }
        sheet.untouched = schedule(after: Self.untouchedLimit) { [weak self] in self?.close(reason: .timeout) }
    }

    func markStale() {
        guard let sheet, !sheet.state.stale else { return }
        sheet.state.stale = true
        let words = sheet.state.resultFetch == nil ? "The session has moved on: this is from an older reply."
            : CommandSheetModel.resultStaleWords
        sheet.state.message = .init(text: words, tone: .warning)
        CommandLog.code("sheet stale", ["offer": sheet.state.logSubject])
        refresh()
        rearm(reassess: false)
    }

    // MARK: Reading the command (two passes)

    func assess(_ text: String, offer: CommandOffer, folder: String, facts: [String: CommandPathFact],
                options: CommandClassifierOptions) -> CommandAssessment {
        var context = offer.context
        context.runFolder = folder
        context.pathFacts = facts
        return classify(text, context, options)
    }

    /// What the classifier needs from the sheet besides the context: the shell (`commandShell`), the block's kind, and
    /// whether a Fetch file shape is recognised (not on the ordinary sheet of "Run in terminal instead").
    static func options(shell: CommandExecutionDescriptor.Shell, offer: CommandOffer, mode: CommandSheetState.Mode) -> CommandClassifierOptions {
        CommandClassifierOptions(shell: shell, blockKind: offer.blockKind, recognizesFetchFile: mode != .ordinary(fromFetch: true))
    }

    /// The options for the open sheet of `offer`.
    func options(for sheet: OpenSheet, offer: CommandOffer) -> CommandClassifierOptions {
        Self.options(shell: sheet.state.shell, offer: offer, mode: sheet.state.mode)
    }

    /// The second pass: `lstat` the targets the first pass listed, read again with those facts; and the setuid note.
    /// Run, Type and Fetch wait for it. A result for an older generation is dropped.
    func reassess() {
        // A result fetch has no command to read.
        guard let sheet, let offer = sheet.state.offer, let frozen = sheet.frozen else { return }
        sheet.generation += 1
        let generation = sheet.generation
        let folder = sheet.state.folder.path
        let options = options(for: sheet, offer: offer)
        let first = assess(offer.text, offer: offer, folder: folder, facts: [:], options: options)
        let path = frozen.path
        Task { @MainActor [weak self] in
            guard let self else { return }
            let facts = first.localTargets.isEmpty ? [:] : await self.lookUpFacts(first.localTargets)
            let programs = first.segments.compactMap(\.program)
            let setuid = await self.setuidPrograms(programs, path)
            guard let sheet = self.sheet, sheet.generation == generation else { return }
            let second = facts.isEmpty ? first : self.assess(offer.text, offer: offer, folder: folder, facts: facts, options: options)
            self.applyAssessment(second, setuid: setuid)
        }
    }

    func applyAssessment(_ assessment: CommandAssessment, setuid: [String]) {
        guard let sheet else { return }
        let before = sheet.state.assessment
        let wasReady = sheet.state.assessmentReady
        sheet.state.assessment = assessment
        sheet.state.assessmentReady = true
        sheet.state.setuidPrograms = setuid
        // Ticks stay only on red lines that are still there, unchanged (a changed line needs its own tick).
        let keys = Set(CommandSheetModel.redLines(sheet.state).map(CommandSheetModel.key(of:)))
        sheet.state.ticked = sheet.state.ticked.intersection(keys)
        let changed = before != assessment
        if changed, wasReady {
            sheet.state.message = .init(text: "What this command touches changed since you looked; review it again.", tone: .warning)
            CommandLog.code("sheet assessment changed", ["offer": sheet.state.logSubject, "class": .label(assessment.commandClass)])
        }
        refresh()
        if changed || !wasReady { rearm(reassess: false) }
    }

    private func checkServerAlias() {
        guard let sheet, let offer = sheet.state.offer else { return }
        var candidates: [String] = []
        if case .remote(let host) = sheet.state.assessment.machine { candidates.append(host) }
        if let alias = offer.context.facts.sshAlias { candidates.append(alias) }
        guard !candidates.isEmpty else { return }
        let id = sheet.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            var verified: String?
            for candidate in candidates where SSHConfigHosts.isWellFormedAlias(candidate) {
                if await self.isExactAlias(candidate) { verified = candidate; break }
            }
            guard let sheet = self.sheet, sheet.id == id else { return }
            sheet.state.serverAlias = verified
            self.refresh()
        }
    }

    // MARK: Placement and observers

    func place() {
        guard let sheet, let view = sheet.view else { return }
        let screen = screenFrame?()
            ?? (anchorWindow?.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(sheet.anchor) }) ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width = Self.width(for: sheet.state.offer?.text ?? "", screen: screen)
        if view.frame.width != width { view.setFrameSize(CGSize(width: width, height: view.frame.height)) }
        let natural = view.naturalHeight(width: width)
        var frame: CGRect
        if let placed = sheet.placedFrame {
            // Later changes keep the sheet where it is (its top edge stays), only its height follows the content: it
            // never jumps away from (or onto) the pointer that is working in it. Kept on screen.
            let height = min(natural, max(screen.height * CommandSheetPlacement.heightShare, 200), screen.height - 2 * CommandSheetPlacement.margin)
            frame = CGRect(x: placed.minX, y: placed.maxY - height, width: width, height: height)
            frame.origin.x = min(max(frame.minX, screen.minX + CommandSheetPlacement.margin), screen.maxX - CommandSheetPlacement.margin - width)
            frame.origin.y = min(max(frame.minY, screen.minY + CommandSheetPlacement.margin), screen.maxY - CommandSheetPlacement.margin - height)
        } else {
            // Opening: beside the block on its window side, level with the monitor, never under the pointer.
            frame = CommandSheetPlacement.frame(size: CGSize(width: width, height: natural), anchor: sheet.anchor,
                                                block: anchorFrame?() ?? anchorWindow?.frame, screen: screen,
                                                pointer: pointerLocation())
        }
        sheet.placedFrame = frame
        if let anchorWindow {
            sheet.panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, anchorWindow.level.rawValue + 1))
        }
        if sheet.panel.frame != frame { sheet.panel.setFrame(frame, display: sheet.panel.isVisible) }
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.layoutSubtreeIfNeeded()
        sheet.panel.invalidateShadow()
    }

    /// 720 pt, up to 960 for long lines.
    static func width(for text: String, screen: CGRect) -> CGFloat {
        let longest = text.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0
        let wanted = CGFloat(longest) * 7.9 + 2 * CommandSheetView.side + 60
        return min(max(CommandSheetView.defaultWidth, min(wanted, CommandSheetView.maxWidth)), screen.width - 20)
    }

    private func startObservers(for open: OpenSheet) {
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, _ object: Any?, center: NotificationCenter = .default, reassess: Bool) {
            open.observers.append((center, center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged(reassess: reassess) }
            }))
        }
        watch(NSWindow.didMoveNotification, open.panel, reassess: false)
        watch(NSWindow.didResizeNotification, open.panel, reassess: false)
        watch(NSWindow.didChangeOcclusionStateNotification, open.panel, reassess: false)
        watch(NSWindow.didChangeScreenNotification, open.panel, reassess: false)
        watch(NSApplication.didChangeScreenParametersNotification, nil, reassess: true)
        let workspace = NSWorkspace.shared.notificationCenter
        watch(NSWorkspace.didWakeNotification, nil, center: workspace, reassess: true)
        watch(NSWorkspace.screensDidWakeNotification, nil, center: workspace, reassess: true)
        watch(NSWorkspace.sessionDidBecomeActiveNotification, nil, center: workspace, reassess: true)
        let distributed = DistributedNotificationCenter.default()
        open.observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.environmentChanged(reassess: true) }
        }))
        _ = center
    }

    /// Something around the sheet changed: arming starts again (and, for wake, unlock or displays, the command is read
    /// again with fresh file facts).
    func environmentChanged(reassess: Bool) {
        guard sheet != nil else { return }
        rearm(reassess: reassess)
        refreshBlocker()
    }

    private func refreshBlocker() {
        guard let sheet else { return }
        if runPolicyTurnedOff() {
            refresh()
            rearm(reassess: false)
        }
        let blocker = host.commandBlocker(role: .run)
        let typeBlocker = host.commandBlocker(role: .typeIntoTerminal)
        if blocker != sheet.state.terminalBlocker || typeBlocker != sheet.state.typeBlocker {
            sheet.state.terminalBlocker = blocker
            sheet.state.typeBlocker = typeBlocker
            refresh()
            rearm(reassess: false)
        }
    }

    private func observeAnchorWindow() {
        for observer in anchorObservers { NotificationCenter.default.removeObserver(observer) }
        anchorObservers = []
        guard let anchorWindow else { return }
        anchorObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                      object: anchorWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.anchorWindow else { return }
                if !window.isVisible || !window.occlusionState.contains(.visible) { self.close(reason: .blockHidden) }
                else { self.environmentChanged(reassess: false) }
            }
        })
    }

    /// While open, four times a second: arming counts only while the sheet is fully visible, and the
    /// terminal's limits are read again (a tab closed elsewhere can switch Run on).
    private func checkCoverage() {
        guard let sheet else { return }
        let visible = isFullyVisible(sheet.panel)
        if visible != sheet.fullyVisible {
            sheet.fullyVisible = visible
            if visible { rearm(reassess: false) }
            sheet.view?.needsDisplay = true
        }
        sheet.blockerPoll += 1
        if sheet.blockerPoll % 4 == 0 { refreshBlocker() }
        let now = clock()
        if let until = sheet.state.copiedUntil, until <= now { sheet.state.copiedUntil = nil; refresh() }
        if let until = sheet.state.copiedCleanedUntil, until <= now { sheet.state.copiedCleanedUntil = nil; refresh() }
        if let until = sheet.state.openedServerUntil, until <= now { sheet.state.openedServerUntil = nil; refresh() }
    }

    // MARK: Closing

    enum CloseReason: String, CommandLogLabel {
        case cancel, dismissed, blockHidden = "block-hidden", timeout, replaced, ran, typed, fetchCancelled = "fetch-cancelled"
        var logLabel: String { rawValue }
    }

    /// Closes the sheet. Every way out but a Run or Type reports `cancelled`; a running fetch keeps
    /// running unless the user pressed Cancel.
    func close(reason: CloseReason) {
        guard let open = sheet else { return }
        sheet = nil
        for (center, observer) in open.observers { center.removeObserver(observer) }
        open.observers = []
        open.untouched = nil
        open.coverage?.invalidate()
        open.coverage = nil
        open.armRedraw = []
        open.frozen?.discard()
        if let handle = open.fetchHandle {
            if reason == .fetchCancelled || reason == .cancel { handle.cancel() } else { backgroundFetches[open.id] = handle }
        }
        hide(open.panel)
        open.panel.contentView = nil
        CommandLog.code("sheet closed", ["offer": open.state.logSubject, "reason": .label(reason)])
        switch reason {
        case .ran, .typed: break
        default:
            if !open.fetchStarted { open.events(.cancelled) }
        }
    }

    // MARK: Helpers

    /// The folder a run starts in, decided by the sheet itself from the session facts: a local session's own
    /// folder when it exists here, else the home folder (also for every command an SSH session hands to the Mac, and
    /// for a session whose place is unknown: the sheet says so). A folder under a network or automount root is never
    /// looked up: it is kept, so the binding refuses it with its reason ("on a network or another volume") and nothing
    /// runs, rather than silently running somewhere else. A session already known to work on such a root
    /// (`refusedLocalCwd`) gets its folder back as it is, to be shown: it is never bound, and nothing of it runs.
    static func folder(for offer: CommandOffer, home: String, guard pathGuard: NetworkPathGuard,
                       fs: LocalPathFileSystem) -> (path: String, fallback: Bool) {
        let facts = offer.context.facts
        if CommandSheetModel.worksOnRefusedVolume(facts), let refused = facts.refusedLocalCwd { return (refused, false) }
        guard facts.place == .local else { return (home, false) }
        if let cwd = facts.localCwd, cwd.hasPrefix("/"), !cwd.contains("\0") {
            switch LocalPathWalk.resolve(cwd, followLastLink: true, guard: pathGuard, fs: fs) {
            case .network:
                return (cwd, false)
            case .found(_, let info) where info.kind == .directory:
                return (cwd, false)
            default:
                break
            }
        }
        return (home, true)
    }

    /// The session's folder when the session works on an external or network volume: the session side's word
    /// (`refusedLocalCwd`), or, decided again now, its folder on this Mac (`localWorkFolder`, else `localCwd`) walked
    /// part by part under the network check (local lookups only; nothing at or below a refused root). Nil for SSH
    /// sessions and for every other folder.
    static func refusedWorkFolder(for offer: CommandOffer, guard pathGuard: NetworkPathGuard, fs: LocalPathFileSystem) -> String? {
        let facts = offer.context.facts
        guard facts.place != .ssh else { return nil }
        if let refused = facts.refusedLocalCwd { return refused }
        guard let folder = facts.localWorkFolder ?? facts.localCwd, folder.hasPrefix("/"), !folder.contains("\0") else { return nil }
        return LocalPathWalk.resolve(folder, followLastLink: true, guard: pathGuard, fs: fs) == .network ? folder : nil
    }

    /// At a click: the session's folder turned out to be on a refused root. The sheet says so, lets go of its folder and
    /// keeps Run and Type off from now on (Copy stays).
    func markWorkFolderRefused(_ folder: String) {
        guard let sheet else { return }
        sheet.state.workFolderRefused = true
        sheet.state.machinePick = nil
        sheet.state.folder = .init(path: folder, shortPath: FolderBinding.shortPath(folder, home: home), isHomeFallback: false,
                                   problem: CommandSheetModel.refusedVolumeFolderWords)
        if let frozen = sheet.frozen {
            frozen.discard()
            sheet.state.howItRuns = Self.howItRuns(frozen: frozen, folder: folder)
        }
        sheet.state.message = .init(text: CommandSheetModel.refusedVolumeWords, tone: .problem)
        refresh()
        rearm(reassess: false)
    }

    static func howItRuns(frozen: FrozenCommand, folder: String) -> [[CommandSheetModel.Part]] {
        let options = CommandEnvironmentRules.arguments(kind: .run, shell: frozen.shell).joined(separator: " ")
        let identity: String
        switch CommandSpawnPath.configured {
        case .helper:
            identity = "as its own app (macOS asks for permissions in its own name), without access to \(AppIdentity.displayName)'s private files and sockets"
        case .forkpty:
            identity = "with \(AppIdentity.displayName)'s own macOS permissions (the fallback spawn path is on)"
        }
        let names = frozen.environmentNames.joined(separator: ", ")
        let bound = frozen.folder != nil ? "  (bound when this sheet opened; if it changes, nothing runs)"
            : "  (not bound: nothing runs from this sheet)"
        return [
            [.dim("Shell   "), .mono("/bin/zsh \(options) <the text above>")],
            [.dim("PATH    "), .mono(frozen.path)],
            [.dim("Folder  "), .mono(folder), .dim(bound)],
            [.dim("Env     "), .host(names + "; nothing else")],
            [.dim("Tab     "), .host("a new tab, never saved; its output stays until you close it; no restart")],
            [.dim("Runs    "), .host(identity)],
            [.dim("Reader  "), .host("command reader policy \(CommandClassifier.policyVersion), hidden characters policy \(CommandHiddenCharacters.policyVersion)")],
        ]
    }

    func schedule(after delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in MainActor.assumeIsolated { block() } }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func repeating(every interval: TimeInterval, _ block: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { block() } }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// One open sheet: its state, its frozen copy, its window and its timers.
@MainActor
final class OpenSheet {
    let id = UUID()
    var state: CommandSheetState
    /// What one approval of an offer covers; nil for a result fetch, which runs nothing.
    let frozen: FrozenCommand?
    let freshness: CommandOfferFreshnessChecking
    let events: @MainActor (CommandOfferEvent) -> Void
    let panel: CommandSheetPanel
    let anchor: CGRect
    var view: CommandSheetView?
    var model: CommandSheetModel?
    var arming = CommandArming()
    var generation = 0
    var fullyVisible = false
    var blockerPoll = 0
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var untouched: Timer? { didSet { oldValue?.invalidate() } }
    var coverage: Timer?
    var armRedraw: [Timer] = [] { didSet { oldValue.forEach { $0.invalidate() } } }
    var fetchHandle: FetchHandle?
    /// Plans answered for an older login-user choice are dropped.
    var fetchGeneration = 0
    /// A fetch started from this sheet: closing it afterwards is not a Cancel.
    var fetchStarted = false
    /// "Open a terminal on <host>" was pressed and the console has not answered yet.
    var serverTabPending = false
    /// Where the sheet was placed; after the first placement it stays there.
    var placedFrame: CGRect?

    init(state: CommandSheetState, frozen: FrozenCommand?, freshness: CommandOfferFreshnessChecking,
         events: @escaping @MainActor (CommandOfferEvent) -> Void, panel: CommandSheetPanel, anchor: CGRect,
         clock: () -> TimeInterval) {
        self.state = state
        self.frozen = frozen
        self.freshness = freshness
        self.events = events
        self.panel = panel
        self.anchor = anchor
    }
}
