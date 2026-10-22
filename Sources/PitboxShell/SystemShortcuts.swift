import AppKit
import Carbon.HIToolbox

/// Best-effort lookup of enabled macOS keyboard shortcuts (System Settings > Keyboard > Keyboard Shortcuts), which
/// win over app hotkeys. Reads `com.apple.symbolichotkeys`; ids missing from that file use the macOS defaults below.
/// Read-only: never changes the user's shortcuts.
public enum SystemShortcuts {
    /// A system shortcut: key code plus Carbon-independent modifiers.
    struct Entry: Equatable {
        var name: String
        var keyCode: UInt32
        var modifiers: KeyCombo.Modifiers
        var enabled: Bool
    }

    /// The name of an enabled system shortcut using `keyCode` with `modifiers`, if any.
    public static func conflict(keyCode: UInt32, modifiers: KeyCombo.Modifiers) -> String? {
        let domain = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        return conflict(keyCode: keyCode, modifiers: modifiers, symbolicHotKeys: domain ?? [:])
    }

    /// Testable core: `symbolicHotKeys` is the `AppleSymbolicHotKeys` dictionary.
    static func conflict(keyCode: UInt32, modifiers: KeyCombo.Modifiers, symbolicHotKeys: [String: Any]) -> String? {
        var entries = defaults
        for (id, raw) in symbolicHotKeys {
            guard let dict = raw as? [String: Any] else { continue }
            let enabled = (dict["enabled"] as? NSNumber)?.boolValue ?? false
            let params = ((dict["value"] as? [String: Any])?["parameters"] as? [NSNumber])?.map(\.intValue)
            let name = entries[id]?.name ?? "macOS shortcut #\(id)"
            if let params, params.count >= 3, params[1] != 65535 {
                entries[id] = Entry(name: name, keyCode: UInt32(params[1]),
                                    modifiers: Self.modifiers(fromCocoa: params[2]), enabled: enabled)
            } else {
                entries[id]?.enabled = enabled
            }
        }
        return entries.values.first { $0.enabled && $0.keyCode == keyCode && $0.modifiers == modifiers }?.name
    }

    /// Cocoa modifier bits as stored in the plist (shift 0x20000, control 0x40000, option 0x80000, command 0x100000).
    static func modifiers(fromCocoa raw: Int) -> KeyCombo.Modifiers {
        var m: KeyCombo.Modifiers = []
        if raw & 0x20000 != 0 { m.insert(.shift) }
        if raw & 0x40000 != 0 { m.insert(.control) }
        if raw & 0x80000 != 0 { m.insert(.option) }
        if raw & 0x100000 != 0 { m.insert(.command) }
        return m
    }

    /// macOS defaults for the ids most likely to collide with a Pitbox hotkey (used when the id is not in the file).
    static let defaults: [String: Entry] = [
        "32": Entry(name: "Mission Control", keyCode: UInt32(kVK_UpArrow), modifiers: .control, enabled: true),
        "33": Entry(name: "Application windows", keyCode: UInt32(kVK_DownArrow), modifiers: .control, enabled: true),
        "60": Entry(name: "Select the previous input source", keyCode: UInt32(kVK_Space), modifiers: .control,
                    enabled: true),
        "61": Entry(name: "Select next source in Input menu", keyCode: UInt32(kVK_Space), modifiers: [.control, .option],
                    enabled: true),
        "64": Entry(name: "Show Spotlight search", keyCode: UInt32(kVK_Space), modifiers: .command, enabled: true),
        "65": Entry(name: "Show Finder search window", keyCode: UInt32(kVK_Space), modifiers: [.command, .option],
                    enabled: true),
        "79": Entry(name: "Move left a space", keyCode: UInt32(kVK_LeftArrow), modifiers: .control, enabled: true),
        "81": Entry(name: "Move right a space", keyCode: UInt32(kVK_RightArrow), modifiers: .control, enabled: true),
    ]
}
