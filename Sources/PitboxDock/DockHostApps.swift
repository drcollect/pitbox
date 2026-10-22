import AppKit
import Foundation

/// Which apps run, by bundle id, and a call when that changes: the guest uses it only to decide how long to wait for a
/// host before showing, and to notice a listed host app that runs without speaking the protocol (docs/DOCK_PROTOCOL.md
/// "Start order"). Injectable for tests.
@MainActor
protocol DockHostApps: AnyObject {
    /// The bundle ids of the running apps.
    func runningBundleIDs() -> Set<String>
    /// Called on the main actor after an app launched or quit.
    var onChange: (@MainActor () -> Void)? { get set }
}

/// `NSWorkspace`'s running applications and its launch and quit notifications. It reads bundle ids only.
@MainActor
final class WorkspaceHostApps: DockHostApps {
    var onChange: (@MainActor () -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
    }

    isolated deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}
