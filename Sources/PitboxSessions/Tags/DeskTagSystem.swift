import AppKit
import CoreGraphics
import Foundation

// The seams between desk tags and the system. Production implementations are
// in DeskTagSystemLive.swift; tests replace every one with a fake, so no test reads a real window, registers an
// Accessibility observer or orders a panel in front.

/// One window of the window server's list (`CGWindowListCopyWindowInfo`, no permission; names are never read).
struct DeskTagServerWindow: Equatable, Sendable {
    var number: CGWindowID
    var pid: pid_t
    /// Quartz global coordinates (origin at the primary display's top-left, y down).
    var bounds: CGRect
    /// 0 is the normal window level.
    var layer: Int
    /// On screen in the current Space (false: minimized, another Space, the app hidden).
    var isOnScreen: Bool
    var alpha: Double

    /// A window-server entry.
    init(number: CGWindowID, pid: pid_t, bounds: CGRect, layer: Int = 0, isOnScreen: Bool = true, alpha: Double = 1) {
        self.number = number; self.pid = pid; self.bounds = bounds; self.layer = layer
        self.isOnScreen = isOnScreen; self.alpha = alpha
    }
}

/// The window server, read-only. Any thread.
protocol DeskTagWindowServer: AnyObject, Sendable {
    /// One window by number (`CGWindowListCopyWindowInfo([.optionIncludingWindow], number)`); nil once it is gone.
    func window(number: CGWindowID) -> DeskTagServerWindow?
    /// Every on-screen window, front to back (`.optionOnScreenOnly`): the fallback's covered check.
    func onScreenFrontToBack() -> [DeskTagServerWindow]
}

/// The Accessibility notifications the observer listens to, registered on each Claude copy's application element
/// (which delivers them for every window of the app), except `destroyed`, which is registered on each watched window.
enum CodeWindowNotification: String, Sendable, CaseIterable {
    case moved, resized, miniaturized, deminiaturized, destroyed
    case focusedWindowChanged = "focused", mainWindowChanged = "main"
    case appActivated = "activated", appDeactivated = "deactivated", appHidden = "hidden", appShown = "shown"
}

/// Why an observer registration failed.
enum DeskTagAXFailure: Error, Equatable, Sendable {
    /// The app has no Accessibility permission.
    case apiDisabled
    /// The app is not ready yet, or did not answer in time: retried with backoff.
    case notReady
    /// The app does not support observers.
    case unsupported
}

/// The observer's Accessibility calls. Observer thread only; every call that talks to Claude is bounded by a per-element
/// messaging timeout (never the system-wide one, which the window guard owns). Reads only: it registers observers and
/// reads `AXFullScreen` and the focused window, and never sets an attribute or performs an action on any window.
protocol DeskTagAXObserving: AnyObject {
    /// Where notifications go, on the observer thread: the pid, the window number when the registration was a window's
    /// own (`destroyed`), and the notification.
    var sink: ((pid_t, CGWindowID?, CodeWindowNotification) -> Void)? { get set }
    func isTrusted() -> Bool
    /// One observer for the app of `pid`, on the observer thread's run loop. Nil on success.
    func observe(pid: pid_t) -> DeskTagAXFailure?
    /// Stops delivery for `pid` at once (the run-loop source goes; no round trip to the app).
    func unobserve(pid: pid_t)
    /// Registers `destroyed` on the window's own element (found by window number). False when it is not found.
    func watch(pid: pid_t, number: CGWindowID) -> Bool
    /// Forgets the window; a late callback for it is ignored.
    func unwatch(pid: pid_t, number: CGWindowID)
    /// `AXFullScreen` of a watched window; nil when unknown.
    func isFullScreen(pid: pid_t, number: CGWindowID) -> Bool?
    /// The app's focused window's number (lab mode only); nil when unknown.
    func focusedWindowNumber(pid: pid_t) -> CGWindowID?
}

/// The left mouse button (`CGEventSource.buttonState`, permission-free). Any thread.
protocol DeskTagButton: AnyObject, Sendable {
    func isLeftButtonDown() -> Bool
}

/// The observer's one serial queue: a dedicated thread with its own run loop in production (`DeskTagObserverThread`), a
/// manual queue with virtual time in tests. Never the main thread, never the guard's or the parker's thread.
protocol DeskTagQueue: AnyObject, Sendable {
    func async(_ work: @escaping () -> Void)
    /// Runs `work` after `seconds` without blocking the queue in between.
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void)
    /// The run loop that observer sources join (nil for a manual queue).
    var runLoop: CFRunLoop? { get }
}

/// System events the controller follows on the main thread.
enum DeskTagSystemEvent: Equatable, Sendable {
    /// `NSWorkspace.activeSpaceDidChangeNotification`: every tag is checked again at once.
    case spaceChanged
    /// Displays were added, removed or rearranged.
    case screensChanged
    /// Any app became active (the fallback's covered check looks again).
    case appActivated(pid_t)
}

/// Main-thread facts and events from the system.
@MainActor
protocol DeskTagSystem: AnyObject {
    /// The displays in Quartz coordinates and the primary display's height (for converting to AppKit's).
    func displays() -> [DeskTagDisplay]
    var primaryHeight: CGFloat { get }
    /// The pointer, AppKit screen coordinates.
    func pointerLocation() -> CGPoint
    /// Whether the app is the active app.
    func isOwnAppActive() -> Bool
    func frontmostPID() -> pid_t?
    /// Starts delivering events; `stop` ends it.
    func start(_ handler: @escaping @MainActor (DeskTagSystemEvent) -> Void)
    func stop()
    /// A local key monitor for Escape (it only ever sees keys while the app is the active app). The handler returns
    /// whether it used the key (then the key goes no further). Returns a token for `removeEscapeMonitor`.
    func addEscapeMonitor(_ handler: @escaping @MainActor () -> Bool) -> AnyObject?
    func removeEscapeMonitor(_ token: AnyObject)
}

/// Panel ordering (main thread). The live one orders real panels; tests record the calls and never order a panel in.
@MainActor
protocol DeskTagWindowing: AnyObject {
    /// Shows `panel` at `frame` (AppKit screen coordinates) at `level`, directly above window `number` when given (the
    /// first cover mode), else in front of its level. `reorder` false only moves a panel already shown.
    func show(_ panel: NSPanel, frame: CGRect, level: NSWindow.Level, above number: CGWindowID?, reorder: Bool)
    func hide(_ panel: NSPanel)
}

/// A cancellable one-shot timer of `DeskTagScheduler`.
@MainActor
protocol DeskTagTimer: AnyObject {
    func cancel()
}

/// Main-thread timers and the monotonic clock (`ProcessInfo.systemUptime`, the observer's clock too). Tests use virtual
/// time.
@MainActor
protocol DeskTagScheduler: AnyObject {
    var now: TimeInterval { get }
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> DeskTagTimer
}
