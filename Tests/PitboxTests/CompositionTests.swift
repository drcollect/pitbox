import AppKit
import Foundation
import Testing
@testable import Pitbox
import PitboxKit
import PitboxSessions
import PitboxShell

/// The composition root over scratch files and fakes, with a panel that is never shown (no window, no status item, no
/// guard, no hotkey, no login item): what the menu reads, how settings reach the panel and the engine, Launch at Login,
/// the second instance. The full launch needs Accessibility and the screen and is checked at the attended first launch.
@MainActor
@Suite("Composition root", .serialized)
struct CompositionTests {
    /// An app over a scratch settings file (`text`), its hub wired as `launch()` wires it, and a panel never shown.
    static func app(_ folder: ScratchFolder, _ text: String = "{}") throws -> PitboxApp {
        try folder.write(text, to: "settings.json")
        let app = PitboxApp()
        let hub = SettingsHub.load(url: folder.file("settings.json"))
        hub.onChange = { [weak app] old, new in app?.apply(old: old, new: new) }
        app.hub = hub
        app.panel = BlockPanelController(settings: SettingsBridge.blockSettings(hub.current))
        return app
    }

    /// A settings-window write of `warnings.*` and hand edits of `profiles`, `showText` and `serverNames`
    /// each reach the engine with the new value at the moment the block reloads it.
    @Test func settingsWindowWritesAndHandEditsReachTheEngine() async throws {
        let folder = ScratchFolder("h1")
        let app = try Self.app(folder)
        let box = try #require(app.hub?.box)
        let probe = EngineProbe(settings: { box.value })
        app.block = PitboxBlock(source: probe, parker: IdleParker(), presenter: RecordingSheet(), freshness: FreshFreshness(),
                                settings: app.settings, buckets: folder.file("code-buckets.json"), blockState: nil)
        let model = app.makeSettingsModel()
        #expect(model.setFlag(.warningsStuck, false))
        #expect(probe.seen.last?.warnings.stuck == false, "the engine reads the new value when it is reloaded")
        #expect(model.setFlag(.warningsSameFile, false))
        #expect(probe.seen.last?.warnings == CodeSettings.Warnings(stuck: false, sameFile: false))
        #expect(model.settings.warnings == CodeSettings.Warnings(stuck: false, sameFile: false))

        let hub = try #require(app.hub)
        hub.start(debounce: 0.05)
        defer { hub.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        try folder.write(#"""
        {"warnings":{"stuck":false,"sameFile":false},
         "profiles":[{"folder":"Claude-Work","letter":"B","name":"Acme"}],
         "showText":{"B":false},"serverNames":{"buildbox":["build"]}}
        """#, to: "settings.json")
        #expect(await eventually(15) { probe.seen.last?.profiles.count == 1 })
        let last = try #require(probe.seen.last)
        #expect(last.profiles.first?.name == "Acme")
        #expect(last.showText == ["B": false])
        #expect(last.serverNames == ["buildbox": ["build"]])
        #expect(last.warnings == CodeSettings.Warnings(stuck: false, sameFile: false), "the window's write stays")
        let reloads = probe.seen.count
        // A panel-only change (a fold) does not reload the engine.
        app.persist(BlockSettings(folded: true))
        #expect(probe.seen.count == reloads)
        #expect(app.settings.folded)
    }

    @Test func theMenuMirrorsThePanelAndTheSettings() throws {
        let folder = ScratchFolder("menu")
        let app = try Self.app(folder, #"{"columns":1,"folded":true,"edge":"left","topGap":100,"bottomGap":200,"keepAboveWindows":false}"#)
        app.loginStatus = .requiresApproval
        var state = app.menuState()
        #expect(!state.isVisible && !state.hiddenByHost && state.isFolded)
        #expect(state.columns == 1 && state.edge == .left && !state.keepAboveWindows)
        #expect(state.topGap == 100 && state.bottomGap == 200)
        #expect(!state.isDocked && state.displayUUID == nil)
        #expect(state.guardState == .off && state.guardDetail == nil, "no guard yet")
        #expect(state.dockEnabled && state.hostName == nil)
        #expect(state.dockStatus == "No host app listed (dock.hosts in the settings file)", "no link yet, no host listed")
        #expect(state.launchAtLogin == .requiresApproval, "the cached state, no XPC query")
        #expect(state.hotkeys.isEmpty && !state.hideText && state.doneOnTrack == 0 && state.inThePit == 0)
        #expect(app.write(.dockEnabled(false)))
        state = app.menuState()
        #expect(!state.dockEnabled && state.dockStatus == "Off: Pitbox stays alone at the screen edge")
        #expect(PitboxApp().menuState() == PitboxMenuState(), "nothing built yet: the defaults")
    }

    @Test func fileSettingsMoveThePanelWithoutWritingBack() throws {
        let folder = ScratchFolder("panel")
        let app = try Self.app(folder)
        var writes = 0
        app.panel.onSettingsChanged = { _ in writes += 1 }
        try folder.write(#"{"columns":1,"edge":"left","keepAboveWindows":false,"topGap":300}"#, to: "settings.json")
        app.hub?.fileChanged()
        #expect(app.settings.columns == 1 && app.settings.topGap == 300)
        #expect(app.panel.settings == SettingsBridge.blockSettings(app.settings))
        #expect(writes == 0, "a file change is applied, never written back")
        app.hub?.fileChanged()
        #expect(writes == 0)
    }

    /// The menu's Launch at Login always makes the system follow the click, also when the file already said so.
    @Test func launchAtLoginFollowsTheClickEvenWhenTheFileAgrees() throws {
        let folder = ScratchFolder("login")
        let app = try Self.app(folder, #"{"launchAtLogin":true}"#)
        var reconciled: [Bool] = []
        app.loginItem = LoginItemControl(status: { .disabled }, reconcile: { wanted in
            reconciled.append(wanted)
            return wanted ? .enabled : .disabled
        })
        app.setLaunchAtLogin(true)
        #expect(reconciled == [true], "the file already said true: the system is still made to match")
        #expect(app.loginStatus == .enabled)
        app.setLaunchAtLogin(false)
        #expect(reconciled == [true, false], "a change is reconciled once")
        #expect(app.settings.launchAtLogin == false && app.loginStatus == .disabled)
        // A hand edit of the key reconciles too.
        try folder.write(#"{"launchAtLogin":true}"#, to: "settings.json")
        app.hub?.fileChanged()
        #expect(reconciled == [true, false, true])
    }

    /// The login item (an XPC query) is read when the menu opens, at most once a second; the icon's refreshes
    /// never read it.
    @Test func theLoginItemIsReadAtMostOnceASecond() throws {
        let folder = ScratchFolder("login-cache")
        let app = try Self.app(folder)
        var reads = 0
        app.loginItem = LoginItemControl(status: { reads += 1; return .enabled }, reconcile: { _ in .enabled })
        app.menuWillOpen()
        app.menuWillOpen()
        #expect(reads == 1)
        _ = app.menuState()
        _ = app.menuState()
        #expect(reads == 1, "building the state never asks the system")
        app.loginStatusReadAt -= 2
        app.menuWillOpen()
        #expect(reads == 2 && app.menuState().launchAtLogin == .enabled)
    }

    /// A second instance logs what failed and quits on the next main-queue turn, building nothing.
    @Test func aSecondInstanceQuitsWithoutBuildingAnything() throws {
        let folder = ScratchFolder("second")
        let held = try SingleInstanceLock.acquire(in: folder.url).get()
        defer { held.release() }
        let app = PitboxApp()
        app.lockFolder = folder.url
        app.prepareFolders = {}
        var quits = 0
        app.quit = { quits += 1 }
        app.launch()
        #expect(quits == 1 && !app.launched)
        #expect(app.hub == nil && app.panel == nil && app.block == nil, "nothing built, nothing shown")
        #expect(app.dock.listener == nil && app.dock.guest == nil, "a second Pitbox never touches the dock socket")
        app.terminate()
        #expect(PitboxApp.lockFailureWords(.taken) == "lock taken by another Pitbox; quitting")
        #expect(PitboxApp.lockFailureWords(.unusable("errno 2")) == "cannot create the lock file (errno 2); quitting")
    }

    @Test func theConsoleNeverSeesAHiddenBlock() throws {
        let folder = ScratchFolder("console-view")
        let app = try Self.app(folder)
        #expect(!app.blockCanShowConsole, "not shown")
        var answers: [Bool] = []
        app.ensureBlockShown { answers.append($0) }
        #expect(answers == [false], "nothing to show: answered at once")
        let alone = BlockLayout(columns: 2, cell: 323, showsRail: false, folded: false, docked: false, windowSide: .left,
                                leftPadding: 16, rightPadding: 16)
        #expect(PitboxApp.foldButtonSide(alone) == .left, "alone at the right edge: the left corner")
        let docked = BlockLayout(columns: 2, cell: 323, showsRail: false, folded: false, docked: true, windowSide: .left,
                                 leftPadding: 16, rightPadding: 0)
        #expect(PitboxApp.foldButtonSide(docked) == .right, "docked: the host's side")
    }

    @Test func nothingIsTornDownBeforeALaunch() {
        let app = PitboxApp()
        app.terminate()
        #expect(!app.launched)
        app.syncVisibility()
        app.updateRows()
        app.updateRail()
        app.feedDeskTags()
        #expect(app.blockFrameOnScreen == nil)
    }
}
