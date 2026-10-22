import CoreGraphics
import Foundation
import PitboxKit

enum GuardLogLevel: Sendable { case info, warn, error }

/// What looking at one window led to. Drives the reconcile memory and the tests.
enum EvalOutcome: Equatable {
    case gone
    case notManaged
    case backoff
    case deferred
    case clear
    /// Left alone for good while the window keeps its bounds (policy: role, subrole, full screen).
    case ignored(String)
    /// Left alone for now (an Accessibility error, or the window server says it is not a normal on-screen window):
    /// worth another look later.
    case skipped(String)
    case coolingDown(until: TimeInterval)
    /// Left alone while the block's drop claims it (drag-to-park): no write, no fight record, no mark; looked at again
    /// at `until`, on the guard's clock (GuardEngine+Claims.swift).
    case claimed(until: TimeInterval)
    case corrected(CGRect)
    case wouldCorrect(CGRect)
    case cannotFit(CGRect)
}

/// The guard's decision loop. It knows nothing about Accessibility, threads or timers: the host feeds it events and
/// the current time, calls `tick(now:)` at `nextWake(now:)`, and it acts through its `AXWindowProviding`. Tests drive
/// it with fake windows and a fake clock. Not thread-safe: the host calls it from one thread.
final class GuardEngine<Provider: AXWindowProviding> {
    typealias Window = Provider.Window

    /// A window to look at: `due` moves on with every notification, but never past `since + maxSettleDelay`.
    struct Pending: Equatable { var due: TimeInterval; var fromDrag: Bool; var since: TimeInterval }
    struct Mark: Equatable { var pid: pid_t; var frame: CGRect; var target: CGRect? }
    struct Backoff: Equatable { var until: TimeInterval; var delay: TimeInterval }
    /// The last correction of a window, to recognize an app growing it back to a minimum width after the fact.
    struct LastCorrection: Equatable { var before: CGRect; var after: CGRect; var at: TimeInterval }

    let provider: Provider
    let ownPID: pid_t
    let isMouseDown: () -> Bool
    let log: (GuardLogLevel, String) -> Void

    private(set) var options: GuardOptions
    private(set) var regions: [ReservedRegion] = []
    private(set) var displays: [GuardDisplay] = []
    /// Managed apps (regular, not exempt, not Pitbox): pid to display name.
    private(set) var apps: [pid_t: String] = [:]
    private(set) var paused = false
    private(set) var suspended = false

    // Scheduling
    var pending: [Window: Pending] = [:]
    var deferred: Set<Window> = []
    var dragSince: TimeInterval?
    var reconcileAt: TimeInterval?
    var reconcileAfterRelease = false
    var lastReconcile: TimeInterval = -.infinity
    var lastMouseUp: TimeInterval = -.infinity
    /// When a shown strip last changed size or place (`setRegions`): corrections right after it are not a fight.
    var regionsChangedAt: TimeInterval = -.infinity
    var fightWake: TimeInterval?
    /// Nothing is corrected before this (a display change or a wake is settling).
    var holdUntil: TimeInterval = -.infinity

    // Memory
    var windowPIDs: [Window: pid_t] = [:]
    var fights: FightTracker<Window>
    var learnedMinWidth: [Window: CGFloat] = [:]
    var lastCorrection: [Window: LastCorrection] = [:]
    var cannotFit: [Window: Mark] = [:]
    var dryRunNoted: [Window: Mark] = [:]
    var settled: [SettleKey: TimeInterval] = [:]
    var backoff: [pid_t: Backoff] = [:]
    var manualAccessibilityTried: Set<pid_t> = []
    var unexposedLogged: Set<pid_t> = []

    // Drop claims (GuardEngine+Claims.swift)
    /// Drag-to-park's registry, handed over by the host; nil: no window is ever claimed.
    var dropClaims: WindowDropClaims?
    /// Windows whose latest look found them claimed, waiting for the claim's end.
    var claimWaits: [Window: ClaimWait] = [:]

    // Output
    var correctedCount = 0
    var lastError: String?
    /// The app a backoff `lastError` is about, so the message goes away when that app answers again or quits.
    var lastErrorPID: pid_t?
    /// Set when Accessibility reports the API disabled (permission revoked). The host stops the guard.
    var apiDisabled = false

    init(provider: Provider, options: GuardOptions, ownPID: pid_t, isMouseDown: @escaping () -> Bool,
         log: @escaping (GuardLogLevel, String) -> Void) {
        self.provider = provider
        self.options = options
        self.ownPID = ownPID
        self.isMouseDown = isMouseDown
        self.log = log
        fights = FightTracker(options: options)
    }

    /// Something to guard: not paused, strips reserved and displays known.
    var isActive: Bool { !paused && !suspended && !regions.isEmpty && !displays.isEmpty }
    var cannotFitCount: Int { cannotFit.count }
    func fightingCount(now: TimeInterval) -> Int { fights.coolingDownCount(now: now) }
    func isManaged(pid: pid_t) -> Bool { apps[pid] != nil }
    func appName(_ pid: pid_t) -> String { apps[pid] ?? "pid \(pid)" }

