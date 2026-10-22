import AppKit

/// What a console shortcut asks for. Handled by the console, never sent to the program in the terminal.
enum TerminalShortcut: Equatable {
    case newSession
    case closeSession
    case nextSession
    case previousSession
    /// Cmd-1 ... Cmd-8: the tab at this zero-based position.
    case selectSession(Int)
    /// Cmd-9: the last tab, like browsers.
    case selectLastSession
    /// Give the keyboard back to the app that had it.
    case releaseKeyboard
    case find
    /// Cmd-Backspace: delete to the start of the line (Ctrl-U).
    case deleteToLineStart
}

/// A key event reduced to what the shortcut table needs, so the table can be tested without AppKit events.
struct KeyInput: Equatable {
    var keyCode: UInt16
    /// `charactersIgnoringModifiers` (Shift still applies).
    var characters: String
    var command = false
    var control = false
    var option = false
    var shift = false
    var isRepeat = false

    init(keyCode: UInt16, characters: String, command: Bool = false, control: Bool = false, option: Bool = false,
         shift: Bool = false, isRepeat: Bool = false) {
        self.keyCode = keyCode; self.characters = characters; self.command = command; self.control = control
        self.option = option; self.shift = shift; self.isRepeat = isRepeat
    }

    init(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", command: flags.contains(.command),
                  control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift),
                  isRepeat: event.isARepeat)
    }
}

/// The shortcut table. Physical key codes are used for the bracket and arrow keys so layouts where `[` and `]` need
/// Option (German) still have a shortcut; Cmd-Option-Left/Right is the layout-independent alternative.
enum TerminalShortcuts {
    static let tab: UInt16 = 48, escape: UInt16 = 53, backspace: UInt16 = 51
    static let leftBracket: UInt16 = 33, rightBracket: UInt16 = 30
    static let leftArrow: UInt16 = 123, rightArrow: UInt16 = 124

    static func match(_ key: KeyInput) -> TerminalShortcut? {
        // Ctrl-Tab / Ctrl-Shift-Tab: rotate.
        if key.control, !key.command, !key.option, key.keyCode == tab { return key.shift ? .previousSession : .nextSession }
        guard key.command, !key.control else { return nil }
        if key.option, !key.shift {
            if key.keyCode == rightArrow { return .nextSession }
            if key.keyCode == leftArrow { return .previousSession }
            return nil
        }
        guard !key.option else { return nil }
        if key.shift {
            if key.keyCode == rightBracket || ["]", "}"].contains(key.characters) { return .nextSession }
            if key.keyCode == leftBracket || ["[", "{"].contains(key.characters) { return .previousSession }
            return nil
        }
        switch key.keyCode {
        case escape: return .releaseKeyboard
        case backspace: return .deleteToLineStart
        default: break
        }
        switch key.characters.lowercased() {
        case "t": return key.isRepeat ? nil : .newSession
        case "w": return key.isRepeat ? nil : .closeSession
        case "f": return .find
        case "9": return .selectLastSession
        case let digit where digit.count == 1 && ("1"..."8").contains(digit): return Int(digit).map { .selectSession($0 - 1) }
        default: return nil
        }
    }
}

extension TerminalShortcuts {
    /// Option-Left/Right/Backspace/Delete as word motions (`ESC b`, `ESC f`, `ESC DEL`, `ESC d`), what Terminal.app sends.
    ///
    /// With Option-as-Meta off (the default, so Option can still type `@ [ ] { } | ~` on German layouts) the system maps
    /// these keys to word-movement commands SwiftTerm does not translate, so they would do nothing. With Option-as-Meta on,
    /// SwiftTerm handles them itself and this is not used.
    static func optionEditingSequence(_ key: KeyInput) -> [UInt8]? {
        guard key.option, !key.command, !key.control, !key.shift else { return nil }
        switch key.keyCode {
        case leftArrow: return [0x1b, UInt8(ascii: "b")]
        case rightArrow: return [0x1b, UInt8(ascii: "f")]
        case backspace: return [0x1b, 0x7f]
        case forwardDelete: return [0x1b, UInt8(ascii: "d")]
        default: return nil
        }
    }

    static let forwardDelete: UInt16 = 117
}
