import AppKit
import Foundation
import PitboxKit

/// Desk tags beside desk windows: one small panel beside each matched Claude Code pop-out on the desk, showing its
/// command, warning, run text or dashboard, and acting on a click without ever taking the keyboard or activating the
/// app. Main thread.
///
/// - **What shows**: at most two pills, the main item (an offer, a warning, or while running the short run
///   text) and "▦ Dashboard" below it; nothing when none applies, never for parked windows or the main window.
/// - **Where**: right-aligned at the window's right edge minus `CodeTuning.tagRightInset`, centred on its top
///   edge, inside when the window is just under the menu bar, clamped to the display and out of the block's region.
/// - **Following**: `CodeWindowObserver` reads the window server after Claude's notifications (≤ 1 per 16 ms),
///   tags hide during a drag and show 0.15 s after the last move with the button up; a Space or display change checks
///   every tag at once; a 1 Hz backstop pass runs while any tag is watched.
/// - **Hiding**: minimized, another Space, off screen, full screen, covering its display, smaller than
///   320 × 200, closed, the app hidden, the block hidden, `deskTags` off, not matched; covered windows by the window
///   server's order (first cover mode) or by the front-to-back check (fallback).
/// - **Clicks**: one offer opens its sheet, several offers, a warning or a running tag open the desk peek, ▦
///   opens the dashboard after its arming. Nothing runs.
/// - **Feasibility**: until the attended check on this Mac passes (`DeskTagFeasibility.current`), tags show only in
///   the lab mode; the Ready list carries desk sessions either way.
///
/// Idle cost: with no tag to show, nothing is observed and no timer runs. With tags: the observer's notifications, one
/// window-server read per tag per second, and main-thread work only when something changed.
///
/// Wiring (composition root):
/// ```swift
/// let windowObserver = CodeWindowObserver()
/// let deskTags = DeskTagController(actions: deskTagActions, stripRegions: { panel.regions }, observer: windowObserver)
/// deskTags.start()
/// // on every block rebuild: deskTags.update(sessions: source.sessions, deskWindows: parker.deskWindows.map { … })
/// // panel.onVisibilityChanged → deskTags.setStripVisible(_:); settings → deskTags.update(settings:)
/// // Hide text → deskTags.setHideText(_:); Ready list → deskTags.setSuppressed(_:); fold or hide → deskTags.dismissOverlays()
/// ```
@MainActor
public final class DeskTagController {
    struct Tag {
        var desk: DeskTagDeskWindow
        var index: Int
        var facts = DeskTagWindowFacts()
        var content: DeskTagContent?
        var panel: DeskTagPanel?
        /// AppKit screen coordinates, while shown.
        var shownFrame: CGRect?
        /// Quartz coordinates, while shown.
        var shownLayout: DeskTagLayout?
        /// The log word of what is shown (`tag shown … kind=`).
        var shownKind: String?
        var reason: DeskTagHideReason? = .noContent
        var dragLastMove: TimeInterval?
        var hovered = false
        var key: CodeWindowKey { CodeWindowKey(pid: desk.pid, number: desk.windowNumber) }
    }

    let observer: CodeWindowObserver
    let actions: DeskTagActions
    let system: DeskTagSystem
    let windowing: DeskTagWindowing
    let scheduler: DeskTagScheduler
    let button: DeskTagButton
    let stripRegions: @MainActor () -> [ReservedRegion]
    let ownPID: pid_t
    let feasibility: DeskTagFeasibility
    let lab: DeskTagLabOptions
    /// How tags stay under covering windows; the lab mode can override it.
    let coverMode: DeskTagCoverMode
    /// The tag's distance from the window's right edge; the lab mode can override it.
    let rightInset: CGFloat
    var clock: DeskTagClock
    /// Wall time, for the words ("Running 12 min", "ETA 23:24 passed").
    var dateNow: () -> Date = { Date() }
    var homeDirectory = NSHomeDirectory()

    private(set) var sessions: [String: CodeSessionSnapshot] = [:]
    private(set) var stripVisible = false
    private(set) var settings = CodeSettings()
    private(set) var hideText = false
    private(set) var suppressed = DeskTagSuppressed()
    private(set) var started = false

    var tags: [String: Tag] = [:]
    var keyIndex: [CodeWindowKey: String] = [:]
    var displays: [DeskTagDisplay] = []
    var frontToBack: [DeskTagServerWindow] = []
    var watchedKeys: Set<CodeWindowKey> = []
    var client: Int?
    var dragTimer: DeskTagTimer?
    var clockTimer: DeskTagTimer?
    var peek: DeskPeekPanel?
    var peekFocus: DeskPeekFocus = .top
    var peekHovered = false
    var peekCloseTimer: DeskTagTimer?
    var escapeMonitor: AnyObject?
    var labState = DeskTagLabState()

