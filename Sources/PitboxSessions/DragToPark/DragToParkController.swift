import AppKit
import CoreGraphics
import Foundation
import PitboxKit

/// Drag-to-park: dragging a Claude Code pop-out by its title bar into the block parks it. This is the block's side: it
/// notices a pop-out drag, arms the drop once the pointer has been inside the block's region for 0.25 s, claims the
/// window in `WindowDropClaims` so the window guard leaves it alone, shows the label and the slot, and parks through
/// the window side on release, recording the frame from before the drag. Released unarmed, nothing new happens: the
/// guard slides the window back as it always did. With `dragToPark` off nothing here runs at all.
///
/// - **Which windows:** the window join's desk pop-outs (`CodeWindowParking.deskWindows`, by pid and window number) of
///   the running readable copies.
/// - **Noticing a drag:** a move of such a pop-out with the left button down, from the shared window observer
///   (`attach(observer:)`, `CodeWindowObserver`, which reads the button with each move), or, without notifications,
///   a press in the top 52 pt of a matched pop-out (global and local mouse-down monitors, no permission) whose
///   window-server bounds then move with the pointer. While a drag runs, a 30 Hz poll reads the pointer, the button and
///   the window's bounds by number; it stops at the release (mouse-up monitors plus the poll, so a lost mouse-up still
///   ends it).
/// - **Folded:** while the block shows only its rail, drags are noticed and followed as above but never armed; a drag
///   whose pointer is over the rail's region reports `onRailHover` (the rail's 0.6 s spring-loaded unfold), and once the
///   block unfolds the same drag arms over the block as any other.
/// - **Cost:** idle while the block is hidden, or with `dragToPark` off (no timer, no
///   monitor, no interest in the observer). Otherwise one pass a second (the desk pop-outs, the claimable copies, one
///   window-server listing for their frames at rest) and, while pop-outs are on the desk, the mouse monitors and the
///   observer's watch of those windows; the 30 Hz poll only during a drag.
/// - **Threads:** main thread only; the claims registry is lock-based and never waits on another thread.
/// - **Privacy:** only window numbers, frames and the pointer are read; no title, no session text; log lines carry
///   labels and `session=#N` only. The label and the slot show the app's words and the user's bucket names.
///
/// Wiring (composition root, once `CodeWindowParker` offers `CodeDropParking`):
/// ```swift
/// let claims = WindowDropClaims()                        // shared with the guard: windowGuard.dropClaims = claims
/// claims.onReleasedUnparked = { DispatchQueue.main.async { MainActor.assumeIsolated { windowGuard.lookAgain() } } }
/// let drop = CodeDragToPark(claims: claims, parker: codeParker, source: codeEngine, stripRegions: { panel.regions },
///                           settings: codeSettings)
/// drop.attach(observer: windowObserver)                  // the window observer, shared with the desk tags
/// block.dragToPark = drop                                // the block's makeView calls drop.attach(tile:)
/// // the block shown, hidden or folded → drop.setStripVisible(_:) (`PitboxBlock.setStripVisible` does it)
/// // the settings file re-read → drop.update(settings:) (`PitboxBlock.update(settings:)` does it)
/// ```
@MainActor
public final class CodeDragToPark {
    // The block's side of a drop, set by `attach(tile:)` (DragToPark+Tile.swift).
    /// The bucket of the visible Code monitors block under a screen point (AppKit coordinates), nil elsewhere; nil: no
    /// bucket is ever under the pointer.
    public var bucketUnderPointer: (@MainActor (CGPoint) -> CodeDropTarget?)?
    /// The session's own bucket (Unsorted for a new one), the target when the pointer is elsewhere in the block. Nil:
    /// the label says "Drop to park" alone.
    public var ownBucket: (@MainActor (String) -> CodeDropTarget?)?
    /// Marks the target bucket while a drop is armed over it (its outline, later its dashed slot), or clears it (nil).
    public var onSlotChange: (@MainActor (CodeDropSlot?) -> Void)?
    /// The drop parked a session: it goes to the drop's bucket (the bucket store).
    public var onParked: (@MainActor (String, CodeDropTarget) -> Void)?
    /// While the block is folded to its rail (`setRailShown(true)`): a pop-out drag's pointer entered (`true`) or left
    /// (`false`) the rail's region. The app drives the rail's spring-loaded unfold with it (`hoverBegan`/`hoverEnded`);
    /// after the unfold (`setStripVisible(true)`) the same drag arms as any other.
    public var onRailHover: (@MainActor (Bool) -> Void)?

