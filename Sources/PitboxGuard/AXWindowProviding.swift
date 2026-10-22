import CoreGraphics
import Darwin

/// One window from the window server's on-screen list (`CGWindowListCopyWindowInfo`): the active Space only, cheap,
/// and needs no permission.
struct OnScreenWindow: Equatable, Sendable {
    var windowID: CGWindowID
    var pid: pid_t
    /// Quartz global coordinates.
    var bounds: CGRect
    /// 0 is the normal window level; menus, panels, overlays and the desktop use other levels.
    var layer: Int
    var alpha: Double
}

/// What the guard reads from one Accessibility window in a single round trip.
struct WindowInfo: Equatable, Sendable {
    var pid: pid_t
    /// Quartz global coordinates.
    var frame: CGRect
    var role: String?
    var subrole: String?
    var minimized: Bool
    /// Native full screen (`AXFullScreen`).
    var fullScreen: Bool
}

/// What the window server says about one window.
struct ServerWindowState: Equatable, Sendable {
    /// 0 is the normal window level.
    var layer: Int
    /// On screen in the active Space (false for other Spaces, hidden apps and minimized windows).
    var onScreen: Bool
}

/// Whether Accessibility lets the guard change a window's size and position.
struct WindowCapabilities: Equatable, Sendable {
    var resizable: Bool
    var movable: Bool
}

/// Accessibility failures, reduced to what the guard reacts to.
enum AXFailure: Error, Equatable, Sendable {
    /// The window (or app) is gone.
    case invalidElement
    /// The app did not answer in time, or is not ready yet.
    case cannotComplete
    /// The Accessibility permission is off.
    case apiDisabled
    /// The app does not support what was asked.
    case unsupported
    case other(Int32)
}

/// The seam between the decision loop (`GuardEngine`) and the system. `AXWindowProvider` implements it with
/// Accessibility and the window server; tests implement it with fake windows, so the whole loop runs without any
/// permission. All methods are called on one thread.
protocol AXWindowProviding: AnyObject {
    /// A handle to one window. `AXUIElement` (compared with `CFEqual`) in production.
    associatedtype Window: Hashable

    /// On-screen windows of the active Space, front to back.
    func onScreenWindows() -> [OnScreenWindow]
    /// The app's Accessibility windows (one round trip).
    func windows(ofPID pid: pid_t) -> Result<[Window], AXFailure>
    /// The owning process, without a round trip.
    func pid(of window: Window) -> pid_t?
    /// The window-server number of the window, if it can be found out.
    func windowID(of window: Window) -> CGWindowID?
    /// Role, subrole, frame and state in one round trip.
    func info(of window: Window) -> Result<WindowInfo, AXFailure>
    /// Whether size and position can be set. A failure means the app did not answer (or the window is gone), not "no".
    func capabilities(of window: Window) -> Result<WindowCapabilities, AXFailure>
    /// Level and visibility of a window-server window, if known.
    func serverState(ofWindowID id: CGWindowID) -> ServerWindowState?
    /// Applies `target` (size first, then position) and returns the frame the window actually ended up with.
    func setFrame(_ target: CGRect, of window: Window, from current: CGRect) -> Result<CGRect, AXFailure>
    /// Sets `AXManualAccessibility` on the app. Returns true if the app accepted it.
    func enableManualAccessibility(pid: pid_t) -> Bool
}