    /// How often time-based words are rebuilt while a tag shows them ("Running 12 min", an ETA passing).
    static let clockInterval: TimeInterval = 30

    /// The production controller: live window ordering, displays, timers and system notifications. Feasibility and the
    /// cover mode are the shipped constants; the lab mode comes from the app's environment (`PITBOX_DESKTAG_LAB=1`).
    public convenience init(actions: DeskTagActions, stripRegions: @escaping @MainActor () -> [ReservedRegion],
                            observer: CodeWindowObserver,
                            lab: DeskTagLabOptions = .from(environment: ProcessInfo.processInfo.environment)) {
        self.init(observer: observer, actions: actions, system: DeskTagLiveSystem(), windowing: DeskTagLiveWindowing(),
                  scheduler: DeskTagLiveScheduler(), button: DeskTagLiveButton(), stripRegions: stripRegions, ownPID: getpid(),
                  feasibility: .current, lab: lab, clock: .system)
    }

    /// - Parameter coverMode: tests choose the mode; otherwise the shipped one, or the lab's.
    init(observer: CodeWindowObserver, actions: DeskTagActions, system: DeskTagSystem, windowing: DeskTagWindowing,
         scheduler: DeskTagScheduler, button: DeskTagButton, stripRegions: @escaping @MainActor () -> [ReservedRegion],
         ownPID: pid_t, feasibility: DeskTagFeasibility, lab: DeskTagLabOptions, clock: DeskTagClock,
         coverMode: DeskTagCoverMode? = nil) {
        self.observer = observer; self.actions = actions; self.system = system; self.windowing = windowing
        self.scheduler = scheduler; self.button = button; self.stripRegions = stripRegions; self.ownPID = ownPID
        self.feasibility = feasibility; self.lab = lab; self.clock = clock
        self.coverMode = coverMode ?? (lab.enabled ? (lab.coverMode ?? DeskTagCoverMode.current) : DeskTagCoverMode.current)
        rightInset = lab.enabled ? (lab.rightInset ?? DeskTagTuning.rightInset) : DeskTagTuning.rightInset
    }

    // MARK: Lifecycle

    /// Starts following the system's Space and display changes. Call once, after wiring.
    public func start() {
        guard !started else { return }
        started = true
        displays = system.displays()
        client = observer.addClient { [weak self] event in self?.handle(event) }
        system.start { [weak self] event in self?.handle(event) }
        if lab.enabled {
            DeskTagLog.info("desktag lab on cover=\(coverMode.rawValue) inset=\(Int(rightInset)) feasibility=\(feasibility.rawValue)")
            scheduleLabCost()
        }
        refresh()
    }

    /// Hides every tag and stops observing (quit).
    public func stop() {
        guard started else { return }
        started = false
        closePeek()
        for id in Array(tags.keys) { removeTag(id) }
        if let client { observer.removeClient(client) }
        client = nil
        system.stop()
        dragTimer?.cancel(); dragTimer = nil
        clockTimer?.cancel(); clockTimer = nil
    }

    // MARK: Inputs

    /// The followed sessions (the data side's snapshots) and the desk windows the join holds (session, pid, window
    /// number). Only desk windows of known sessions get tags. Call on every block rebuild.
    public func update(sessions list: [CodeSessionSnapshot], deskWindows: [DeskTagDeskWindow]) {
        var byID: [String: CodeSessionSnapshot] = [:]
        for session in list where byID[session.id] == nil { byID[session.id] = session }
        sessions = byID
        var next: [String: DeskTagDeskWindow] = [:]
        for window in deskWindows where byID[window.sessionID] != nil && next[window.sessionID] == nil {
            next[window.sessionID] = window
        }
        for (id, tag) in tags where next[id] != tag.desk { removeTag(id) }
        for (id, window) in next where tags[id] == nil {
            tags[id] = Tag(desk: window, index: byID[id]?.index ?? 0)
        }
        for (id, session) in byID where tags[id] != nil { tags[id]?.index = session.index }
        keyIndex = Dictionary(tags.map { ($0.value.key, $0.key) }, uniquingKeysWith: { first, _ in first })
        refresh()
    }

    /// The settings file changed (`jTags`, `showText`, `warnings`, `commands`): every tag and the open peek follow at once.
    public func update(settings: CodeSettings) {
        let before = standsInForDeskMonitors
        self.settings = settings
        refresh()
        if standsInForDeskMonitors != before { onStandInChanged?(standsInForDeskMonitors) }
    }

