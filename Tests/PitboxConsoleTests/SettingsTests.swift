import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

struct SettingsTests {
    @Test func defaultsAreWhatTheBriefAsksFor() {
        let s = TerminalSettings.standard
        #expect(s.fontName == "SF Mono" && s.fontSize == 13)
        #expect(s.scrollback == 10_000)
        #expect(s.autoRotate == false, "auto-rotate is off by default")
        #expect(s.optionAsMeta == false, "German layouts need Option for @ [ ] { } | ~")
        #expect(s.allowClipboardWrite == false)
        #expect(s.presets == [.builtInShell])
    }

    /// Every key with its default value, plus example presets (the old settings file's text, without its "about").
    static let fullSettingsJSON = """
    {
      "version": 1,
      "fontName": "SF Mono",
      "fontSize": 13,
      "scrollback": 10000,
      "backgroundOpacity": 0.65,
      "cursorStyle": "blinkBlock",
      "bell": "visual",
      "optionAsMeta": false,
      "onExit": "closeIfClean",
      "newTabLocation": "home",
      "autoRotate": false,
      "autoRotateSeconds": 20,
      "maxSessions": 10,
      "allowClipboardWrite": false,
      "allowSnapshots": false,
      "appearance": "system",
      "presets": [
        { "id": "shell", "name": "Shell" },
        { "id": "claude", "name": "Claude", "argv": ["claude"], "cwd": "~" },
        { "id": "monitor", "name": "Monitor", "script": "if command -v htop >/dev/null 2>&1; then exec htop; else exec top -o cpu; fi" },
        { "id": "ssh-example", "name": "SSH: edit me", "argv": ["ssh", "user@example.com"], "enabled": false }
      ]
    }
    """

    @Test func everyKeyAtItsDefaultParsesToTheDefaultsPlusExamples() throws {
        let parsed = try #require(TerminalSettings.parse(Data(Self.fullSettingsJSON.utf8)))
        #expect(parsed.warnings.isEmpty, "\(parsed.warnings)")
        let s = parsed.settings
        var expected = TerminalSettings.standard
        expected.presets = s.presets
        #expect(s == expected, "the object states the built-in defaults")
        #expect(s.presets.map(\.id) == ["shell", "claude", "monitor", "ssh-example"])
        #expect(s.enabledPresets.map(\.id) == ["shell", "claude", "monitor"], "the ssh example is disabled")
        #expect(s.preset(id: "claude")?.argv == ["claude"])
        #expect(s.preset(id: "monitor")?.kind == .script)
        #expect(s.preset(id: "ssh-example") == nil)
    }

    @Test func parsingIsTolerant() throws {
        let json = """
        { "fontSize": 200, "scrollback": "many", "bell": "loud", "optionAsMeta": true, "autoRotateSeconds": 1,
          "maxSessions": 99, "backgroundOpacity": 0.01, "shell": "zsh", "unknownKey": [1,2,3], "onExit": "keep",
          "presets": [ {"id":"a","name":"A","argv":["x"]}, 7, {"name":""}, {"id":"a","name":"dup"}, {"id":"Bad Id"},
                       {"id":"b","argv":[]}, {"id":"c","script":"echo hi","cwd":"~/x","env":{"OK":"1","1BAD":"x"}} ] }
        """
        let parsed = try #require(TerminalSettings.parse(Data(json.utf8)))
        let s = parsed.settings
        #expect(s.fontSize == 32, "clamped")
        #expect(s.scrollback == 10_000, "wrong type falls back")
        #expect(s.bell == .visual, "unknown enum value falls back")
        #expect(s.optionAsMeta == true && s.onExit == .keep)
        #expect(s.autoRotateSeconds == 3 && s.maxSessions == 24 && s.backgroundOpacity == 0.2)
        #expect(s.shell == nil, "relative shell paths are refused")
        #expect(s.presets.map(\.id) == ["shell", "a", "c"], "bad presets are skipped, the built-in shell is added")
        #expect(s.presets[2].env == ["OK": "1"] && s.presets[2].cwd == "~/x")
        #expect(parsed.warnings.count >= 8, "every problem is reported: \(parsed.warnings)")
    }

