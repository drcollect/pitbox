import AppKit
import Carbon.HIToolbox

/// Why a hotkey string could not be used.
public enum HotkeyError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    /// A part of the string is neither a modifier nor a key.
    case unknownToken(String)
    case missingKey
    case multipleKeys
    /// Letters, digits, space etc. need Control, Option or Command (Shift alone would swallow typing).
    case needsModifier
    /// Fn / Globe combos cannot be registered (and dictation tools often own Fn).
    case fnNotSupported
    /// A combo other tools or macOS rely on (for example Option-Space, a common dictation default).
    case reserved(String)
    /// The character is not on the current keyboard layout.
    case notOnKeyboard(String)
    /// Another hotkey of this app already uses the combo.
    case duplicate(String)
    /// Carbon refused the registration (usually: another app registered it first).
    case registrationFailed(Int32)

    public var description: String {
        switch self {
        case .empty: return "no shortcut given"
        case .unknownToken(let t): return "unknown key or modifier '\(t)'"
        case .missingKey: return "no key after the modifiers"
        case .multipleKeys: return "more than one key"
        case .needsModifier: return "needs Control, Option or Command"
        case .fnNotSupported: return "Fn/Globe shortcuts are not supported"
        case .reserved(let why): return why
        case .notOnKeyboard(let c): return "'\(c)' is not on the current keyboard layout"
        case .duplicate(let other): return "already used by the '\(other)' shortcut"
        case .registrationFailed(let status):
            return status == Int32(eventHotKeyExistsErr) ? "already taken by another app" : "macOS refused it (\(status))"
        }
    }
}

/// Keys with a fixed virtual key code on every layout.
public enum NamedKey: String, CaseIterable, Sendable {
    case space, `return`, tab, escape, delete, forwardDelete, left, right, up, down, home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

    /// Carbon virtual key code (`kVK_...`).
    public var keyCode: UInt32 {
        let code: Int
        switch self {
        case .space: code = kVK_Space
        case .return: code = kVK_Return
        case .tab: code = kVK_Tab
        case .escape: code = kVK_Escape
        case .delete: code = kVK_Delete
        case .forwardDelete: code = kVK_ForwardDelete
        case .left: code = kVK_LeftArrow
        case .right: code = kVK_RightArrow
        case .up: code = kVK_UpArrow
        case .down: code = kVK_DownArrow
        case .home: code = kVK_Home
        case .end: code = kVK_End
        case .pageUp: code = kVK_PageUp
        case .pageDown: code = kVK_PageDown
        case .f1: code = kVK_F1
        case .f2: code = kVK_F2
        case .f3: code = kVK_F3
        case .f4: code = kVK_F4
        case .f5: code = kVK_F5
        case .f6: code = kVK_F6
        case .f7: code = kVK_F7
        case .f8: code = kVK_F8
        case .f9: code = kVK_F9
        case .f10: code = kVK_F10
        case .f11: code = kVK_F11
        case .f12: code = kVK_F12
        case .f13: code = kVK_F13
        case .f14: code = kVK_F14
        case .f15: code = kVK_F15
        case .f16: code = kVK_F16
        case .f17: code = kVK_F17
        case .f18: code = kVK_F18
        case .f19: code = kVK_F19
        case .f20: code = kVK_F20
        }
        return UInt32(code)
    }

    public var isFunctionKey: Bool { rawValue.count >= 2 && rawValue.first == "f" && Int(rawValue.dropFirst()) != nil }

    /// Menu-style label.
    public var label: String {
        switch self {
        case .space: return "Space"
        case .return: return "↩"
        case .tab: return "⇥"
        case .escape: return "⎋"
        case .delete: return "⌫"
        case .forwardDelete: return "⌦"
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        default: return rawValue.uppercased()
        }
    }

    /// Canonical token used in config strings.
    public var token: String {
        switch self {
        case .forwardDelete: return "forwarddelete"
        case .pageUp: return "pageup"
        case .pageDown: return "pagedown"
        default: return rawValue
        }
    }
}