    /// The block's panel was shown or hidden: tags exist only while it is shown (so a sheet a tag opens sits beside a
    /// visible panel).
    public func setStripVisible(_ visible: Bool) {
        guard visible != stripVisible else { return }
        stripVisible = visible
        if !visible { closePeek() }
        refresh()
        if visible { observer.refreshAll() }
    }

    /// The block's Hide text: pills show signs and counts only, the desk peek hides session text.
    public func setHideText(_ hidden: Bool) {
        guard hidden != hideText else { return }
        hideText = hidden
        refresh()
    }

    /// Offers and warnings the Ready list no longer shows: their tags go.
    public func setSuppressed(_ suppressed: DeskTagSuppressed) {
        guard suppressed != self.suppressed else { return }
        self.suppressed = suppressed
        refresh()
    }

    /// Closes the desk peek (the block folded or hid).
    public func dismissOverlays() {
        closePeek()
    }

    /// Tags on screen now (for a counts-only status).
    public var shownCount: Int { tags.values.filter { $0.shownFrame != nil }.count }

    /// Whether tags stand in for desk monitors: the attended check passed (or the lab mode runs) and `deskTags` is on.
    /// The block's `deskWindowsHaveTags` follows it, so a desk pop-out loses its monitor only while a tag can stand in
    /// for it.
    public var standsInForDeskMonitors: Bool { feasibility.allowsTags(lab: lab.enabled) && settings.deskTags }

    /// Called on the main thread when `standsInForDeskMonitors` changed (the `deskTags` setting).
    public var onStandInChanged: ((Bool) -> Void)?

    // MARK: Rendering

    var global: DeskTagGlobalState {
        DeskTagGlobalState(stripVisible: started && stripVisible, settingOn: settings.deskTags,
                        feasible: feasibility.allowsTags(lab: lab.enabled))
    }

    func textHidden(_ session: CodeSessionSnapshot) -> Bool {
        hideText || settings.showText[session.profile.letter] == false
    }

    func content(for session: CodeSessionSnapshot) -> DeskTagContent? {
        DeskTagContentBuilder.content(DeskTagContentBuilder.Inputs(
            session: session, suppressed: suppressed, textHidden: textHidden(session), warningsShown: settings.warnings,
            labPill: lab.enabled, now: dateNow(), clock: clock, commands: settings.commands))
    }

    /// Recomputes every tag's content, the observer's interest and every tag's place.
    func refresh() {
        for id in tags.keys {
            tags[id]?.content = sessions[id].flatMap(content(for:))
        }
        updateInterest()
        for id in tags.keys { render(id) }
        refreshPeek()
        updateClockTimer()
    }

    /// The observer watches the tags that could show (content, panel shown, setting on, feasible); with none it
    /// observes nothing.
    func updateInterest() {
        guard let client else { return }
        let state = global
        let allowed = state.stripVisible && state.settingOn && state.feasible
        let keys = allowed ? Set(tags.values.filter { $0.content != nil }.map(\.key)) : []
        for (id, tag) in tags where watchedKeys.contains(tag.key) && !keys.contains(tag.key) {
            // Unwatched: forget the window's facts, so a later tag never shows at a stale place.
            tags[id]?.facts = DeskTagWindowFacts()
        }
        watchedKeys = keys
        let wantsList = !keys.isEmpty && (coverMode == .floating || lab.enabled)
        observer.setInterest(CodeWindowInterest(pids: Set(keys.map(\.pid)), windows: keys, backstop: !keys.isEmpty,
                                                frontToBack: wantsList, notes: lab.enabled && !keys.isEmpty), for: client)
        if !wantsList { frontToBack = [] }
    }

    /// Shows, moves or hides one tag by the rules.
    func render(_ id: String) {
        guard var tag = tags[id] else { return }
        let begin = scheduler.now
        let display = tag.facts.window.flatMap { DeskTagPlacement.display(for: $0.bounds, in: displays) }
        // Covered is decided below, from the tag's new place and the latest front-to-back list.
        var facts = tag.facts
        facts.covered = false
        var reason = DeskTagVisibility.hideReason(global: global, hasContent: tag.content != nil, facts: facts,
                                               display: display)
        var layout: DeskTagLayout?
        if reason == nil, let content = tag.content, let window = tag.facts.window, let display {
            layout = DeskTagPlacement.layout(window: window.bounds, display: display, strips: stripRegions(),
                                          widths: DeskTagStackView.naturalWidths(content),
                                          compactWidths: DeskTagStackView.compactWidths(content), rightInset: rightInset)
            if layout == nil { reason = .noRoom }
        }
        if reason == nil, coverMode == .floating, let layout,
           DeskTagVisibility.isCovered(tag: layout.frame, claude: tag.desk.windowNumber, frontToBack: frontToBack,
                                    ownPID: ownPID) {
            reason = .covered
        }
        tag.facts.covered = reason == .covered
        if let reason {
            hide(&tag, reason: reason)
        } else if let layout, let content = tag.content {
            show(&tag, content: content, layout: layout)
        }
        tags[id] = tag
        labState.mainSeconds += max(0, scheduler.now - begin)
        if peek?.sessionID == id {
            if tag.shownFrame == nil { closePeek() } else { placePeek() }
        }
    }

