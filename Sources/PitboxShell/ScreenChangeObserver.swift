import AppKit

/// Coalesced "the display geometry may have changed" signal: display reconfiguration, Dock or menu bar changes,
/// Space switches, wake. A slow watchdog (every few seconds, only while started) catches changes that post no
/// notification; the owner compares frames, so a tick with no change costs one `NSScreen` read.
@MainActor
final class ScreenChangeObserver {
    private let onChange: () -> Void
    private var center: [NSObjectProtocol] = []
    private var workspace: [NSObjectProtocol] = []
    private var distributed: [NSObjectProtocol] = []
    /// The repeating watchdog while started (the main run loop holds it until `stop()` invalidates it).
    private(set) var watchdog: Timer?
    private var pending = false
    private let watchdogInterval: TimeInterval

    init(watchdogInterval: TimeInterval = 4, onChange: @escaping () -> Void) {
        self.watchdogInterval = watchdogInterval
        self.onChange = onChange
    }

    var isRunning: Bool { watchdog != nil }

    /// The run loop keeps a valid timer and the notification centres keep their tokens: release them with the observer.
    isolated deinit {
        stop()
    }

    func start() {
        guard !isRunning else { return }
        let nc = NotificationCenter.default
        center.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            workspace.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        // Posted when Dock preferences change (size, position, auto-hide).
        let dnc = DistributedNotificationCenter.default()
        distributed.append(dnc.addObserver(forName: Notification.Name("com.apple.dock.prefchanged"), object: nil,
                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 0.5) }
        })
        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange() }
        }
        timer.tolerance = watchdogInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func stop() {
        center.forEach { NotificationCenter.default.removeObserver($0) }
        workspace.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributed.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        center = []
        workspace = []
        distributed = []
        watchdog?.invalidate()
        watchdog = nil
        pending = false
    }

    /// Several notifications usually arrive together; run `onChange` once shortly after the burst.
    private func schedule(after delay: TimeInterval = 0.12) {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending else { return }
                self.pending = false
                self.onChange()
            }
        }
    }
}
