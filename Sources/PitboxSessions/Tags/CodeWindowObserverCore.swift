import CoreGraphics
import Foundation

/// A watched window: a Claude copy's process and the window-server number of one of its windows.
struct CodeWindowKey: Hashable, Sendable {
    var pid: pid_t
    var number: CGWindowID
}

/// One watched window as the window server lists it after a notification, a watch or a backstop pass.
struct CodeWindowState: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// After Accessibility notifications of its app (coalesced, at most once per 16 ms per app).
        case notifications
        /// It was just added to the watched set.
        case watched
        /// The 1 Hz backstop pass.
        case backstop
        /// Asked for (a Space or display change), or a follow-up read after a miniaturize.
        case refresh
    }

    var key: CodeWindowKey
    /// Nil once the window server no longer lists it.
    var window: DeskTagServerWindow?
    var reason: Reason
    /// The notifications that led to this read (empty for watched and backstop reads).
    var notifications: Set<CodeWindowNotification>
    /// The left button at the read, for moves (a drag).
    var buttonDown: Bool
    /// Monotonic seconds of the read.
    var at: TimeInterval
}

/// What the observer tells its clients.
enum CodeWindowObserverEvent: Equatable, Sendable {
    /// Watched windows whose entry changed (bounds, on-screen flag, gone), or that moved.
    case windows([CodeWindowState])
    /// An app-level notification of a Claude copy: activated, deactivated, hidden, shown, focused or main window
    /// changed, miniaturized, deminiaturized.
    case app(pid_t, CodeWindowNotification)
    /// `AXFullScreen` of a watched window changed.
    case fullScreen(CodeWindowKey, Bool)
    /// The on-screen list, front to back (fallback cover mode and the lab's order check).
    case frontToBack([DeskTagServerWindow])
    /// Accessibility trust as the observer found it.
    case trust(Bool)
    /// Lab mode: every raw notification, with the button state and its monotonic time.
    case note(pid_t, CodeWindowNotification, buttonDown: Bool, at: TimeInterval)
}

/// What the clients of the observer want, as one union.
struct CodeWindowInterest: Equatable, Sendable {
    /// Claude copies to observe.
    var pids: Set<pid_t> = []
    /// Windows to read after notifications and in the backstop pass.
    var windows: Set<CodeWindowKey> = []
    /// Run the 1 Hz backstop pass while windows are watched.
    var backstop = false
    /// Read the on-screen list too (fallback cover mode, lab).
    var frontToBack = false
    /// Deliver every raw notification (lab).
    var notes = false

    static func union(_ list: [CodeWindowInterest]) -> CodeWindowInterest {
        var out = CodeWindowInterest()
        for item in list {
            out.pids.formUnion(item.pids)
            out.windows.formUnion(item.windows)
            out.backstop = out.backstop || item.backstop
            out.frontToBack = out.frontToBack || item.frontToBack
            out.notes = out.notes || item.notes
        }
        // A watched window's app is always observed.
        out.pids.formUnion(out.windows.map(\.pid))
        return out
    }
}

/// The observer's state, confined to its queue: every method runs there, so the
/// state needs no locks; `deliver` is called there too. Reads only: Accessibility observers and the window server.
///
/// On a notification for a Claude copy, every watched window of that copy is read from the window server by number (no
/// Accessibility round trip), at most once per 16 ms per copy (the first at once, the rest coalesced to the end of the
/// interval), and changed entries go to the clients. A miniaturize or deminiaturize is read again 0.3 s and 0.7 s later
/// (the Dock animation). `AXFullScreen` is read once a resize has been quiet 0.3 s. While windows are watched and a
/// client wants it, a 1 Hz backstop pass reads them all (the guard for missed notifications); with nothing watched there
/// is no timer at all.
final class CodeWindowObserverCore: @unchecked Sendable {
    let queue: DeskTagQueue
    let ax: DeskTagAXObserving
    let server: DeskTagWindowServer
    let button: DeskTagButton
    /// Monotonic seconds (`ProcessInfo.systemUptime` in production).
    let uptime: () -> TimeInterval
    /// Called on the queue.
    var deliver: ((CodeWindowObserverEvent) -> Void)?

