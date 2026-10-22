import AppKit
import Foundation
import PitboxKit

/// Copies text for the block. Command text goes out marked concealed and transient, so well-behaved clipboard managers
/// never keep it.
@MainActor
protocol CodeMonitorPasteboard: AnyObject {
    func copyPrivately(_ text: String)
    func copy(_ text: String)
}

/// The general pasteboard.
@MainActor
final class CodeGeneralPasteboard: CodeMonitorPasteboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func copyPrivately(_ text: String) {
        let board = NSPasteboard.general
        board.declareTypes([.string, Self.concealed, Self.transient], owner: nil)
        board.setString(text, forType: .string)
        board.setData(Data(), forType: Self.concealed)
        board.setData(Data(), forType: Self.transient)
    }

    func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// The Code monitors block's state, shared by every view of the kind.
/// Main thread.
@MainActor
final class CodeMonitorsModel {
    let source: CodeSessionsSource
    let parker: CodeWindowParking
    let presenter: CommandOfferPresenting
    let freshness: CommandOfferFreshnessChecking
    let pasteboard: CodeMonitorPasteboard
    /// The user's buckets and who sits where (`code-buckets.json`; in memory only unless the block gives a file).
    let buckets: CodeBucketStore
    private(set) var settings: CodeSettings
    private(set) var focus: MonitorFocus = .all
    private(set) var hideText = false
    private(set) var snapshot = CodeMonitorsSnapshot()
    /// The sessions behind the members passing the focus, in their stable order (pop-outs on the desk too).
    private(set) var shownSessions: [CodeSessionSnapshot] = []
    /// The fold rail's counts after every rebuild (the block throttles them to once a second).
    var onAttentionCounts: ((CodeAttentionCounts) -> Void)?
    /// The one-time "In the pit" hint under the header; the block installs it (nil: no hint).
    var pitHint: CodePitHint?
    /// A click on a run's result line: the app selects that terminal tab and expands the terminal.
    var onRevealRun: (@MainActor (UUID) -> Void)?
    /// The clock (tests replace it).
    var now: () -> Date = { Date() }
    var homeDirectory = NSHomeDirectory()

    // MARK: Hooks (the other features plug in here)

    /// Desk windows lose their monitors (`deskWindows: "tags"`, the default) only once desk tags stand in for them.
    /// The composition root sets it when desk tags run; until then desk pop-outs keep their monitors.
    var deskWindowsHaveTags = false { didSet { if deskWindowsHaveTags != oldValue, started { rebuild() } } }
    /// Asks the panel for the keyboard (`true`) and hands it back (`false`): a bucket's name field and Escape during a
    /// drag. Set through the block (`panel.setNeedsKeyboard`).
    var keyboardRequester: ((Bool) -> Void)?
    /// A session's command and file items in Ready, for the bucket badges; nil counts the snapshot's offers.
    var readyCounts: ((CodeSessionSnapshot) -> CodeReadyCounts)?
    /// Other features' additions to each monitor item (marks, …), run in order after the item is built. They get the
    /// session as the data side gave it; session text they put on an item must go through `CodePlainText`.
    var itemDecorators: [(CodeSessionSnapshot, inout CodeMonitorItem) -> Void] = []
    /// A click on a monitor's mark (`CodeMonitorMark.id`), with the session id.
    var onMarkClick: ((_ sessionID: String, _ markID: String) -> Void)?
    /// An armed press on a result (a monitor's result line, a result button of its peek, a Ready card's result or
    /// ⤓ Fetch…, a desk tag's result), with the session as the data side gave it and the anchor (screen coordinates): the
    /// block hands it to `CodeResultActions.perform`.
    var onResultClick: ((_ session: CodeSessionSnapshot, _ button: CodeResultButton, _ anchor: CGRect) -> Void)?
    /// Open (`open`) or Show in Finder of a file Fetch file saved, from a Ready result row, by its saved name.
    var onFetchedFile: ((_ fileName: String, _ open: Bool, _ anchor: CGRect) -> Void)?
    /// Ready for you, Finished alerts, While you were away (nil: the block without them).
    var ready: CodeReadyForYou?
    /// The block's rows, from the panel's height (12 or more: 6 Ready cards instead of 3).
    var tileRows = 10
    private var readyChangePending = false
    /// The page shown per bucket while the app runs (not stored); views clamp it. Set through
    /// `setPage(_:of:)`.
    var pages: [String: Int] = [:]
    /// "Show monitor": the session to bring into view, with a counter so each request is seen once. Set
    /// through `revealMonitor(_:)`.
    var revealRequest: (sessionID: String, serial: Int)?

