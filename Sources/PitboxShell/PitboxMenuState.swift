import AppKit
import PitboxKit

/// The window guard as the menu shows it (the app maps the guard's status into this).
public enum GuardMenuState: Equatable, Sendable {
    /// Guarding: "Window guard: on" (a click pauses it).
    case on
    /// Paused by the user: "Window guard: paused" (a click resumes it).
    case paused
    /// Not trusted for Accessibility yet: "Window guard: needs Accessibility" (disabled).
    case needsAccessibility
    /// Not running: "Window guard: off" (disabled).
    case off
}

/// A display as the Display submenu lists it.
public struct MenuDisplay: Equatable, Sendable {
    /// The display's UUID (what the settings remember).
    public var uuid: String
    /// Its name as macOS shows it.
    public var name: String

    public init(uuid: String, name: String) {
        self.uuid = uuid
        self.name = name
    }
}

/// Everything the status menu shows, read each time it opens. The app fills it from the panel, the settings, the
/// sessions, the guard, the dock link and the hotkey manager; nothing here imports those modules.
public struct PitboxMenuState: Equatable, Sendable {
    /// On screen: what the user sees (`BlockPanelController.isVisible`). Drives "Show Pitbox" / "Hide Pitbox".
    public var isVisible = false
    /// Shown, but hidden because the host hides its strip (`BlockPanelController.isHiddenByHost`): "Show Pitbox" then
    /// puts it alone at the screen edge, and says so.
    public var hiddenByHost = false
    /// Folded into the rail.
    public var isFolded = false
    /// 2 or 1 (the setting).
    public var columns = 2
    /// Docked beside a host right now (`BlockPanelController.isDockedNow`): Edge, Top Gap and Bottom Gap are hidden,
    /// Keep Above Windows and Display show the host's state, disabled (the host's win).
    public var isDocked = false
    /// Docked: the host's level is above windows (`BlockPanelController.level.isAboveNormalWindows`).
    public var dockedAboveWindows = true
    /// Docked: the UUID of the host's display (`BlockDisplay.uuid(of: block.displayID)`), named from `displays`.
    public var dockedDisplayUUID: String?
    /// The alone edge.
    public var edge: Edge = .right
    /// The connected displays, main first.
    public var displays: [MenuDisplay] = []
    /// The remembered display (nil or "main": the main display).
    public var displayUUID: String?
    /// "Keep Above Windows".
    public var keepAboveWindows = true
    /// Alone gaps in points.
    public var topGap: Double = 0
    public var bottomGap: Double = 0
    /// "Hide text" is on (session text hidden in the block).
    public var hideText = false
    /// Sessions done and on track, which "Pit all done" sends into the pit.
    public var doneOnTrack = 0
    /// Windows in the pit, which "All back on track" restores.
    public var inThePit = 0
    /// The window guard.
    public var guardState: GuardMenuState = .off
    /// Extra words after the guard's state, e.g. "3 windows kept clear".
    public var guardDetail: String?
    /// "Dock with <host>" is ticked (`dock.enabled`).
    public var dockEnabled = true
    /// The host's own name from the dock handshake; nil before any handshake (the menu says "the host app").
    public var hostName: String?
    /// The disabled line under "Dock with …": "Docked", "Not connected", "<host> not responding", ….
    public var dockStatus: String = ""
    /// Accessibility is granted (hides "Grant Accessibility…").
    public var accessibilityGranted = false
    /// The login item as the system sees it (`LoginItem.status`).
    public var launchAtLogin: LoginItem.Status = .disabled
    /// The hotkey manager's registrations (`HotkeyManager.registrations`), for the shortcuts and "taken" lines.
    public var hotkeys: [String: HotkeyManager.Registration] = [:]
    /// The app's version for About ("1.0 (42)").
    public var version: String = PitboxMenuState.bundleVersion

    public init() {}