    /// Window-server reads and notifications handled (the lab's cost line). Written on the queue, read from any thread.
    var reads: Int { counterLock.withLock { readCount } }
    var notifications: Int { counterLock.withLock { notificationCount } }
    private let counterLock = NSLock()
    private var readCount = 0
    private var notificationCount = 0

    private enum ObserveState: Equatable {
        case observing
        case waiting(attempt: Int)
        case gaveUp
    }

    private struct Watched {
        var last: DeskTagServerWindow?
        var fullScreen: Bool?
    }

    private(set) var interest = CodeWindowInterest()
    private var observed: [pid_t: ObserveState] = [:]
    private var watched: [CodeWindowKey: Watched] = [:]
    private var pendingNotes: [pid_t: Set<CodeWindowNotification>] = [:]
    private var lastRefresh: [pid_t: TimeInterval] = [:]
    private var scheduled: Set<pid_t> = []
    private var backstopGeneration = 0
    private var backstopArmed = false
    private var fullScreenGeneration: [pid_t: Int] = [:]
    private var retryGeneration: [pid_t: Int] = [:]
    private var lastFrontToBack: TimeInterval = -.infinity
    private var frontToBackScheduled = false
    private var reportedTrust: Bool?

    static let followUpDelays: [TimeInterval] = [0.3, 0.7]

    init(queue: DeskTagQueue, ax: DeskTagAXObserving, server: DeskTagWindowServer, button: DeskTagButton,
         uptime: @escaping () -> TimeInterval) {
        self.queue = queue; self.ax = ax; self.server = server; self.button = button; self.uptime = uptime
        ax.sink = { [weak self] pid, number, note in self?.handle(pid: pid, number: number, note) }
    }

    var watchedKeys: Set<CodeWindowKey> { Set(watched.keys) }
    var observedPIDs: Set<pid_t> { Set(observed.filter { $0.value == .observing }.keys) }
    var isBackstopArmed: Bool { backstopArmed }

    // MARK: Interest

    func setInterest(_ next: CodeWindowInterest) {
        let previous = interest
        interest = next
        for pid in Set(observed.keys).subtracting(next.pids) {
            ax.unobserve(pid: pid)
            observed[pid] = nil
            retryGeneration[pid, default: 0] += 1
            lastRefresh[pid] = nil
            pendingNotes[pid] = nil
        }
        for pid in next.pids.subtracting(observed.keys) { observe(pid, attempt: 0) }
        for key in Set(watched.keys).subtracting(next.windows) {
            ax.unwatch(pid: key.pid, number: key.number)
            watched[key] = nil
        }
        let added = next.windows.subtracting(watched.keys)
        if !added.isEmpty {
            var states: [CodeWindowState] = []
            let now = uptime()
            for key in added.sorted(by: { ($0.pid, $0.number) < ($1.pid, $1.number) }) {
                if observed[key.pid] == .observing { _ = ax.watch(pid: key.pid, number: key.number) }
                let window = read(key.number)
                watched[key] = Watched(last: window, fullScreen: nil)
                states.append(CodeWindowState(key: key, window: window, reason: .watched, notifications: [], buttonDown: false, at: now))
            }
            deliver?(.windows(states))
            for key in added { readFullScreen(key) }
        }
        if next.frontToBack, !previous.frontToBack || !added.isEmpty { readFrontToBack(force: true) }
        updateBackstop()
    }

    /// Reads every watched window now (a Space or display change), and retries copies given up on.
    func refreshAll() {
        for (pid, state) in observed where state == .gaveUp { observe(pid, attempt: 0) }
        refresh(Set(watched.keys), reason: .refresh, notes: [])
        if interest.frontToBack { readFrontToBack(force: true) }
    }

