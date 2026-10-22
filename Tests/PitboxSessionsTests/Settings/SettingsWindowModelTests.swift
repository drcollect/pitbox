import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The settings window's model: what each control shows, what each change writes (through a writer over a scratch
/// file), the hotkey check and the file-only keys. Invented values only.
@MainActor
@Suite("Settings window model")
struct SettingsWindowModelTests {
    /// A model over a scratch settings file, recording what reached the app.
    @MainActor
    final class Rig {
        let folder = SeamFolder("settings-model")
        let url: URL
        let model: SettingsWindowModel
        var written: [CodeSettings] = []
        var changes = 0

        init(_ text: String = "{}", displays: [SettingsDisplay] = [],
             checkHotkey: @escaping @MainActor (String) -> String? = { _ in nil }) {
            url = folder.file("settings.json")
            try? CodeStateFiles.writeAtomically(Data(text.utf8), to: url)
            let url = self.url
            model = SettingsWindowModel(settings: CodeSettings.read(at: url) ?? CodeSettings(),
                                        write: { CodeSettings.apply($0, at: url) },
                                        displays: { displays }, checkHotkey: checkHotkey,
                                        hotkeyStatus: { $0 == .park ? "⌃⌥P is taken by another app" : nil })
            model.onWritten = { [unowned self] in self.written.append($0) }
            model.onChange = { [unowned self] in self.changes += 1 }
        }

        var file: CodeSettings { CodeSettings.read(at: url) ?? CodeSettings() }
    }

