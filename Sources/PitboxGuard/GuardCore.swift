import ApplicationServices
import CoreGraphics
import Foundation
import PitboxKit

/// A running app as seen on the main thread (NSWorkspace), handed to the guard thread.
struct AppSnapshot: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String?
    var name: String
    var isRegular: Bool
    /// Bundles Electron or Chromium (only computed for `ManualAccessibilityPolicy.electronAndChromium`).
    var isChromium: Bool
}

/// The engine's side of `GuardStatus`, produced on the guard thread.
struct CoreStatus: Equatable, Sendable {
    var running = false
    var corrected = 0
    var fighting = 0
    var cannotFit = 0
    var observedApps = 0
    var lastError: String?
}

/// Everything that runs on the guard thread: the engine with the real Accessibility provider, one AXObserver per
/// app, and a single wake timer. Methods are called from the main thread and hop to the guard thread.
/// The core keeps itself alive (observer callbacks point at it) until `shutdown()`.
final class GuardCore {
    private let thread: GuardThread
    private let runLoop: CFRunLoop
    private let statusSink: @Sendable (CoreStatus) -> Void
    private let permissionLostSink: @Sendable () -> Void
    private let ownPID = getpid()
    private var retainedSelf: Unmanaged<GuardCore>?

    // Guard-thread state.
    private var options: GuardOptions
    private var provider: AXWindowProvider?
    private var engine: GuardEngine<AXWindowProvider>?
    private var observers: AXObserverSet?
    private var wakeTimer: GuardTimer?
    private var apps: [pid_t: AppSnapshot] = [:]
    private var running = false
    private var published: CoreStatus?
    /// Drag-to-park's registry (thread-safe itself; the reference is guard-thread state like the rest).
    private var dropClaims: WindowDropClaims?

