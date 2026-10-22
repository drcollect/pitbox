import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

// The settings file's new keys and its place (`Paths.settingsFile`). Invented values only.

@Suite("Settings: the new keys")
struct SettingsKeysTests {
    @Test func theFileIsSettingsJsonInTheAppSupportFolder() {
        #expect(CodeSettings.fileURL == Paths.settingsFile)
        #expect(CodeSettings.fileURL.lastPathComponent == "settings.json")
    }

    @Test func everyNewKeyHasItsDefault() {
        let s = CodeSettings()
        #expect(s.columns == 2 && !s.folded && s.edge == .right && s.display == "main" && s.cellWidth == 323)
        #expect(s.dock == CodeSettings.Dock(enabled: true, hosts: []))
        #expect(s.profiles.isEmpty && s.focusProfiles.isEmpty && s.dashboards.isEmpty && s.neverSay.isEmpty)
        #expect(s.commands == .copyOnly && s.sandboxDenyFolders.isEmpty && s.sandboxAllowSocketFolders.isEmpty)
        #expect(s.console == CodeSettings.Console(fontSize: 12, theme: .system))
        #expect(s.hotkeys == CodeSettings.Hotkeys(park: "ctrl+opt+p", fold: "ctrl+opt+c"))
        // No private value is a default any more: no server names or zones, every running copy's text shown.
        #expect(s.serverNames.isEmpty && s.serverTimeZones.isEmpty && s.showText.isEmpty)
    }