    /// What allows arming right now.
    public private(set) var conditions: CodeDragToParkConditions

    /// How long the failure line stays.
    static let failureDuration: TimeInterval = 3
    /// After a release unarmed or a failed park, the window's frame is read again this much later (the guard may slide
    /// it back first).
    static let observeDelay: TimeInterval = 0.5
    static let pollInterval: TimeInterval = 1 / Double(CodeTuning.dropPollHz)
    static let passInterval: TimeInterval = 1

    private var tracker = PopOutDragTracker()
    private let claims: CodeDropClaiming
    private let parker: CodeDropParking
    private let desk: @MainActor () -> [CodeDropPopout]
    private let processes: @MainActor () -> [ClaudeProcessInfo]
    private let stripRegions: @MainActor () -> [ReservedRegion]
    private let system: CodeDragSystem
    private let label: CodeDropLabelPresenting
    private var claimablePIDs: Set<pid_t>?
    /// The shared window observer and this drop's client there (`CodeWindowObserver`).
    private weak var observer: CodeWindowObserver?
    private var observerClient: Int?
    private var passTimer: CodeDragToken?
    private var pollTimer: CodeDragToken?
    private var monitors: CodeDragToken?
    private var pendingWork: [Int: CodeDragToken] = [:]
    private var workCount = 0
    private var slotShown = false
    private enum LabelMode: Equatable { case none, armed, failure(Int) }
    private var labelMode = LabelMode.none
    private var failureCount = 0
    private var stopped = false
    /// The last answer given to `onRailHover`.
    private(set) var railHovered = false

    /// The production drag-to-park: the real pointer, button, window server, mouse monitors and label panel.
    /// - Parameters:
    ///   - claims: the one `WindowDropClaims` the window guard reads too.
    ///   - parker: the window side (`CodeWindowParker`): its `deskWindows` say which pop-outs are on the desk, and its
    ///     `parkDropped` (once it conforms to `CodeDropParking`) parks with the frame from before the drag.
    ///   - source: the data side (`CodeSessionsEngine`): the running Claude copies (readable ones are claimable) and the
    ///     sessions' local indexes for log lines. Read only; the block keeps its `onChange`.
    ///   - stripRegions: the block's published regions (`panel.regions`), read at every poll.
    ///   - settings: the settings file (`dragToPark`).
    public convenience init(claims: WindowDropClaims, parker: CodeWindowParking & CodeDropParking, source: CodeSessionsSource,
                            stripRegions: @escaping @MainActor () -> [ReservedRegion], settings: CodeSettings) {
        self.init(claims: claims, parker: parker, desk: Self.deskPopouts(parker: parker, source: source),
                  processes: { [weak source] in source?.runningProcesses ?? [] }, stripRegions: stripRegions,
                  conditions: CodeDragToParkConditions(dragToPark: settings.dragToPark), system: CodeLiveDragSystem(),
                  label: DropLabelPanelController())
    }

    /// The desk pop-outs as the production drop reads them: the window join's `deskWindows` with the data side's
    /// indexes (both held weakly; the block keeps their `onChange`).
    static func deskPopouts(parker: CodeWindowParking, source: CodeSessionsSource) -> @MainActor () -> [CodeDropPopout] {
        { [weak parker, weak source] in CodeDropPopout.desk(parker?.deskWindows ?? [:], sessions: source?.sessions ?? []) }
    }

