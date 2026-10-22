import ApplicationServices
import Foundation

/// One `AXObserver` per observed app, all delivering to one callback on the guard thread's run loop.
///
/// Subscriptions are made on the application element, which delivers them for all of the app's windows:
/// window created / moved / resized / miniaturized / deminiaturized, focused and main window changed, app shown.
/// An app that is not ready yet (typical right after launch) is retried with backoff; an app that does not
/// implement Accessibility is left to the reconcile pass.
final class AXObserverSet {
    static let notifications: [String] = [
        kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification, kAXApplicationShownNotification,
    ]
    /// Without these the app is not considered observed.
    static let essential: Set<String> = [kAXWindowCreatedNotification, kAXWindowMovedNotification,
                                         kAXWindowResizedNotification]
    static let maxAttempts = 6

    private enum State: Equatable {
        case observing
        case waiting(attempt: Int, retryAt: TimeInterval)
        case gaveUp
        case unsupported
    }

    private struct Entry {
        var observer: AXObserver?
        var state: State
    }

    private var entries: [pid_t: Entry] = [:]
    private let runLoop: CFRunLoop
    private let refcon: UnsafeMutableRawPointer
    private let callback: AXObserverCallback
    private let appElement: (pid_t) -> AXUIElement

    init(runLoop: CFRunLoop, refcon: UnsafeMutableRawPointer, callback: AXObserverCallback,
         appElement: @escaping (pid_t) -> AXUIElement) {
        self.runLoop = runLoop
        self.refcon = refcon
        self.callback = callback
        self.appElement = appElement
    }

    var observingCount: Int { entries.values.reduce(0) { $0 + ($1.state == .observing ? 1 : 0) } }

    func isObserving(_ pid: pid_t) -> Bool { entries[pid]?.state == .observing }

    /// The earliest pending retry.
    var nextRetry: TimeInterval? {
        entries.values.compactMap { entry -> TimeInterval? in
            if case .waiting(_, let at) = entry.state { return at }
            return nil
        }.min()
    }

    /// Starts observing `pid` unless it already is. `fresh` restarts an app that was given up on (for example when
    /// it is activated later). Returns the failure, if any; `.apiDisabled` means the permission is off.
    @discardableResult
    func observe(_ pid: pid_t, now: TimeInterval, fresh: Bool = false) -> AXFailure? {
        let previous = entries[pid]?.state
        var attempt = 0
        switch previous {
        case .observing?: return nil
        case .unsupported?, .gaveUp?: if !fresh { return nil }
        case .waiting(let count, _)?: attempt = fresh ? 0 : count
        case nil: break
        }
        let failure: AXFailure
        switch register(pid) {
        case .success(let observer):
            CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            entries[pid] = Entry(observer: observer, state: .observing)
            return nil
        case .failure(let value):
            failure = value
        }
        switch failure {
        case .apiDisabled:
            entries[pid] = nil
        case .unsupported:
            entries[pid] = Entry(observer: nil, state: .unsupported)
        case .cannotComplete, .invalidElement, .other:
            // Not ready (typical right after launch) or busy: retry after 0.5, 1, 2, 4, 8 s, then give up until the
            // app is activated again.
            let next = attempt + 1
            entries[pid] = next >= Self.maxAttempts
                ? Entry(observer: nil, state: .gaveUp)
                : Entry(observer: nil, state: .waiting(attempt: next, retryAt: now + 0.5 * pow(2, Double(attempt))))
        }
        return failure
    }

    /// Retries registrations that are due. Returns `.apiDisabled` if the permission turned out to be off.
    func retryDue(now: TimeInterval) -> AXFailure? {
        let due = entries.compactMap { pid, entry -> pid_t? in
            if case .waiting(_, let at) = entry.state, at <= now { return pid }
            return nil
        }
        for pid in due where observe(pid, now: now) == .apiDisabled { return .apiDisabled }
        return nil
    }

    /// Stops delivery at once by removing the run-loop source; the observer and its registrations die with it.
    /// (No `AXObserverRemoveNotification` calls: each would be a round trip that a hung app could stall.)
    func unobserve(_ pid: pid_t) {
        guard let entry = entries.removeValue(forKey: pid), let observer = entry.observer else { return }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    func removeAll() {
        for pid in Array(entries.keys) { unobserve(pid) }
        entries.removeAll()
    }

    private func register(_ pid: pid_t) -> Result<AXObserver, AXFailure> {
        var created: AXObserver?
        let error = AXObserverCreate(pid, callback, &created)
        guard error == .success, let observer = created else { return .failure(AXFailure(error)) }
        let app = appElement(pid)
        for name in Self.notifications {
            let result = AXObserverAddNotification(observer, app, name as CFString, refcon)
            if result == .success || result == .notificationAlreadyRegistered { continue }
            // Dropping the observer (never added to a run loop) discards the registrations made so far.
            if Self.essential.contains(name) { return .failure(AXFailure(result)) }
        }
        return .success(observer)
    }
}