    @Test func theNewKeysReadEachOnItsOwn() {
        let all = CodeSettings.decode(Data(#"""
        {"columns":1,"folded":true,"edge":"left","display":"37D8832A-2D66-02CA-B9F7-8F30A301B230","cellWidth":340,
         "dock":{"enabled":false,"hosts":["com.example.host"]},
         "profiles":[{"folder":"Claude-Work","letter":"B","name":"Acme","colour":"#E05A47"}],
         "focusProfiles":{"Acme":["A"],"Globex":["B","C"]},
         "dashboards":[{"host":"dash.example.com","pathPrefix":"/dash/","handlePattern":"[a-z]+-[a-z]+"}],
         "neverSay":["Nova"],"commands":"run","sandboxDenyFolders":["~/Secrets","/Volumes/Vault"],
         "sandboxAllowSocketFolders":["/Users/alex/Library/Application Support/Tool"],
         "console":{"fontSize":14,"theme":"dark"},"hotkeys":{"park":"ctrl+opt+k","fold":"ctrl+opt+j"}}
        """#.utf8))
        #expect(all.columns == 1 && all.folded && all.edge == .left && all.cellWidth == 340)
        #expect(all.display == "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        #expect(all.dock == CodeSettings.Dock(enabled: false, hosts: ["com.example.host"]))
        #expect(all.profiles == [CodeSettings.Profile(folder: "Claude-Work", letter: "B", name: "Acme", colour: 0xE05A47)])
        #expect(all.focusProfiles == ["Acme": ["A"], "Globex": ["B", "C"]])
        #expect(all.dashboards == [CodeSettings.Dashboard(host: "dash.example.com", pathPrefix: "/dash/",
                                                         handlePattern: "[a-z]+-[a-z]+")])
        #expect(all.neverSay == ["Nova"] && all.commands == .run)
        #expect(all.sandboxDenyFolders == ["~/Secrets", "/Volumes/Vault"])
        #expect(all.sandboxAllowSocketFolders == ["/Users/alex/Library/Application Support/Tool"])
        #expect(all.console == CodeSettings.Console(fontSize: 14, theme: .dark))
        #expect(all.hotkeys == CodeSettings.Hotkeys(park: "ctrl+opt+k", fold: "ctrl+opt+j"))
    }

    @Test func aWrongValueGivesThatKeysDefaultAndKeepsTheOthers() {
        let wrong = CodeSettings.decode(Data(#"""
        {"columns":3,"folded":"yes","edge":"top","display":"bad/display","cellWidth":200,
         "dock":{"enabled":"no","hosts":["com.example.host","not a bundle id",7]},
         "neverSay":["", "12", "Nova", "Nova"],"commands":"always","sandboxDenyFolders":["relative/x","/ok",3],
         "console":{"fontSize":200,"theme":"dark"},"hotkeys":{"park":"","fold":"ctrl+opt+j"},
         "chime":true}
        """#.utf8))
        let defaults = CodeSettings()
        #expect(wrong.columns == defaults.columns && wrong.folded == defaults.folded && wrong.edge == defaults.edge)
        #expect(wrong.display == defaults.display && wrong.cellWidth == defaults.cellWidth)
        #expect(wrong.dock == CodeSettings.Dock(enabled: true, hosts: ["com.example.host"]), "each member on its own")
        #expect(wrong.neverSay == ["Nova"], "no empty word, no word without letters, no duplicate")
        #expect(wrong.commands == .copyOnly, "an unknown commands value never opens Run")
        #expect(wrong.sandboxDenyFolders == ["/ok"])
        #expect(wrong.console == CodeSettings.Console(fontSize: 12, theme: .dark))
        #expect(wrong.hotkeys == CodeSettings.Hotkeys(park: "ctrl+opt+p", fold: "ctrl+opt+j"))
        #expect(wrong.chime, "a good old key next to wrong new ones is kept")
        // A whole key of the wrong type is its default.
        let types = CodeSettings.decode(Data(#"{"dock":true,"profiles":{},"dashboards":"x","focusProfiles":[1],"console":3}"#.utf8))
        #expect(types == CodeSettings())
    }

    @Test func listedCopiesAreCheckedOneByOne() {
        let s = CodeSettings.decode(Data(#"""
        {"profiles":[
          {"folder":"Claude-Work","letter":"B","name":"Acme"},
          {"folder":"Claude-Lab","letter":"B","name":"Same letter"},
          {"folder":"claude-work","letter":"D","name":"Same folder, other case"},
          {"folder":"Claude","letter":"E","name":"The default folder"},
          {"folder":"../Elsewhere","letter":"F"},
          {"folder":".hidden","letter":"G"},
          {"folder":"Claude-Lab","letter":"A","name":"The default letter"},
          {"folder":"Claude-Lab","letter":"?"},
          {"folder":"Claude-Lab","letter":"h"},
          {"folder":"Claude-Lab","letter":"C","colour":"not a colour"},
          {"folder":"Claude-Side","letter":"D","name":"  Globex\u0007  "},
          "not an object"
        ]}
        """#.utf8))
        #expect(s.profiles.map(\.letter) == ["B", "C", "D"])
        #expect(s.profiles.map(\.folder) == ["Claude-Work", "Claude-Lab", "Claude-Side"])
        #expect(s.profiles[1].name == "Claude-Lab" && s.profiles[1].colour == nil, "no name: the folder; a bad colour: none")
        #expect(s.profiles[2].name == "Globex", "plain text on one line")
        let profiles = CodeProfiles(s)
        #expect(profiles.known.map(\.name) == ["A · Claude", "B · Acme", "C · Claude-Lab", "D · Globex"])
    }

    @Test func dashboardSitesAndFocusNamesAreChecked() {
        let s = CodeSettings.decode(Data(#"""
        {"dashboards":[{"host":"dash.example.com","pathPrefix":"/dash/"},{"host":"dash.example.com","pathPrefix":"/dash/"},
                       {"host":"board.example.org"},{"host":"Bad.Example.com"},{"host":"dash.example.com","pathPrefix":"dash"},
                       {"host":"x.example.net","handlePattern":"("}],
         "focusProfiles":{"  Acme ":["A","b","Z","A"],"all":["A"],"":["B"]}}
        """#.utf8))
        #expect(s.dashboards == [CodeSettings.Dashboard(host: "dash.example.com", pathPrefix: "/dash/"),
                                 CodeSettings.Dashboard(host: "board.example.org", pathPrefix: "/")])
        #expect(CodeDashboardSites(s).all.map(\.key) == ["dash.example.com/dash/", "board.example.org/"])
        #expect(s.focusProfiles == ["Acme": ["A", "Z"]], "trimmed names, capital letters, never the name all")
    }

    @Test func deskTagsIsTheKeyAndOlderFilesStillRead() throws {
        // Files written before the rename say `jTags`; `deskTags` wins when both are present; the app writes `deskTags`.
        #expect(!CodeSettings.decode(Data(#"{"jTags":false}"#.utf8)).deskTags)
        #expect(!CodeSettings.decode(Data(#"{"deskTags":false}"#.utf8)).deskTags)
        #expect(CodeSettings.decode(Data(#"{"deskTags":true,"jTags":false}"#.utf8)).deskTags)
        let folder = SeamFolder("settings-desktags")
        let url = folder.file("settings.json")
        #expect(CodeSettings.loadOrCreate(at: url) == CodeSettings())
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["deskTags"] != nil && object["jTags"] == nil)
    }

    @Test func theDefaultsFileHoldsEveryKeyAndReadsBackTheSame() throws {
        let folder = SeamFolder("settings-defaults")
        let url = folder.file("settings.json")
        #expect(CodeSettings.loadOrCreate(at: url) == CodeSettings())
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in ["columns", "folded", "edge", "display", "cellWidth", "dock", "profiles", "focusProfiles", "dashboards",
                    "neverSay", "commands", "sandboxDenyFolders", "sandboxAllowSocketFolders", "console", "hotkeys",
                    "deskTags", "showText", "serverNames", "serverTimeZones", "dragToPark"] {
            #expect(object[key] != nil, "\(key)")
        }
        #expect(CodeSettings.loadOrCreate(at: url) == CodeSettings())
        // A full round trip of non-default values.
        var custom = CodeSettings.withTestProfiles
        custom.profiles[0].colour = 0x0A0B0C
        custom.dashboards = [CodeSettings.Dashboard(host: "dash.example.com", pathPrefix: "/dash/", handlePattern: "[a-z-]+")]
        custom.dock = CodeSettings.Dock(enabled: false, hosts: ["com.example.host"])
        custom.edge = .left
        custom.commands = .run
        #expect(CodeSettings.decode(custom.encodedDefaults()) == custom)
    }

    @Test func theMenuWritesNestedKeysAndKeepsTheRest() throws {
        let folder = SeamFolder("settings-nested")
        let url = folder.file("settings.json")
        try Data(#"{"dock":{"enabled":true,"hosts":["com.example.host"],"later":1},"profiles":[{"folder":"Claude-Work","letter":"B"}],"x":2}"#.utf8)
            .write(to: url)
        chmod(url.path, 0o600)
        let written = try CodeSettings.apply(.dockEnabled(false), at: url).get()
        #expect(written.dock == CodeSettings.Dock(enabled: false, hosts: ["com.example.host"]))
        #expect(written.profiles.map(\.folder) == ["Claude-Work"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let dock = try #require(object["dock"] as? [String: Any])
        #expect(dock["later"] as? Int == 1 && object["x"] as? Int == 2, "unknown members and keys stay")
        _ = CodeSettings.apply(.columns(1), at: url)
        _ = CodeSettings.apply(.parkHotkey("ctrl+opt+k"), at: url)
        let read = CodeSettings.loadOrCreate(at: url)
        #expect(read.columns == 1 && read.hotkeys == CodeSettings.Hotkeys(park: "ctrl+opt+k", fold: "ctrl+opt+c"))
        #expect(CodeSettings.apply(.cellWidth(400), at: url) == .failure(.invalidValue))
    }
}