    init(claims: CodeDropClaiming, parker: CodeDropParking, desk: @escaping @MainActor () -> [CodeDropPopout],
         processes: @escaping @MainActor () -> [ClaudeProcessInfo], stripRegions: @escaping @MainActor () -> [ReservedRegion],
         conditions: CodeDragToParkConditions, system: CodeDragSystem, label: CodeDropLabelPresenting) {
        self.claims = claims
        self.parker = parker
        self.desk = desk
        self.processes = processes
        self.stripRegions = stripRegions
        self.conditions = conditions
        self.system = system
        self.label = label
    }

    /// Takes moves of the desk pop-outs from the shared window observer (the first way to notice a
    /// drag): this drop watches those windows while it is active, and each move read with the button down starts a drag;
    /// read with the button up, it is a frame at rest. Without an observer the mouse-down fallback alone notices drags.
    public func attach(observer: CodeWindowObserver) {
        if let current = self.observer, let client = observerClient { current.removeClient(client) }
        self.observer = observer
        observerClient = observer.addClient { [weak self] event in self?.observed(event) }
        updateInterest()
    }

    // MARK: Conditions

    /// The block became visible or hidden (shown, hidden or folded to the rail).
    public func setStripVisible(_ visible: Bool) { change { $0.stripShown = visible } }
    /// The block is on screen folded to its rail (`true`) or not (`false`): drags are watched only to spring-load the
    /// rail; nothing arms or parks on the rail.
    public func setRailShown(_ shown: Bool) { change { $0.railShown = shown } }
    /// The settings file was read again (its `dragToPark`).
    public func update(settings: CodeSettings) { change { $0.dragToPark = settings.dragToPark } }

    /// The block's sessions or the window side changed: the desk pop-outs and claimable copies are read now instead of
    /// at the next pass. Cheap; does nothing while drag-to-park is idle.
    public func refresh() {
        guard conditions.watchesDrags, !stopped else { return }
        readInputs()
        updateActivity()
    }

    /// A desk pop-out moved (`bounds` from the window server, the button read with it): a drag when the button is down,
    /// else a frame at rest.
    func moved(pid: pid_t, windowNumber: UInt32, bounds: CGRect, buttonDown: Bool) {
        guard !stopped, tracker.isCandidate(windowNumber), tracker.popouts[windowNumber]?.pid == pid,
              conditions.watchesDrags || tracker.drag != nil else { return }
        tracker.moved(windowNumber: windowNumber, bounds: bounds, buttonDown: buttonDown, pointer: system.pointer(),
                      now: system.now)
        updateActivity()
    }

    /// The observer's reads of the watched pop-outs: a move goes to `moved`; any other read (watched, backstop, a
    /// refresh, a resize) is a frame at rest while the button is up.
    private func observed(_ event: CodeWindowObserverEvent) {
        guard case .windows(let states) = event, !stopped else { return }
        for state in states {
            guard let window = state.window, window.isOnScreen else { continue }
            if state.notifications.contains(.moved) {
                moved(pid: state.key.pid, windowNumber: state.key.number, bounds: window.bounds, buttonDown: state.buttonDown)
            } else if tracker.popouts[state.key.number]?.pid == state.key.pid {
                tracker.observe(windowNumber: state.key.number, bounds: window.bounds, buttonDown: system.isLeftButtonDown())
            }
        }
    }

    /// The observer watches the desk pop-outs of claimable copies while this drop is active, and nothing otherwise.
    private func updateInterest() {
        guard let observer, let client = observerClient else { return }
        var interest = CodeWindowInterest()
        if conditions.watchesDrags, !stopped {
            interest.windows = Set(tracker.popouts.values.filter { tracker.isCandidate($0.windowNumber) }
                .map { CodeWindowKey(pid: $0.pid, number: $0.windowNumber) })
            interest.pids = Set(interest.windows.map(\.pid))
        }
        observer.setInterest(interest, for: client)
    }

    /// Ends drag-to-park (quit): a drag is disarmed, its claim released; timers, monitors, the label and the slot go.
    /// Parks already asked of the window side finish there.
    public func stop() {
        guard !stopped else { return }
        apply(tracker.cancelDrag())
        stopped = true
        passTimer = nil
        pollTimer = nil
        monitors = nil
        if let observer, let client = observerClient { observer.removeClient(client) }
        observerClient = nil
        for work in pendingWork.values { work.cancel() }
        pendingWork.removeAll()
        label.hide()
        labelMode = .none
        setSlot(nil)
        setRailHover(false)
    }