    private func show(_ tag: inout Tag, content: DeskTagContent, layout: DeskTagLayout) {
        let panel = tag.panel ?? makePanel(for: tag.desk.sessionID)
        tag.panel = panel
        panel.view.configure(content, compact: layout.compact)
        let frame = ScreenSpace.appKit(fromQuartz: layout.frame, primaryHeight: system.primaryHeight)
        let wasShown = tag.shownFrame != nil
        if !wasShown || tag.shownFrame != frame || tag.shownLayout != layout { labState.placements += 1 }
        windowing.show(panel.panel, frame: frame, level: panelLevel(tag), above: orderTarget(tag), reorder: !wasShown)
        panel.view.noteLayout(at: scheduler.now)
        if !wasShown || tag.shownKind != content.logKind {
            DeskTagLog.info("tag shown \(DeskTagLog.tag(tag.index)) kind=\(content.logKind)\(layout.compact ? " compact=1" : "")")
        }
        tag.shownKind = content.logKind
        tag.shownFrame = frame
        tag.shownLayout = layout
        tag.reason = nil
    }

    private func hide(_ tag: inout Tag, reason: DeskTagHideReason) {
        if let panel = tag.panel, tag.shownFrame != nil {
            windowing.hide(panel.panel)
            panel.view.noteHidden()
            if reason != .dragging { DeskTagLog.info("tag hidden \(DeskTagLog.tag(tag.index)) reason=\(reason.rawValue)") }
        }
        tag.shownFrame = nil
        tag.shownLayout = nil
        tag.shownKind = nil
        tag.reason = reason
    }

    /// The tag's window level: its Claude window's own level in the first cover mode (an always-on-top pop-out sits at
    /// the floating level, and a panel can only be ordered directly above a window of its own level); in the fallback at
    /// least the floating level and above the Claude window's.
    func panelLevel(_ tag: Tag) -> NSWindow.Level {
        let layer = tag.facts.window?.layer ?? 0
        switch coverMode {
        case .orderedAbove: return NSWindow.Level(rawValue: layer)
        case .floating: return NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, layer + 1))
        }
    }

    /// The window a tag is ordered above: its Claude window in the first cover mode, none in the fallback.
    func orderTarget(_ tag: Tag) -> CGWindowID? {
        coverMode == .orderedAbove ? tag.desk.windowNumber : nil
    }

    private func makePanel(for id: String) -> DeskTagPanel {
        let panel = DeskTagPanel()
        panel.view.now = { [weak self] in self?.scheduler.now ?? 0 }
        panel.view.pointer = { [weak self] in self?.system.pointerLocation() ?? .zero }
        panel.view.onPress = { [weak self] index in self?.pressed(id, index: index) }
        panel.view.onHover = { [weak self] inside in self?.tagHover(id, inside: inside) }
        return panel
    }

    /// The desk window left the join (closed, parked, minimized by the user, unmatched) or its session went.
    func removeTag(_ id: String) {
        guard var tag = tags[id] else { return }
        if peek?.sessionID == id { closePeek() }
        hide(&tag, reason: .noContent)
        tags[id] = nil
        keyIndex[tag.key] = nil
    }

    /// Re-orders every shown tag of a Claude copy above its window (after an activation or focus change of that copy).
    func reorder(pid: pid_t) {
        guard coverMode == .orderedAbove else { return }
        for tag in tags.values where tag.desk.pid == pid {
            guard let frame = tag.shownFrame, let panel = tag.panel else { continue }
            windowing.show(panel.panel, frame: frame, level: panelLevel(tag), above: tag.desk.windowNumber, reorder: true)
        }
        if let peek, let tag = tags[peek.sessionID], tag.desk.pid == pid { placePeek(reorder: true) }
    }

    // MARK: Time-based words

    /// While a shown tag's words depend on the clock (a running tag), they are rebuilt every 30 s; otherwise no timer.
    func updateClockTimer() {
        let needs = tags.values.contains { $0.shownFrame != nil && $0.content?.main?.kind == .running }
        if !needs { clockTimer?.cancel(); clockTimer = nil; return }
        guard clockTimer == nil else { return }
        clockTimer = scheduler.after(Self.clockInterval) { [weak self] in
            guard let self else { return }
            self.clockTimer = nil
            self.refresh()
        }
    }
}