    @Test func appearanceCanBeFixedDarkOrLight() throws {
        #expect(TerminalSettings.standard.appearance == .system)
        for (text, expected) in [("dark", TerminalAppearance.dark), ("light", .light), ("system", .system)] {
            let parsed = try #require(TerminalSettings.parse(Data("{\"appearance\": \"\(text)\"}".utf8)))
            #expect(parsed.settings.appearance == expected && parsed.warnings.isEmpty)
        }
        let bad = try #require(TerminalSettings.parse(Data("{\"appearance\": \"black\"}".utf8)))
        #expect(bad.settings.appearance == .system && bad.warnings.contains { $0.hasPrefix("appearance:") })
    }

    @MainActor @Test func aFixedAppearanceDarkensTheWholeConsole() throws {
        let view = NSView()
        view.appearance = NSAppearance(named: .darkAqua)
        #expect(TerminalTheme.isDark(view.effectiveAppearance))
        view.appearance = NSAppearance(named: .aqua)
        #expect(!TerminalTheme.isDark(view.effectiveAppearance))
    }

    @Test func notJSONIsRejected() {
        #expect(TerminalSettings.parse(Data("not json".utf8)) == nil)
        #expect(TerminalSettings.parse(Data("[1,2]".utf8)) == nil)
    }

    @Test func presetKindsAndPrecedence() throws {
        var w: [String] = []
        let program = try #require(TerminalPreset.parse(["id": "p", "argv": ["ssh", "host"], "script": "ignored"], index: 0, warnings: &w))
        #expect(program.kind == .program && program.script == nil && w.count == 1, "argv wins over script")
        let script = try #require(TerminalPreset.parse(["name": "My Box (prod)", "script": "top"], index: 1, warnings: &w))
        #expect(script.id == "my-box-prod" && script.name == "My Box (prod)" && script.kind == .script)
        let shell = try #require(TerminalPreset.parse(["id": "s"], index: 2, warnings: &w))
        #expect(shell.kind == .shell && shell.enabled && shell.restore)
        #expect(TerminalPreset.parse(["id": "x", "argv": ["a\0b"]], index: 3, warnings: &w) == nil, "NUL in argv is refused")
        #expect(TerminalPreset.isValidID("a-b_9") && !TerminalPreset.isValidID("-a") && !TerminalPreset.isValidID(String(repeating: "a", count: 33)))
    }

    @Test func shellQuoteAndPathEscaping() {
        #expect(ShellQuote.quote("plain") == "'plain'")
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
        #expect(ShellQuote.join(["ssh", "-o", "A B", "$(rm -rf ~)"]) == "'ssh' '-o' 'A B' '$(rm -rf ~)'")
        #expect(ShellQuote.escapePath("/Users/me/My File (1).png") == #"/Users/me/My\ File\ \(1\).png"#)
        #expect(ShellQuote.escapePath("/tmp/a;b&c|d$e`f") == #"/tmp/a\;b\&c\|d\$e\`f"#)
        #expect(ShellQuote.escapePath("~/x") == #"\~/x"#, "a leading tilde must not expand")
        #expect(ShellQuote.escapePath("/tmp/café 日本") == #"/tmp/café\ 日本"#, "non-ASCII stays readable")
        #expect(ShellQuote.escapePath("/tmp/a\nb\u{1b}c") == "/tmp/abc", "control characters cannot be typed and are dropped")
    }
}

