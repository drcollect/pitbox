import CoreFoundation
import CoreGraphics
import Foundation
import PitboxKit

// The seams between the window join / parker and the system. Production
// implementations are in CodeWindowSystemLive.swift; tests replace every one of them with fakes, so no test ever
// touches a real window or Accessibility.

/// One window of the window-server list (`CGWindowListCopyWindowInfo`, no permission needed).
struct CodeServerWindow: Equatable, Sendable {
    var number: CGWindowID
    var pid: pid_t
    /// Quartz global coordinates (top-left origin, y down), like AX positions and `session-popouts.json`.
    var bounds: CGRect
    /// 0 is the normal window level.
    var layer: Int
    /// On screen in the current Space (false: minimized, another Space, hidden app).
    var isOnScreen: Bool
}

/// The window server, read-only.
protocol CodeWindowServer: AnyObject {
    /// Every window of `pids` the window server knows, minimized and other-Space windows included (`.optionAll`).
    func windows(ofPIDs pids: Set<pid_t>) -> [CodeServerWindow]
    /// One window by number; nil once it is gone.
    func window(number: CGWindowID) -> CodeServerWindow?
}

/// One Accessibility window as the parker holds it: an `AXUIElement` in production, any CF-comparable object (an
/// `NSNumber`) in tests. Equality is `CFEqual`, so two handles of one window compare equal.
struct CodeAXElement: Hashable, @unchecked Sendable {
    let raw: AnyObject

    static func == (lhs: CodeAXElement, rhs: CodeAXElement) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }
}

/// What one Accessibility window says in one round trip.
struct CodeAXWindowInfo: Equatable, Sendable {
    /// `AXTitle`: for a pop-out, the session title exactly. Session text: never logged.
    var title: String?
    /// `AXPosition` + `AXSize`, Quartz global coordinates; nil when unreadable.
    var frame: CGRect?
    var minimized: Bool
    var role: String?
    var subrole: String?

    init(title: String?, frame: CGRect?, minimized: Bool, role: String? = "AXWindow", subrole: String? = "AXStandardWindow") {
        self.title = title; self.frame = frame; self.minimized = minimized; self.role = role; self.subrole = subrole
    }
}

/// Accessibility failures, reduced to what the parker reacts to.
enum CodeAXFailure: Error, Equatable, Sendable {
    /// The window (or the app) is gone.
    case invalidElement
    /// The app did not answer within the messaging timeout, or is not ready.
    case cannotComplete
    /// The app has no Accessibility permission.
    case apiDisabled
    /// The app does not support what was asked.
    case unsupported
    case other(Int32)
}

/// The Accessibility calls the join and the parker make. Called only on the parker's thread; every call that talks to
/// Claude is bounded by the 2 s messaging timeout, set per element, never process-wide (the window guard owns
/// the process-wide value).
protocol CodeAccessibility: AnyObject {
    func isTrusted() -> Bool
    /// The app's Accessibility windows (the current Space and minimized windows; other Spaces are invisible).
    func windows(ofPID pid: pid_t) -> Result<[CodeAXElement], CodeAXFailure>
    /// Title, frame, minimized, role and subrole in one round trip.
    func info(of window: CodeAXElement) -> Result<CodeAXWindowInfo, CodeAXFailure>
    /// `AXMinimized` alone.
    func isMinimized(_ window: CodeAXElement) -> Result<Bool, CodeAXFailure>
    /// The window-server number through `_AXUIElementGetWindow`, nil when the function is missing or fails.
    func windowNumber(of window: CodeAXElement) -> CGWindowID?
    func setMinimized(_ minimized: Bool, of window: CodeAXElement) -> CodeAXFailure?
    /// Size, then position (Quartz global coordinates).
    func setFrame(_ frame: CGRect, of window: CodeAXElement) -> CodeAXFailure?
    /// `AXRaise`.
    func raise(_ window: CodeAXElement) -> CodeAXFailure?
    /// `AXMain = true`.
    func setMain(_ window: CodeAXElement) -> CodeAXFailure?
    /// The app's `AXFocusedWindow`, nil when it has none.
    func focusedWindow(ofPID pid: pid_t) -> Result<CodeAXElement?, CodeAXFailure>
    /// `AXFrontmost = true` on the app element: activates an app from a background (accessory) app like this one,
    /// where `NSRunningApplication`'s cooperative activation may be ignored. False when it did not take.
    func setFrontmost(pid: pid_t) -> Bool
    /// Drops cached app elements of a process that ended.
    func forget(pid: pid_t)
}

/// One running Claude desktop copy, as the parker's thread sees it: the data side's `ClaudeProcessInfo` plus
/// whether the app is hidden.
struct CodeClaudeProcess: Equatable, Sendable {
    var pid: pid_t
    var profile: CodeProfile
    /// That copy's `Claude.app`, from the running process: a copy may run from its own folder (a launcher's app copy),
    /// so never a fixed `/Applications/Claude.app`. Used to open a deep link in this copy.
    var appURL: URL?
    /// The app is hidden (⌘H): all its windows are off screen.
    var isHidden: Bool = false

    init(pid: pid_t, profile: CodeProfile, appURL: URL?, isHidden: Bool = false) {
        self.pid = pid; self.profile = profile; self.appURL = appURL; self.isHidden = isHidden
    }

    /// From the data side's process list (`CodeSessionsSource.runningProcesses`).
    init(_ info: ClaudeProcessInfo, isHidden: Bool) {
        self.init(pid: info.pid, profile: info.profile, appURL: info.bundlePath.map { URL(fileURLWithPath: $0) }, isHidden: isHidden)
    }
}

/// Activation, the app's state and URLs. `activate` and `open` are called on the parker's thread; `frontmostPID` and
/// `isHidden` on the main thread.
protocol CodeWorkspace: AnyObject, Sendable {
    /// The frontmost app's process id.
    @MainActor func frontmostPID() -> pid_t?
    /// Whether the app of `pid` is hidden (⌘H).
    @MainActor func isHidden(pid: pid_t) -> Bool
    /// Whether `pid` is still a running Claude process. Any thread. A parked record is dropped only when this says no,
    /// never because a process list is empty or late (the app starting while Claude runs).
    func isClaudeRunning(pid: pid_t) -> Bool
    /// `NSRunningApplication(processIdentifier:).activate()`: the fallback when `AXFrontmost` did not take.
    func activate(pid: pid_t) -> Bool
    /// Opens `url` with the app at `appURL` (`NSWorkspace.open(_:withApplicationAt:configuration:)`). `done`
    /// gets whether it opened, on any thread.
    func open(_ url: URL, withApplicationAt appURL: URL, done: @escaping @Sendable (Bool) -> Void)
}

/// One display, Quartz global coordinates.
struct CodeDisplay: Equatable, Sendable {
    var id: UInt32
    var frame: CGRect
    /// Menu bar to Dock.
    var visibleFrame: CGRect
}

/// The displays, read on the main thread right before a restore.
@MainActor
protocol CodeScreens: AnyObject {
    func displays() -> [CodeDisplay]
}

/// The parker's one serial queue: a dedicated thread in production (`CodeAXThread`), a manual queue with virtual
/// time in tests. Work never runs on the main thread and never blocks a GCD pool thread while waiting.
protocol CodeWorkQueue: AnyObject, Sendable {
    func async(_ work: @escaping () -> Void)
    /// Runs `work` after `seconds` without blocking the queue in between.
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void)
}