    // MARK: - Inputs

    func update(options new: GuardOptions, now: TimeInterval) {
        guard new != options else { return }
        if options.dryRun, !new.dryRun {
            // A dry run only logged what it would have set: allow the real thing once.
            manualAccessibilityTried.removeAll()
            unexposedLogged.removeAll()
        }
        options = new
        fights.threshold = max(1, new.fightThreshold)
        fights.window = new.fightWindow
        fights.cooldown = new.fightCooldown
        fights.maxCooldown = max(new.fightCooldown, new.maxFightCooldown)
        clearJudgements()
        requestReconcile(at: now)
    }

    func setRegions(_ new: [ReservedRegion], now: TimeInterval) {
        guard new != regions else { return }
        // A strip resized or moved while shown (a width, gap or edge change) is the user's doing; a strip appearing
        // (launch, show) is not, so an app that fights from the start is still caught.
        if !regions.isEmpty, !new.isEmpty { regionsChangedAt = now }
        regions = new
        clearJudgements()
        if !new.isEmpty { requestReconcile(at: now + options.settleDelay) }
    }

    /// A new arrangement (not just the Dock or menu bar moving) holds corrections for `displayChangeHold`.
    func setDisplays(_ new: [GuardDisplay], now: TimeInterval) {
        guard new != displays else { return }
        let rearranged = !displays.isEmpty && !Self.sameArrangement(displays, new)
        displays = new
        clearJudgements()
        if rearranged { holdCorrections(now: now) }
        requestReconcile(at: max(now + options.settleDelay, holdUntil))
    }

    /// Corrects nothing for `displayChangeHold` (a display change or a wake is in progress), then runs a pass.
    func holdCorrections(now: TimeInterval) {
        holdUntil = max(holdUntil, now + options.displayChangeHold)
        requestReconcile(at: holdUntil)
    }