    /// The host's name for the menu: the handshake's name made one short line, or "the host app".
    public var hostDisplayName: String {
        let cleaned = hostName.map { MenuText.oneLine($0, maxLength: 40) } ?? ""
        return cleaned.isEmpty ? "the host app" : cleaned
    }

    /// "1.2 (34)" from the bundle; "development build" outside an app bundle.
    public static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return "development build" }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != short { return "\(short) (\(build))" }
        return short
    }
}

/// What the menu's items do. Each closure is the app's; the defaults do nothing, except About, Quit, Login Items and
/// Show the settings file, which have system defaults.
@MainActor
public struct PitboxMenuActions {
    /// "Show Pitbox" / "Hide Pitbox" (the panel's `toggle()`).
    public var toggleShown: @MainActor () -> Void = {}
    /// "Fold" / "Unfold" (the panel's `toggleFold()`, as ⌃⌥C).
    public var toggleFold: @MainActor () -> Void = {}
    /// Columns ▸ 2 or 1.
    public var setColumns: @MainActor (Int) -> Void = { _ in }
    /// Edge ▸ Right or Left (alone).
    public var setEdge: @MainActor (Edge) -> Void = { _ in }
    /// The display's UUID, or nil for "Main display".
    public var setDisplay: @MainActor (String?) -> Void = { _ in }
    /// "Keep Above Windows": the new value.
    public var setKeepAboveWindows: @MainActor (Bool) -> Void = { _ in }
    /// Top Gap ▸ a preset in points (0 is "None").
    public var setTopGap: @MainActor (Double) -> Void = { _ in }
    /// Bottom Gap ▸ a preset in points (0 is "None").
    public var setBottomGap: @MainActor (Double) -> Void = { _ in }
    /// "Hide text": the new value.
    public var setHideText: @MainActor (Bool) -> Void = { _ in }
    /// "Pit front window" (as ⌃⌥P).
    public var pitFrontWindow: @MainActor () -> Void = {}
    /// "Pit all done".
    public var pitAllDone: @MainActor () -> Void = {}
    /// "All back on track" (restores every window in the pit).
    public var allBackOnTrack: @MainActor () -> Void = {}
    /// `true` pauses the guard, `false` resumes it.
    public var setGuardPaused: @MainActor (Bool) -> Void = { _ in }
    /// "Dock with <host>": the new value.
    public var setDockEnabled: @MainActor (Bool) -> Void = { _ in }
    /// "Grant Accessibility…" (the onboarding window).
    public var grantAccessibility: @MainActor () -> Void = {}
    /// "Settings…".
    public var openSettings: @MainActor () -> Void = {}
    /// "Show the settings file" (default: reveals it in Finder).
    public var showSettingsFile: @MainActor () -> Void = { NSWorkspace.shared.activateFileViewerSelecting([Paths.settingsFile]) }
    /// "Launch at Login": the new value.
    public var setLaunchAtLogin: @MainActor (Bool) -> Void = { _ in }
    /// "Launch at Login: approve in System Settings…" (default: opens Login Items).
    public var openLoginItemsSettings: @MainActor () -> Void = { LoginItem.openSystemSettings() }
    /// About, with the state's version.
    public var about: @MainActor (String) -> Void = { AboutPanel.show(version: $0) }
    /// "Quit Pitbox" (default: terminates the app).
    public var quit: @MainActor () -> Void = { NSApp.terminate(nil) }

    public init() {}
}

/// Menu text made safe for one line.
enum MenuText {
    /// One line: control characters, line breaks and invisible format characters become single spaces; trimmed; at
    /// most `maxLength` characters (the last one "…" when cut).
    static func oneLine(_ text: String, maxLength: Int = 120) -> String {
        var out = ""
        var pendingSpace = false
        var count = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .format { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.unicodeScalars.append(" ") }
            pendingSpace = false
            out.unicodeScalars.append(scalar)
            count += 1
            if count > maxLength * 4 { break }
        }
        guard out.count > maxLength else { return out }
        return out.prefix(max(0, maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