    private var runs = CodeOfferRunBook()
    /// Open sheets: the offer, its session and the supersession the sheet was last told about.
    private var presented: [CommandOffer.ID: (sessionID: String, supersession: CommandOffer.Supersession?)] = [:]
    private var observers: [ObjectIdentifier: () -> Void] = [:]
    private var visibleViews: Set<ObjectIdentifier> = []
    private var stripVisible = true
    private var note: (text: String, until: Date)?
    private var started = false
    /// Started and not stopped.
    var isStarted: Bool { started }
    /// Wake words a dock host announced: the Finished alerts never say them (kept here until Ready is enabled).
    var hostWakeWords: Set<String> = []
    private var lastWatched: Set<String>?
    /// Bumped when every peek must close (block hidden or folded, `dismissOverlays`).
    private(set) var overlayGeneration = 0
    /// Most transcripts watched closely.
    static let maxWatched = 24
    static let noteDuration: TimeInterval = 6

    /// `buckets` nil keeps the buckets in memory only (tests and previews); the block hands the real file's store.
    init(source: CodeSessionsSource, parker: CodeWindowParking, presenter: CommandOfferPresenting,
         freshness: CommandOfferFreshnessChecking, settings: CodeSettings, pasteboard: CodeMonitorPasteboard,
         buckets: CodeBucketStore? = nil) {
        self.source = source; self.parker = parker; self.presenter = presenter; self.freshness = freshness
        self.settings = settings; self.pasteboard = pasteboard
        self.buckets = buckets ?? CodeBucketStore(url: nil, owner: getuid(), now: Date(), writeInterval: CodeTuning.memoryWriteInterval)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        source.onChange = { [weak self] in self?.rebuild() }
        parker.onChange = { [weak self] in self?.rebuild() }
        parker.start()
        source.start()
        updateActivity()
        rebuild()
        ready?.setStripVisible(stripVisible)
    }

    func stop() {
        guard started else { return }
        started = false
        source.stop()
        parker.stop()
        ready?.setStripVisible(false)
    }

    func observe(_ owner: AnyObject, _ handler: @escaping () -> Void) { observers[ObjectIdentifier(owner)] = handler }

    func stopObserving(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
        setViewVisible(false, owner: owner)
    }

    /// A view became visible or not (on screen, not occluded, not scrolled out). The window pass runs and the source
    /// keeps its timers only while the block is shown (not hidden, not folded) and a view shows.
    func setViewVisible(_ visible: Bool, owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        let changed = visible ? visibleViews.insert(id).inserted : visibleViews.remove(id) != nil
        if changed { updateActivity() }
    }

    func setStripVisible(_ visible: Bool) {
        guard visible != stripVisible else { return }
        stripVisible = visible
        if !visible { closeOverlays() }
        updateActivity()
        if started { ready?.setStripVisible(visible) }
    }

    /// Closes every peek and the command sheet (as a Cancel): block hidden or folded.
    func closeOverlays() {
        overlayGeneration += 1
        presenter.dismissSheet()
        notify()
    }

    /// Desk tags and drag-to-park need the window pass (and so `deskWindows`) while the block shows, even when the
    /// block's view is scrolled out of view. The source still reads only while a block view is on screen.
    var needsWindowPassOffTile = false {
        didSet { if needsWindowPassOffTile != oldValue { updateActivity() } }
    }

    private func updateActivity() {
        let tileShown = started && stripVisible && !visibleViews.isEmpty
        parker.setActive(tileShown || (started && stripVisible && needsWindowPassOffTile))
        if started { source.setStripVisible(tileShown) }
    }

    func setFocus(_ focus: MonitorFocus) {
        guard focus != self.focus else { return }
        self.focus = focus
        rebuild()
    }

    /// The block's rows changed (the panel's height): the Ready list shows 6 cards from 12 rows on.
    func setRows(_ rows: Int) {
        let rows = max(1, rows)
        guard rows != tileRows else { return }
        tileRows = rows
        if started { rebuild() }
    }

    func update(settings: CodeSettings) {
        self.settings = settings
        ready?.update(settings: settings)
        rebuild()
    }