    static func sameArrangement(_ a: [GuardDisplay], _ b: [GuardDisplay]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.id == $1.id && $0.frame == $1.frame }
    }

    func setPaused(_ value: Bool, now: TimeInterval) {
        guard value != paused else { return }
        paused = value
        if value { clearSchedule() } else { requestReconcile(at: now) }
    }

    /// The login session went inactive (fast user switching) or came back.
    func setSuspended(_ value: Bool, now: TimeInterval) {
        guard value != suspended else { return }
        suspended = value
        if value { clearSchedule() } else { requestReconcile(at: now + options.settleDelay) }
    }

    func addApp(pid: pid_t, name: String) {
        apps[pid] = name
    }

    func removeApp(pid: pid_t) {
        apps[pid] = nil
        backoff[pid] = nil
        answered(pid)
        manualAccessibilityTried.remove(pid)
        unexposedLogged.remove(pid)
        let gone = Set(windowPIDs.filter { $0.value == pid }.map(\.key))
        guard !gone.isEmpty else { return }
        for window in gone { forget(window) }
    }

    /// An Accessibility notification about `window` (created, moved, resized, deminiaturized, focused): look at it
    /// once things have been quiet for `settleDelay`, or `maxSettleDelay` after the first one if they never are.
    func windowChanged(_ window: Window, now: TimeInterval) {
        guard isActive else { return }
        let current = pending[window]
        // A claimed window waits for its claim's end, not for its bounds: its notifications change nothing.
        if let current, current.fromDrag, let wait = claimWaits[window], wait.isLive(at: now) { return }
        let since = current?.since ?? now
        let latest = since + max(options.maxSettleDelay, options.settleDelay)
        let due = min(max(current?.due ?? 0, now + options.settleDelay), latest)
        pending[window] = Pending(due: due, fromDrag: current?.fromDrag ?? false, since: since)
    }

    func windowMinimized(_ window: Window) {
        pending[window] = nil
        claimWaits[window] = nil
        deferred.remove(window)
        forgetMarks(window)
    }

    func requestReconcile(at time: TimeInterval) {
        reconcileAt = min(reconcileAt ?? time, time)
    }

    /// The left mouse button went up (monitor event or poll): correct what waited for the user to let go. Drop claims
    /// learn the release too, so a hold ends 3 s after it even when the block missed it.
    func mouseReleased(now: TimeInterval) {
        dropClaims?.noteMouseUp()
        // After a release no claim holds longer than maxHoldAfterMouseUp: cap every live claim wait's look there, so a
        // drag held past the stuck-button rule cannot keep the window over the strip until claimedAt + 30.
        let cap = now + WindowDropClaims.maxHoldAfterMouseUp + options.releaseSettleDelay
        for (window, wait) in claimWaits where wait.isLive(at: now) {
            guard let item = pending[window], item.fromDrag, item.due > cap else { continue }
            pending[window]?.due = cap
        }
        lastMouseUp = now
        guard dragSince != nil || !deferred.isEmpty || reconcileAfterRelease else { return }
        dragSince = nil
        flushDeferred(now: now)
    }

    /// Forgets scheduling state, judgements, apps (the host re-adds apps on the next start) and the last error.
    /// Keeps counters, fight history, learned minimum widths and a display-change hold in progress (a restart during
    /// a wake must still wait for the display to settle).
    func reset() {
        clearSchedule()
        clearJudgements()
        apps.removeAll()
        backoff.removeAll()
        apiDisabled = false
        lastError = nil
        lastErrorPID = nil
    }

    // MARK: - Clock

    /// Does everything that is due at `now`: the periodic or requested reconcile pass, then the settled windows.
    func tick(now: TimeInterval) {
        guard isActive, now >= holdUntil else { return }
        if dragSince != nil {
            if !isMouseDown() {
                mouseReleased(now: now)
            } else if !isMouseDownNow(now), !deferred.isEmpty {
                flushDeferred(now: now)
            }
        }
        if let wake = fightWake, wake <= now {
            fightWake = fights.nextCooldownEnd(after: now)
            requestReconcile(at: now)
        }
        if (reconcileAt.map { $0 <= now } ?? false) || now - lastReconcile >= options.reconcileInterval {
            reconcile(now: now)
            if apiDisabled { return }
        }
        let due = pending.filter { $0.value.due <= now }
        guard !due.isEmpty else { return }
        let held = isMouseDownNow(now)
        for (window, item) in due {
            pending[window] = nil
            if held { deferForDrag(window, now: now); continue }
            evaluate(window, now: now, userInitiated: item.fromDrag || causedByUser(now))
            if apiDisabled { return }
        }
    }

    /// When `tick` should run next, and how late it may be; nil when there is nothing to do (idle costs nothing).
    func nextWake(now: TimeInterval) -> (at: TimeInterval, leeway: TimeInterval)? {
        guard isActive else { return nil }
        if now < holdUntil { return (holdUntil, 0.1) }
        var best: (at: TimeInterval, leeway: TimeInterval)?
        func consider(_ at: TimeInterval?, _ leeway: TimeInterval) {
            guard let at else { return }
            if let current = best, current.at <= at { return }
            best = (at, leeway)
        }
        consider(pending.values.lazy.map(\.due).min(), 0.01)
        consider(reconcileAt, 0.02)
        consider(lastReconcile + options.reconcileInterval, options.reconcileInterval * 0.25)
        if let since = dragSince {
            let stuck = now - since > options.maxDragDeferral
            consider(now + (stuck ? 1 : options.dragPollInterval), 0.02)
        }
        consider(fightWake, 0.5)
        return best
    }

    // MARK: - Helpers

    /// The left button is down and has not been down suspiciously long.
    func isMouseDownNow(_ now: TimeInterval) -> Bool {
        guard isMouseDown() else { return false }
        if let since = dragSince, now - since > options.maxDragDeferral { return false }
        return true
    }

    func deferForDrag(_ window: Window, now: TimeInterval) {
        deferred.insert(window)
        if dragSince == nil { dragSince = now }
    }

    func flushDeferred(now: TimeInterval) {
        let due = now + options.releaseSettleDelay
        for window in deferred {
            pending[window] = Pending(due: max(pending[window]?.due ?? 0, due), fromDrag: true,
                                      since: pending[window]?.since ?? now)
        }
        deferred.removeAll()
        if reconcileAfterRelease {
            reconcileAfterRelease = false
            requestReconcile(at: due)
        }
    }

    func recentUserAction(_ now: TimeInterval) -> Bool { now - lastMouseUp <= options.userActionWindow }

    /// A correction now follows something the user did: a mouse release, or a change of the strips (a width, gap or
    /// edge change is the user's, so the windows it moves are not fighting the guard).
    func causedByUser(_ now: TimeInterval) -> Bool {
        recentUserAction(now) || now - regionsChangedAt <= options.settleDelay + options.userActionWindow
    }

    func overlapsRegion(_ frame: CGRect) -> Bool {
        regions.contains { Placement.overlaps(frame, $0.rect, tolerance: options.tolerance) }
    }

    func forget(_ window: Window) {
        pending[window] = nil
        claimWaits[window] = nil
        deferred.remove(window)
        windowPIDs[window] = nil
        fights.forget(window)
        learnedMinWidth[window] = nil
        lastCorrection[window] = nil
        forgetMarks(window)
    }

    func forgetMarks(_ window: Window) {
        cannotFit[window] = nil
        dryRunNoted[window] = nil
    }

    private func clearSchedule() {
        pending.removeAll()
        claimWaits.removeAll()
        deferred.removeAll()
        dragSince = nil
        reconcileAt = nil
        reconcileAfterRelease = false
    }

    /// Geometry-dependent conclusions become stale when strips, displays or options change.
    private func clearJudgements() {
        settled.removeAll()
        cannotFit.removeAll()
        dryRunNoted.removeAll()
    }
}
