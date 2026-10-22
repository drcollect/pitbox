import Foundation
import PitboxKit

/// A display as the settings window lists it.
public struct SettingsDisplay: Equatable, Sendable {
    /// The display's UUID (what `display` remembers).
    public var uuid: String
    /// Its name as macOS shows it.
    public var name: String

    public init(uuid: String, name: String) {
        self.uuid = uuid
        self.name = name
    }
}

/// The two global keys the window edits.
public enum SettingsHotkey: String, CaseIterable, Sendable {
    /// `hotkeys.park`: pit the front window.
    case park
    /// `hotkeys.fold`: fold or unfold the block.
    case fold
}

/// Every control of the settings window (the raw value is the control's identifier).
public enum SettingsField: String, CaseIterable, Sendable {
    case columns, edge, display, cellWidth
    case look, deskWindows, peekDelay, deskTags, dragToPark
    case ready, chime, sayIt, recap, warningsStuck, warningsSameFile
    case parkHotkey, foldHotkey
    case dock
    case consoleFontSize, consoleTheme

    /// The fields shown as a pop-up menu.
    public static let popUps: [SettingsField] = [.columns, .edge, .display, .look, .deskWindows, .peekDelay, .ready, .recap,
                                                 .consoleTheme]
    /// The fields shown as a checkbox.
    public static let checkboxes: [SettingsField] = [.deskTags, .dragToPark, .chime, .sayIt, .warningsStuck,
                                                     .warningsSameFile, .dock]
}

/// One entry of a pop-up menu: its title, what choosing it writes (nil: a line that only shows a hand-edited value or
/// a display that is not connected), and whether it is the value in force.
public struct SettingsChoice: Equatable, Sendable {
    public var title: String
    public var change: CodeSettings.MenuChange?
    public var selected: Bool

    public init(title: String, change: CodeSettings.MenuChange?, selected: Bool) {
        self.title = title
        self.change = change
        self.selected = selected
    }
}

/// A file-only key as the window shows it, read-only.
public struct SettingsFileOnlyRow: Equatable, Sendable {
    /// The key as the file spells it (`dock.hosts` for the nested one).
    public var key: String
    /// Its value in words, one line.
    public var value: String
}

/// What the settings window shows and does: the harmless keys, edited through `CodeSettings.apply` (the app gets every
/// write's result at once through `onWritten`); the file-only keys, shown read-only with "Show the settings file". A
/// hand edit of the file arrives through `update(settings:)`. Nothing here knows the shell: the displays, the hotkey
/// check and the hotkeys' registration state are injected by the app. Main thread.
@MainActor
public final class SettingsWindowModel {
    /// The settings as the file says now.
    public private(set) var settings: CodeSettings
    /// Why the last change was not written (the words the window shows), nil after a good write.
    public private(set) var lastError: String?
    /// A hotkey text that was not accepted, per key, with the reason (cleared by the next good entry).
    public private(set) var hotkeyErrors: [SettingsHotkey: String] = [:]

    /// The connected displays, main first.
    public var displays: @MainActor () -> [SettingsDisplay]
    /// Why a hotkey text cannot be used ("Unknown key …"), or nil when the shell can parse it.
    public var checkHotkey: @MainActor (String) -> String?
    /// How a registered key stands now ("⌃⌥P is taken by another app"), or nil when it is fine.
    public var hotkeyStatus: @MainActor (SettingsHotkey) -> String?
    /// "Show the settings file".
    public var showSettingsFile: @MainActor () -> Void
    /// Every successful write's result (the app applies it at once).
    public var onWritten: (@MainActor (CodeSettings) -> Void)?
    /// The window refreshes its controls.
    var onChange: (@MainActor () -> Void)?

    private let writer: @MainActor (CodeSettings.MenuChange) -> Result<CodeSettings, CodeSettings.WriteFailure>

    /// - Parameter write: the writer (default: `CodeSettings.apply` on `Paths.settingsFile`).
    public init(settings: CodeSettings,
                write: @escaping @MainActor (CodeSettings.MenuChange) -> Result<CodeSettings, CodeSettings.WriteFailure> = {
                    CodeSettings.apply($0)
                },
                displays: @escaping @MainActor () -> [SettingsDisplay] = { [] },
                checkHotkey: @escaping @MainActor (String) -> String? = { _ in nil },
                hotkeyStatus: @escaping @MainActor (SettingsHotkey) -> String? = { _ in nil },
                showSettingsFile: @escaping @MainActor () -> Void = {}) {
        self.settings = settings
        self.writer = write
        self.displays = displays
        self.checkHotkey = checkHotkey
        self.hotkeyStatus = hotkeyStatus
        self.showSettingsFile = showSettingsFile
    }

