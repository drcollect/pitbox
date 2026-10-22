import Foundation
import PitboxKit
import PitboxSessions
import PitboxShell

/// What the binder needs of `HotkeyManager` (tests use a fake: no real Carbon registration).
@MainActor
protocol HotkeyRegistering: AnyObject {
    @discardableResult
    func register(id: String, spec: String, exclusiveCheck: Bool, action: @escaping () -> Void) -> Result<KeyCombo, HotkeyError>
    func unregister(id: String)
    var registrations: [String: HotkeyManager.Registration] { get }
}

extension HotkeyManager: HotkeyRegistering {}

/// The two global keys (settings `hotkeys`): pit the front window and fold the block. Each is checked for exclusivity
/// first (a probe with an exclusive Carbon registration, released at once): keys another app holds are not shared but
/// reported (the menu and the settings window show "⌃⌥P is taken by another app"); the menu's opening retries them. A
/// settings change re-registers only a key whose text changed; an empty text leaves that key unregistered.
@MainActor
final class HotkeyBinder {
    private let hotkeys: HotkeyRegistering
    private let actions: [String: () -> Void]
    private var specs: [String: String] = [:]

    /// - Parameters:
    ///   - park: ⌃⌥P's action (`PitboxMenuBar.parkHotkeyID`).
    ///   - fold: ⌃⌥C's action (`PitboxMenuBar.foldHotkeyID`).
    init(hotkeys: HotkeyRegistering, park: @escaping () -> Void, fold: @escaping () -> Void) {
        self.hotkeys = hotkeys
        actions = [PitboxMenuBar.parkHotkeyID: park, PitboxMenuBar.foldHotkeyID: fold]
    }

    /// Registers the keys the settings name (only those whose text changed since the last call).
    func apply(_ keys: CodeSettings.Hotkeys) {
        bind(PitboxMenuBar.parkHotkeyID, keys.park)
        bind(PitboxMenuBar.foldHotkeyID, keys.fold)
    }

    /// Unregisters both keys (quit).
    func unbindAll() {
        for id in specs.keys.sorted() { hotkeys.unregister(id: id) }
        specs = [:]
    }

    /// The settings window's line under a key's field: nil while it is registered without a warning.
    func status(_ key: SettingsHotkey) -> String? {
        AppWords.hotkeyStatus(hotkeys.registrations[Self.id(key)])
    }

    /// The manager's id of a settings key.
    static func id(_ key: SettingsHotkey) -> String {
        key == .park ? PitboxMenuBar.parkHotkeyID : PitboxMenuBar.foldHotkeyID
    }

    private func bind(_ id: String, _ raw: String) {
        let spec = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard specs[id] != spec else { return }
        specs[id] = spec
        guard !spec.isEmpty, let action = actions[id] else {
            hotkeys.unregister(id: id)
            return
        }
        hotkeys.register(id: id, spec: spec, exclusiveCheck: true, action: action)
    }
}