    @Test func everyPopUpHasExactlyOneSelectedEntry() {
        let rig = Rig()
        for field in SettingsField.popUps {
            let list = rig.model.choices(for: field)
            #expect(!list.isEmpty, "\(field)")
            #expect(list.filter(\.selected).count == 1, "\(field)")
        }
        #expect(rig.model.choices(for: .columns).map(\.title) == ["2", "1"])
        #expect(rig.model.choices(for: .peekDelay).map(\.title) == ["After 0.4 s", "After 1.2 s", "Off"])
        #expect(rig.model.choices(for: .peekDelay).first(where: \.selected)?.title == "After 1.2 s")
        #expect(rig.model.choices(for: .recap).first(where: \.selected)?.title == "After 15 min away")
        #expect(rig.model.choices(for: .consoleTheme).first(where: \.selected)?.title == "Same as the system")
        for field in SettingsField.checkboxes { #expect(SettingsWindowModel.flagChange(field, true) != nil, "\(field)") }
    }

    @Test func handEditedValuesShowAsTheirOwnLine() {
        let rig = Rig(#"{"peekDelaySeconds":2,"readyRecentHours":12,"recapAfterMinutes":45,"awayRecap":true}"#)
        let peek = rig.model.choices(for: .peekDelay)
        #expect(peek.last == SettingsChoice(title: "After 2 s", change: nil, selected: true))
        #expect(rig.model.choices(for: .ready).last?.title == "Also sessions you used in the last 12 hours")
        #expect(rig.model.choices(for: .recap).last == SettingsChoice(title: "After 45 min away", change: nil, selected: true))
        #expect(!rig.model.choose(.peekDelay, index: peek.count - 1), "the custom line writes nothing")
        let off = Rig(#"{"awayRecap":false}"#)
        #expect(off.model.choices(for: .recap).first == SettingsChoice(title: "Off", change: .awayRecap(afterMinutes: nil),
                                                                       selected: true))
    }

    @Test func displaysAreListedByNameAndAMissingOneIsShown() {
        let displays = [SettingsDisplay(uuid: "AAAA-1111", name: "Built-in Display"),
                        SettingsDisplay(uuid: "BBBB-2222", name: "Acme Ultrawide"),
                        SettingsDisplay(uuid: "CCCC-3333", name: "Acme Ultrawide"),
                        SettingsDisplay(uuid: "bad uuid!", name: "Ignored")]
        let rig = Rig(#"{"display":"BBBB-2222"}"#, displays: displays)
        let list = rig.model.choices(for: .display)
        #expect(list.map(\.title) == ["Main display", "Built-in Display", "Acme Ultrawide", "Acme Ultrawide (2)"])
        #expect(list.firstIndex(where: \.selected) == 2)
        #expect(rig.model.choose(.display, index: 1))
        #expect(rig.file.display == "AAAA-1111")
        let gone = Rig(#"{"display":"DDDD-4444"}"#, displays: displays)
        #expect(gone.model.choices(for: .display).last
                == SettingsChoice(title: "A display that is not connected (main display meanwhile)", change: nil, selected: true))
    }

    @Test func choicesAndFlagsAreWrittenAndHandedToTheApp() {
        let rig = Rig()
        #expect(rig.model.choose(.columns, index: 1))
        #expect(rig.model.choose(.edge, index: 1))
        #expect(rig.model.choose(.look, index: 1))
        #expect(rig.model.choose(.recap, index: 3))
        #expect(rig.model.choose(.consoleTheme, index: 2))
        #expect(rig.model.setFlag(.chime, true))
        #expect(rig.model.setFlag(.warningsSameFile, false))
        #expect(rig.model.setFlag(.dock, false))
        let file = rig.file
        #expect(file.columns == 1 && file.edge == .left && file.look == .rows && file.recapAfterMinutes == 60)
        #expect(file.console.theme == .dark && file.chime && !file.warnings.sameFile && !file.dock.enabled)
        #expect(rig.written.count == 8 && rig.written.last == rig.file)
        #expect(rig.model.settings == rig.file && rig.model.lastError == nil)
        #expect(!rig.model.setFlag(.columns, true), "not a checkbox")
        #expect(!rig.model.choose(.columns, index: 9))
    }

    @Test func sliderAndStepperValuesAreRoundedAndKeptInRange() {
        let rig = Rig()
        #expect(rig.model.setCellWidth(341.6))
        #expect(rig.file.cellWidth == 342)
        #expect(rig.model.setCellWidth(900))
        #expect(rig.file.cellWidth == 360)
        #expect(!rig.model.setCellWidth(.infinity))
        #expect(rig.model.setConsoleFontSize(13.4))
        #expect(rig.file.console.fontSize == 13)
        #expect(rig.model.setConsoleFontSize(2))
        #expect(rig.file.console.fontSize == 8, "clamped to the console's own range")
        let before = rig.written.count
        #expect(rig.model.setConsoleFontSize(8), "the same value is fine")
        #expect(rig.written.count == before, "and writes nothing")
    }

    @Test func hotkeysAreCheckedBeforeTheyAreWritten() {
        let rig = Rig(checkHotkey: { $0.contains("nope") ? "Unknown key" : nil })
        #expect(rig.model.hotkeySpec(.park) == "ctrl+opt+p" && rig.model.hotkeySpec(.fold) == "ctrl+opt+c")
        #expect(rig.model.hotkeyLine(.park) == "⌃⌥P is taken by another app")
        #expect(!rig.model.setHotkey(.fold, text: "  "))
        #expect(rig.model.hotkeyLine(.fold) == "Type a shortcut such as ctrl+opt+p")
        #expect(!rig.model.setHotkey(.park, text: "ctrl+nope"))
        #expect(rig.model.hotkeyLine(.park) == "Unknown key", "the refusal wins over the registration line")
        #expect(rig.file.hotkeys == CodeSettings.Hotkeys(), "nothing written")
        let before = rig.written.count
        #expect(rig.model.setHotkey(.park, text: " ctrl+opt+p "))
        #expect(rig.written.count == before, "the same keys write nothing")
        #expect(rig.model.hotkeyLine(.park) == "⌃⌥P is taken by another app")
        #expect(rig.model.setHotkey(.fold, text: "ctrl+opt+k"))
        #expect(rig.file.hotkeys.fold == "ctrl+opt+k" && rig.model.hotkeyErrors.isEmpty)
    }

    @Test func aFailedWriteSaysSoAndChangesNothing() throws {
        let rig = Rig()
        try Data(#"{"chime":"#.utf8).write(to: rig.url)
        #expect(!rig.model.setFlag(.chime, true))
        #expect(rig.model.lastError == "Can't change: the settings file couldn't be read")
        #expect(rig.written.isEmpty && !rig.model.settings.chime)
        try CodeStateFiles.writeAtomically(Data("{}".utf8), to: rig.url)
        #expect(rig.model.setFlag(.chime, true))
        #expect(rig.model.lastError == nil)
    }

    @Test func handEditsReachTheControls() {
        let rig = Rig()
        let before = rig.changes
        rig.model.update(settings: rig.model.settings)
        #expect(rig.changes == before, "the same settings change nothing")
        var edited = rig.model.settings
        edited.chime = true
        rig.model.update(settings: edited)
        #expect(rig.changes == before + 1 && rig.model.isOn(.chime))
    }

    @Test func fileOnlyKeysAreAllShownReadOnly() {
        let rig = Rig(#"{"commands":"run","extraPath":["/opt/tools/bin"],"profiles":[{"folder":"Claude-Work","letter":"B","name":"Acme"}],"dashboards":[{"host":"dash.example.com","pathPrefix":"/dash/"}],"dock":{"enabled":true,"hosts":["com.example.host"]},"showText":{"B":false}}"#)
        let rows = rig.model.fileOnlyRows
        #expect(Set(rows.map(\.key)) == CodeSettings.fileOnlyKeys.union(["dock.hosts"]))
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
        #expect(byKey["commands"] == "run (Run after review)")
        #expect(byKey["extraPath"] == "/opt/tools/bin")
        #expect(byKey["profiles"] == "B · Acme")
        #expect(byKey["dashboards"] == "dash.example.com/dash/")
        #expect(byKey["dock.hosts"] == "com.example.host")
        #expect(byKey["showText"] == "text hidden for B")
        #expect(byKey["sandboxDenyFolders"] == "none")
        let fresh = Rig()
        #expect(fresh.model.fileOnlyRows.first { $0.key == "commands" }?.value == "copyOnly (Copy and Type only, no Run)")
    }

    @Test func numbersReadWithoutTrailingZeros() {
        #expect(SettingsWindowModel.number(2) == "2")
        #expect(SettingsWindowModel.number(0.5) == "0.5")
        #expect(SettingsWindowModel.number(1.25) == "1.25")
    }
}
