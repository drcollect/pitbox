import AppKit
import Foundation
import PitboxKit

/// The data side of Code monitors: it finds Claude's running copies, reads their pop-out lists, session files and
/// transcript tails carefully (no links followed, regular files of the user only, size, nesting and duplicate-key
/// checks), derives each session's state, Now line, todos, last steps and activity, and finds the command offers of the
/// latest finished reply with the classifier's result. All reading happens on one background queue; `sessions`,
/// `runningProfiles` and `banner` change on the main thread, followed by `onChange`.
///
/// Nothing here runs a command, types into Claude or sends anything anywhere. Session text (titles, TL;DRs, replies,
/// commands) is only held for the block and the sheet; logs carry labels and numbers only.
@MainActor
public final class CodeSessionsEngine: CodeSessionsSource {
    /// The pop-out sessions of the running copies plus the followed ones, by copy and then first seen.
    public private(set) var sessions: [CodeSessionSnapshot] = []
    /// The copies running now, A, B, C, then unknown ones ("Claude ?", never read).
    public private(set) var runningProfiles: [CodeProfile] = []
    /// The running Claude processes with their copies (pids for the window join, app paths for deep links).
    public private(set) var runningProcesses: [ClaudeProcessInfo] = []
    /// "Claude's session files changed (Claude <version>). Showing titles only." when most read files fail.
    public private(set) var banner: String?
    /// Called on the main thread after `sessions`, `runningProfiles`, `runningProcesses`, `banner` or the recent
    /// sessions behind `recentSessions(within:)` changed.
    public var onChange: (() -> Void)?
    /// Called on the main thread with the offers that just left (stale), before `onChange`: an open sheet for one
    /// of them switches Run, Type and Fetch off (`CommandOfferPresenting.offerWentStale`).
    public var onOffersWentStale: ((Set<CommandOffer.ID>) -> Void)?
    /// What was run from offers, for "ran 4 min ago · exit 0"; the block feeds it the sheet's events.
    public let runRecords = CodeRunRecords()

    /// The click-time check to hand to `CommandOfferPresenting.present(_:anchor:freshness:events:)`.
    public var freshnessChecker: CommandOfferFreshnessChecking { checker }

    let checker: CodeOfferFreshnessChecker
    let worker: CodeSessionsWorker
    private let observesApplications: Bool
    private let observerTokens = ObserverTokens()
    private let clock: @Sendable () -> Date
    private var started = false
    /// Sessions active within `CodeTuning.readyRecentHoursMax` (by id); `recentSessions(within:)` filters them.
    private(set) var recentAll: [CodeRecentSession] = []

    /// An engine reading through `environment` (the user's Mac by default). Nothing is read before `start()`.
    public init(environment: CodeSessionsEnvironment = .live()) {
        let checker = CodeOfferFreshnessChecker(owner: environment.userID, clock: environment.clock)
        let box = EngineBox()
        self.checker = checker
        self.clock = environment.clock
        self.observesApplications = environment.observesApplications
        self.worker = CodeSessionsWorker(environment: environment, checker: checker) { publication, stale in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.engine?.apply(publication, stale: stale) }
            }
        }
        box.engine = self
    }

    deinit {
        worker.stop()
        observerTokens.removeAll()
    }

    /// Reads everything once and starts following file events (and, live, Claude launching and quitting).
    public func start() {
        guard !started else { return }
        started = true
        if observesApplications { observeApplications() }
        worker.start()
    }

    /// Stops watching and forgets everything read; `sessions` becomes empty.
    public func stop() {
        guard started else { return }
        started = false
        observerTokens.removeAll()
        worker.stop()
    }

    /// Sessions to show (and read first) even without a pop-out, such as parked ones; ids failing
    /// `^local_[A-Za-z0-9-]{1,64}$` are ignored. At most 24 sessions get their transcripts read.
    public func setWatched(_ sessionIDs: Set<String>) { worker.setWatched(sessionIDs) }

    /// Visible: changes are parsed (at most once per session per 2 s) and time-based states re-evaluated. Hidden: no
    /// timers, file events only mark sessions dirty.
    public func setStripVisible(_ visible: Bool) { worker.setVisible(visible) }

    /// Reads everything again now: settings, processes, the session index, the SSH config, pop-outs and every shown
    /// session (unchanged files cost one `fstat`).
    public func refresh() { worker.refresh() }

    /// Claude may have launched or quit (the engine follows NSWorkspace itself in the live environment).
    public func refreshProcesses() { worker.processesChanged() }

    // MARK: Derived fields

    /// The derivers to run after each parse, and the store their records live in; replaces any earlier
    /// registration. Call it once, before `start()`, from the composition root (it works later too: the next
    /// publication derives everything). The store should be the same one the block uses.
    public func register(_ derivers: CodeDeriverSet, memory: CodeMemoryStore) { worker.setDerivers(derivers, memory: memory) }

    /// Unarchived sessions of the running readable copies, from their session files alone, whose user-side or own
    /// activity lies within the last `hours` (at most 48): the user's most recent first, then the session's own.
    /// Pop-out sessions are included; the block leaves them out of the recent ones itself.
    public func recentSessions(within hours: Double) -> [CodeRecentSession] {
        RecentSessionScanner.filter(recentAll, within: hours, now: clock())
    }

    /// The settings file changed (the menu wrote it, or the user edited it): read it again and derive again.
    public func reloadSettings() { worker.settingsChanged() }

    /// Tests: returns once the work queued so far has run and its result has reached the main thread.
    func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            worker.flush { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func apply(_ publication: CodeSessionsWorker.Publication, stale: Set<CommandOffer.ID>) {
        sessions = publication.sessions
        runningProfiles = publication.profiles
        runningProcesses = publication.processes
        banner = publication.banner
        recentAll = publication.recent
        if !stale.isEmpty { onOffersWentStale?(stale) }
        onChange?()
    }

    private func observeApplications() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == ClaudeProcessDiscovery.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.refreshProcesses() }
            }
            observerTokens.add(token)
        }
    }
}

/// Lets the worker's callback reach the engine without keeping it alive (set once on the main thread, read there).
private final class EngineBox: @unchecked Sendable {
    weak var engine: CodeSessionsEngine?
}

/// NSWorkspace observer tokens, removable from `deinit`.
private final class ObserverTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) { lock.withLock { tokens.append(token) } }

    func removeAll() {
        let removed = lock.withLock { () -> [NSObjectProtocol] in
            defer { tokens = [] }
            return tokens
        }
        for token in removed { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}
