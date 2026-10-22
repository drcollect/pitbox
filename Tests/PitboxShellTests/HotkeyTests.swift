import AppKit
import Carbon.HIToolbox
import Testing
@testable import PitboxShell

/// A German (QWERTZ) layout fragment: z and y swapped, no "[" on an unshifted key.
private let german = KeyboardLayoutMap(name: "German", codes: {
    var codes = KeyboardLayoutMap.ansi.codes
    codes["z"] = UInt32(kVK_ANSI_Y)
    codes["y"] = UInt32(kVK_ANSI_Z)
    codes["["] = nil
    codes["ü"] = UInt32(kVK_ANSI_LeftBracket)
    return codes
}())

private func combo(_ s: String) -> KeyCombo? { try? KeyCombo.parse(s).get() }
private func error(_ s: String) -> HotkeyError? {
    if case .failure(let e) = KeyCombo.parse(s) { return e }
    return nil
}

@Suite struct HotkeyParsingTests {
    @Test func defaultsFromConfig() throws {
        let toggle = try #require(combo("ctrl+opt+s"))
        #expect(toggle.modifiers == [.control, .option])
        #expect(toggle.key == .character("s"))
        #expect(toggle.description == "⌃⌥S")
        #expect(toggle.canonicalString == "ctrl+opt+s")
        #expect(toggle.carbonModifiers == UInt32(controlKey | optionKey))
        #expect(toggle.modifierFlags == [.control, .option])

        let ask = try #require(combo("ctrl+opt+space"))
        #expect(ask.key == .named(.space))
        #expect(ask.description == "⌃⌥Space")
        #expect(ask.keyCode(in: .ansi) == UInt32(kVK_Space))
    }

    @Test func toleratesCaseSpacingAndAliases() {
        let expected = KeyCombo(modifiers: [.control, .option], key: .character("s"))
        for s in [" Ctrl + Option + S ", "control+alt+s", "CTL+OPT+s", "opt+ctrl+s", "⌃⌥s", "⌃⌥S", "⌃+⌥+s"] {
            #expect(combo(s) == expected, "\(s)")
        }
        #expect(combo("cmd+shift+k")?.modifiers == [.command, .shift])
        #expect(combo("command+k")?.modifiers == [.command])
        #expect(combo("hyper+t")?.modifiers == [.control, .option, .shift, .command])
        #expect(combo("meh+t")?.modifiers == [.control, .option, .shift])
    }

    @Test func namedAndPunctuationKeys() {
        #expect(combo("ctrl+opt+return")?.key == .named(.return))
        #expect(combo("ctrl+opt+enter")?.key == .named(.return))
        #expect(combo("ctrl+esc")?.key == .named(.escape))
        #expect(combo("cmd+opt+left")?.key == .named(.left))
        #expect(combo("ctrl+pagedown")?.key == .named(.pageDown))
        #expect(combo("cmd+minus")?.key == .character("-"))
        #expect(combo("cmd+-")?.key == .character("-"))
        #expect(combo("cmd+comma")?.key == .character(","))
        #expect(combo("cmd++")?.key == .character("+"))
        #expect(combo("cmd+plus")?.key == .character("+"))
        #expect(combo("cmd+plus")?.canonicalString == "cmd+plus")
        #expect(combo("ctrl+opt+ä")?.key == .character("ä"))
    }

    @Test func functionKeysMayStandAlone() {
        #expect(combo("f13")?.key == .named(.f13))
        #expect(combo("F19")?.keyCode(in: .ansi) == UInt32(kVK_F19))
        #expect(combo("shift+f5")?.modifiers == [.shift])
        #expect(combo("f13")?.description == "F13")
    }

    @Test func rejectsBadStrings() {
        #expect(error("") == .empty)
        #expect(error("   ") == .empty)
        #expect(error("ctrl+opt") == .missingKey)
        #expect(error("ctrl+") == .missingKey)
        #expect(error("ctrl+s+d") == .multipleKeys)
        #expect(error("s") == .needsModifier)
        #expect(error("shift+s") == .needsModifier)
        #expect(error("space") == .needsModifier)
        #expect(error("fn+s") == .fnNotSupported)
        #expect(error("globe+ctrl+s") == .fnNotSupported)
        #expect(error("ctrl+banana") == .unknownToken("banana"))
        #expect(error("ctrl++s") == .unknownToken(""))
    }