/// A global shortcut: modifiers plus one key, parsed from config strings such as `"ctrl+opt+s"`.
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    /// Modifier keys of a combo.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// The key a combo triggers on.
    public enum Key: Hashable, Sendable {
        /// A character key ("s", "7", "ä", "-"), resolved to a key code through the current keyboard layout.
        case character(String)
        /// A key with a fixed key code (Space, Return, arrows, F1-F20).
        case named(NamedKey)
    }

    /// Control, Option, Shift, Command.
    public var modifiers: Modifiers
    /// The one non-modifier key.
    public var key: Key

    /// A combo from parts (`parse(_:)` validates; this does not).
    public init(modifiers: Modifiers, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Menu-style rendering, e.g. "⌃⌥S".
    public var description: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .character(let c): s += c.uppercased()
        case .named(let n): s += n.label
        }
        return s
    }

    /// Canonical config string, e.g. "ctrl+opt+s".
    public var canonicalString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        switch key {
        case .character(let c): parts.append(c == "+" ? "plus" : c)
        case .named(let n): parts.append(n.token)
        }
        return parts.joined(separator: "+")
    }

    /// Carbon modifier mask for `RegisterEventHotKey`.
    public var carbonModifiers: UInt32 {
        var m = 0
        if modifiers.contains(.control) { m |= controlKey }
        if modifiers.contains(.option) { m |= optionKey }
        if modifiers.contains(.shift) { m |= shiftKey }
        if modifiers.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    /// AppKit modifier flags (menus, event matching).
    public var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { f.insert(.control) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        if modifiers.contains(.command) { f.insert(.command) }
        return f
    }

    /// Virtual key code on `layout`, or nil if the character is not on it.
    public func keyCode(in layout: KeyboardLayoutMap) -> UInt32? {
        switch key {
        case .named(let n): return n.keyCode
        case .character(let c): return layout.keyCode(for: c)
        }
    }

    // MARK: Parsing

    /// Parses `"ctrl+opt+s"`-style strings. Case-insensitive; parts are separated by `+`; modifier symbols may be
    /// glued to the key (`"⌃⌥s"`). Modifiers: ctrl/control, opt/option/alt, shift, cmd/command, plus `hyper`
    /// (all four) and `meh` (all but Command). Keys: a single character, `space`, `return`/`enter`, `tab`,
    /// `esc`/`escape`, `delete`/`backspace`, `forwarddelete`, arrows (`left`...), `home`, `end`, `pageup`,
    /// `pagedown`, `f1`...`f20`, and punctuation names (`minus`, `equal`, `comma`, `period`, `slash`, `backslash`,
    /// `semicolon`, `quote`, `grave`, `leftbracket`, `rightbracket`, `plus`).
    /// Rejects Fn combos, keys without Control/Option/Command (F-keys excepted) and reserved combos.
    public static func parse(_ text: String) -> Result<KeyCombo, HotkeyError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return .failure(.empty) }

        var parts: [String]
        if trimmed == "+" {
            parts = ["+"]
        } else if trimmed.hasSuffix("++") {
            parts = trimmed.dropLast(2).split(separator: "+", omittingEmptySubsequences: false).map(String.init) + ["+"]
        } else {
            parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }

        var modifiers: Modifiers = []
        var key: Key?
        for (index, rawPart) in parts.enumerated() {
            var part = rawPart
            // Modifier symbols glued to a key: "⌃⌥s".
            while part.count > 1, let first = part.first, let m = symbolModifiers[first] {
                modifiers.formUnion(m)
                part.removeFirst()
            }
            if part.isEmpty {
                return .failure(index == parts.count - 1 ? .missingKey : .unknownToken(rawPart))
            }
            if ["fn", "function", "globe", "🌐"].contains(part) { return .failure(.fnNotSupported) }
            if let m = modifierWords[part] {
                modifiers.formUnion(m)
                continue
            }
            if part.count == 1, let first = part.first, let m = symbolModifiers[first] {
                modifiers.formUnion(m)
                continue
            }
            guard let k = parseKey(part) else { return .failure(.unknownToken(part)) }
            if key != nil { return .failure(.multipleKeys) }
            key = k
        }
        guard let key else { return .failure(.missingKey) }

        let combo = KeyCombo(modifiers: modifiers, key: key)
        let isFunctionKey: Bool = { if case .named(let n) = key { return n.isFunctionKey }; return false }()
        if !isFunctionKey, modifiers.isDisjoint(with: [.control, .option, .command]) {
            return .failure(.needsModifier)
        }
        if let why = reservedCombos[combo] { return .failure(.reserved(why)) }
        return .success(combo)
    }

    private static let modifierWords: [String: Modifiers] = [
        "ctrl": .control, "control": .control, "ctl": .control,
        "opt": .option, "option": .option, "alt": .option,
        "shift": .shift,
        "cmd": .command, "command": .command,
        "hyper": [.control, .option, .shift, .command],
        "meh": [.control, .option, .shift],
    ]

    private static let symbolModifiers: [Character: Modifiers] = [
        "⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command,
    ]

    private static let namedKeys: [String: NamedKey] = {
        var map: [String: NamedKey] = [
            "space": .space, "spacebar": .space,
            "return": .return, "enter": .return,
            "tab": .tab,
            "esc": .escape, "escape": .escape,
            "delete": .delete, "backspace": .delete,
            "forwarddelete": .forwardDelete, "fwddelete": .forwardDelete, "del": .forwardDelete,
            "left": .left, "right": .right, "up": .up, "down": .down,
            "arrowleft": .left, "arrowright": .right, "arrowup": .up, "arrowdown": .down,
            "home": .home, "end": .end,
            "pageup": .pageUp, "pgup": .pageUp, "pagedown": .pageDown, "pgdn": .pageDown,
        ]
        for n in NamedKey.allCases where n.isFunctionKey { map[n.rawValue] = n }
        return map
    }()

    private static let punctuationNames: [String: String] = [
        "minus": "-", "equal": "=", "equals": "=", "comma": ",", "period": ".", "dot": ".", "slash": "/",
        "backslash": "\\", "semicolon": ";", "quote": "'", "apostrophe": "'", "grave": "`", "backtick": "`",
        "leftbracket": "[", "rightbracket": "]", "plus": "+",
    ]

    private static func parseKey(_ part: String) -> Key? {
        if let n = namedKeys[part] { return .named(n) }
        if let p = punctuationNames[part] { return .character(p) }
        if part.count == 1, let scalar = part.unicodeScalars.first, !CharacterSet.whitespacesAndNewlines.contains(scalar),
           !CharacterSet.controlCharacters.contains(scalar) {
            return .character(part)
        }
        return nil
    }

    /// Combos a global hotkey must never take.
    static let reservedCombos: [KeyCombo: String] = [
        KeyCombo(modifiers: .option, key: .named(.space)): "⌥Space is a common dictation shortcut",
        KeyCombo(modifiers: .command, key: .named(.space)): "⌘Space is Spotlight",
        KeyCombo(modifiers: [.command, .option], key: .named(.space)): "⌘⌥Space is Finder search",
        KeyCombo(modifiers: .command, key: .named(.tab)): "⌘Tab is the app switcher",
        KeyCombo(modifiers: [.command, .shift], key: .named(.tab)): "⌘⇧Tab is the app switcher",
        KeyCombo(modifiers: .command, key: .character("q")): "⌘Q quits apps",
    ]
}

extension HotkeyError {
    /// True for Carbon's "these keys are registered already" (`eventHotKeyExistsErr`): with the exclusive check, another
    /// app holds them.
    public var isTakenByAnotherApp: Bool {
        if case .registrationFailed(let status) = self { return status == Int32(eventHotKeyExistsErr) }
        return false
    }
}