    /// The Ready list changed (a press, its undo timer, a rebuild): the bucket badges and the summary line follow,
    /// once per turn of the main queue (a change during `rebuild()` never rebuilds inside it).
    func readyChanged() {
        guard !readyChangePending else { return }
        readyChangePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let model = self else { return }
                model.readyChangePending = false
                model.rebuild()
                model.notify()
            }
        }
    }

    /// Called after every rebuild, changed or not (desk tags follow the sessions and desk windows from here).
    var onRebuilt: (() -> Void)?
    /// Called when Hide text flips (desk tags hide their text too).
    var onHideTextChanged: ((Bool) -> Void)?

    func toggleHideText() {
        hideText.toggle()
        CodeTileLog.info("hide text \(hideText ? "on" : "off")")
        onHideTextChanged?(hideText)
        rebuild()
    }

    // MARK: The snapshot

    func rebuild() {
        let now = self.now()
        let parked = parker.parkedSessionIDs
        let members = CodeMonitorBuilder.members(source.sessions, parked: parked)
        // Where new sessions land: Unsorted, with a first-seen time that keeps their place across restarts.
        buckets.noteSeen(members.map(\.id), now: now)
        let archived = Set(source.sessions.filter(\.isArchived).map(\.id))
        if !archived.isEmpty { buckets.forget(archived) }
        let showsProfiles = source.runningProfiles.count > 1
        let ordered = CodeBucketLayout.ordered(members, firstSeen: buckets.firstSeen(of:))
        let focus = self.focus
        let shown = ordered.filter { focus.passes($0, severalCopies: showsProfiles) }
        parker.update(sessions: ordered, processes: source.runningProcesses)
        // Followed: pop-outs, parked sessions, then main-window sessions by the user's own activity, 24 at most.
        let followed = ready?.follow(monitors: ordered, statuses: parker.statuses, parked: parked,
                                     recent: source.recentSessions(within: settings.readyRecentHours))
        let watched = followed?.ids ?? Set(ordered.prefix(Self.maxWatched).map(\.id)).union(parked)
        if watched != lastWatched {
            lastWatched = watched
            source.setWatched(watched)
        }
        if let ready, let followed {
            let buckets = self.buckets
            ready.update(CodeReadyInput(
                sessions: source.sessions, followed: followed, statuses: parker.statuses,
                bucketName: { id in buckets.buckets.count > 1 ? buckets.bucket(buckets.bucketID(of: id))?.name : nil },
                hideText: hideText, showText: settings.showText,
                passesFilter: { focus.passes($0, severalCopies: showsProfiles) },
                tallTile: tileRows >= CodeTuning.readyTallTileRows, now: now, commands: settings.commands))
        }
        let statuses = parker.statuses
        let deskMonitors = settings.deskWindows == .monitors || !deskWindowsHaveTags
        let monitorSessions = shown.filter {
            CodeBucketLayout.hasMonitor($0, status: statuses[$0.id], parked: parked, deskMonitors: deskMonitors)
        }
        let inputs = CodeMonitorBuilder.Inputs(sessions: monitorSessions, statuses: statuses, runs: runs, hideText: hideText,
                                               showText: settings.showText, showsProfiles: showsProfiles,
                                               homeDirectory: homeDirectory, now: now, commands: settings.commands)
        var next = CodeMonitorsSnapshot()
        next.sections = sections(monitorSessions, inputs: inputs)
        next.monitors = next.sections.flatMap(\.monitors)
        next.bucketMode = buckets.buckets.count > 1
        next.look = settings.look
        next.bucketNote = buckets.note
        next.showsProfiles = showsProfiles
        next.banner = CodePlainText.line(source.banner, limit: 160)
        let parkedSince = ordered.compactMap { session -> Date? in
            if case .parked(let since)? = statuses[session.id]?.place { return since }
            return nil
        }
        next.hint = pitHint?.update(parkedSince: parkedSince, now: now) == true ? CodePitHint.text : nil
        if next.hint != nil, snapshot.hint == nil {
            // The line goes by itself: one more rebuild once its time is up, even when nothing else changes.
            DispatchQueue.main.asyncAfter(deadline: .now() + CodePitHint.duration + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
        if let note, note.until <= now { self.note = nil }
        next.header = CodeMonitorsHeader(
            count: next.monitors.count,
            needYou: shown.filter { $0.state == .needsYou }.count,
            hideText: hideText,
            parkAllDone: parkAllCandidates(shown).count,
            note: self.note?.text,
            parked: monitorSessions.filter { CodeBucketLayout.isParked($0, status: statuses[$0.id], parked: parked) }.count,
            onDesk: shown.filter { statuses[$0.id]?.place == .onDesk }.count,
            canCreateBucket: buckets.canCreate)
        if next.monitors.isEmpty { (next.emptyTitle, next.emptyDetail) = emptyWords(members: ordered) }
        shownSessions = shown
        followStaleOffers(in: source.sessions)   // every session the source has (earlier and recent ones' offers)
        onAttentionCounts?(attentionCounts(shown: shown))
        onRebuilt?()
        guard next != snapshot else { return }
        snapshot = next
        notify()
    }

    /// The monitors bucket by bucket (Unsorted first), each in its stable order, with their header counts. Positions
    /// (VoiceOver's "Code monitor 2 of 6") run across the whole block.
    private func sections(_ sessions: [CodeSessionSnapshot], inputs: CodeMonitorBuilder.Inputs) -> [CodeBucketSection] {
        let grouped = CodeBucketLayout.group(sessions, buckets: buckets.buckets, bucketOf: buckets.bucketID(of:))
        let counter = readyCounts ?? CodeReadyCounts.fromSnapshot
        var position = 0
        return grouped.map { bucket, members in
            let items = members.map { session -> CodeMonitorItem in
                position += 1
                var item = CodeMonitorBuilder.item(session, position: position, total: sessions.count, inputs: inputs)
                for decorate in itemDecorators { decorate(session, &item) }
                return item
            }
            return CodeBucketSection(bucket: bucket, monitors: items, counts: CodeBucketLayout.counts(members, ready: counter))
        }
    }

    func notify() {
        for handler in Array(observers.values) { handler() }
    }

    private func emptyWords(members: [CodeSessionSnapshot]) -> (String, String?) {
        if source.runningProfiles.isEmpty, members.isEmpty {
            return ("Claude is not running", "Start Claude and pop a session out to see it here.")
        }
        if !members.isEmpty, !focus.isAll {
            return ("Nothing for \(focus.name)", "Switch the focus to All to see every pop-out.")
        }
        return ("No Code pop-outs", "Pop a session out in Claude to see it here.")
    }

    private func parkAllCandidates(_ shown: [CodeSessionSnapshot]) -> [String] {
        shown.filter { session in
            guard session.state.isDone, let status = parker.statuses[session.id] else { return false }
            return status.place == .onDesk && status.busy == nil
        }.map(\.id)
    }

    /// The fold rail's counts (the `attention` message, docs/DOCK_PROTOCOL.md §5.11): the monitors under the focus
    /// that need you (Needs you or Problem), and over the followed sessions under the focus, the open Finished items
    /// (the Ready list's, else the sessions' own marks) and the running ones (the summary line's rules).
    func attentionCounts(shown: [CodeSessionSnapshot]) -> CodeAttentionCounts {
        let showsProfiles = source.runningProfiles.count > 1
        let focus = self.focus
        let followed = source.sessions.filter { focus.passes($0, severalCopies: showsProfiles) }
        let finished = ready?.justFinished(in: followed)
            ?? followed.filter { ($0.finished?.isOpen ?? false) && ($0.finished?.hasItem ?? false) }.count
        return CodeAttentionCounts(needsYou: shown.filter { $0.state.asksForAttention }.count, finished: finished,
                                   running: followed.filter(RunText.isRunning).count)
    }

    /// An open sheet whose offer left the session's offers is told it went stale; one whose offer stays but
    /// gained (or changed) its supersession is told the session replied since.
    private func followStaleOffers(in sessions: [CodeSessionSnapshot]) {
        guard !presented.isEmpty else { return }
        // Offers of the latest and of the earlier replies.
        let changes = CodeReadyOffers.changes(presented: presented.mapValues(\.supersession), sessions: sessions)
        for id in changes.stale {
            presented[id] = nil
            presenter.offerWentStale(id)
            CodeTileLog.info("offer went stale offer=\(id)")
        }
        for (id, supersession) in changes.superseded {
            presented[id]?.supersession = supersession
            presenter.offerWasSuperseded(id, supersession: supersession)
            CodeTileLog.info("offer superseded offer=\(id) newer=\(supersession.newerReplies)")
        }
    }

    // MARK: Actions

    func session(_ id: String) -> CodeSessionSnapshot? { shownSessions.first { $0.id == id } }

    /// A click on a monitor's screen: park, restore, activate or open, by its window's state.
    func clickScreen(_ id: String) {
        guard let status = parker.statuses[id] else { return }
        perform(status.click, id)
    }

    func perform(_ click: CodeWindowClick, _ id: String) {
        guard click != .none, let session = session(id) else { return }
        CodeTileLog.info("window \(click.rawValue) session=#\(session.index)")
        parker.perform(click, sessionID: id)
        if click == .restore { ready?.markSeen(id) }   // restoring is looking (the unread dot goes)
    }

    func parkAllDone() {
        let ids = parkAllCandidates(shownSessions)
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await parker.parkAllDone(ids)
            if let text = result.note {
                note = (text, now().addingTimeInterval(Self.noteDuration))
                rebuild()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteDuration + 0.1) { [weak self] in
                    MainActor.assumeIsolated { self?.rebuild() }
                }
            }
        }
    }

    /// Opens the confirmation sheet for one offer. The sheet re-classifies and checks freshness itself; the
    /// block never runs anything.
    func openSheet(_ offerID: CommandOffer.ID, sessionID: String, anchor: CGRect) {
        // An earlier reply's offer, or one of a main-window session (no monitor), opens the same way.
        guard let found = CodeReadyOffers.entry(offerID, in: source.sessions), found.sessionID == sessionID else { return }
        let entry = found.entry
        presented[offerID] = (sessionID, entry.offer.supersession)
        CodeTileLog.info("sheet opened offer=\(offerID) class=\(entry.assessment.commandClass.rawValue)")
        let offer = entry.offer
        presenter.present(offer, anchor: anchor, freshness: freshness) { [weak self] event in
            self?.handle(event, offer: offer, sessionID: sessionID)
        }
    }

    private func handle(_ event: CommandOfferEvent, offer: CommandOffer, sessionID: String) {
        switch event {
        case .cancelled, .started, .typed, .fetched, .refused: presented[offer.id] = nil
        case .copied, .finished, .stopped: break
        }
        runs.record(event, offer: offer, sessionID: sessionID, at: now())
        ready?.record(event, offer: offer, sessionID: sessionID)
        CodeTileLog.info("offer event offer=\(offer.id) \(Self.eventLabel(event))")
        rebuild()
    }

    static func eventLabel(_ event: CommandOfferEvent) -> String {
        switch event {
        case .copied: return "copied"
        case .typed: return "typed"
        case .started: return "started"
        case .finished(_, let status, let seconds): return "finished status=\(status) seconds=\(Int(seconds.rounded()))"
        case .stopped(_, let signal, let seconds): return "stopped signal=\(signal) seconds=\(Int(seconds.rounded()))"
        case .fetched(let outcome):
            switch outcome {
            case .saved: return "fetched"
            case .failed: return "fetch failed"
            case .cancelled: return "fetch cancelled"
            }
        case .cancelled: return "cancelled"
        case .refused: return "refused"
        }
    }

    /// The peek's Copy for one offer: the exact text, concealed and transient; never for B1, B2 or B5.
    @discardableResult
    func copyOffer(_ offerID: CommandOffer.ID, sessionID: String) -> Bool {
        guard let entry = session(sessionID)?.offers.first(where: { $0.id == offerID }),
              CodeOfferWords.canCopy(entry.assessment) else { return false }
        pasteboard.copyPrivately(entry.offer.text)
        CodeTileLog.info("offer copied offer=\(offerID)")
        return true
    }

    /// The peek's Copy link (`claude://claude.ai/epitaxy/local_<id>`).
    @discardableResult
    func copyLink(sessionID: String) -> Bool {
        guard let link = CodeDeepLink.shareLink(sessionID: sessionID) else { return false }
        pasteboard.copy(link)
        return true
    }

    func revealRun(_ runID: UUID) {
        onRevealRun?(runID)
    }

    /// A result button was pressed (already armed) on a monitor or in its peek: the session's result as the data side
    /// gave it goes to `onResultClick`.
    func clickResult(_ button: CodeResultButton, sessionID: String, anchor: CGRect) {
        guard let session = shownSessions.first(where: { $0.id == sessionID }),
              session.results.contains(where: { $0.id == button.resultID }) else { return }
        onResultClick?(session, button, anchor)
    }

    /// Counts only, for an optional read-only `code.status`: never text.
    func status() -> CodeMonitorsStatus {
        let all = CodeMonitorBuilder.members(source.sessions, parked: parker.parkedSessionIDs)
        let parked = all.filter { parker.statuses[$0.id]?.isParked == true }.count
        let running = all.filter { if case .running? = runs.latest[$0.id]?.state { return true } else { return false } }.count
        return CodeMonitorsStatus(monitors: all.count, parked: parked,
                                  needYou: all.filter { $0.state.asksForAttention }.count,
                                  offers: all.reduce(0) { $0 + $1.offers.count }, runningCommands: running)
    }
}

/// Counts for an optional read-only `code.status` control command. No titles, no text, no commands.
public struct CodeMonitorsStatus: Equatable, Sendable, Codable {
    public var monitors: Int
    public var parked: Int
    public var needYou: Int
    public var offers: Int
    public var runningCommands: Int
}