    // MARK: Observing

    private func observe(_ pid: pid_t, attempt: Int) {
        guard interest.pids.contains(pid) else { return }
        switch ax.observe(pid: pid) {
        case nil:
            observed[pid] = .observing
            report(trust: true)
            for key in watched.keys where key.pid == pid { _ = ax.watch(pid: pid, number: key.number) }
        case .apiDisabled?:
            observed[pid] = .gaveUp
            report(trust: false)
        case .unsupported?:
            observed[pid] = .gaveUp
            DeskTagLog.warn("window observer unsupported pid=\(pid)")
        case .notReady?:
            let delays = DeskTagTuning.observeRetryDelays
            guard attempt < delays.count else {
                observed[pid] = .gaveUp
                DeskTagLog.warn("window observer gave up pid=\(pid) attempts=\(attempt)")
                return
            }
            observed[pid] = .waiting(attempt: attempt + 1)
            retryGeneration[pid, default: 0] += 1
            let generation = retryGeneration[pid] ?? 0
            queue.after(delays[attempt]) { [weak self] in
                guard let self, self.retryGeneration[pid] == generation, case .waiting? = self.observed[pid] else { return }
                self.observe(pid, attempt: attempt + 1)
            }
        }
    }

    private func report(trust: Bool) {
        guard reportedTrust != trust else { return }
        reportedTrust = trust
        if !trust { DeskTagLog.warn("window observer has no Accessibility permission") }
        deliver?(.trust(trust))
    }

    // MARK: Notifications

    /// One Accessibility notification, on the queue.
    func handle(pid: pid_t, number: CGWindowID?, _ note: CodeWindowNotification) {
        guard observed[pid] == .observing else { return }
        counterLock.withLock { notificationCount += 1 }
        let now = uptime()
        if interest.notes {
            let down = note == .moved || note == .resized ? button.isLeftButtonDown() : false
            deliver?(.note(pid, note, buttonDown: down, at: now))
        }
        switch note {
        case .destroyed:
            if let number {
                let key = CodeWindowKey(pid: pid, number: number)
                if watched[key] != nil { refresh([key], reason: .notifications, notes: [.destroyed]) }
            } else {
                request(pid, note)
            }
            return
        case .appActivated, .appDeactivated, .appHidden, .appShown, .focusedWindowChanged, .mainWindowChanged:
            deliver?(.app(pid, note))
        case .miniaturized, .deminiaturized:
            deliver?(.app(pid, note))
            for delay in Self.followUpDelays {
                queue.after(delay) { [weak self] in
                    guard let self, self.observed[pid] == .observing else { return }
                    self.refresh(self.keys(of: pid), reason: .refresh, notes: [note])
                }
            }
        case .resized:
            scheduleFullScreenRead(pid)
        case .moved:
            break
        }
        request(pid, note)
    }

    /// Coalescing per copy: the first read at once, then at most one per `placeCoalesce`, at the end of the interval.
    private func request(_ pid: pid_t, _ note: CodeWindowNotification) {
        pendingNotes[pid, default: []].insert(note)
        guard !scheduled.contains(pid) else { return }
        let now = uptime()
        let wait = (lastRefresh[pid] ?? -.infinity) + DeskTagTuning.placeCoalesce - now
        if wait <= 0 {
            flush(pid)
        } else {
            scheduled.insert(pid)
            queue.after(wait) { [weak self] in
                guard let self else { return }
                self.scheduled.remove(pid)
                self.flush(pid)
            }
        }
    }

    private func flush(_ pid: pid_t) {
        let notes = pendingNotes.removeValue(forKey: pid) ?? []
        lastRefresh[pid] = uptime()
        guard observed[pid] == .observing else { return }
        refresh(keys(of: pid), reason: .notifications, notes: notes)
        if interest.frontToBack { readFrontToBack(force: false) }
    }