    @Test func rejectsReservedCombos() {
        for s in ["opt+space", "alt+space", "⌥space", "cmd+space", "cmd+opt+space", "cmd+tab", "cmd+shift+tab", "cmd+q"] {
            guard case .reserved = error(s) else {
                Issue.record("\(s) should be reserved")
                continue
            }
        }
        // Near misses stay allowed.
        #expect(combo("ctrl+opt+space") != nil)
        #expect(combo("shift+opt+space") != nil)
        #expect(combo("cmd+shift+q") != nil)
    }

    @Test func characterKeysFollowTheKeyboardLayout() {
        let z = KeyCombo(modifiers: [.control, .option], key: .character("z"))
        #expect(z.keyCode(in: .ansi) == UInt32(kVK_ANSI_Z))
        #expect(z.keyCode(in: german) == UInt32(kVK_ANSI_Y))
        #expect(combo("ctrl+opt+s")?.keyCode(in: german) == UInt32(kVK_ANSI_S))
        #expect(combo("ctrl+[")?.keyCode(in: german) == nil)
        #expect(combo("ctrl+ü")?.keyCode(in: german) == UInt32(kVK_ANSI_LeftBracket))
        #expect(combo("ctrl+opt+space")?.keyCode(in: german) == UInt32(kVK_Space))
    }

    @Test func errorsReadWell() {
        #expect(HotkeyError.needsModifier.description == "needs Control, Option or Command")
        #expect(HotkeyError.registrationFailed(Int32(eventHotKeyExistsErr)).description == "already taken by another app")
        #expect(HotkeyError.duplicate("toggle").description.contains("toggle"))
    }
}

@Suite struct SystemShortcutTests {
    private let space = UInt32(kVK_Space)

    @Test func defaultsApplyWhenTheFileHasNoEntry() {
        #expect(SystemShortcuts.conflict(keyCode: space, modifiers: [.control, .option], symbolicHotKeys: [:])
            == "Select next source in Input menu")
        #expect(SystemShortcuts.conflict(keyCode: space, modifiers: [.command], symbolicHotKeys: [:]) == "Show Spotlight search")
        #expect(SystemShortcuts.conflict(keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .option], symbolicHotKeys: [:]) == nil)
    }

    @Test func disabledEntriesDoNotConflict() {
        // As on a Mac with both input-source shortcuts present and disabled.
        let plist: [String: Any] = [
            "60": ["enabled": false, "value": ["parameters": [32, 49, 262_144], "type": "standard"]],
            "61": ["enabled": false, "value": ["parameters": [32, 49, 786_432], "type": "standard"]],
        ]
        #expect(SystemShortcuts.conflict(keyCode: space, modifiers: [.control, .option], symbolicHotKeys: plist) == nil)
        #expect(SystemShortcuts.conflict(keyCode: space, modifiers: [.control], symbolicHotKeys: plist) == nil)
    }

    @Test func remappedEntriesAreRead() {
        let plist: [String: Any] = [
            "64": ["enabled": true, "value": ["parameters": [115, 1, 786_432], "type": "standard"]],
        ]
        // Spotlight moved to ctrl+opt+s.
        #expect(SystemShortcuts.conflict(keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .option], symbolicHotKeys: plist)
            == "Show Spotlight search")
        #expect(SystemShortcuts.conflict(keyCode: space, modifiers: [.command], symbolicHotKeys: plist) == nil)
    }

    @Test func cocoaModifierBits() {
        #expect(SystemShortcuts.modifiers(fromCocoa: 0x40000 | 0x80000) == [.control, .option])
        #expect(SystemShortcuts.modifiers(fromCocoa: 0x100000 | 0x20000) == [.command, .shift])
    }
}

