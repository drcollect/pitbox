import AppKit
import Foundation
import PitboxKit

/// What Ready for you and Finished take from the app: presence, sound, on-device speech and two
/// window facts. The target imports the Kit only, so the composition root passes these. The defaults are safe: no
/// sound, no speech, presence unknown (never away, no recap), nobody looking.
///
/// ```swift
/// var ready = CodeReadyEnvironment()
/// ready.idleSeconds = { Presence.hidIdleSeconds() }                     // CGEventSource HID idle time
/// ready.screenLocked = { Presence.screenLocked() || CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
/// ready.canSpeakNow = { !Presence.screenLocked() && CGDisplayIsAsleep(CGMainDisplayID()) == 0 }
/// ready.isKeyWindow = { id in /* the session's desk window is the frontmost app's key window (CGWindowList) */ }
/// ready.claudeIsFrontmost = { engine.runningProcesses.contains { $0.pid == frontmostPID } }
/// ready.chime = { CodeFinishChime.play() }
/// ready.speech = CodeOwnSpeech(beginOwnSpeech: { await dock.beginSpeech() },   // alone: { true }
///                              speak: { await voice.speak($0) },
///                              endOwnSpeech: { dock.endSpeech() })            // alone: { }
/// ```
public struct CodeReadyEnvironment {
    /// The wall clock (tests use a fixed one).
    public var clock: @MainActor () -> Date
    /// Seconds since the last HID input (`ScoutWakeEnvironment.hidIdleSeconds`); nil when unknown.
    public var idleSeconds: @MainActor () -> TimeInterval?
    /// The screen is locked or the displays sleep: away for the recap, and no sound.
    public var screenLocked: @MainActor () -> Bool
    /// No Talk, dictation or spoken reminder runs, the screen is not locked and the displays are awake.
    public var canSpeakNow: @MainActor () -> Bool
    /// The session's pop-out window is the key window of the frontmost app.
    public var isKeyWindow: @MainActor (_ sessionID: String) -> Bool
    /// A Claude copy is the frontmost app (for main-window sessions).
    public var claudeIsFrontmost: @MainActor () -> Bool
    /// The finish chime (`CodeFinishChime.play`); nil: no sound.
    public var chime: (@MainActor () -> Void)?
    /// On-device speech for Say it; nil: never speaks.
    public var speech: CodeOwnSpeech?
    /// Runs `work` after `seconds` on the main queue (no thread waits); tests run the work by hand.
    public var schedule: @MainActor (_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    public init(clock: @escaping @MainActor () -> Date = { Date() },
                idleSeconds: @escaping @MainActor () -> TimeInterval? = { nil },
                screenLocked: @escaping @MainActor () -> Bool = { false },
                canSpeakNow: @escaping @MainActor () -> Bool = { true },
                isKeyWindow: @escaping @MainActor (String) -> Bool = { _ in false },
                claudeIsFrontmost: @escaping @MainActor () -> Bool = { false },
                chime: (@MainActor () -> Void)? = nil, speech: CodeOwnSpeech? = nil,
                schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = CodeReadyEnvironment.mainQueue) {
        self.clock = clock; self.idleSeconds = idleSeconds; self.screenLocked = screenLocked
        self.canSpeakNow = canSpeakNow; self.isKeyWindow = isKeyWindow; self.claudeIsFrontmost = claudeIsFrontmost
        self.chime = chime; self.speech = speech; self.schedule = schedule
    }

    /// `DispatchQueue.main.asyncAfter`: nothing parks a thread while it waits.
    public static func mainQueue(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { MainActor.assumeIsolated { work() } }
    }
}

/// Ready for you, Finished alerts and While you were away for the block, behind one narrow API for the block model
/// (main thread). The block computes the followed set here, hands it to `setWatched`, feeds every rebuild to
/// `update(_:)`, puts a list view (`makeView()`, one per block view) into the block view's Ready slot, and performs the
/// actions it gets (`onAction`). Sheet events go to `record(_:offer:sessionID:)`, so an item that ran becomes its
/// result row.
@MainActor
final class CodeReadyForYou {
    let memory: CodeMemoryStore
    let environment: CodeReadyEnvironment
    let list: CodeReadyList
    let alerts: CodeFinishAlerts
    let recap: CodeAwayRecap
    private(set) var settings: CodeSettings
    private(set) var followed: CodeFollowedSet = .empty
    /// Which of the user's activity fields count.
    var policy = CodeFollowedSet.Policy()
    /// The recap's "Still running" words for a session, nil when it is not running. The block sets the desk tag text
    /// (`RunText.tag`); nil keeps the recap's own short words.
    var runWords: ((CodeSessionSnapshot, Date) -> String?)?
    /// Called after the list changed.
    var onChange: (() -> Void)?
    private var lastInput: CodeReadyInput?
    /// The list views of the block views (a view has one superview, so each block view gets its own).
    private var views: [WeakListView] = []

