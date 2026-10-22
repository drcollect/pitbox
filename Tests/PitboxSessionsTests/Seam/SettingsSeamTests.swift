import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

// `code-settings.json`: the newer keys, the careful read, and the ⋯ menu's writer.

@Suite("Settings: the newer keys")
struct SettingsSeamTests {
    @Test func theNewKeysReadTolerantlyEachOnItsOwn() {
        let all = CodeSettings.decode(Data(#"""
        {"look":"rows","deskWindows":"monitors","peekDelaySeconds":0.4,"jTags":false,"dragToPark":false,"chime":true,
         "sayIt":true,"sayHeadlines":true,"awayRecap":false,"recapAfterMinutes":30,"finishedMinMinutes":0,
         "readyRecentHours":0,"warnings":{"stuck":false,"sameFile":false},
         "serverTimeZones":{"buildbox":"UTC","box":"Europe/Lisbon"},"unknownKey":[1,2]}
        """#.utf8))
        #expect(all.look == .rows && all.deskWindows == .monitors && all.peekDelaySeconds == 0.4)
        #expect(!all.deskTags && !all.dragToPark && all.chime && all.sayIt && all.sayHeadlines && !all.awayRecap)
        #expect(all.recapAfterMinutes == 30 && all.finishedMinMinutes == 0 && all.readyRecentHours == 0)
        #expect(all.warnings == CodeSettings.Warnings(stuck: false, sameFile: false))
        #expect(all.serverTimeZones == ["buildbox": "UTC", "box": "Europe/Lisbon"])

        let wrong = CodeSettings.decode(Data(#"""
        {"look":"grid","deskWindows":3,"peekDelaySeconds":5,"jTags":"yes","recapAfterMinutes":3,"finishedMinMinutes":61,
         "readyRecentHours":72,"warnings":{"stuck":"no","sameFile":false},"chime":true,
         "serverTimeZones":{"buildbox":"Mars/Base","box":"Europe/Lisbon","bad alias":"UTC"}}
        """#.utf8))
        #expect(wrong.look == .monitors && wrong.deskWindows == .tags && wrong.peekDelaySeconds == 1.2 && wrong.deskTags)
        #expect(wrong.recapAfterMinutes == 15 && wrong.finishedMinMinutes == 3 && wrong.readyRecentHours == 6)
        #expect(wrong.warnings == CodeSettings.Warnings(stuck: true, sameFile: false), "each warning on its own")
        #expect(wrong.chime, "a good value next to wrong ones is kept")
        #expect(wrong.serverTimeZones == ["box": "Europe/Lisbon"])
        #expect(CodeSettings.decode(Data(#"{"peekDelaySeconds":0}"#.utf8)).peekDelaySeconds == 0, "0 is off")
        #expect(CodeSettings.decode(Data(#"{"peekDelaySeconds":0.2}"#.utf8)).peekDelaySeconds == 1.2)
        #expect(CodeSettings.decode(Data(#"{"chime":true,"chime":false}"#.utf8)) == CodeSettings(), "a duplicated key fails")
        let deep = String(repeating: "[", count: 17) + String(repeating: "]", count: 17)
        #expect(CodeSettings.decode(Data(#"{"chime":true,"x":\#(deep)}"#.utf8)) == CodeSettings(), "nesting over 16")
    }

    @Test func zoneLessETAsOfAnAliasAreReadInItsZoneElseUTC() {
        var settings = CodeSettings()
        settings.serverTimeZones = ["box": "Europe/Lisbon"]
        #expect(settings.serverTimeZone(for: "box").identifier == "Europe/Lisbon")
        #expect(settings.serverTimeZone(for: "buildbox").secondsFromGMT() == 0, "not listed: UTC")
        #expect(CodeSettings().serverTimeZone(for: "buildbox").secondsFromGMT() == 0)
    }

    @Test func theMenuChangesOneKeyAndKeepsEveryOther() throws {
        let folder = SeamFolder("settings")
        let url = folder.file("code-settings.json")
        let original = #"{"commandShell":"login","extraPath":["/opt/x/bin"],"serverNames":{"buildbox":["box.example"]},"showText":{"B":false},"chime":false,"usersOwnKey":{"nested":[1,2,{"deep":"\#(secretWord)"}]},"version":7}"#
        try original.write(to: url, atomically: true, encoding: .utf8)
        let changed = try CodeSettings.apply(.chime(true), at: url).get()
        #expect(changed.chime && changed.commandShell == .login && changed.showText["B"] == false)
        let before = try #require(try JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(after["chime"] as? Bool == true)
        #expect(Set(after.keys) == Set(before.keys), "no key added or lost")
        for key in before.keys where key != "chime" {
            #expect(NSDictionary(dictionary: [key: before[key] as Any]) == NSDictionary(dictionary: [key: after[key] as Any]), "\(key)")
        }
        var info = stat()
        #expect(lstat(url.path, &info) == 0 && (info.st_mode & 0o777) == 0o600)
        #expect(folder.names == ["code-settings.json"], "no temporary file is left")

        // Two keys at once for the recap; a value outside its range writes nothing.
        let recap = try CodeSettings.apply(.awayRecap(afterMinutes: 30), at: url).get()
        #expect(recap.awayRecap && recap.recapAfterMinutes == 30)
        #expect(try CodeSettings.apply(.awayRecap(afterMinutes: nil), at: url).get().awayRecap == false)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(CodeSettings.apply(.peekDelaySeconds(5), at: url) == .failure(.invalidValue))
        #expect(CodeSettings.apply(.awayRecap(afterMinutes: 200), at: url) == .failure(.invalidValue))
        #expect(CodeSettings.apply(.readyRecentHours(-1), at: url) == .failure(.invalidValue))
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        for change: CodeSettings.MenuChange in [.look(.rows), .deskWindows(.monitors), .peekDelaySeconds(0.4),
                                                 .readyRecentHours(0), .sayIt(true), .dragToPark(false)] {
            #expect((try? CodeSettings.apply(change, at: url).get()) != nil)
        }
        let final = CodeSettings.loadOrCreate(at: url)
        #expect(final.look == .rows && final.deskWindows == .monitors && final.peekDelaySeconds == 0.4)
        #expect(final.readyRecentHours == 0 && final.sayIt && !final.dragToPark && final.commandShell == .login)
    }

    @Test func fileOnlyKeysAreNeverWrittenByTheMenu() {
        let changes: [CodeSettings.MenuChange] = [.look(.monitors), .deskWindows(.tags), .peekDelaySeconds(1.2),
                                                  .readyRecentHours(6), .chime(true), .sayIt(false),
                                                  .awayRecap(afterMinutes: 15), .awayRecap(afterMinutes: nil),
                                                  .dragToPark(true), .deskTags(false), .columns(1), .folded(true),
                                                  .edge(.left), .display("main"), .cellWidth(340), .dockEnabled(false),
                                                  .consoleFontSize(14), .consoleTheme(.dark), .parkHotkey("ctrl+opt+k"),
                                                  .foldHotkey("ctrl+opt+j")]
        let fileOnly: Set<String> = ["commandShell", "extraPath", "serverNames", "showText", "serverTimeZones", "sayHeadlines",
                                     "commands", "sandboxDenyFolders", "sandboxAllowSocketFolders", "profiles", "dashboards"]
        #expect(CodeSettings.fileOnlyKeys == fileOnly)
        for change in changes {
            let keys = Set(change.members(in: [:])?.keys.map { $0 } ?? [])
            #expect(!keys.isEmpty && keys.isDisjoint(with: fileOnly), "\(change)")
        }
        // dock.hosts is file-only inside `dock`: turning the link off keeps the hosts as the file has them.
        let object: [String: JSONValue] = ["dock": .object(["enabled": .bool(true), "hosts": .array([.string("com.example.host")])])]
        #expect(CodeSettings.MenuChange.dockEnabled(false).members(in: object)
            == ["dock": .object(["enabled": .bool(false), "hosts": .array([.string("com.example.host")])])])
        // Out of range: nothing written.
        for bad: CodeSettings.MenuChange in [.columns(3), .cellWidth(299), .consoleFontSize(80), .display("bad/display"),
                                             .parkHotkey(""), .peekDelaySeconds(9)] {
            #expect(bad.members(in: [:]) == nil, "\(bad)")
        }
    }

    @Test func aFileThatFailsTheCarefulReadIsNeverWritten() throws {
        let folder = SeamFolder("settings-bad")
        let url = folder.file("code-settings.json")
        // A link: neither followed nor replaced.
        let target = folder.file("elsewhere.json")
        try #"{"chime":false}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(CodeSettings.apply(.chime(true), at: url) == .failure(.unreadable("link")))
        #expect(try String(contentsOf: target, encoding: .utf8) == #"{"chime":false}"#)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil, "still a link")
        #expect(CodeSettings.loadOrCreate(at: url) == CodeSettings(), "a link gives the defaults")
        #expect(CodeSettings.WriteFailure.unreadable("link").message == "Can't change: the settings file couldn't be read")
        try FileManager.default.removeItem(at: url)

        for (label, text) in [("duplicate-key", #"{"chime":true,"chime":false}"#), ("not-object", "[1,2,3]"),
                              ("syntax", "{chime: yes}")] {
            try text.write(to: url, atomically: true, encoding: .utf8)
            #expect(CodeSettings.apply(.chime(true), at: url) == .failure(.unreadable(label)), "\(label)")
            #expect(try String(contentsOf: url, encoding: .utf8) == text, "\(label): untouched")
        }
        try Data(repeating: 0x20, count: CodeTuning.settingsReadMax + 1).write(to: url)
        #expect(CodeSettings.apply(.chime(true), at: url) == .failure(.unreadable("too-large")))
    }

    @Test func aMissingFileIsCreatedFromTheDefaultsAndANewFileOnlyByAnExclusiveCreate() throws {
        let folder = SeamFolder("settings-new")
        let url = folder.file("code-settings.json")
        let changed = try CodeSettings.apply(.look(.rows), at: url).get()
        #expect(changed.look == .rows && changed.chime == false)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["look"] as? String == "rows" && object["serverTimeZones"] != nil && object["commandShell"] as? String == "clean")
        try FileManager.default.removeItem(at: url)

        // loadOrCreate writes every key once, 0600; a dangling link is never written through.
        #expect(CodeSettings.loadOrCreate(at: url) == CodeSettings())
        let defaults = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in ["commandShell", "extraPath", "serverNames", "showText", "look", "deskWindows", "peekDelaySeconds", "deskTags",
                    "dragToPark", "chime", "sayIt", "sayHeadlines", "awayRecap", "recapAfterMinutes", "finishedMinMinutes",
                    "readyRecentHours", "warnings", "serverTimeZones"] {
            #expect(defaults[key] != nil, "\(key)")
        }
        #expect(CodeSettings.decode(try Data(contentsOf: url)) == CodeSettings())
        try FileManager.default.removeItem(at: url)
        let nowhere = folder.file("nowhere.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: nowhere)
        #expect(CodeSettings.loadOrCreate(at: url) == CodeSettings())
        #expect(!FileManager.default.fileExists(atPath: nowhere.path), "nothing written through the link")
    }
}