@Suite @MainActor struct HotkeyManagerTests {
    @Test func registersReplacesAndReportsFailures() {
        let manager = HotkeyManager(layout: { .ansi })
        defer { manager.unregisterAll() }
        var changes = 0
        manager.onRegistrationsChanged = { changes += 1 }

        let first = manager.register(id: "a", spec: "hyper+f18") {}
        #expect((try? first.get()) == KeyCombo(modifiers: [.control, .option, .shift, .command], key: .named(.f18)))
        #expect(manager.combo(for: "a") != nil)

        // The same combo under another id is refused; the first registration stays.
        let dup = manager.register(id: "b", spec: "hyper+F18") {}
        if case .failure(let e) = dup { #expect(e == .duplicate("a")) } else { Issue.record("duplicate accepted") }
        #expect(manager.registrations["b"]?.combo == nil)

        // Re-registering an id replaces it.
        let replaced = manager.register(id: "a", spec: "hyper+f17") {}
        #expect((try? replaced.get())?.key == .named(.f17))
        #expect(manager.register(id: "b", spec: "hyper+f18") {}.isSuccess)

        let bad = manager.register(id: "c", spec: "opt+space") {}
        #expect(!bad.isSuccess)
        #expect(manager.registrations["c"]?.spec == "opt+space")

        manager.unregister(id: "c")
        #expect(manager.registrations["c"] == nil)
        #expect(changes >= 5)
        manager.unregisterAll()
        #expect(manager.registrations.isEmpty)
    }

    @Test func aFailedShortcutIsTriedAgainWhenTheLayoutChanges() {
        var current = KeyboardLayoutMap.ansi
        let manager = HotkeyManager(layout: { current })
        defer { manager.unregisterAll() }
        var changes = 0
        manager.onRegistrationsChanged = { changes += 1 }

        // "ü" is not on the ANSI layout: refused, and remembered as failed.
        let first = manager.register(id: "x", spec: "hyper+ü") {}
        if case .failure(let e) = first { #expect(e == .notOnKeyboard("ü")) } else { Issue.record("ü accepted on ANSI") }
        #expect(manager.combo(for: "x") == nil)

        // The same layout again changes nothing.
        manager.keyboardLayoutChanged()
        #expect(changes == 1)
        #expect(manager.combo(for: "x") == nil)

        // A test layout that types ü with the F16 key (so the real registration is hyper+F16, as in the other tests).
        current = KeyboardLayoutMap(name: "Test", codes: ["ü": UInt32(kVK_F16)])
        manager.keyboardLayoutChanged()
        #expect(changes == 2)
        #expect(manager.combo(for: "x")?.key == .character("ü"))
        #expect(manager.registrations["x"]?.spec == "hyper+ü")

        // Unregistered, it is not tried again.
        manager.unregister(id: "x")
        current = .ansi
        manager.keyboardLayoutChanged()
        #expect(manager.registrations["x"] == nil)
    }

    @Test func onlyFailuresALayoutCanFixAreTriedAgain() {
        #expect(HotkeyManager.aLayoutMayFix(.failure(.notOnKeyboard("ü"))))
        #expect(HotkeyManager.aLayoutMayFix(.failure(.missingKey)))
        #expect(HotkeyManager.aLayoutMayFix(.failure(.registrationFailed(-9878))))
        for error: HotkeyError in [.empty, .unknownToken("x"), .multipleKeys, .needsModifier, .fnNotSupported,
                                   .reserved("taken"), .duplicate("other")] {
            #expect(!HotkeyManager.aLayoutMayFix(.failure(error)), "\(error)")
        }
    }

    @Test func currentLayoutIsReadable() {
        let layout = KeyboardLayoutMap.current()
        #expect(!layout.codes.isEmpty)
        for letter in ["a", "s", "q", "z"] { #expect(layout.keyCode(for: letter) != nil, "\(letter) on \(layout.name)") }
        #expect(layout.keyCode(for: "S") == layout.keyCode(for: "s"))
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