    private struct WeakListView {
        weak var view: CodeReadyListView?
    }

    /// Actions for the block: a sheet, a window, a monitor, a link, a fetched file, a run's tab; with the pressed
    /// card's frame in screen coordinates (the sheet's anchor).
    var onAction: ((CodeReadyAction, CGRect) -> Void)? {
        get { list.onAction }
        set { list.onAction = newValue }
    }

    /// The bezel pulse of a live finish.
    var onFinishPulse: ((String) -> Void)? {
        get { alerts.onFinishPulse }
        set { alerts.onFinishPulse = newValue }
    }

    init(memory: CodeMemoryStore, settings: CodeSettings, environment: CodeReadyEnvironment = CodeReadyEnvironment()) {
        self.memory = memory
        self.environment = environment
        self.settings = settings
        list = CodeReadyList(memory: memory)
        alerts = CodeFinishAlerts(environment: environment, memory: memory, settings: settings)
        recap = CodeAwayRecap(environment: environment, settings: settings)
        list.schedule = environment.schedule
        list.now = environment.clock
        list.onChange = { [weak self] in
            guard let self else { return }
            views.removeAll { $0.view == nil }
            for item in views { item.view?.refresh() }
            onChange?()
        }
        recap.onChange = { [weak self] in
            guard let self else { return }
            list.recap = recap.recap
        }
        recap.onRecap = { [weak self] made in self?.alerts.sayRecap(made) }
        recap.contents = { [weak self] in self?.recapContents() }
        list.onGotIt = { [weak self] in self?.recap.gotIt() }
    }

    // MARK: Views

    /// A list view for one block view (its Ready slot: `tileView.readyAccessory`). Wire its `onHeightChange` to that
    /// block view's `accessoriesChanged()`.
    func makeView() -> CodeReadyListView {
        let view = CodeReadyListView(list: list)
        views.removeAll { $0.view == nil }
        views.append(WeakListView(view: view))
        view.refresh()
        return view
    }

    /// The list views alive (tests).
    var listViews: [CodeReadyListView] { views.compactMap(\.view) }

    /// A session's command and file items (Later ones included) for its bucket's "▶ n" and "⤓ n" badges.
    func counts(for sessionID: String) -> (commands: Int, files: Int) {
        let counts = list.snapshot.countsBySession[sessionID]
        return (counts?.commands ?? 0, counts?.files ?? 0)
    }

    /// The open Finished items of `sessions` in the list (OK'd ones go at once), for the summary line "2 just finished"
    /// (`CodeSummaryAccessory.justFinished`).
    func justFinished(in sessions: [CodeSessionSnapshot]) -> Int {
        Set(sessions.map(\.id)).reduce(0) { $0 + (list.snapshot.countsBySession[$1]?.finished ?? 0) }
    }

    /// The followed sessions active only on their own, for `CodeSummaryAccessory.ownActivityOnly`: the dashboards
    /// list gives them no Open.
    var ownActivityOnly: Set<String> { followed.ownActivityOnly }

    // MARK: The followed set

