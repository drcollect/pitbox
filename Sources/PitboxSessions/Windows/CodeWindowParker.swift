import CoreGraphics
import Foundation
import PitboxKit

/// The window side of Code monitors: joins sessions with their pop-out windows, parks
/// (minimizes) and restores them through Accessibility, and keeps `code-monitors.json`.
///
/// Threads: this object lives on the main thread; the join and every Accessibility call run on one serial queue of its
/// own (a dedicated thread, 2 s messaging timeout per element), never on the main thread. Results come back here and
/// `onChange` fires. While the block is visible (`setActive(true)`) a pass runs every second; while it is hidden
/// nothing runs on a timer.
///
/// Privacy: statuses, results and log lines carry the app's own words, numbers and the session's local index only;
/// window titles are compared, never stored, logged or shown by this type. The records file holds ids, numbers and frames.
///
/// The Claude processes (pids, copies, app paths) come from the data side (`CodeSessionsSource.runningProcesses`),
/// handed in with the sessions; the parker never discovers processes itself.
///
/// Wiring (composition root): `CodeWindowParker(stripRegions: { panel.regions })`, then pass it to
/// `PitboxBlock`; the block calls `start()`, `update(sessions:processes:)` and `setActive(_:)`.
@MainActor
public final class CodeWindowParker: CodeWindowParking {
    public private(set) var statuses: [String: CodeWindowStatus] = [:]
    public private(set) var parkedSessionIDs: Set<String> = []
    public private(set) var deskWindows: [String: CodeDeskWindow] = [:]
    public var onChange: (() -> Void)?
    /// Whether the 1 Hz pass runs (the block is visible).
    public private(set) var isActive = false

    /// Seconds between window passes while active.
    public static let passInterval: TimeInterval = 1

    let core: CodeParkerCore
    private let queue: CodeWorkQueue
    private let screens: CodeScreens
    private let workspace: CodeWorkspace
    private let stripRegions: @MainActor () -> [ReservedRegion]
    private let deliver: (@escaping @Sendable () -> Void) -> Void
    private let startTicker: (@escaping @MainActor () -> Void) -> (() -> Void)
    private var stopTicker: (() -> Void)?
    private var inputs: [CodeWindowSessionInput] = []
    private var processInfos: [ClaudeProcessInfo] = []
    private var receivedProcesses = false
    private var passInFlight = false
    private var passPending = false
    private var started = false

    /// The production parker: the window server, Accessibility, NSWorkspace and NSScreen, with records in
    /// `Paths.appSupport/code-monitors.json`. `stripRegions` gives the strip's region(s), read right before a restore
    /// (pass `{ panel.regions }`; never assign the panel's `onRegionsChanged`, the window guard owns it).
    public convenience init(stripRegions: @escaping @MainActor () -> [ReservedRegion]) {
        self.init(server: CodeLiveWindowServer(), ax: CodeLiveAccessibility(),
                  workspace: CodeLiveWorkspace(), screens: CodeLiveScreens(), queue: CodeAXThread(),
                  store: CodeParkedRecordStore(), clock: { Date() }, uptime: { ProcessInfo.processInfo.systemUptime },
                  stripRegions: stripRegions, deliver: { work in DispatchQueue.main.async(execute: work) },
                  startTicker: CodeWindowParker.mainRunLoopTicker)
    }

    init(server: CodeWindowServer, ax: CodeAccessibility, workspace: CodeWorkspace, screens: CodeScreens,
         queue: CodeWorkQueue, store: CodeParkedRecordStore, clock: @escaping () -> Date,
         uptime: @escaping () -> TimeInterval, stripRegions: @escaping @MainActor () -> [ReservedRegion],
         deliver: @escaping (@escaping @Sendable () -> Void) -> Void,
         startTicker: @escaping (@escaping @MainActor () -> Void) -> (() -> Void)) {
        core = CodeParkerCore(server: server, ax: ax, workspace: workspace, store: store, queue: queue, clock: clock, uptime: uptime)
        self.queue = queue
        self.screens = screens
        self.workspace = workspace
        self.stripRegions = stripRegions
        self.deliver = deliver
        self.startTicker = startTicker
        core.onPublish = { [weak self, deliver] snapshot in
            deliver { MainActor.assumeIsolated { self?.apply(snapshot) } }
        }
    }

    /// Loads the records and publishes them, so monitors of windows parked before a restart show (and get watched)
    /// at once. Passes start with the first process list (`update(sessions:processes:)`): a pass without one would take
    /// every Claude for gone.
    public func start() {
        guard !started else { return }
        started = true
        queue.async { [core] in
            core.loadRecordsIfNeeded()
            core.publish()
        }
        if receivedProcesses { requestPass() }
    }

