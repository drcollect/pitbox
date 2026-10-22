import Foundation
import ServiceManagement
import PitboxKit

/// "Launch at Login" through `SMAppService.mainApp` (macOS 13+). Only works from the app bundle
/// (the built `Pitbox.app`); from a bare executable (tests, `swift run`) every call reports `.unavailable` and changes
/// nothing. Signing matters: an ad-hoc signed app may need re-approval after rebuilds (see scripts/make-dev-cert.sh).
public enum LoginItem {
    /// Login item state.
    public enum Status: Equatable, Sendable {
        /// Pitbox starts at login.
        case enabled
        /// Not registered.
        case disabled
        /// Registered, but the user must allow it in System Settings > General > Login Items.
        case requiresApproval
        /// Cannot be used from here (not an app bundle, or the service is unknown to the system).
        case unavailable(String)
    }

    /// Current state as the system sees it.
    public static var status: Status {
        guard isAppBundle else { return .unavailable("not running from an app bundle") }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable("the system does not know this app")
        @unknown default: return .unavailable("unknown status")
        }
    }

    /// Shorthand for `status == .enabled`.
    public static var isEnabled: Bool { status == .enabled }

    /// Registers or unregisters the app as a login item. Returns the resulting status.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Result<Status, Error> {
        guard isAppBundle else { return .success(status) }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            Log.info("login item \(enabled ? "registered" : "unregistered"): \(status)", "shell")
            return .success(status)
        } catch {
            Log.warn("login item change failed: \(error.localizedDescription)", "shell")
            return .failure(error)
        }
    }

    /// Makes the system match `wanted` (normally the Launch at Login setting) at startup. Leaves a pending
    /// approval alone. Logs what it found and what it did while a login item is wanted (labels only). Returns the
    /// resulting status.
    @discardableResult
    public static func reconcile(wanted: Bool) -> Status {
        guard isAppBundle else { return status }
        let before = SMAppService.mainApp.status
        if change(wanted: wanted, system: before) != .none { _ = setEnabled(wanted) }
        let after = status
        if wanted { Log.info("login item at start: was \(label(before)), now \(after)", "shell") }
        return after
    }

    /// What `reconcile` does for the system's own status.
    enum Change: Equatable { case register, unregister, none }

    /// `.notFound` counts as not registered: it is what macOS reports for an app that never registered (measured: an
    /// app never reached Login Items although launch at login was on, because the old rule only registered from
    /// `.notRegistered`). Registering is what makes the app known. A pending approval stays.
    static func change(wanted: Bool, system: SMAppService.Status) -> Change {
        switch (wanted, system) {
        case (true, .notRegistered), (true, .notFound): return .register
        case (false, .enabled), (false, .requiresApproval): return .unregister
        default: return .none
        }
    }

    /// A fixed label for the log.
    static func label(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// Opens System Settings > General > Login Items.
    public static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    private static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}