    private func keys(of pid: pid_t) -> Set<CodeWindowKey> { Set(watched.keys.filter { $0.pid == pid }) }

    /// Reads `keys` and delivers the entries that changed (bounds, on-screen flag, gone). The button state goes with them
    /// when a move led to the read, so a client can tell a drag (only the dragged window's bounds change).
    private func refresh(_ keys: Set<CodeWindowKey>, reason: CodeWindowState.Reason, notes: Set<CodeWindowNotification>) {
        guard !keys.isEmpty else { return }
        let now = uptime()
        let down = notes.contains(.moved) ? button.isLeftButtonDown() : false
        var states: [CodeWindowState] = []
        for key in keys.sorted(by: { ($0.pid, $0.number) < ($1.pid, $1.number) }) {
            guard var entry = watched[key] else { continue }
            let window = read(key.number)
            let changed = window != entry.last
            entry.last = window
            watched[key] = entry
            guard changed else { continue }
            states.append(CodeWindowState(key: key, window: window, reason: reason, notifications: notes, buttonDown: down, at: now))
        }
        if !states.isEmpty { deliver?(.windows(states)) }
    }

    private func read(_ number: CGWindowID) -> DeskTagServerWindow? {
        counterLock.withLock { readCount += 1 }
        return server.window(number: number)
    }

    // MARK: Full screen

    private func scheduleFullScreenRead(_ pid: pid_t) {
        fullScreenGeneration[pid, default: 0] += 1
        let generation = fullScreenGeneration[pid] ?? 0
        queue.after(DeskTagTuning.fullScreenSettle) { [weak self] in
            guard let self, self.fullScreenGeneration[pid] == generation else { return }
            for key in self.keys(of: pid) { self.readFullScreen(key) }
        }
    }

    private func readFullScreen(_ key: CodeWindowKey) {
        guard observed[key.pid] == .observing, var entry = watched[key],
              let value = ax.isFullScreen(pid: key.pid, number: key.number), value != entry.fullScreen else { return }
        entry.fullScreen = value
        watched[key] = entry
        deliver?(.fullScreen(key, value))
    }

    // MARK: Front to back

    private func readFrontToBack(force: Bool) {
        let now = uptime()
        let wait = lastFrontToBack + DeskTagTuning.placeCoalesce - now
        if force || wait <= 0 {
            lastFrontToBack = now
            counterLock.withLock { readCount += 1 }
            deliver?(.frontToBack(server.onScreenFrontToBack()))
        } else if !frontToBackScheduled {
            frontToBackScheduled = true
            queue.after(wait) { [weak self] in
                guard let self else { return }
                self.frontToBackScheduled = false
                guard self.interest.frontToBack else { return }
                self.readFrontToBack(force: true)
            }
        }
    }

    // MARK: Backstop (the 1 Hz pass)

    private func updateBackstop() {
        let wanted = interest.backstop && !watched.isEmpty
        guard wanted != backstopArmed else { return }
        backstopArmed = wanted
        backstopGeneration += 1
        if wanted { scheduleBackstop(backstopGeneration) }
    }

    private func scheduleBackstop(_ generation: Int) {
        queue.after(DeskTagTuning.backstopInterval) { [weak self] in
            guard let self, self.backstopArmed, self.backstopGeneration == generation else { return }
            self.refresh(Set(self.watched.keys), reason: .backstop, notes: [])
            if self.interest.frontToBack { self.readFrontToBack(force: true) }
            self.scheduleBackstop(generation)
        }
    }

    /// The app's focused window's number (lab mode only), read on the queue.
    func focusedWindowNumber(pid: pid_t) -> CGWindowID? {
        guard observed[pid] == .observing else { return nil }
        return ax.focusedWindowNumber(pid: pid)
    }

    /// Stops everything: observers, watched windows, timers.
    func stop() {
        setInterest(CodeWindowInterest())
    }
}