/// The console's settings are a value the app hands over (no settings file of its own); its own files (the tab list)
/// are private and trusted only when nobody else can change them.
@MainActor
struct ConsoleSettingsTests {
    @Test func theHostRunsWithTheSettingsItWasGivenAndWritesNoSettingsFile() throws {
        let h = ConsoleHarness(settingsJSON: #"{"fontSize": 20, "maxSessions": 2}"#)
        #expect(h.console.settings.fontSize == 20 && h.manager.settings.maxSessions == 2)
        #expect(try #require(h.selectedView).font.pointSize == 20)
        let settingsFile = h.dir.url.appendingPathComponent("settings.json")
        #expect(!FileManager.default.fileExists(atPath: settingsFile.path), "the console never writes a settings file")
    }

    @Test func anUpdateReachesTheManagerTheMenuAndNewTabs() throws {
        let h = ConsoleHarness()
        let first = try #require(h.selectedView)
        var next = testSettings(#"{"presets":[{"id":"only","name":"Only","argv":["htop"]}], "maxSessions": 3}"#)
        next.fontSize = 20
        next.appearance = .dark
        h.console.update(settings: next)
        #expect(h.manager.presetsForMenu().map(\.id) == ["shell", "only"], "new presets show in the menu")
        #expect(h.manager.settings == next && h.console.settings == next)
        #expect(h.view.appearance?.name == .darkAqua, "a fixed appearance applies at once")
        let second = try #require(h.manager.newSession())
        #expect(second.view.font.pointSize == 20, "new tabs use the new font size")
        #expect(first.font.pointSize == 13, "open tabs keep theirs")
        _ = h.manager.newSession()
        #expect(!h.manager.canCreateSession, "the new limit applies at once")
        next.appearance = .system
        h.console.update(settings: next)
        #expect(h.view.appearance == nil, "back to the system's appearance")
    }

    @Test func untrustedStateFilesAreNotUsed() throws {
        let state = SavedState(selected: 0, tabs: [.init(preset: "shell", cwd: "/tmp")])
        // Group/world-writable: whoever can write it could change which presets start.
        let dir = TempDir()
        state.save(to: dir.paths.stateFile)
        #expect(SavedState.load(from: dir.paths.stateFile) == state)
        chmod(dir.paths.stateFile.path, 0o666)
        #expect(SavedState.load(from: dir.paths.stateFile) == nil)

        // A symlink (even to a good file) is not followed.
        let other = TempDir()
        state.save(to: other.paths.stateFile)
        let linkDir = TempDir()
        try FileManager.default.createSymbolicLink(at: linkDir.paths.stateFile, withDestinationURL: other.paths.stateFile)
        #expect(SecureFile.trust(of: linkDir.paths.stateFile) == .untrusted("not a regular file"))
        #expect(SavedState.load(from: linkDir.paths.stateFile) == nil)

        // A file owned by someone else.
        let mine = TempDir()
        state.save(to: mine.paths.stateFile)
        #expect(SecureFile.trust(of: mine.paths.stateFile, uid: getuid() &+ 1) == .untrusted("owned by another user"))
        #expect(SavedState.load(from: mine.paths.stateFile, uid: getuid() &+ 1) == nil)
    }

    @Test func aFolderOthersCanWriteMakesTheFileUntrusted() throws {
        let dir = TempDir()
        SavedState(selected: 0, tabs: [.init(preset: "shell", cwd: nil)]).save(to: dir.paths.stateFile)
        chmod(dir.url.path, 0o777)
        defer { chmod(dir.url.path, 0o700) }
        #expect(SecureFile.trust(of: dir.paths.stateFile) == .untrusted("folder writable by group or others"))
        #expect(SavedState.load(from: dir.paths.stateFile) == nil)
    }

    @Test func aMissingFolderIsCreatedPrivately() throws {
        let dir = TempDir()
        let nested = TerminalPaths(directory: dir.url.appendingPathComponent("Application Support/Pitbox"))
        #expect(SecureFile.write(Data("{}".utf8), to: nested.stateFile))
        #expect(FileManager.default.fileExists(atPath: nested.stateFile.path))
        var info = stat()
        #expect(stat(nested.directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
    }

    @Test func secureFileWritesAtomicallyAndPrivately() throws {
        let dir = TempDir()
        let url = dir.url.appendingPathComponent("sub/state.json")
        #expect(SecureFile.write(Data("one".utf8), to: url))
        #expect(SecureFile.write(Data("two".utf8), to: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "two")
        var info = stat()
        #expect(stat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(SecureFile.trust(of: url) == .trusted)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["state.json"], "no temp files stay behind: \(leftovers)")
    }
}
