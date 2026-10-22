import Foundation
import Testing
@testable import PitboxConsole

struct RestorePlannerTests {
    private func settings(_ json: String) -> TerminalSettings { TerminalSettings.parse(Data(json.utf8))!.settings }
    private let dirs: Set<String> = ["/Users/tester", "/Users/tester/proj", "/tmp"]

    @Test func nothingSavedMeansOneShell() {
        let plan = RestorePlanner.plan(saved: nil, settings: .standard, isDirectory: { dirs.contains($0) })
        #expect(plan.sessions == [.init(preset: .builtInShell, cwd: nil)] && plan.selected == 0)
        let empty = RestorePlanner.plan(saved: SavedState(), settings: .standard, isDirectory: { dirs.contains($0) })
        #expect(empty.sessions.count == 1)
    }

    @Test func shellsReturnInTheirLastFolderProgramsWhereThePresetSaysAndTheSelectionSurvives() {
        let s = settings(presetJSON())
        let saved = SavedState(selected: 2, tabs: [
            .init(preset: "shell", cwd: "/tmp"), .init(preset: "claude", cwd: "/somewhere/else"), .init(preset: "top", cwd: "/tmp"),
            .init(preset: "shell", cwd: "/Users/tester/proj"),
        ])
        let plan = RestorePlanner.plan(saved: saved, settings: s, isDirectory: { dirs.contains($0) })
        #expect(plan.sessions.map(\.preset.id) == ["shell", "claude", "top", "shell"])
        #expect(plan.sessions.map(\.cwd) == ["/tmp", nil, nil, "/Users/tester/proj"], "only plain shells use the saved folder")
        #expect(plan.selected == 2)
    }

    @Test func aFolderThatIsGoneFallsBackToHomeAndUnknownPresetsBecomeShells() {
        let s = settings(presetJSON())
        let saved = SavedState(selected: 0, tabs: [.init(preset: "shell", cwd: "/gone"), .init(preset: "deleted-preset", cwd: "/tmp"), .init(preset: "off", cwd: "/tmp")])
        let plan = RestorePlanner.plan(saved: saved, settings: s, isDirectory: { dirs.contains($0) })
        #expect(plan.sessions.map(\.preset.id) == ["shell", "shell", "shell"], "missing and disabled presets come back as shells")
        #expect(plan.sessions.map(\.cwd) == [nil, "/tmp", "/tmp"])
    }

    @Test func presetsThatOptOutAreNotRestoredAndTheSelectionAdjusts() {
        let s = settings(presetJSON())
        let saved = SavedState(selected: 2, tabs: [.init(preset: "once", cwd: nil), .init(preset: "shell", cwd: "/tmp"), .init(preset: "top", cwd: nil)])
        let plan = RestorePlanner.plan(saved: saved, settings: s, isDirectory: { dirs.contains($0) })
        #expect(plan.sessions.map(\.preset.id) == ["shell", "top"] && plan.selected == 1)
        let onlyOptOut = RestorePlanner.plan(saved: SavedState(selected: 0, tabs: [.init(preset: "once", cwd: nil)]), settings: s, isDirectory: { dirs.contains($0) })
        #expect(onlyOptOut.sessions.map(\.preset.id) == ["shell"], "never zero tabs")
    }

    @Test func theSessionLimitAndBadSelectionAreRespected() {
        let s = settings(#"{"maxSessions": 2}"#)
        let saved = SavedState(selected: 9, tabs: (0..<5).map { _ in .init(preset: "shell", cwd: "/tmp") })
        let plan = RestorePlanner.plan(saved: saved, settings: s, isDirectory: { dirs.contains($0) })
        #expect(plan.sessions.count == 2 && plan.selected == 0)
    }

    @Test func theSavedFileRoundTripsAndIsPrivate() throws {
        let dir = TempDir()
        let url = dir.paths.stateFile
        let state = SavedState(selected: 1, tabs: [.init(preset: "shell", cwd: "/tmp"), .init(preset: "claude", cwd: nil)])
        state.save(to: url)
        #expect(SavedState.load(from: url) == state)
        var info = stat()
        #expect(stat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(SavedState.load(from: dir.url.appendingPathComponent("missing.json")) == nil)
        dir.write("bad.json", "{ nope")
        #expect(SavedState.load(from: dir.url.appendingPathComponent("bad.json")) == nil)
        dir.write("world.json", #"{"version":1,"selected":0,"tabs":[{"preset":"shell"}]}"#, mode: 0o666)
        #expect(SavedState.load(from: dir.url.appendingPathComponent("world.json")) == nil, "a file others can write is not trusted")
        dir.write("future.json", #"{"version":2,"selected":0,"tabs":[]}"#)
        #expect(SavedState.load(from: dir.url.appendingPathComponent("future.json")) == nil, "unknown versions are ignored")
    }
}

@MainActor
struct RestoreThroughTheManagerTests {
    @Test func tabsComeBackAsFreshProcessesInTheirFolders() {
        let saved = SavedState(selected: 1, tabs: [.init(preset: "shell", cwd: "/tmp"), .init(preset: "claude", cwd: nil), .init(preset: "shell", cwd: "/gone-forever")])
        let h = ManagerHarness(settingsJSON: presetJSON(), saved: saved)
        #expect(h.ids == ["shell", "claude", "shell"] && h.selectedIndex == 1)
        #expect(h.processes.map(\.spec.cwd) == ["/tmp", "/Users/tester/proj", "/Users/tester"])
        #expect(h.processes[1].spec.argv == ["zsh", "-l", "-i", "-c", "exec 'claude'"])
        #expect(h.manager.sessions.filter(\.isSelected).count == 1 && h.manager.sessions[1].isSelected)
    }

    @Test func theTabListIsSavedAfterChangesWithADebounce() throws {
        let h = ManagerHarness()
        _ = h.manager.newSession()
        h.processes[1].changeDirectory("/tmp")
        h.manager.pollMetadata()
        #expect(SavedState.load(from: h.stateFile) == nil || SavedState.load(from: h.stateFile)?.tabs.count != 2, "not written yet: debounced")
        h.clock.advance(by: TerminalSessionManager.saveDelay + 0.1)
        let saved = try #require(SavedState.load(from: h.stateFile))
        #expect(saved.tabs == [.init(preset: "shell", cwd: "/Users/tester"), .init(preset: "shell", cwd: "/tmp")])
        #expect(saved.selected == 1)
        // A closed tab disappears from the file.
        _ = h.manager.requestClose(h.manager.sessions[0].id)
        h.clock.advance(by: TerminalSessionManager.saveDelay + 0.1)
        #expect(SavedState.load(from: h.stateFile)?.tabs == [.init(preset: "shell", cwd: "/tmp")])
    }

    @Test func aRestartOfTheAppRestoresWhatWasSaved() throws {
        let first = ManagerHarness()
        _ = first.manager.newSession()
        first.processes[0].changeDirectory("/tmp")
        first.manager.pollMetadata()
        first.manager.select(index: 0)
        first.manager.shutdown()
        let saved = try #require(SavedState.load(from: first.stateFile))

        let second = ManagerHarness(saved: saved)
        #expect(second.ids == ["shell", "shell"] && second.selectedIndex == 0)
        #expect(second.processes[0].spec.cwd == "/tmp" && second.processes[1].spec.cwd == "/Users/tester")
    }
}