    // MARK: Activity

    private func change(_ body: (inout CodeDragToParkConditions) -> Void) {
        var next = conditions
        body(&next)
        guard next != conditions, !stopped else { return }
        let wasWatching = conditions.watchesDrags
        conditions = next
        // Nothing was watched while idle: the desk pop-outs and their frames at rest are read at once.
        if conditions.watchesDrags, !wasWatching { pass() }
        // A drag in progress disarms at once (the next poll would do it within 33 ms).
        if tracker.drag != nil { poll() }
        updateRailHover()
        updateActivity()
    }

    /// Timers and monitors follow what can happen: nothing while idle.
    private func updateActivity() {
        guard !stopped else { return }
        if conditions.watchesDrags {
            if passTimer == nil {
                passTimer = system.every(Self.passInterval, tolerance: 0.3) { [weak self] in self?.pass() }
            }
        } else {
            passTimer = nil
        }
        let wantsMonitors = (conditions.watchesDrags && !tracker.popouts.isEmpty) || tracker.press != nil
            || tracker.drag != nil
        if wantsMonitors, monitors == nil {
            monitors = system.addMouseMonitors(down: { [weak self] point in self?.pressed(at: point) },
                                               up: { [weak self] in self?.mouseUp() })
        } else if !wantsMonitors {
            monitors = nil
        }
        if tracker.needsPolling, pollTimer == nil {
            pollTimer = system.every(Self.pollInterval, tolerance: 0.005) { [weak self] in self?.poll() }
        } else if !tracker.needsPolling {
            pollTimer = nil
        }
        updateInterest()
    }

    // MARK: The 1 Hz pass

    private func pass() {
        guard conditions.watchesDrags, !stopped else { return }
        readInputs()
        if !tracker.popouts.isEmpty, !system.isLeftButtonDown() {
            let windows = system.onScreenWindows()
            for popout in tracker.popouts.values {
                guard let window = windows.first(where: { $0.number == popout.windowNumber }) else { continue }
                tracker.observe(windowNumber: popout.windowNumber, bounds: window.bounds, buttonDown: false)
            }
        }
        updateActivity()
    }

    /// The claimable copies (to the registry when they change) and the desk pop-outs; pop-outs that just appeared get
    /// their frame at rest read at once.
    private func readInputs() {
        let claimable = Set(processes().filter(\.profile.isReadable).map(\.pid))
        if claimable != claimablePIDs {
            claimablePIDs = claimable
            claims.setClaimablePIDs(claimable)
        }
        let before = Set(tracker.popouts.keys)
        apply(tracker.update(popouts: desk(), claimable: claimable))
        let added = Set(tracker.popouts.keys).subtracting(before)
        if !added.isEmpty, !system.isLeftButtonDown() {
            for number in added { observe(number) }
        }
    }

    private func observe(_ number: UInt32) {
        guard !stopped, let bounds = system.onScreenBounds(of: number) else { return }
        tracker.observe(windowNumber: number, bounds: bounds, buttonDown: system.isLeftButtonDown())
    }

    // MARK: Events

    private func pressed(at appKitPoint: CGPoint) {
        guard !stopped, conditions.watchesDrags, tracker.drag == nil, !tracker.popouts.isEmpty else { return }
        let point = system.quartzPoint(fromAppKit: appKitPoint)
        let own = label.windowNumber
        let front = system.onScreenWindows().first { window in
            window.alpha > 0 && window.number != own && window.bounds.contains(point)
        }
        tracker.pressed(at: point, front: front.map { ($0.number, $0.bounds) }, pointer: system.pointer())
        updateActivity()
    }

    private func mouseUp() {
        guard !stopped else { return }
        apply(tracker.released(now: system.now, pointer: system.pointer()))
        updateRailHover()
        updateActivity()
    }

