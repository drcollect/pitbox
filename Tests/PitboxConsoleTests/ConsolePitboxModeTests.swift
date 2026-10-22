import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// Pitbox's console has no plain shells: it opens nothing at start, restores nothing, does not reopen a shell when the
/// last tab closes, writes no tab list, and its strip has no "+" or preset menu. Command, Type and "Open a terminal on
/// <host>" tabs stay. The terminal's own behaviour (the code the console was moved from) is still tested elsewhere
/// with `mode: .terminal`.
@MainActor
struct ConsolePitboxModeTests {
    @Test func theAppsHostIsPitboxsConsole() {
        let console = ConsoleHost(keyboardRequester: { _ in })
        #expect(console.mode == .pitbox, "the public initializer has no other mode")
    }

    @Test func nothingOpensAtStartAndNothingIsRestored() {
        let saved = SavedState(selected: 0, tabs: [.init(preset: "shell", cwd: "/tmp"), .init(preset: "claude", cwd: nil)])
        let h = ManagerHarness(settingsJSON: presetJSON(), saved: saved, mode: .pitbox)
        #expect(h.manager.sessions.isEmpty, "no shell at start and no saved shell tab comes back")
        #expect(h.processes.isEmpty, "nothing was started")
        #expect(h.manager.presetsForMenu().isEmpty)
        #expect(h.manager.newSession() == nil && h.manager.newSession(preset: TerminalPreset.builtInShell) == nil,
                "no plain shell can be opened")
        #expect(h.manager.sessions.isEmpty && h.processes.isEmpty)
    }

    @Test func theLastTabClosingLeavesTheConsoleEmptyAndNoTabListIsWritten() throws {
        let h = CommandConsoleHarness(mode: .pitbox)
        #expect(h.manager.sessions.isEmpty)
        try? FileManager.default.removeItem(at: h.dir.paths.stateFile)
        h.start(try h.request("echo hi"))
        let session = try #require(h.commandSessions.first)
        h.commands.processes[0].end(.exited(0))
        h.manager.closeNow(session.id)
        #expect(h.manager.sessions.isEmpty, "no default shell takes its place")
        #expect(h.launcher.processes.isEmpty, "no plain shell was ever started")
        h.clock.advance(by: 5)
        h.console.shutdown()
        #expect(!FileManager.default.fileExists(atPath: h.dir.paths.stateFile.path), "Pitbox's console writes no tab list")
    }

    @Test func commandTypeAndServerTabsStay() async throws {
        let h = CommandConsoleHarness(mode: .pitbox)
        h.start(try h.request("echo hi"))
        h.start(try h.request("echo typed", role: .typeIntoTerminal))
        let ssh = h.home.subfolder(".ssh")
        try Data("Host buildbox\n  HostName 192.0.2.10\n".utf8).write(to: ssh.appendingPathComponent("config"))
        chmod(ssh.appendingPathComponent("config").path, 0o600)
        #expect(await h.console.openServerTab(alias: "buildbox") == nil)
        #expect(h.manager.sessions.map(\.preset.commandRole) == [.run, .typeIntoTerminal, .server])
    }

    @Test func theStripHasNoNewTabControls() throws {
        let h = ConsoleHarness(mode: .pitbox)
        let strip = h.view.strip
        #expect(!strip.showsNewTabControls)
        #expect(strip.newFrame == .zero && strip.menuFrame == .zero)
        #expect(strip.viewport.maxX >= strip.bounds.width - 8 - 0.5, "the tabs take the room of the controls")
        for point in [CGPoint(x: strip.bounds.width - 10, y: strip.bounds.midY), CGPoint(x: strip.bounds.width - 40, y: strip.bounds.midY)] {
            #expect(strip.hit(at: point) == nil, "nothing to hit where + and the chevron were")
        }
        #expect(strip.contextMenu(for: .newSession) == nil && strip.contextMenu(for: .presetMenu) == nil)
        let labels = (strip.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(!labels.contains(TabStripView.ButtonLabel.newTab) && !labels.contains(TabStripView.ButtonLabel.menu),
                "VoiceOver finds no New Tab or Presets button")
        strip.activate(.newSession, at: .zero)
        strip.activate(.presetMenu, at: .zero)
        #expect(h.manager.sessions.isEmpty, "even a direct activation opens nothing")
    }

    @Test func cmdTIsNotTakenByPitboxsConsole() throws {
        let h = ConsoleHarness(mode: .pitbox)
        #expect(h.view.handle(.newSession) == false, "the key goes on unhandled")
        #expect(h.manager.sessions.isEmpty)
        let terminal = ConsoleHarness()
        #expect(terminal.view.handle(.newSession) == true)
        #expect(terminal.manager.sessions.count == 2, "the terminal's mode still opens a shell")
    }

    @Test func theTerminalsModeKeepsItsControls() {
        let h = ConsoleHarness()
        #expect(h.view.strip.showsNewTabControls)
        #expect(h.view.strip.newFrame.width > 0 && h.view.strip.menuFrame.width > 0)
    }

    /// A settings update applies the rotation interval at once, and rotation on or off when that setting changes (the
    /// strip's own toggle is the user's choice otherwise).
    @Test func anUpdateAppliesTheRotationSettings() {
        let h = ManagerHarness()
        _ = h.manager.newSession(); _ = h.manager.newSession()
        h.manager.select(index: 0)
        h.manager.update(settings: testSettings(#"{"autoRotate": true, "autoRotateSeconds": 5}"#))
        #expect(h.manager.autoRotate && h.manager.autoRotateInterval == 5)
        h.clock.advance(by: 5.5)
        #expect(h.selectedIndex == 1, "rotates on the new interval")
        h.manager.update(settings: testSettings(#"{"autoRotate": true, "autoRotateSeconds": 30}"#))
        #expect(h.manager.autoRotateInterval == 30)
        h.clock.advance(by: 10)
        #expect(h.selectedIndex == 1, "the longer interval holds")
        h.manager.setAutoRotate(false)   // the user's own toggle
        h.manager.update(settings: testSettings(#"{"autoRotate": true, "autoRotateSeconds": 20}"#))
        #expect(!h.manager.autoRotate, "an update that does not change the setting keeps the user's choice")
        h.manager.update(settings: testSettings(#"{"autoRotate": false, "autoRotateSeconds": 20}"#))
        #expect(!h.manager.autoRotate)
    }
}
