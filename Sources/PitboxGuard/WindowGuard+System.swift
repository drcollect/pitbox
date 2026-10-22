import AppKit
import PitboxKit

/// System events that feed the guard (all delivered on the main thread, forwarded to the guard thread).
///
/// Mouse: NSEvent global and local monitors for left-mouse-up, which need no permission for mouse events (unlike a
/// CGEventTap, which needs Input Monitoring or Accessibility, runs a callback for every event and is disabled by the
/// system when it is slow). The button state itself is read with `CGEventSource.buttonState`, also permission-free,
/// right before each correction and every 100 ms while a correction waits for a release, so a missed mouse-up
/// cannot block the guard. Each mouse-up also goes to `dropClaims` (drag-to-park), which watches the button itself too.
extension WindowGuard {
    func installSystemObservers() {
        guard systemTokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { owner, note in
            if let app = Self.snapshot(note, options: owner.options) { owner.core?.appLaunched(app) }
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { owner, note in
            if let app = Self.snapshot(note, options: owner.options) { owner.core?.appTerminated(app.pid) }
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { owner, note in
            if let app = Self.snapshot(note, options: owner.options) { owner.core?.appActivated(app) }
        }
        observe(workspace, NSWorkspace.didUnhideApplicationNotification) { owner, _ in owner.core?.appShown() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { owner, _ in owner.core?.spaceChanged() }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(workspace, name) { owner, _ in
                owner.core?.update(displays: Self.currentDisplays())
                owner.core?.wake()
            }
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { owner, _ in
            owner.core?.setSuspended(false)
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { owner, _ in
            owner.core?.setSuspended(true)
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { owner, _ in
            owner.core?.update(displays: Self.currentDisplays())
            owner.refreshStatus()
        }
        let core = self.core
        // A release reaches the drop claims first, on the main thread at the event itself (the engine's own report goes
        // through the guard thread's queue), so a claim's 3 s hold counts from the real release.
        let released: () -> Void = { [weak self] in
            onMainThread { self?.dropClaims?.noteMouseUp() }
            core?.mouseUp()
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { _ in released() }) {
            mouseMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { event in
            released()
            return event
        }) {
            mouseMonitors.append(monitor)
        }
    }

    func removeSystemObservers() {
        for entry in systemTokens { entry.center.removeObserver(entry.token) }
        systemTokens.removeAll()
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (WindowGuard, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, note)
            }
        }
        systemTokens.append((center, token))
    }

    // MARK: - Snapshots (main thread)

    /// Displays in Quartz coordinates.
    static func currentDisplays() -> [GuardDisplay] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let height = primary.frame.height
        return screens.map { screen in
            GuardDisplay(id: ScreenSpace.displayID(of: screen),
                         frame: ScreenSpace.quartz(fromAppKit: screen.frame, primaryHeight: height),
                         visibleFrame: ScreenSpace.quartz(fromAppKit: screen.visibleFrame, primaryHeight: height))
        }
    }

    static func runningApps(options: GuardOptions) -> [AppSnapshot] {
        NSWorkspace.shared.runningApplications.compactMap { snapshot($0, options: options) }
    }

    private static func snapshot(_ note: Notification, options: GuardOptions) -> AppSnapshot? {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return nil }
        return snapshot(app, options: options)
    }

    static func snapshot(_ app: NSRunningApplication, options: GuardOptions) -> AppSnapshot? {
        let pid = app.processIdentifier
        guard pid > 0 else { return nil }
        let chromium = options.manualAccessibility == .electronAndChromium
            && ChromiumDetector.isChromium(bundleID: app.bundleIdentifier, bundleURL: app.bundleURL)
        return AppSnapshot(pid: pid, bundleID: app.bundleIdentifier,
                           name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
                           activationPolicy: app.activationPolicy, isChromium: chromium)
    }
}

extension AppSnapshot {
    /// A snapshot whose `isRegular` comes from the app's activation policy: only `.regular` counts. `.accessory`
    /// (`LSUIElement`: Pitbox, a dock host's strip) and `.prohibited` apps are never managed (`WindowPolicy.manages`).
    init(pid: pid_t, bundleID: String?, name: String, activationPolicy: NSApplication.ActivationPolicy,
         isChromium: Bool) {
        self.init(pid: pid, bundleID: bundleID, name: name, isRegular: activationPolicy == .regular,
                  isChromium: isChromium)
    }
}

/// Recognizes apps built on Chromium or Electron (only used by `ManualAccessibilityPolicy.electronAndChromium`).
enum ChromiumDetector {
    static let frameworks = ["Electron Framework.framework", "Chromium Embedded Framework.framework"]
    static let bundlePrefixes = [
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func isChromium(bundleID: String?, bundleURL: URL?) -> Bool {
        if let id = bundleID, bundlePrefixes.contains(where: { id.hasPrefix($0) }) { return true }
        guard let url = bundleURL else { return false }
        let folder = url.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        return frameworks.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}