    private func poll() {
        guard !stopped else { return }
        let pointer = system.pointer()
        let bounds = tracker.watchedWindow.flatMap { system.onScreenBounds(of: $0) }
        let under = tracker.drag != nil && conditions.allowsArming
            ? bucketUnderPointer?(system.appKitPoint(fromQuartz: pointer)) : nil
        let input = DragToParkTick(now: system.now, pointer: pointer, buttonDown: system.isLeftButtonDown(),
                                   strips: stripRegions().map(\.rect), allowsArming: conditions.allowsArming,
                                   windowBounds: bounds, bucketUnderPointer: under)
        let claims = self.claims
        let own = ownBucket
        apply(tracker.tick(input, claim: { claims.claim(pid: $0, windowNumber: $1) }, ownBucket: { own?($0) ?? nil }))
        updateRailHover(pointer: pointer)
        updateActivity()
    }

    // MARK: The rail (spring-loaded unfold)

    /// A pop-out drag is over the rail's region while the block is folded: `onRailHover(true)`; anything else: `false`.
    /// Only the pointer and the published region are read; nothing is claimed, armed or parked here.
    private func updateRailHover(pointer: CGPoint? = nil) {
        let hovering: Bool
        if !stopped, conditions.watchesRail, tracker.drag != nil {
            let point = pointer ?? system.pointer()
            hovering = stripRegions().contains { $0.rect.contains(point) }
        } else {
            hovering = false
        }
        setRailHover(hovering)
    }

    private func setRailHover(_ hovering: Bool) {
        guard hovering != railHovered else { return }
        railHovered = hovering
        onRailHover?(hovering)
    }

    private func parkFinished(_ windowNumber: UInt32, _ result: CodeDropParkResult) {
        apply(tracker.parkFinished(windowNumber: windowNumber, result: result))
        updateActivity()
    }

    // MARK: Effects

    private func apply(_ effects: [DragToParkEffect]) {
        for effect in effects {
            switch effect {
            case .releaseClaim(let pid, let number, let parked):
                claims.release(pid: pid, windowNumber: number, parked: parked)
            case .noteMouseUp:
                claims.noteMouseUp()
            case .showLabel(let text, let point):
                labelMode = .armed
                label.show(text, failure: false, at: system.appKitPoint(fromQuartz: point))
            case .showFailure(let text, let point):
                showFailure(text, at: point)
            case .hideLabel:
                if labelMode == .armed {
                    labelMode = .none
                    label.hide()
                }
            case .showSlot(let slot):
                setSlot(slot)
            case .hideSlot:
                setSlot(nil)
            case .park(let sessionID, let number, let frame):
                parker.parkDropped(sessionID: sessionID, restoreFrame: frame) { [weak self] result in
                    self?.parkFinished(number, result)
                }
            case .moveToBucket(let sessionID, let target):
                onParked?(sessionID, target)
            case .observeSoon(let number):
                later(Self.observeDelay) { [weak self] in self?.observe(number) }
            case .log(let line):
                CodeTileLog.info(line)
            }
        }
    }

    private func setSlot(_ slot: CodeDropSlot?) {
        guard slot != nil || slotShown else { return }
        slotShown = slot != nil
        onSlotChange?(slot)
    }

    /// The failure line for 3 s; a drop armed meanwhile replaces it, and its timer then leaves the new label alone.
    private func showFailure(_ text: String, at point: CGPoint) {
        guard !stopped else { return }
        failureCount += 1
        let mode = LabelMode.failure(failureCount)
        labelMode = mode
        label.show(text, failure: true, at: system.appKitPoint(fromQuartz: point))
        later(Self.failureDuration) { [weak self] in
            guard let self, self.labelMode == mode else { return }
            self.labelMode = .none
            self.label.hide()
        }
    }

    /// A delayed call that is kept until it runs (a token cancels its work when it goes) and cancelled by `stop()`.
    private func later(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        workCount += 1
        let id = workCount
        pendingWork[id] = system.after(delay) { [weak self] in
            self?.pendingWork[id] = nil
            work()
        }
    }
}
