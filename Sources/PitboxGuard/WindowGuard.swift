import AppKit
import ApplicationServices
import PitboxKit

/// Keeps other apps' windows out of the reserved strips, the way tiling window managers do: through the
/// Accessibility API (macOS has no API for reserving screen space).
///
/// Windows that end up over a strip (maximize, zoom, drag, new windows, app launch, dialogs) are narrowed so they stop
/// at the strip's edge, or moved beside it when narrowing would not work; the height is never changed. Native
/// full-screen windows, minimized windows, windows on other Spaces, floating panels and exempt apps are left alone.
/// Drags are never fought: corrections wait for the mouse button to be released. An app that keeps putting a window
/// back is left alone for a while (see `GuardOptions.fightThreshold`). A Claude pop-out the block claims for
/// drag-to-park (`dropClaims`) is left alone until its claim ends, then corrected as after any drag.
///
/// Main thread only. All Accessibility work happens on a private thread. Needs the Accessibility permission:
/// `start()` waits for it (polling every 2 s) and starts by itself once it is granted.
@MainActor
public final class WindowGuard {
    /// System Settings, Privacy & Security, Accessibility (for onboarding UI).
    public static var accessibilitySettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
    }

    /// Current options. Changing them applies at once (for example toggling `dryRun`).
    public var options: GuardOptions {
        didSet {
            guard options != oldValue else { return }
            core?.update(options: options, apps: Self.runningApps(options: options))
            refreshStatus()
        }
    }

    /// The latest status; `onStatusChange` reports every change.
    public private(set) var status: GuardStatus
    /// Called on the main thread whenever `status` changes.
    public var onStatusChange: ((GuardStatus) -> Void)?

    /// Whether Pitbox holds the Accessibility permission right now.
    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Drag-to-park's claims: the one registry the block writes and the guard reads. A Claude pop-out claimed there by
    /// window number is left alone until the claim ends (at most 3 s after the release, 30 s at all), then looked at as
    /// caused by the user. Set by the composition root before `start()`; nil (the default) claims nothing and the guard
    /// behaves exactly as without drag-to-park. The guard's mouse-up monitors also report releases to it, so a release
    /// the block missed still ends a hold.
    public var dropClaims: WindowDropClaims? {
        didSet {
            guard dropClaims !== oldValue else { return }
            core?.setDropClaims(dropClaims)
        }
    }

    private let regionSource: ReservedRegionSource
    var core: GuardCore?
    private var wantsRunning = false
    /// The core was told to start (and not stopped since).
    private var coreStarted = false
    private var paused = false
    private var trusted: Bool
    private var guardError: String?
    private var coreStatus = CoreStatus()
    private var trustTimer: Timer?
    /// Strips last handed to the core, and a slow backstop check in case `onRegionsChanged` gets replaced.
    private var pushedRegions: [ReservedRegion] = []
    private var regionCheckTimer: Timer?
    private var warnedAboutRegionHook = false
    var systemTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    var mouseMonitors: [Any] = []

    /// Watches `regions` for changes (chaining any `onRegionsChanged` handler already installed, which is still
    /// called first). Does nothing else until `start()`.
    public init(regions: ReservedRegionSource, options: GuardOptions = .init()) {
        regionSource = regions
        self.options = options
        let trusted = AXIsProcessTrusted()
        self.trusted = trusted
        status = GuardStatus(trusted: trusted, dryRun: options.dryRun, regionCount: regions.regions.count)
        let previous = regions.onRegionsChanged
        regions.onRegionsChanged = { [weak self] in
            previous?()
            onMainThread { self?.regionsDidChange() }
        }
    }

    deinit {
        core?.shutdown()
        trustTimer?.invalidate()
        regionCheckTimer?.invalidate()
        for entry in systemTokens { entry.center.removeObserver(entry.token) }
        let monitors = mouseMonitors
        if !monitors.isEmpty { DispatchQueue.main.async { for monitor in monitors { NSEvent.removeMonitor(monitor) } } }
    }

    /// Starts guarding. Idempotent. Without the Accessibility permission it records that in `status`, checks again
    /// every 2 s and starts as soon as the permission is granted.
    public func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        if AXIsProcessTrusted() {
            trusted = true
            beginRunning()
        } else {
            trusted = false
            guardError = "Accessibility permission not granted; waiting for it"
            Log.info("window guard waiting for the Accessibility permission", "guard")
            startTrustPolling()
        }
        refreshStatus()
    }

    /// Stops guarding and releases every observer. `start()` resumes.
    public func stop() {
        guard wantsRunning else { return }
        wantsRunning = false
        coreStarted = false
        stopTrustPolling()
        stopRegionCheck()
        removeSystemObservers()
        core?.stop()
        refreshStatus()
    }

    /// Suspends corrections (observers stay registered, nothing is corrected) or resumes them with a full pass.
    public func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        core?.setPaused(paused)
        refreshStatus()
    }

    /// A drop claim ended without a park (`dropClaims.onReleasedUnparked`, hopped to the main thread): every window
    /// waiting on a claim is looked at at once, and a pass runs, so a pop-out the block could not park slides back now
    /// rather than at the claim's end. Main thread only; it only queues work on the guard thread. Harmless while the
    /// guard is stopped, paused or has no claims.
    public func lookAgain() {
        core?.lookAgain()
    }

    /// Shows the system prompt that sends the user to the Accessibility settings (only if not yet trusted).
    /// Returns whether the permission is granted now.
    @discardableResult
    public func requestAccessibilityPrompt() -> Bool {
        let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if granted { checkTrust() }
        return granted
    }

    // MARK: - Internals

    private func beginRunning() {
        guard wantsRunning, !coreStarted else { return }
        coreStarted = true
        stopTrustPolling()
        guardError = nil
        let core = self.core ?? makeCore()
        self.core = core
        core.setDropClaims(dropClaims)
        installSystemObservers()
        pushedRegions = regionSource.regions
        startRegionCheck()
        core.start(apps: Self.runningApps(options: options), regions: pushedRegions,
                   displays: Self.currentDisplays(), options: options, paused: paused)
    }

    private func makeCore() -> GuardCore {
        GuardCore(options: options, statusSink: { [weak self] status in
            onMainThread { self?.coreStatusChanged(status) }
        }, permissionLost: { [weak self] in
            onMainThread { self?.permissionLost() }
        })
    }

    private func coreStatusChanged(_ status: CoreStatus) {
        coreStatus = status
        refreshStatus()
    }

    private func permissionLost() {
        trusted = false
        coreStarted = false
        guardError = "Accessibility permission was turned off; waiting for it"
        stopRegionCheck()
        removeSystemObservers()
        if wantsRunning { startTrustPolling() }
        refreshStatus()
    }

    private func regionsDidChange() {
        pushedRegions = regionSource.regions
        // Shell moves the strip when the displays change, sometimes before any notification reaches the guard (its
        // watchdog polls): hand over the displays first, so the core always sees the change and holds.
        core?.update(displays: Self.currentDisplays())
        core?.update(regions: pushedRegions)
        refreshStatus()
    }

    /// Backstop for a replaced `onRegionsChanged` (`ReservedRegionSource` allows one handler): compares the strips
    /// every 2 s while running. Costs a few microseconds per check.
    private func startRegionCheck() {
        guard regionCheckTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkRegions() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        regionCheckTimer = timer
    }

    private func stopRegionCheck() {
        regionCheckTimer?.invalidate()
        regionCheckTimer = nil
    }

    private func checkRegions() {
        guard regionSource.regions != pushedRegions else { return }
        if !warnedAboutRegionHook {
            warnedAboutRegionHook = true
            Log.warn("reserved strips changed without onRegionsChanged reaching the guard; was the handler replaced? "
                     + "(the guard catches up every 2 s)", "guard")
        }
        regionsDidChange()
    }

    private func startTrustPolling() {
        guard trustTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    private func stopTrustPolling() {
        trustTimer?.invalidate()
        trustTimer = nil
    }

    private func checkTrust() {
        guard wantsRunning, !coreStarted, AXIsProcessTrusted() else { return }
        trusted = true
        Log.info("Accessibility permission granted", "guard")
        beginRunning()
        refreshStatus()
    }

    func refreshStatus() {
        let next = GuardStatus(trusted: trusted, running: wantsRunning && trusted && coreStatus.running,
                               paused: paused, dryRun: options.dryRun, regionCount: regionSource.regions.count,
                               correctedCount: coreStatus.corrected, fightingWindows: coreStatus.fighting,
                               cannotFitWindows: coreStatus.cannotFit, observedApps: coreStatus.observedApps,
                               lastError: guardError ?? coreStatus.lastError)
        guard next != status else { return }
        status = next
        onStatusChange?(next)
    }
}

/// Runs `body` on the main thread: inline when already there, otherwise queued (in order).
func onMainThread(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}
