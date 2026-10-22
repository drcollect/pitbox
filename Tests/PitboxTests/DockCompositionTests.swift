import AppKit
import Foundation
import Testing
@testable import Pitbox
@testable import PitboxConsole
@testable import PitboxDock
import PitboxKit
import PitboxSessions
@testable import PitboxShell

/// The composition root's dock glue over a scratch settings file and the dock rig: the file's `dock.enabled` decides
/// whether a socket exists, the menu's tick and a hand edit open and close the link, the menu shows the host's name and
/// the link's line, and docked the app's overlays keep out of the whole docked area. Invented data only.
@MainActor
@Suite("Composition root: the dock link", .serialized)
struct DockCompositionTests {
    @Test func theDockSettingOpensAndClosesTheLinkAndTheMenuFollows() async throws {
        let folder = ScratchFolder("dock")
        let app = try CompositionTests.app(folder, #"{"dock":{"enabled":false,"hosts":["com.example.host"]}}"#)
        let rig = try DockRig(bind: false)
        defer { rig.tearDown() }
        app.dock = rig.wiring
        app.panel = rig.panel
        app.dock.bind(app.settings.dock)   // as `launch()` does right after the lock
        #expect(!rig.folder.socketExists, "off in the file: no socket")
        var shown = 0
        app.dock.start(panel: rig.panel, targets: app.dockTargets(), whenPlaced: {
            shown += 1
            rig.panel.show()
        })
        #expect(shown == 1, "off: the panel shows at once")
        var state = app.menuState()
        #expect(!state.dockEnabled && state.hostName == nil)
        #expect(state.dockStatus == "Off: Pitbox stays alone at the screen edge")

        // The menu's tick writes `dock.enabled`; the hub's change opens the link.
        app.menuActions().setDockEnabled(true)
        #expect(app.settings.dock.enabled && rig.folder.socketExists)
        let host = try await rig.dock()
        state = app.menuState()
        #expect(state.dockEnabled && state.isDocked && state.hostName == "Host")
        #expect(state.dockStatus == "Docked with Host")
        #expect(app.dockedRegions == rig.panel.regions + [ReservedRegion(displayID: 12,
                                                                         rect: CGRect(x: 23533, y: 30, width: 1587, height: 1312),
                                                                         edge: .right)])
        #expect(app.blockFrameOnScreen == CGRect(x: 22902, y: 98, width: 2218, height: 1312), "beside the docked area")

        // A hand edit turns docking off: `bye` with `settings`, alone, no socket.
        try folder.write(#"{"dock":{"enabled":false,"hosts":["com.example.host"]}}"#, to: "settings.json")
        app.hub?.fileChanged()
        #expect(await host.next { if case .bye = $0 { true } else { false } } == .bye(.settings))
        #expect(!rig.folder.socketExists && !app.menuState().isDocked)
        #expect(app.dockedRegions == rig.panel.regions && app.blockFrameOnScreen == DockFixture.aloneFrame)
        #expect(shown == 1)
    }

    @Test func aHostsFocusAndWakeWordsReachTheBlockThroughTheApp() async throws {
        let folder = ScratchFolder("dock-block")
        let app = try CompositionTests.app(folder, #"""
        {"dock":{"enabled":true,"hosts":["com.example.host"]},"focusProfiles":{"Work":["B"]},
         "profiles":[{"folder":"Claude-Work","letter":"B","name":"Acme"}]}
        """#)
        let box = try #require(app.hub?.box)
        app.block = PitboxBlock(source: EngineProbe(settings: { box.value }), parker: IdleParker(),
                                presenter: RecordingSheet(), freshness: FreshFreshness(), settings: app.settings,
                                buckets: folder.file("code-buckets.json"), blockState: nil)
        let rig = try DockRig(bind: false)
        defer { rig.tearDown() }
        app.dock = rig.wiring
        app.panel = rig.panel
        app.dock.bind(app.settings.dock)
        app.dock.start(panel: rig.panel, targets: app.dockTargets(), whenPlaced: { rig.panel.show() })
        let host = try await rig.dock()
        #expect(app.block.focus == .all)
        host.send(#"{"t":"focus","key":"Work"}"#)
        #expect(await eventually(2) { app.block.focus != .all })
        #expect(app.block.focus == MonitorFocus.named("Work", in: app.settings))
        host.send(#"{"t":"focus","key":"all"}"#)
        #expect(await eventually(2) { app.block.focus == .all })
        host.send(#"{"t":"focus","key":"Unknown"}"#)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(app.block.focus == .all, "an unknown name shows everything")
    }

    /// A full sandbox memory never leaves a connected host's folders open: the next spawn's profile denies what the
    /// verified host announced although the memory's file is at its cap, through the memory (kept for this run) and
    /// through the dock link's live list.
    @Test func aFullSandboxMemoryStillDeniesTheConnectedHostsFolders() async throws {
        let folder = ScratchFolder("dock-sandbox")
        let app = try CompositionTests.app(folder, #"{"dock":{"enabled":true,"hosts":["com.example.host"]}}"#)
        let memory = SandboxMemory(file: folder.file("sandbox-memory.json"), home: "/Users/alex", limit: 2)
        memory.remember(folders: ["/private/tmp/pbx-old-1", "/private/tmp/pbx-old-2"],
                        socketFolders: ["/private/tmp/pbx-olds-1", "/private/tmp/pbx-olds-2"])
        app.sandboxMemory = memory
        let rig = try DockRig(bind: false)
        defer { rig.tearDown() }
        app.dock = rig.wiring
        app.panel = rig.panel
        app.dock.bind(app.settings.dock)
        app.dock.start(panel: rig.panel, targets: app.dockTargets(), whenPlaced: { rig.panel.show() })
        let hostFolder = "/Users/alex/Library/Application Support/Host"
        let hostSockets = "/private/tmp/host-runner-501"
        _ = try await rig.connect(folders: [hostFolder], socketFolders: [hostSockets])
        #expect(await eventually(10) { rig.wiring.announced.lists.folders == [hostFolder] })
        #expect(rig.wiring.announced.lists.socketFolders == [hostSockets])
        #expect(app.consoleInputs().announcedFolders() == rig.wiring.announced.lists, "the console reads the live list")
        let policy = ConsoleSeamFactory.sandboxPolicy(app.settings, memory: memory, announced: rig.wiring.announced.lists)
        let profile = try #require(CommandSandbox.profile(policy))
        #expect(profile.contains(#"(deny file-read* file-write* (subpath "\#(hostFolder)"))"#))
        #expect(profile.contains(#"(deny network-outbound (remote unix-socket (subpath "\#(hostSockets)")))"#))
        #expect(profile.contains(#"(deny file-read* file-write* (subpath "/private/tmp/pbx-old-2"))"#), "the known ones stay")
        // The memory keeps the new entries for this run; its file still holds the first two only.
        #expect(memory.folders.contains(hostFolder) && memory.socketFolders.contains(hostSockets))
        #expect(SandboxMemory(file: folder.file("sandbox-memory.json"), home: "/Users/alex", limit: 2).folders.count == 2)
        // A memory that knows nothing of the host still gives a profile that denies it, through the live list.
        let other = SandboxMemory(file: folder.file("other-memory.json"), home: "/Users/alex", limit: 0)
        let live = ConsoleSeamFactory.sandboxPolicy(app.settings, memory: other, announced: rig.wiring.announced.lists)
        #expect(live.announcedFolders == [hostFolder] && live.announcedSocketFolders == [hostSockets])
    }

    /// Docking turned off within a second of a host's held fold: the held `folded` is written from inside the settings
    /// change that closes the link, and the panel, the settings in force and the file end up agreeing.
    @Test func dockingOffWhileAHostFoldIsHeldLeavesThePanelAndTheFileAgreeing() async throws {
        let folder = ScratchFolder("dock-fold-off")
        let app = try CompositionTests.app(folder, #"{"dock":{"enabled":true,"hosts":["com.example.host"]}}"#)
        let rig = try DockRig(bind: false)
        defer { rig.tearDown() }
        app.dock = rig.wiring
        app.panel = rig.panel
        app.dock.bind(app.settings.dock)
        app.dock.start(panel: rig.panel, targets: app.dockTargets(), whenPlaced: { rig.panel.show() })
        let host = try await rig.dock()
        host.send(#"{"t":"fold","folded":true}"#)
        #expect(await eventually(10) { rig.panel.isFolded && app.settings.folded }, "the first fold is written at once")
        host.send(#"{"t":"fold","folded":false}"#)
        #expect(await eventually(10) { !rig.panel.isFolded })
        #expect(app.settings.folded && rig.wiring.foldWritePending, "the unfold is held (the manual clock stands still)")
        // The user turns docking off within the second.
        app.menuActions().setDockEnabled(false)
        #expect(!app.settings.dock.enabled)
        #expect(!rig.panel.isFolded, "the panel shows the host's last fold")
        #expect(!app.settings.folded && CodeSettings.read(at: folder.file("settings.json"))?.folded == false,
                "the file says what the panel shows")
        #expect(!rig.wiring.foldWritePending)
    }

    /// A guest past its 64 remembered entries still hands the verified host's whole announcement to the live list: the
    /// profile denies the new folders although neither the guest nor the memory remembers them.
    @Test func aGuestPastItsRememberCapStillPutsTheHostsFoldersInTheProfile() async throws {
        let folder = ScratchFolder("dock-guest-cap")
        let app = try CompositionTests.app(folder, #"{"dock":{"enabled":true,"hosts":["com.example.host"]}}"#)
        let memory = SandboxMemory(file: folder.file("sandbox-memory.json"), home: "/Users/alex")
        app.sandboxMemory = memory
        let rig = try DockRig(bind: false)
        defer { rig.tearDown() }
        app.dock = rig.wiring
        app.panel = rig.panel
        app.dock.bind(app.settings.dock)
        app.dock.start(panel: rig.panel, targets: app.dockTargets(), whenPlaced: { rig.panel.show() })
        let guest = try #require(rig.wiring.guest)
        guest.passedFolders = Set((0..<DockGuest.maxRememberedFolders).map { "/private/tmp/pbx-earlier-\($0)" })
        guest.passedSocketFolders = Set((0..<DockGuest.maxRememberedFolders).map { "/private/tmp/pbx-earlier-s\($0)" })
        let hostFolder = "/Users/alex/Library/Application Support/Host"
        let hostSockets = "/private/tmp/host-runner-501"
        _ = try await rig.connect(folders: [hostFolder], socketFolders: [hostSockets])
        #expect(await eventually(10) { rig.wiring.announced.lists.folders == [hostFolder] })
        #expect(guest.cappedFolders == 2, "the guest remembers neither")
        #expect(memory.folders.isEmpty && memory.socketFolders.isEmpty, "so the memory never heard of them")
        let policy = ConsoleSeamFactory.sandboxPolicy(app.settings, memory: memory, announced: app.consoleInputs().announcedFolders())
        let profile = try #require(CommandSandbox.profile(policy))
        #expect(profile.contains(#"(deny file-read* file-write* (subpath "\#(hostFolder)"))"#))
        #expect(profile.contains(#"(deny network-outbound (remote unix-socket (subpath "\#(hostSockets)")))"#))
    }
}
