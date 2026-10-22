import AppKit
import Foundation
import Testing
@testable import Pitbox
import PitboxKit
import PitboxSessions
import PitboxShell

/// ⌃⌥P and ⌃⌥C from the settings, over a fake registrar (no Carbon registration in these tests).
@MainActor
@Suite("Hotkey binder")
struct HotkeyBinderTests {
    final class FakeHotkeys: HotkeyRegistering {
        var registered: [(id: String, spec: String, exclusive: Bool)] = []
        var unregistered: [String] = []
        var actions: [String: () -> Void] = [:]
        var registrations: [String: HotkeyManager.Registration] { [:] }

        func register(id: String, spec: String, exclusiveCheck: Bool, action: @escaping () -> Void) -> Result<KeyCombo, HotkeyError> {
            registered.append((id, spec, exclusiveCheck))
            actions[id] = action
            return KeyCombo.parse(spec)
        }

        func unregister(id: String) {
            unregistered.append(id)
            actions[id] = nil
        }
    }

    @Test func bothKeysAreCheckedForExclusivityAndFireTheirActions() {
        let fake = FakeHotkeys()
        var fired: [String] = []
        let binder = HotkeyBinder(hotkeys: fake, park: { fired.append("park") }, fold: { fired.append("fold") })
        binder.apply(CodeSettings.Hotkeys())
        #expect(fake.registered.map(\.id) == ["park", "fold"])
        #expect(fake.registered.map(\.spec) == ["ctrl+opt+p", "ctrl+opt+c"])
        #expect(fake.registered.filter { !$0.exclusive }.isEmpty)
        fake.actions["park"]?()
        fake.actions["fold"]?()
        #expect(fired == ["park", "fold"])
        #expect(HotkeyBinder.id(.park) == PitboxMenuBar.parkHotkeyID && HotkeyBinder.id(.fold) == PitboxMenuBar.foldHotkeyID)
    }

    @Test func onlyAChangedKeyIsRegisteredAgain() {
        let fake = FakeHotkeys()
        let binder = HotkeyBinder(hotkeys: fake, park: {}, fold: {})
        binder.apply(CodeSettings.Hotkeys())
        binder.apply(CodeSettings.Hotkeys())
        #expect(fake.registered.count == 2, "the same text: nothing again")
        binder.apply(CodeSettings.Hotkeys(park: "ctrl+opt+k", fold: "ctrl+opt+c"))
        #expect(fake.registered.count == 3 && fake.registered.last?.id == "park" && fake.registered.last?.spec == "ctrl+opt+k")
        binder.apply(CodeSettings.Hotkeys(park: "ctrl+opt+k", fold: " "))
        #expect(fake.unregistered == ["fold"], "an empty text leaves the key unregistered")
        binder.unbindAll()
        #expect(Set(fake.unregistered) == ["fold", "park"])
        #expect(binder.status(.park) == nil, "nothing recorded: no line")
    }
}
