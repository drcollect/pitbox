import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The panel's keys and the warnings in `CodeSettings` (topGap, bottomGap, keepAboveWindows, launchAtLogin and their
/// `MenuChange` cases, plus `warningsStuck`/`warningsSameFile`), the read that never writes, and the watcher's
/// `noteWritten`. Behaviour as before the move into `CodeSettings`.
@Suite("Settings: the panel's keys", .serialized)
struct PanelKeysTests {
    static func file(_ text: String, in folder: SeamFolder) throws -> URL {
        let url = folder.file("settings.json")
        try CodeStateFiles.writeAtomically(Data(text.utf8), to: url)
        return url
    }

    static func object(_ url: URL) throws -> [String: JSONValue] {
        try CodeStateFiles.readObject(at: url, owner: getuid(), maxBytes: 1 << 20).get()
    }

    @Test func theKeysReadEachOnItsOwnWithTheirDefaults() {
        let defaults = CodeSettings()
        #expect(defaults.topGap == 0 && defaults.bottomGap == 0 && defaults.keepAboveWindows && !defaults.launchAtLogin)
        let good = CodeSettings.decode(Data(#"{"topGap":100,"bottomGap":250.5,"keepAboveWindows":false,"launchAtLogin":true}"#.utf8))
        #expect(good.topGap == 100 && good.bottomGap == 250.5 && !good.keepAboveWindows && good.launchAtLogin)
        let wrong = CodeSettings.decode(Data(#"{"topGap":601,"bottomGap":-1,"keepAboveWindows":"no","launchAtLogin":true,"chime":true}"#.utf8))
        #expect(wrong.topGap == 0 && wrong.bottomGap == 0 && wrong.keepAboveWindows, "a wrong value gives that key's default")
        #expect(wrong.launchAtLogin && wrong.chime, "and never costs the others")
        let keys: Set<String> = ["topGap", "bottomGap", "keepAboveWindows", "launchAtLogin"]
        #expect(keys.isDisjoint(with: CodeSettings.fileOnlyKeys))
        #expect(keys.isSubset(of: Set(defaults.jsonObject().keys)), "the defaults file names them")
        var custom = CodeSettings()
        custom.topGap = 200
        custom.launchAtLogin = true
        #expect(CodeSettings.decode(custom.encodedDefaults()) == custom)
    }

    @Test func eachKeyIsWrittenAndEverythingElseKept() throws {
        let folder = SeamFolder("panel-keys")
        let url = try Self.file(#"{"chime":true,"futureKey":{"a":[1,2]},"sandboxDenyFolders":["/opt/secret"]}"#, in: folder)
        let cases: [(CodeSettings.MenuChange, String, JSONValue)] = [
            (.topGap(100), "topGap", .number(100)),
            (.bottomGap(200.4), "bottomGap", .number(200)),
            (.keepAboveWindows(false), "keepAboveWindows", .bool(false)),
            (.launchAtLogin(true), "launchAtLogin", .bool(true)),
        ]
        for (change, key, value) in cases {
            let result = try CodeSettings.apply(change, at: url).get()
            let object = try Self.object(url)
            #expect(object[key] == value, "\(key)")
            #expect(object["futureKey"] == .object(["a": .array([.number(1), .number(2)])]), "unknown keys stay")
            #expect(object["sandboxDenyFolders"] == .array([.string("/opt/secret")]), "file-only keys stay as written")
            #expect(result.chime)
        }
        let final = try #require(CodeSettings.read(at: url))
        #expect(final.topGap == 100 && final.bottomGap == 200 && !final.keepAboveWindows && final.launchAtLogin)
        var st = stat()
        #expect(lstat(url.path, &st) == 0 && (st.st_mode & 0o777) == 0o600)
        #expect(folder.names == ["settings.json"], "no temporary file left behind")
    }

    @Test func warningsKeepTheirOtherMember() throws {
        let folder = SeamFolder("panel-warnings")
        let url = try Self.file(#"{"warnings":{"stuck":false,"sameFile":true}}"#, in: folder)
        #expect(try CodeSettings.apply(.warningsSameFile(false), at: url).get().warnings
                == CodeSettings.Warnings(stuck: false, sameFile: false))
        #expect(try CodeSettings.apply(.warningsStuck(true), at: url).get().warnings
                == CodeSettings.Warnings(stuck: true, sameFile: false))
        let fresh = SeamFolder("panel-warnings-new")
        let missing = fresh.file("settings.json")
        #expect(try CodeSettings.apply(.warningsStuck(false), at: missing).get().warnings
                == CodeSettings.Warnings(stuck: false, sameFile: true), "a missing member keeps its default")
    }

    @Test func badValuesAndUnreadableFilesWriteNothing() throws {
        let folder = SeamFolder("panel-refuse")
        let url = try Self.file(#"{"topGap":100}"#, in: folder)
        #expect(CodeSettings.apply(.topGap(601), at: url) == .failure(.invalidValue))
        #expect(CodeSettings.apply(.bottomGap(.nan), at: url) == .failure(.invalidValue))
        #expect(try Self.object(url)["topGap"] == .number(100))
        let broken = Data(#"{"topGap":100,"#.utf8)
        try broken.write(to: url)
        guard case .failure(.unreadable) = CodeSettings.apply(.topGap(200), at: url) else {
            Issue.record("a broken file must not be written")
            return
        }
        #expect(try Data(contentsOf: url) == broken, "the broken file is left exactly as it was")
    }

    @Test func noChangeCanWriteAFileOnlyKey() {
        let defaults = CodeSettings().jsonObject()
        let all: [CodeSettings.MenuChange] = [
            .look(.rows), .deskWindows(.monitors), .peekDelaySeconds(0.4), .readyRecentHours(6), .chime(true),
            .sayIt(true), .awayRecap(afterMinutes: 30), .dragToPark(false), .deskTags(false), .columns(1),
            .folded(true), .edge(.left), .display("main"), .cellWidth(340), .dockEnabled(false), .consoleFontSize(14),
            .consoleTheme(.dark), .parkHotkey("ctrl+opt+k"), .foldHotkey("ctrl+opt+j"), .warningsStuck(false),
            .warningsSameFile(false), .topGap(10), .bottomGap(10), .keepAboveWindows(false), .launchAtLogin(true),
        ]
        for change in all {
            let members = change.members(in: defaults) ?? [:]
            #expect(!members.isEmpty, "\(change)")
            #expect(Set(members.keys).isDisjoint(with: CodeSettings.fileOnlyKeys), "\(change)")
        }
    }

    @Test func readingNeverWrites() throws {
        let folder = SeamFolder("panel-read")
        let missing = folder.file("settings.json")
        #expect(CodeSettings.read(at: missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        try Data(#"{"topGap":100,"topGap":200}"#.utf8).write(to: missing)
        #expect(CodeSettings.read(at: missing) == nil, "a duplicated key fails the careful read")
    }

    /// The app's own write is noted: the watcher does not hand it out again, and a hand edit that puts a key back right
    /// after it is still reported.
    @Test func aNotedWriteIsNotReportedButAHandEditAfterItIs() async throws {
        let folder = SeamFolder("panel-noted")
        let url = folder.file("settings.json")
        try SettingsWatcherTests.writeInPlace(#"{"chime":false}"#, to: url)
        let changes = Shared<[CodeSettings]>([])
        let watcher = CodeSettingsWatcher(url: url, initial: CodeSettings(), debounce: 0.05) { changes.value.append($0) }
        watcher.start()
        defer { watcher.stop() }
        await SettingsWatcherTests.settle(watcher)
        let written = try CodeSettings.apply(.chime(true), at: url).get()
        watcher.noteWritten(written)
        try await Task.sleep(nanoseconds: 300_000_000)
        await SettingsWatcherTests.settle(watcher)
        #expect(changes.value.isEmpty, "the app's own write is not handed out again")
        // A hand edit puts chime back to what the watcher saw before the app's write.
        try SettingsWatcherTests.writeInPlace(#"{"chime":false}"#, to: url)
        #expect(await eventually(15) { changes.value.last?.chime == false })
    }
}