    /// The followed sessions from the monitors (pop-outs and parked, in the block's fixed order), the window
    /// statuses, the parked ids and `source.recentSessions(within: settings.readyRecentHours)`. Hand `ids` to
    /// `CodeSessionsSource.setWatched`.
    @discardableResult
    func follow(monitors: [CodeSessionSnapshot], statuses: [String: CodeWindowStatus], parked: Set<String>,
                recent: [CodeRecentSession]) -> CodeFollowedSet {
        followed = CodeFollowedSet(monitors: monitors, statuses: statuses, parked: parked, recent: recent,
                                   recentHours: settings.readyRecentHours, now: environment.clock(), policy: policy)
        return followed
    }

    // MARK: Updates

    /// A block rebuild: the list follows, and new live finishes alert.
    func update(_ input: CodeReadyInput) {
        lastInput = input
        list.update(input)
        alerts.observe(input.sessions, followed: input.followed)
    }

    /// The sheet's event for an offer (from the list, a monitor or a tag).
    func record(_ event: CommandOfferEvent, offer: CommandOffer, sessionID: String) {
        list.record(event, offer: offer, sessionID: sessionID, now: environment.clock())
    }

    /// The block was shown or hidden: the recap polls only while it is shown; the arming restarts.
    func setStripVisible(_ visible: Bool) {
        recap.setStripVisible(visible)
        for view in listViews { view.stripVisibilityChanged() }
    }

    func update(settings: CodeSettings) {
        self.settings = settings
        alerts.update(settings: settings)
        recap.update(settings: settings)
    }

    /// The user looked at the session (its peek opened, its window was restored): the unread dot goes.
    func markSeen(_ sessionID: String) {
        CodeUnreadMarks.markSeen(sessionID, memory: memory, now: environment.clock())
    }

    /// When the user dismissed this offer (the peek greys it, the sheet says "You dismissed this at 14:05").
    func dismissedAt(_ offerID: CommandOffer.ID) -> Date? {
        guard let session = lastInput?.sessions.first(where: { $0.offers.contains { $0.id == offerID }
            || $0.earlierOffers.contains { $0.id == offerID } }) else { return nil }
        return list.dismissedAt(offerID, in: session)
    }

    /// The list's height at `width` (the block lays itself out with it).
    func height(forWidth width: CGFloat) -> CGFloat { CodeReadyListView.height(of: list.snapshot, width: width) }

    private func recapContents() -> CodeAwayRecapContents? {
        guard let input = lastInput else { return nil }
        let sessions = input.sessions.compactMap { session in input.followed.kind(of: session.id).map { (session, $0) } }
        return CodeAwayRecapContents(sessions: sessions, items: list.allItems, hideText: input.hideText, runWords: runWords)
    }
}

/// Finding offers across the latest reply and the earlier ones (the block's sheet and its stale and superseded
/// checks). Pure.
enum CodeReadyOffers {
    /// The offer `id` in `sessions`, from `offers` or `earlierOffers`.
    static func entry(_ id: CommandOffer.ID, in sessions: [CodeSessionSnapshot]) -> (entry: CodeOfferEntry, sessionID: String)? {
        for session in sessions {
            if let entry = session.offers.first(where: { $0.id == id }) ?? session.earlierOffers.first(where: { $0.id == id }) {
                return (entry, session.id)
            }
        }
        return nil
    }

    /// For the open sheets (offer → the supersession the sheet was last told about): the ones whose offer left both
    /// lists (stale, `offerWentStale`) and the ones whose supersession appeared or changed (`offerWasSuperseded`).
    static func changes(presented: [CommandOffer.ID: CommandOffer.Supersession?], sessions: [CodeSessionSnapshot])
        -> (stale: [CommandOffer.ID], superseded: [(CommandOffer.ID, CommandOffer.Supersession)]) {
        var stale: [CommandOffer.ID] = []
        var superseded: [(CommandOffer.ID, CommandOffer.Supersession)] = []
        for (id, told) in presented.sorted(by: { $0.key.description < $1.key.description }) {
            guard let found = entry(id, in: sessions) else {
                stale.append(id)
                continue
            }
            if let now = found.entry.offer.supersession, now != told { superseded.append((id, now)) }
        }
        return (stale, superseded)
    }
}
