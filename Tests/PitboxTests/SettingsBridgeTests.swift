import AppKit
import Foundation
import Testing
@testable import Pitbox
import PitboxGuard
import PitboxKit
import PitboxSessions
import PitboxShell

/// The pure parts of the composition root: settings ↔ panel, rows and strip width, labels and words.
@Suite("Settings bridge and metrics")
struct SettingsBridgeTests {
    @Test func thePanelTakesItsSettingsFromTheFile() {
        var s = CodeSettings()
        #expect(SettingsBridge.blockSettings(s) == BlockSettings())
        s.columns = 1
        s.folded = true
        s.edge = .left
        s.display = "AAAA-1111"
        s.cellWidth = 340
        s.topGap = 100
        s.bottomGap = 200
        s.keepAboveWindows = false
        let block = SettingsBridge.blockSettings(s)
        #expect(block == BlockSettings(columns: 1, folded: true, edge: .left, displayUUID: "AAAA-1111", cellWidth: 340,
                                       topGap: 100, bottomGap: 200, keepAboveWindows: false))
        #expect(block.hideInFullscreen, "not a setting: always on")
    }

    @Test func aPanelChangeBecomesOneWritePerKey() {
        let old = BlockSettings()
        #expect(SettingsBridge.changes(from: old, to: old).isEmpty)
        var new = old
        new.folded = true
        #expect(SettingsBridge.changes(from: old, to: new) == [.folded(true)])
        new = old
        new.displayUUID = "BBBB-2222"
        #expect(SettingsBridge.changes(from: old, to: new) == [.display("BBBB-2222")])
        #expect(SettingsBridge.changes(from: new, to: old) == [.display("main")], "nil is the main display")
        new = BlockSettings(columns: 1, folded: false, edge: .left, displayUUID: nil, cellWidth: 300, topGap: 100,
                            bottomGap: 200, keepAboveWindows: false)
        #expect(SettingsBridge.changes(from: old, to: new) == [
            .columns(1), .edge(.left), .cellWidth(300), .topGap(100), .bottomGap(200), .keepAboveWindows(false),
        ])
    }

    @Test func writingThePanelsChangesGivesThePanelsSettingsBack() throws {
        let folder = SingleInstanceLockTests.folder("bridge")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("settings.json")
        let wanted = BlockSettings(columns: 1, folded: true, edge: .left, displayUUID: "CCCC-3333", cellWidth: 350,
                                   topGap: 300, bottomGap: 100, keepAboveWindows: false)
        var last = CodeSettings()
        for change in SettingsBridge.changes(from: BlockSettings(), to: wanted) {
            last = try CodeSettings.apply(change, at: url).get()
        }
        #expect(SettingsBridge.blockSettings(last) == wanted)
        #expect(SettingsBridge.blockSettings(try #require(CodeSettings.read(at: url))) == wanted)
    }

    @Test func shellOnlyChangesDoNotReachTheSessions() {
        let base = CodeSettings()
        var shellOnly = base
        shellOnly.columns = 1
        shellOnly.folded = true
        shellOnly.edge = .left
        shellOnly.display = "AAAA-1111"
        shellOnly.cellWidth = 300
        shellOnly.hotkeys.park = "ctrl+opt+k"
        shellOnly.console.fontSize = 20
        shellOnly.dock.enabled = false
        shellOnly.topGap = 200
        shellOnly.keepAboveWindows = false
        shellOnly.launchAtLogin = true
        #expect(SettingsBridge.sessionsPart(shellOnly) == SettingsBridge.sessionsPart(base))
        var sessions = base
        sessions.chime = true
        #expect(SettingsBridge.sessionsPart(sessions) != SettingsBridge.sessionsPart(base))
        sessions = base
        sessions.deskTags = false
        #expect(SettingsBridge.sessionsPart(sessions) != SettingsBridge.sessionsPart(base))
        // The run policy reaches the block too (its Ready cards and offers word Run or Review by it).
        sessions = base
        sessions.commands = .run
        #expect(SettingsBridge.sessionsPart(sessions) != SettingsBridge.sessionsPart(base))
        // The console's keys.
        var console = base
        #expect(SettingsBridge.consolePart(console) == SettingsBridge.consolePart(base))
        console.console.theme = .dark
        #expect(SettingsBridge.consolePart(console) != SettingsBridge.consolePart(base))
        console = base
        console.sandboxDenyFolders = ["/opt/secret"]
        #expect(SettingsBridge.consolePart(console) != SettingsBridge.consolePart(base))
        console = base
        console.chime = true
        #expect(SettingsBridge.consolePart(console) == SettingsBridge.consolePart(base))
    }

    @Test func rowsComeFromThePanelsHeight() {
        // 16 pt above and below: (h − 32 + 12) / 81 rows.
        #expect(BlockMetrics.rows(panelHeight: 1000, drawerHeight: 0, verticalPadding: 16) == 12)
        #expect(BlockMetrics.rows(panelHeight: 900, drawerHeight: 0, verticalPadding: 16) == 10)
        // A 312 pt drawer and its gutter take 324 pt.
        #expect(BlockMetrics.rows(panelHeight: 1000, drawerHeight: 312, verticalPadding: 16) == 8)
        #expect(BlockMetrics.rows(panelHeight: 0, drawerHeight: 0, verticalPadding: 16) == 1)
        #expect(BlockMetrics.rows(panelHeight: 50, drawerHeight: 0, verticalPadding: 16) == 1)
        #expect(BlockMetrics.rows(panelHeight: .nan, drawerHeight: 0, verticalPadding: 16) == 1)
        #expect(BlockMetrics.rows(panelHeight: 1000, drawerHeight: .infinity, verticalPadding: 16) == 12)
    }

    @Test func theStripWidthGivesTheMonitorsThePanelsCell() throws {
        for (columns, cell) in [(2, 323.0), (1, 323.0), (2, 300.0), (2, 360.0), (2, 301.4), (1, 350.0)] {
            let layout = BlockLayout(columns: columns, cell: cell, showsRail: false, folded: false, docked: false,
                                     windowSide: .left, leftPadding: 16, rightPadding: 16)
            let width = try #require(BlockMetrics.stripWidth(for: layout))
            #expect(abs(GridMetrics.cellWidth(forStripWidth: width) - cell) < 0.01, "\(columns) × \(cell)")
        }
        let alone = BlockLayout(columns: 2, cell: 323, showsRail: false, folded: false, docked: false, windowSide: .left,
                                leftPadding: 16, rightPadding: 16)
        #expect(BlockMetrics.stripWidth(for: alone) == 690)
        let rail = BlockLayout(columns: 0, cell: 323, showsRail: true, folded: true, docked: false, windowSide: .left,
                               leftPadding: 0, rightPadding: 0)
        #expect(BlockMetrics.stripWidth(for: rail) == nil)
        let narrowHost = BlockLayout(columns: 2, cell: 240, showsRail: false, folded: false, docked: true, windowSide: .left,
                                     leftPadding: 16, rightPadding: 0)
        #expect(BlockMetrics.stripWidth(for: narrowHost) == nil, "a cell under 300 pt: the view's own width decides")
    }

    @Test func labelsAndWords() throws {
        #expect(AppWords.parkLabel(.parked) == "parked")
        #expect(AppWords.parkLabel(.failed(reason: "a reason that may hold words")) == "failed", "never the reason")
        #expect(AppWords.parkLabel(.noAccessibility) == "needs Accessibility")
        #expect(AppWords.guardMenu(nil) == (.off, nil))
        #expect(AppWords.guardMenu(GuardStatus(trusted: false, running: true)) == (.needsAccessibility, nil))
        #expect(AppWords.guardMenu(GuardStatus(trusted: true, running: true, paused: true)) == (.paused, nil))
        #expect(AppWords.guardMenu(GuardStatus(trusted: true, running: true)) == (.on, nil))
        #expect(AppWords.guardMenu(GuardStatus(trusted: true, running: true, correctedCount: 1)) == (.on, "1 window moved"))
        #expect(AppWords.guardMenu(GuardStatus(trusted: true, running: true, correctedCount: 3)) == (.on, "3 windows moved"))
        #expect(AppWords.guardMenu(GuardStatus(trusted: true, running: false)) == (.off, nil))
        #expect(AppWords.hotkeyProblem("ctrl+opt+p") == nil)
        #expect(AppWords.hotkeyProblem("ctrl+opt+nosuchkey")?.hasPrefix("Not a shortcut") == true)
        #expect(AppWords.hotkeyStatus(nil) == nil)
    }

    @MainActor
    @Test func aKeyThatDoesNotParseIsReportedWithoutRegisteringAnything() {
        // The text fails to parse, so nothing reaches Carbon.
        let manager = HotkeyManager()
        manager.register(id: "park", spec: "ctrl+opt+nosuchkey", exclusiveCheck: true) {}
        let line = AppWords.hotkeyStatus(manager.registrations["park"])
        #expect(line?.hasPrefix("ctrl+opt+nosuchkey unavailable") == true)
        manager.unregisterAll()
    }
}