    // MARK: Inputs

    /// The file changed on disk (or the app wrote it): the controls follow.
    public func update(settings: CodeSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        onChange?()
    }

    /// Something the window shows changed outside the file (displays, a hotkey's registration).
    public func refresh() { onChange?() }

    // MARK: Changes

    /// Writes one change. False (and `lastError` set) when the file could not be changed.
    @discardableResult
    public func apply(_ change: CodeSettings.MenuChange) -> Bool {
        switch writer(change) {
        case .success(let fresh):
            lastError = nil
            settings = fresh
            onWritten?(fresh)
            onChange?()
            return true
        case .failure(let failure):
            lastError = failure.message
            Log.warn("settings window: change not written", "settings")
            onChange?()
            return false
        }
    }

    /// Chooses entry `index` of a pop-up field (an entry without a change does nothing).
    @discardableResult
    public func choose(_ field: SettingsField, index: Int) -> Bool {
        let list = choices(for: field)
        guard list.indices.contains(index), let change = list[index].change else { return false }
        return apply(change)
    }

    /// Sets a checkbox field.
    @discardableResult
    public func setFlag(_ field: SettingsField, _ on: Bool) -> Bool {
        guard let change = Self.flagChange(field, on) else { return false }
        return apply(change)
    }

    /// The column width when alone (rounded to whole points, kept inside 300-360).
    @discardableResult
    public func setCellWidth(_ points: Double) -> Bool {
        guard points.isFinite else { return false }
        let clamped = min(max(points.rounded(), CodeSettings.cellWidthRange.lowerBound), CodeSettings.cellWidthRange.upperBound)
        guard clamped != settings.cellWidth else { return true }
        return apply(.cellWidth(clamped))
    }

    /// The console's font size (whole points, kept inside 8-32).
    @discardableResult
    public func setConsoleFontSize(_ points: Double) -> Bool {
        guard points.isFinite else { return false }
        let clamped = min(max(points.rounded(), CodeSettings.consoleFontRange.lowerBound),
                          CodeSettings.consoleFontRange.upperBound)
        guard clamped != settings.console.fontSize else { return true }
        return apply(.consoleFontSize(clamped))
    }

    /// A hotkey typed into its field: trimmed, checked by the shell's parser, then written. An empty or unparsable
    /// text is refused with its reason (`hotkeyErrors`) and nothing is written.
    @discardableResult
    public func setHotkey(_ key: SettingsHotkey, text: String) -> Bool {
        let spec = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if spec.isEmpty {
            hotkeyErrors[key] = "Type a shortcut such as ctrl+opt+p"
            onChange?()
            return false
        }
        if let problem = checkHotkey(spec) {
            hotkeyErrors[key] = problem
            onChange?()
            return false
        }
        hotkeyErrors[key] = nil
        if spec == hotkeySpec(key) {
            onChange?()
            return true
        }
        return apply(key == .park ? .parkHotkey(spec) : .foldHotkey(spec))
    }

    // MARK: What the controls show

    /// The hotkey text in force.
    public func hotkeySpec(_ key: SettingsHotkey) -> String {
        key == .park ? settings.hotkeys.park : settings.hotkeys.fold
    }

    /// The line under a hotkey field: the refused text's reason, else the registration's state, else nil.
    public func hotkeyLine(_ key: SettingsHotkey) -> String? {
        hotkeyErrors[key] ?? hotkeyStatus(key)
    }

    /// Whether a checkbox field is on.
    public func isOn(_ field: SettingsField) -> Bool {
        let code = settings
        switch field {
        case .deskTags: return code.deskTags
        case .dragToPark: return code.dragToPark
        case .chime: return code.chime
        case .sayIt: return code.sayIt
        case .warningsStuck: return code.warnings.stuck
        case .warningsSameFile: return code.warnings.sameFile
        case .dock: return code.dock.enabled
        default: return false
        }
    }

    // MARK: Helpers

    /// What a checkbox writes.
    static func flagChange(_ field: SettingsField, _ on: Bool) -> CodeSettings.MenuChange? {
        switch field {
        case .deskTags: return .deskTags(on)
        case .dragToPark: return .dragToPark(on)
        case .chime: return .chime(on)
        case .sayIt: return .sayIt(on)
        case .warningsStuck: return .warningsStuck(on)
        case .warningsSameFile: return .warningsSameFile(on)
        case .dock: return .dockEnabled(on)
        default: return nil
        }
    }
}