    /// Stops the pass. The records stay on disk; restarting the app finds the windows again.
    public func stop() {
        setActive(false)
    }

    public func update(sessions: [CodeSessionSnapshot], processes: [ClaudeProcessInfo]) {
        let next = sessions.map {
            CodeWindowSessionInput(id: $0.id, index: $0.index, profile: $0.profile, title: $0.title,
                                   previousTitles: $0.previousTitles, hint: $0.popout?.bounds, hasPopout: $0.popout != nil)
        }
        let processesChanged = processes != processInfos || !receivedProcesses
        processInfos = processes
        receivedProcesses = true
        guard next != inputs || processesChanged else { return }
        if next != inputs {
            inputs = next
            queue.async { [core] in core.setSessions(next) }
        }
        requestPass()
    }

    /// The processes for the parker's thread, with each app's hidden state read now (main thread).
    private func currentProcesses() -> [CodeClaudeProcess] {
        processInfos.map { CodeClaudeProcess($0, isHidden: workspace.isHidden(pid: $0.pid)) }
    }

    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        stopTicker?()
        stopTicker = nil
        guard active else { return }
        stopTicker = startTicker { [weak self] in self?.requestPass() }
        requestPass()
    }

    public func perform(_ click: CodeWindowClick, sessionID id: String) {
        switch click {
        case .park:
            let displays = screens.displays()
            queue.async { [core] in core.park(id, displays: displays) { _ in } }
        case .restore:
            let displays = screens.displays()
            let strip = stripRegions().map(\.rect)
            queue.async { [core] in core.restore(id, displays: displays, stripRects: strip) { _ in } }
        case .activate:
            queue.async { [core] in core.activateWindow(id) { _ in } }
        case .openInMainWindow:
            queue.async { [core] in core.openInMainWindow(id) { _ in } }
        case .none:
            return
        }
    }

    public func parkAllDone(_ sessionIDs: [String]) async -> CodeParkAllResult {
        let displays = screens.displays()
        return await withCheckedContinuation { continuation in
            queue.async { [core] in core.parkAll(sessionIDs, displays: displays) { continuation.resume(returning: $0) } }
        }
    }

    public func parkFrontmostPopout() async -> CodeParkFrontmostResult {
        let pid = workspace.frontmostPID()
        let list = currentProcesses()
        let displays = screens.displays()
        return await withCheckedContinuation { continuation in
            queue.async { [core] in
                core.parkFrontmost(pid: pid, processes: list, displays: displays) { continuation.resume(returning: $0) }
            }
        }
    }

    // MARK: Passes

    /// Runs a pass now unless one is running; then one more right after it. Nothing before the first process list.
    func requestPass() {
        guard receivedProcesses else { return }
        guard !passInFlight else { passPending = true; return }
        passInFlight = true
        let list = currentProcesses()
        queue.async { [core, deliver] in
            core.pass(processes: list)
            deliver { MainActor.assumeIsolated { [weak self] in self?.passFinished() } }
        }
    }

    private func passFinished() {
        passInFlight = false
        if passPending {
            passPending = false
            requestPass()
        }
    }

    private func apply(_ snapshot: CodeParkerSnapshot) {
        guard snapshot.statuses != statuses || snapshot.parkedSessionIDs != parkedSessionIDs
            || snapshot.deskWindows != deskWindows else { return }
        statuses = snapshot.statuses
        parkedSessionIDs = snapshot.parkedSessionIDs
        deskWindows = snapshot.deskWindows
        onChange?()
    }

    /// A repeating main-run-loop timer at `passInterval` (common modes, so it keeps going while a menu is open).
    static func mainRunLoopTicker(_ tick: @escaping @MainActor () -> Void) -> (() -> Void) {
        let timer = Timer(timeInterval: passInterval, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

// MARK: Drag-to-park

extension CodeWindowParker: CodeDropParking {
    /// Park for a pop-out dropped on the block, recording `restoreFrame` (its bounds before the drag).
    public func parkDropped(sessionID: String, restoreFrame: CGRect,
                            done: @escaping @MainActor (CodeDropParkResult) -> Void) {
        let displays = screens.displays()
        queue.async { [core, deliver] in
            core.park(sessionID, displays: displays, frame: restoreFrame) { outcome in
                let result: CodeDropParkResult
                switch outcome {
                case .parked: result = .parked
                case .failed(let reason): result = .failed(reason: reason)
                default: result = .failed(reason: CodeParkerCore.parkFailure)
                }
                deliver { MainActor.assumeIsolated { done(result) } }
            }
        }
    }
}