    init(options: GuardOptions, statusSink: @escaping @Sendable (CoreStatus) -> Void,
         permissionLost: @escaping @Sendable () -> Void) {
        self.options = options
        self.statusSink = statusSink
        permissionLostSink = permissionLost
        thread = GuardThread(name: "pitbox.guard")
        runLoop = thread.startAndWait()
        retainedSelf = Unmanaged.passRetained(self)
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Called from the main thread

    func start(apps list: [AppSnapshot], regions: [ReservedRegion], displays: [GuardDisplay], options: GuardOptions,
               paused: Bool) {
        thread.perform { [self] in
            let engine = setUpIfNeeded()
            let now = Self.now()
            self.options = options
            provider?.setMessagingTimeout(options.messagingTimeout)
            engine.reset()
            engine.update(options: options, now: now)
            engine.setDisplays(displays, now: now)
            engine.setRegions(regions, now: now)
            engine.setPaused(paused, now: now)
            engine.setSuspended(false, now: now)
            running = true
            apps.removeAll()
            for app in list { track(app, now: now) }
            engine.requestReconcile(at: now)
            Log.info("window guard started: \(observers?.observingCount ?? 0) apps observed, "
                     + "\(regions.count) strip(s)\(options.dryRun ? ", dry run" : "")", "guard")
            pump()
        }
    }

    func stop() {
        thread.perform { [self] in
            guard running else { return }
            stopOnThread()
            Log.info("window guard stopped", "guard")
            publish()
        }
    }

    /// Stops everything and ends the guard thread. The core cannot be used afterwards.
    func shutdown() {
        thread.perform { [self] in
            stopOnThread()
            wakeTimer?.invalidate()
            wakeTimer = nil
            retainedSelf?.release()
            retainedSelf = nil
            thread.finish()
        }
    }

    func update(regions: [ReservedRegion]) { withEngine { $0.setRegions(regions, now: $1) } }
    func update(displays: [GuardDisplay]) { withEngine { $0.setDisplays(displays, now: $1) } }
    func setPaused(_ paused: Bool) { withEngine { $0.setPaused(paused, now: $1) } }
    func setSuspended(_ suspended: Bool) { withEngine { $0.setSuspended(suspended, now: $1) } }
    func mouseUp() { withEngine { $0.mouseReleased(now: $1) } }
    // `options` is guard-thread state: these closures read it when they run there.
    func spaceChanged() { withEngine { [self] in $0.requestReconcile(at: $1 + options.spaceChangeDelay) } }
    /// Displays can report a temporary mode for a second or two after waking: correct nothing until it has settled.
    func wake() { withEngine { $0.holdCorrections(now: $1) } }
    func appShown() { withEngine { [self] in $0.requestReconcile(at: $1 + options.settleDelay) } }

    /// Hands drag-to-park's claims to the engine, now or when it is created.
    func setDropClaims(_ claims: WindowDropClaims?) {
        thread.perform { [self] in
            dropClaims = claims
            engine?.dropClaims = claims
        }
    }

    /// A claim ended without a park: windows waiting on a claim are looked at now, and a pass runs. Never waits: the
    /// work is queued on the guard thread like every other call here.
    func lookAgain() { withEngine { $0.lookAgain(now: $1) } }

    func update(options new: GuardOptions, apps list: [AppSnapshot]) {
        thread.perform { [self] in
            options = new
            guard running, let engine else { return }
            let now = Self.now()
            provider?.setMessagingTimeout(new.messagingTimeout)
            engine.update(options: new, now: now)
            for app in list { track(app, now: now) }
            pump()
        }
    }

    func appLaunched(_ app: AppSnapshot) {
        withEngine { [self] engine, now in
            track(app, now: now)
            if engine.isManaged(pid: app.pid) { engine.requestReconcile(at: now + 0.5) }
        }
    }

    func appTerminated(_ pid: pid_t) {
        withEngine { [self] engine, _ in
            apps[pid] = nil
            observers?.unobserve(pid)
            engine.removeApp(pid: pid)
            provider?.forgetApp(pid)
        }
    }

    /// An app came to the front: its activation policy may have changed, or an earlier registration gave up.
    func appActivated(_ app: AppSnapshot) {
        withEngine { [self] engine, now in
            if apps[app.pid] != app { track(app, now: now) }
            if engine.isManaged(pid: app.pid), observers?.isObserving(app.pid) == false,
               observers?.observe(app.pid, now: now, fresh: true) == .apiDisabled {
                engine.apiDisabled = true
            }
        }
    }

    // MARK: - Guard thread

    private func withEngine(_ body: @escaping (GuardEngine<AXWindowProvider>, TimeInterval) -> Void) {
        thread.perform { [self] in
            guard running, let engine else { return }
            body(engine, Self.now())
            pump()
        }
    }

    private func setUpIfNeeded() -> GuardEngine<AXWindowProvider> {
        if let engine { return engine }
        let provider = AXWindowProvider(messagingTimeout: options.messagingTimeout)
        let engine = GuardEngine(provider: provider, options: options, ownPID: ownPID,
                                 isMouseDown: { CGEventSource.buttonState(.combinedSessionState, button: .left) },
                                 log: GuardLog.write)
        engine.dropClaims = dropClaims
        observers = AXObserverSet(runLoop: runLoop, refcon: Unmanaged.passUnretained(self).toOpaque(),
                                  callback: guardObserverCallback, appElement: { provider.appElement($0) })
        wakeTimer = GuardTimer(runLoop: runLoop) { [weak self] in self?.pump() }
        self.provider = provider
        self.engine = engine
        return engine
    }

    /// Adds, updates or drops an app according to policy, and observes it if it is managed.
    private func track(_ app: AppSnapshot, now: TimeInterval) {
        apps[app.pid] = app
        guard let engine, let observers else { return }
        guard WindowPolicy.manages(app, ownPID: ownPID, options: options) else {
            observers.unobserve(app.pid)
            engine.removeApp(pid: app.pid)
            return
        }
        let isNew = !engine.isManaged(pid: app.pid)
        engine.addApp(pid: app.pid, name: app.name)
        if isNew, options.manualAccessibility == .electronAndChromium, app.isChromium {
            if options.dryRun {
                Log.info("dry run: would set AXManualAccessibility on \(app.name)", "guard")
            } else {
                _ = provider?.enableManualAccessibility(pid: app.pid)
            }
        }
        if observers.observe(app.pid, now: now) == .apiDisabled { engine.apiDisabled = true }
    }

    fileprivate func handleNotification(_ name: String, element: AXUIElement) {
        guard running, let engine else { return }
        let now = Self.now()
        switch name {
        case kAXWindowMiniaturizedNotification: engine.windowMinimized(element)
        case kAXApplicationShownNotification: engine.requestReconcile(at: now + options.settleDelay)
        default: engine.windowChanged(element, now: now)
        }
        pump()
    }

    /// Runs whatever is due, re-arms the single wake timer and publishes status changes.
    private func pump() {
        guard running, let engine else { return }
        let now = Self.now()
        engine.tick(now: now)
        if observers?.retryDue(now: now) == .apiDisabled { engine.apiDisabled = true }
        if engine.apiDisabled {
            Log.warn("Accessibility permission is off; window guard waits until it is granted again", "guard")
            stopOnThread()
            publish()
            permissionLostSink()
            return
        }
        var wake = engine.nextWake(now: now)
        if let retry = observers?.nextRetry, retry < (wake?.at ?? .infinity) { wake = (retry, 0.1) }
        if let wake { wakeTimer?.arm(after: wake.at - now, leeway: wake.leeway) } else { wakeTimer?.disarm() }
        publish()
    }

    private func stopOnThread() {
        running = false
        observers?.removeAll()
        engine?.reset()
        wakeTimer?.disarm()
    }

    private func publish() {
        let now = Self.now()
        let status = CoreStatus(running: running, corrected: engine?.correctedCount ?? 0,
                                fighting: engine?.fightingCount(now: now) ?? 0,
                                cannotFit: engine?.cannotFitCount ?? 0,
                                observedApps: running ? observers?.observingCount ?? 0 : 0,
                                lastError: engine?.lastError)
        guard status != published else { return }
        published = status
        statusSink(status)
    }
}

/// AXObserver callback (C convention). `refcon` is the `GuardCore`, kept alive until `shutdown()`.
private func guardObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                   _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<GuardCore>.fromOpaque(refcon).takeUnretainedValue().handleNotification(notification as String,
                                                                                    element: element)
}

/// Engine log lines go to the shared log, category "guard".
enum GuardLog {
    static func write(_ level: GuardLogLevel, _ message: String) {
        switch level {
        case .info: Log.info(message, "guard")
        case .warn: Log.warn(message, "guard")
        case .error: Log.error(message, "guard")
        }
    }
}
