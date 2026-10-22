import AppKit
import Foundation
import Testing
@testable import Pitbox
@testable import PitboxDock
import PitboxKit
import PitboxSessions
@testable import PitboxShell

// The app's dock wiring (`DockWiring`) driven by a fake host over a real socket in a temporary folder: placement and
// the start order, the area and its seq, the host leaving, hiding, fold, look, focus, wake words, private folders, drop
// claims, attention, speech, the menu line, docking on and off, a socket that cannot be bound, quit. Invented data
// only. Time is the rig's manual clock; real time only bounds how long a test waits for a message that must come.

private func isArea(_ message: GuestMessage) -> Bool { if case .area = message { true } else { false } }
private func isAttention(_ message: GuestMessage) -> Bool { if case .attention = message { true } else { false } }
private func isBye(_ message: GuestMessage) -> Bool { if case .bye = message { true } else { false } }
private func isPing(_ message: GuestMessage) -> Bool { message == .ping }

private func areaFor(seq wanted: Int) -> (GuestMessage) -> Bool {
    { message in if case .area(seq: let seq, frame: _, folded: _, visible: _) = message { seq == wanted } else { false } }
}

private func isSpeech(_ message: GuestMessage) -> Bool {
    switch message {
    case .speechBegin, .speechEnd: return true
    default: return false
    }
}

private func isClaimLine(_ message: GuestMessage) -> Bool {
    switch message {
    case .claim, .release, .mouseUp: return true
    default: return false
    }
}

/// The guard region of a docked frame: Quartz coordinates on the host's display, the host's edge.
private func dockedRegion(_ frame: CGRect) -> ReservedRegion {
    ReservedRegion(displayID: 12, rect: ScreenSpace.quartz(fromAppKit: frame, primaryHeight: DockFixture.primaryHeight),
                   edge: .right)
}

/// A value a registry reads from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
@Suite("Dock wiring", .serialized)
struct DockWiringTests {
    // MARK: Start order and placement

    @Test func withoutARunningHostTheBlockShowsAloneAtOnce() throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        #expect(rig.folder.socketExists, "bound at launch, before the panel is shown")
        #expect(rig.shows == 0 && !rig.panel.isShown)
        rig.start()
        #expect(rig.shows == 1 && rig.panel.isVisible)
        #expect(rig.placementAtFirstShow == .alone && rig.panel.frame == DockFixture.aloneFrame)
        #expect(rig.wiring.menuLine == "No host app connected" && rig.wiring.hostName == nil)
    }

    @Test func aRunningHostIsWaitedForAndTheFirstShowIsBesideIt() async throws {
        let rig = try DockRig(running: [DockFixture.hostID])
        defer { rig.tearDown() }
        rig.start()
        #expect(rig.shows == 0, "a listed host app runs: wait for its place")
        #expect(rig.wiring.menuLine == "Waiting for the host app…")
        let host = try await rig.connect()
        rig.clock.advance(by: 0.9)
        #expect(rig.shows == 0)
        host.place(seq: 1)
        #expect(await host.next(where: isArea) == .area(seq: 1, frame: DockFixture.dockedFrame, folded: false, visible: true))
        #expect(rig.shows == 1, "shown once")
        #expect(rig.placementAtFirstShow?.isDocked == true, "no jump from the screen edge")
        #expect(rig.panel.frame == DockFixture.dockedFrame && rig.panel.isDockedNow && rig.panel.isVisible)
        // The guard's region is the block's, with the host's edge (it pushes toward the window side).
        #expect(rig.panel.regions == [dockedRegion(DockFixture.dockedFrame)])
        #expect(rig.panel.level == .aboveWindows)
        #expect(rig.wiring.menuLine == "Docked with Host" && rig.wiring.hostName == "Host")
        // The same place again: the area answers its seq, though nothing moved.
        host.place(seq: 2)
        #expect(await host.next(where: isArea) == .area(seq: 2, frame: DockFixture.dockedFrame, folded: false, visible: true))
        rig.clock.advance(by: 1)
        #expect(rig.shows == 1 && rig.panel.isDockedNow, "the start wait is over")
    }

    @Test func noPlaceWithinOneSecondShowsAloneAndWarnsAfterFive() throws {
        let rig = try DockRig(running: [DockFixture.hostID])
        defer { rig.tearDown() }
        rig.start()
        rig.clock.advance(by: 0.9)
        #expect(rig.shows == 0)
        rig.clock.advance(by: 0.1)
        #expect(rig.shows == 1 && rig.placementAtFirstShow == .alone && rig.panel.frame == DockFixture.aloneFrame)
        rig.clock.advance(by: 4)
        #expect(rig.wiring.menuLine
            == "The host app is running without dock support: two apps may park the same windows. Update or quit one")
    }

    @Test func aLevelBehindWindowsAndTheShellsPlace() {
        let place = HostPlace(seq: 4, displayID: 12, edge: .left, host: DockFixture.hostFrame, visible: false,
                              level: .behind, live: true, cell: .init(width: 322.7), maxWidth: 640)
        let docked = DockWiring.dockPlace(place)
        #expect(docked == DockPlace(hostFrame: DockFixture.hostFrame, displayID: 12, edge: .left,
                                    level: PanelLevel.desktop.windowLevel.rawValue, visible: false, live: true,
                                    cell: 322.7, maxWidth: 640))
        #expect(BlockPanelController.dockedLevel(docked.level) == .desktop)
        let above = DockWiring.dockPlace(HostPlace(seq: 1, displayID: 1, edge: .right, host: DockFixture.hostFrame,
                                                   cell: .init(width: 301.4)))
        #expect(BlockPanelController.dockedLevel(above.level) == .aboveWindows)
        #expect(DockWiring.blockAppearance(DockAppearance(scheme: .light, backdrop: .vibrancy))
            == BlockAppearance(scheme: .light, backdrop: .vibrancy))
        #expect(DockWiring.blockAppearance(.system) == .system)
    }

    // MARK: The host leaving, hiding, dragging

    @Test func theHostLeavingPutsTheBlockBackAtTheScreenEdgeWithinOneSecond() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock(wakeWords: ["hey host"])
        host.send(#"{"t":"appearance","scheme":"dark","backdrop":"solid"}"#)
        host.send(#"{"t":"focus","key":"Work"}"#)
        #expect(await eventually(2) { rig.focuses.last == "Work" })
        #expect(rig.panel.appearance == BlockAppearance(scheme: .dark, backdrop: .solid))
        #expect(rig.wakeWords == [["hey host"]])
        #expect(rig.panel.frame == DockFixture.dockedFrame)
        // The end of file alone puts the block back: the manual clock never moves here, so no timer is involved and
        // the 1 s rule holds however busy the machine is (real time only bounds the wait).
        let before = rig.clock.now()
        host.close()
        #expect(await eventually(10) { !rig.panel.isDockedNow })
        #expect(rig.clock.now() == before, "alone on the end of file, before any timer")
        #expect(rig.panel.placement == .alone && rig.panel.frame == DockFixture.aloneFrame && rig.panel.isVisible)
        #expect(rig.panel.regions.first?.edge == .right && rig.panel.regions.first?.rect.minX == DockFixture.aloneFrame.minX,
                "the guard keeps guarding the moved rectangle")
        #expect(rig.panel.appearance == .system)
        #expect(rig.focuses.last == .some(nil), "back to every session")
        #expect(rig.wakeWords.last == [])
        #expect(rig.shows == 1)
        #expect(rig.wiring.menuLine == "No host app connected")
    }

    @Test func theHostHidingItsStripHidesTheBlockUnlessTheUserShowsItAlone() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock()
        host.place(seq: 2, visible: false)
        #expect(await host.next(where: isArea) == .area(seq: 2, frame: DockFixture.dockedFrame, folded: false, visible: false))
        #expect(rig.panel.isHiddenByHost && !rig.panel.isVisible && rig.panel.regions.isEmpty)
        #expect(rig.wiring.hostRegion == nil && rig.wiring.dockedAreaFrame == nil)
        // The menu's Show: alone at the screen edge while the host hides its strip; no area meanwhile.
        rig.panel.toggle()
        #expect(rig.panel.showsAloneOverride && rig.panel.isVisible && rig.panel.frame == DockFixture.aloneFrame)
        #expect(await host.drain().filter(isArea).isEmpty, "the host would refuse a frame that is not beside it")
        // The host shows its strip again: back beside it, the area follows.
        host.place(seq: 3, visible: true)
        #expect(await host.next(where: isArea) == .area(seq: 3, frame: DockFixture.dockedFrame, folded: false, visible: true))
        #expect(!rig.panel.showsAloneOverride && rig.panel.isDockedNow && rig.panel.isVisible)
    }

    @Test func aLiveHostDragMovesThePanelButHoldsTheGuardRegion() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock()
        let before = rig.panel.regions
        #expect(before == [dockedRegion(DockFixture.dockedFrame)])
        let wider = CGRect(x: 23433, y: 98, width: 1687, height: 1312)
        let moved = CGRect(x: 22802, y: 98, width: 631, height: 1312)
        host.place(seq: 2, live: true, host: wider)
        #expect(await host.next(where: isArea) == .area(seq: 2, frame: moved, folded: false, visible: true))
        #expect(rig.panel.frame == moved && rig.panel.regions == before, "the region waits for the drag's end")
        host.place(seq: 3, host: wider)
        #expect(await host.next(where: isArea) == .area(seq: 3, frame: moved, folded: false, visible: true))
        #expect(rig.panel.regions == [dockedRegion(moved)])
    }

    // MARK: Fold, look, focus, wake words, private folders

    @Test func theHostsFoldFoldsAndUnfoldsTheBlock() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        var panelWrites: [Bool] = []
        rig.panel.onSettingsChanged = { panelWrites.append($0.folded) }
        let host = try await rig.dock()
        host.send(#"{"t":"fold","folded":true}"#)
        let rail = CGRect(x: 23509, y: 98, width: 24, height: 1312)
        #expect(await host.next(where: isArea) == .area(seq: 1, frame: rail, folded: true, visible: true))
        #expect(rig.panel.isFolded && rig.persistedFolds == [true], "folded is the one setting the link writes: at once")
        #expect(panelWrites.isEmpty, "the link writes it, not the panel's own change")
        #expect(rig.panel.regions == [dockedRegion(rail)])
        host.send(#"{"t":"fold","folded":false}"#)
        #expect(await host.next(where: isArea) == .area(seq: 1, frame: DockFixture.dockedFrame, folded: false, visible: true))
        #expect(!rig.panel.isFolded, "shown at once")
        #expect(rig.persistedFolds == [true], "written at most once a second")
        rig.clock.advance(by: 1)
        #expect(rig.persistedFolds == [true, false], "the held value goes out when the second ends")
    }

    @Test func aHostFoldingFastWritesTheSettingAtMostOnceASecondAndTheLastValueWins() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock()
        host.send(#"{"t":"fold","folded":true}"#)
        #expect(await eventually(10) { rig.panel.isFolded })
        #expect(rig.persistedFolds == [true])
        // Twenty folds in a burst, ending unfolded, then a focus as a marker that every line was handled.
        for k in 0..<20 { host.send(#"{"t":"fold","folded":\#(k % 2 == 1 ? "false" : "true")}"#) }
        host.send(#"{"t":"focus","key":"Globex"}"#)
        #expect(await eventually(10) { rig.focuses.last == "Globex" })
        #expect(!rig.panel.isFolded, "the panel follows every fold at once")
        #expect(rig.persistedFolds == [true], "nothing more within the second")
        rig.clock.advance(by: 1)
        #expect(rig.persistedFolds == [true, false], "one write for the burst: the last value")
        rig.clock.advance(by: 1)
        #expect(rig.persistedFolds == [true, false], "nothing held: nothing written")
        // Docking turned off while a fold is held: it is written at once, so the file says what the panel shows.
        host.send(#"{"t":"fold","folded":true}"#)
        #expect(await eventually(10) { rig.panel.isFolded })
        host.send(#"{"t":"fold","folded":false}"#)
        #expect(await eventually(10) { !rig.panel.isFolded })
        #expect(rig.persistedFolds == [true, false, true])
        rig.wiring.settingsChanged(CodeSettings.Dock(enabled: false, hosts: [DockFixture.hostID]))
        #expect(rig.persistedFolds == [true, false, true, false])
        rig.clock.advance(by: 2)
        #expect(rig.persistedFolds == [true, false, true, false])
    }

    @Test func lookAndFocusFollowTheHost() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock()
        host.send(#"{"t":"appearance","scheme":"light","backdrop":"vibrancy"}"#)
        host.send(#"{"t":"focus","key":"Globex"}"#)
        host.send(#"{"t":"focus","key":"all"}"#)
        #expect(await eventually(2) { rig.focuses.count == 2 })
        #expect(rig.focuses == ["Globex", nil])
        #expect(rig.panel.appearance == BlockAppearance(scheme: .light, backdrop: .vibrancy))
        // A change of focusProfiles maps the host's focus again; with "all" there is nothing to map.
        rig.wiring.focusProfilesChanged()
        #expect(rig.focuses == ["Globex", nil])
        host.send(#"{"t":"focus","key":"Globex"}"#)
        #expect(await eventually(2) { rig.focuses.count == 3 })
        rig.wiring.focusProfilesChanged()
        #expect(rig.focuses == ["Globex", nil, "Globex", "Globex"])
    }

    @Test func aVerifiedHostsWakeWordsAndPrivateFoldersReachTheBlockAndTheSandboxMemory() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.connect(wakeWords: ["hey host", "computer"],
                                         folders: ["/Users/alex/Library/Application Support/Host", "/Users/alex/Documents"],
                                         socketFolders: ["/private/tmp/host-runner-501", "/tmp"])
        #expect(await eventually(2) { !rig.remembered.isEmpty })
        #expect(rig.remembered.count == 1)
        #expect(rig.remembered.first?.folders == ["/Users/alex/Library/Application Support/Host"], "broad folders never")
        #expect(rig.remembered.first?.socketFolders == ["/private/tmp/host-runner-501"])
        #expect(rig.wakeWords == [["hey host", "computer"]])
        host.close()
        #expect(await eventually(2) { rig.wakeWords.count == 2 })
        #expect(rig.wakeWords.last == [] && rig.remembered.count == 1, "the memory is append-only: nothing taken back")
    }

    // MARK: Drop claims, attention

    @Test func dropClaimsAreMirroredOnlyWhileDockedWithTheFeature() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let button = Flag(true)
        let claims = WindowDropClaims(isLeftButtonDown: { button.value }, now: { 100 })
        claims.setClaimablePIDs([4242])
        rig.wiring.mirror(claims)
        // Alone: nothing to mirror.
        #expect(claims.claim(pid: 4242, windowNumber: 77))
        claims.release(pid: 4242, windowNumber: 77, parked: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        let host = try await rig.dock()
        #expect(claims.claim(pid: 4242, windowNumber: 77))
        claims.noteMouseUp()
        claims.release(pid: 4242, windowNumber: 77, parked: true)
        // Each line is read as it comes (a busy machine only makes the wait longer), then nothing else follows.
        #expect(await claimLines(host, 3)
            == [.claim(pid: 4242, windowNumber: 77), .mouseUp, .release(pid: 4242, windowNumber: 77, parked: true)])
        // A claim the guard's look dated (the button seen up) still sends the mouse-up.
        #expect(claims.claim(pid: 4242, windowNumber: 78))
        button.value = false
        _ = claims.holdRemaining(pid: 4242, windowNumber: 78)
        claims.setClaimablePIDs([])
        #expect(await claimLines(host, 3)
            == [.claim(pid: 4242, windowNumber: 78), .mouseUp, .release(pid: 4242, windowNumber: 78, parked: false)])
        #expect(await host.drain().filter(isClaimLine).isEmpty, "nothing more")
    }

    /// The next `count` claim lines, each awaited on its own (nil where one never came).
    private func claimLines(_ host: TestHost, _ count: Int) async -> [GuestMessage?] {
        var lines: [GuestMessage?] = []
        for _ in 0..<count { lines.append(await host.next(timeout: 10, where: isClaimLine)) }
        return lines
    }

    @Test func aHostWithoutGuardClaimsGetsNoClaims() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let claims = WindowDropClaims(isLeftButtonDown: { true }, now: { 100 })
        claims.setClaimablePIDs([4242])
        rig.wiring.mirror(claims)
        let host = try await rig.dock(features: ["appearance", "focus", "fold", "speech"])
        #expect(claims.claim(pid: 4242, windowNumber: 7))
        claims.noteMouseUp()
        claims.release(pid: 4242, windowNumber: 7, parked: true)
        #expect(await host.drain(timeout: 0.3).filter(isClaimLine).isEmpty)
    }

    @Test func attentionGoesToTheHostAtMostOnceASecond() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        rig.wiring.attentionChanged(needsYou: 1, finished: 0, running: 2)   // kept while alone
        let host = try await rig.connect()
        #expect(await host.next(where: isAttention) == .attention(needsYou: 1, finished: 0, running: 2),
                "the current counts once after the handshake")
        rig.wiring.attentionChanged(needsYou: 2, finished: 0, running: 2)
        rig.wiring.attentionChanged(needsYou: 3, finished: 1, running: 2)
        #expect(await host.drain().filter(isAttention).isEmpty, "not within the second")
        rig.clock.advance(by: 1)
        #expect(await host.next(where: isAttention) == .attention(needsYou: 3, finished: 1, running: 2), "the newest win")
        rig.clock.advance(by: 1)
        rig.wiring.attentionChanged(needsYou: 3, finished: 1, running: 2)
        #expect(await host.drain().filter(isAttention).isEmpty, "unchanged counts are not sent again")
    }

    // MARK: Speech

    @Test func dockedWithTheSpeechPauseTheLineSpeaksOnlyOnOK() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock()
        let gate = rig.wiring.speechGate

        let first = Task { await gate.begin() }
        guard case .speechBegin(let id)? = await host.next(where: isSpeech) else {
            Issue.record("no speech.begin")
            return
        }
        host.send(#"{"t":"speech.ok","id":\#(id)}"#)
        #expect(await first.value, "ok: speak")
        gate.end()
        #expect(await host.next(where: isSpeech) == .speechEnd(id: id))

        let second = Task { await gate.begin() }
        guard case .speechBegin(let refused)? = await host.next(where: isSpeech) else {
            Issue.record("no second speech.begin")
            return
        }
        host.send(#"{"t":"speech.no","id":\#(refused),"why":"talk"}"#)
        #expect(await second.value == false, "no: silent, the chime only")
        gate.end()
        #expect(await host.drain().filter(isSpeech).isEmpty, "nothing to end after a no")

        let third = Task { await gate.begin() }
        guard case .speechBegin? = await host.next(where: isSpeech) else {
            Issue.record("no third speech.begin")
            return
        }
        rig.clock.advance(by: 2)
        #expect(await third.value == false, "no answer within 2 s: silent")
    }

    @Test func dockedWithoutTheSpeechPauseTheLineStaysSilent() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock(features: ["appearance", "attention", "focus", "fold", "guard.claims"])
        #expect(await rig.wiring.beginSpeech() == false)
        rig.wiring.endSpeech()
        #expect(await host.drain().filter(isSpeech).isEmpty, "nothing is asked")
    }

    @Test func aloneTheLineSpeaksDirectly() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        #expect(await rig.wiring.beginSpeech(), "no listed host app runs")
        rig.apps.running = [DockFixture.hostID]
        #expect(await rig.wiring.beginSpeech() == false, "a listed host app runs undocked: it may be listening")
        let off = try DockRig(enabled: false)
        defer { off.tearDown() }
        off.start()
        #expect(await off.wiring.beginSpeech(), "docking off: nothing of a host listens")
    }

    @Test func theSpokenLineAsksTheGateAndEndsThroughIt() async {
        final class Counts {
            var begun = 0
            var ended = 0
        }
        let counts = Counts()
        let speech = ReadyPresence.speech(voice: nil, gate: SpeechGate(begin: { counts.begun += 1; return false },
                                                                       end: { counts.ended += 1 }))
        #expect(await speech.beginOwnSpeech() == false)
        speech.endOwnSpeech()
        #expect(counts.begun == 1 && counts.ended == 1)
        #expect(await SpeechGate.alone.begin())
    }

    // MARK: Menu

    @Test func theMenuLineNamesEachState() {
        let place = HostPlace(seq: 1, displayID: 12, edge: .right, host: DockFixture.hostFrame, cell: .init(width: 301.4))
        func line(_ state: DockGuestState?, warning: DockWarning? = nil, host: String? = "Host", connected: Bool = false,
                  enabled: Bool = true, hosts: [String] = [DockFixture.hostID]) -> String {
            DockWiring.menuLine(enabled: enabled, hosts: hosts, state: state, warning: warning, hostName: host,
                                connected: connected)
        }
        #expect(line(.docked(place, DockFeature.all)) == "Docked with Host")
        #expect(line(.waitingForHost, host: nil) == "Waiting for the host app…")
        #expect(line(.hostNotResponding(place, [])) == "Host not responding")
        #expect(line(.hostNotResponding(place, []), host: nil) == "The host app not responding")
        #expect(line(.refused(.version(ours: 1...1, theirs: 2...2)))
            == "Can't dock with Host: Pitbox speaks protocol 1, Host speaks 2")
        #expect(line(.alone, warning: .hostWithoutDockSupport)
            == "Host is running without dock support: two apps may park the same windows. Update or quit one")
        #expect(line(.alone, warning: .hostWithoutDockSupport, host: nil)
            == "The host app is running without dock support: two apps may park the same windows. Update or quit one")
        #expect(line(.alone, warning: .socketUnavailable) == "Dock unavailable: the socket could not be opened")
        #expect(line(.refused(.notListed(bundleID: "com.example.other")))
            == "An app (com.example.other) asked to dock but is not in dock.hosts in the settings file")
        #expect(line(.alone, connected: true) == "Connected to Host")
        #expect(line(.alone, hosts: []) == "No host app listed (dock.hosts in the settings file)")
        #expect(line(.alone) == "No host app connected")
        #expect(line(.alone, enabled: false) == "Off: Pitbox stays alone at the screen edge")
        #expect(line(nil, enabled: false) == "Off: Pitbox stays alone at the screen edge")
    }

    @Test func theMenuFollowsAHostThatStopsAnswering() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock()
        let changes = rig.stateChanges
        rig.clock.advance(by: 5)
        #expect(await host.next(where: isPing) == .ping)
        rig.clock.advance(by: 5)
        #expect(await host.next(where: isPing) == .ping)
        rig.clock.advance(by: 5)
        #expect(await eventually(2) { rig.wiring.menuLine == "Host not responding" })
        #expect(rig.stateChanges > changes, "the menu was told")
        #expect(rig.panel.isDockedNow && rig.panel.frame == DockFixture.dockedFrame, "the area is kept")
        #expect(await rig.wiring.beginSpeech() == false)
        host.send(#"{"t":"pong"}"#)
        #expect(await eventually(2) { rig.wiring.menuLine == "Docked with Host" })
    }

    @Test func aHostOfAnotherProtocolVersionIsNamedInTheMenu() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try TestHost(connectingTo: rig.folder.socketPath)
        guard case .hello? = await host.next() else {
            Issue.record("no guest hello")
            return
        }
        host.hello(app: "Host", proto: "[2,2]")
        #expect(await host.next(where: isBye) == .bye(.version))
        #expect(await eventually(2) { rig.wiring.menuLine == "Can't dock with Host: Pitbox speaks protocol 1, Host speaks 2" })
        #expect(!rig.panel.isDockedNow && rig.panel.frame == DockFixture.aloneFrame)
    }

    @Test func theMenuIsToldOfWhatItShowsNotOfEveryPlaceOfALiveDrag() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock()
        let told = rig.stateChanges
        // A live width drag: twenty places a few points apart, same display, edge, level and visibility.
        for k in 1...20 {
            let wider = CGRect(x: 23533 - CGFloat(k * 5), y: 98, width: 1587 + CGFloat(k * 5), height: 1312)
            host.place(seq: 1 + k, live: true, host: wider)
        }
        #expect(await host.next(timeout: 10, where: areaFor(seq: 21)) != nil)
        #expect(rig.stateChanges == told, "the frame alone is not in the menu")
        // Behind windows: the menu shows the level.
        host.place(seq: 22, level: "behind")
        #expect(await host.next(timeout: 10, where: areaFor(seq: 22)) != nil)
        #expect(rig.stateChanges == told + 1)
        // The host hides its strip: the menu says "Hidden with Host".
        host.place(seq: 23, visible: false, level: "behind")
        #expect(await host.next(timeout: 10, where: areaFor(seq: 23)) != nil)
        #expect(rig.stateChanges == told + 2)
    }

    @Test func theLiveListKeepsTheNewestAnnouncementsWithinItsBound() {
        let list = AnnouncedFolders(limit: 16)
        list.add(folders: (0..<12).map { "/private/tmp/a\($0)" }, socketFolders: ["/private/tmp/s0"])
        list.add(folders: (12..<20).map { "/private/tmp/a\($0)" } + ["/private/tmp/a3"], socketFolders: ["/private/tmp/s0"])
        let held = list.lists
        #expect(held.folders.count == 16, "the oldest went")
        #expect(held.folders.last == "/private/tmp/a3", "announced again: the newest")
        #expect(!held.folders.contains("/private/tmp/a0") && held.folders.contains("/private/tmp/a19"))
        #expect(held.socketFolders == ["/private/tmp/s0"], "each entry once")
        #expect(AnnouncedFolders().limit == 256 && AnnouncedFolders(limit: 2).limit == 16, "never below one hello's 16")
    }

    // MARK: Docking on and off, the host list, a socket that cannot be bound, quit

    @Test func dockingOffMeansNoSocketAndTheTickOpensAndClosesTheLinkLive() async throws {
        let rig = try DockRig(enabled: false)
        defer { rig.tearDown() }
        #expect(!rig.folder.socketExists && rig.wiring.listener == nil && rig.wiring.guest == nil)
        rig.start()
        #expect(rig.shows == 1 && rig.placementAtFirstShow == .alone, "off: shown alone at once")
        #expect(rig.wiring.menuLine == "Off: Pitbox stays alone at the screen edge")
        #expect((try? TestHost(connectingTo: rig.folder.socketPath)) == nil, "nothing listens")

        rig.wiring.settingsChanged(CodeSettings.Dock(enabled: true, hosts: [DockFixture.hostID]))
        #expect(rig.folder.socketExists && rig.wiring.guest != nil)
        let host = try await rig.dock()
        #expect(rig.panel.isDockedNow && rig.panel.frame == DockFixture.dockedFrame)
        host.send(#"{"t":"appearance","scheme":"dark","backdrop":"glass"}"#)
        #expect(await eventually(2) { rig.panel.appearance.scheme == .dark })

        rig.wiring.settingsChanged(CodeSettings.Dock(enabled: false, hosts: [DockFixture.hostID]))
        #expect(await host.next(where: isBye) == .bye(.settings))
        #expect(await host.waitForClose())
        #expect(!rig.folder.socketExists && rig.wiring.guest == nil && rig.wiring.listener == nil)
        #expect(rig.panel.placement == .alone && rig.panel.frame == DockFixture.aloneFrame && rig.panel.isVisible)
        #expect(rig.panel.appearance == .system)
        #expect(rig.shows == 1)
        #expect(await rig.wiring.beginSpeech(), "off: the line speaks directly")
        #expect(rig.wiring.menuLine == "Off: Pitbox stays alone at the screen edge")
    }

    @Test func aHostTakenOffTheListIsClosedAndTheListAppliesToTheNextConnection() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock()
        rig.wiring.settingsChanged(CodeSettings.Dock(enabled: true, hosts: ["com.example.other"]))
        #expect(await host.next(where: isBye) == .bye(.settings))
        #expect(await eventually(2) { !rig.panel.isDockedNow })
        #expect(rig.folder.socketExists, "still listening for listed hosts")
        let next = try TestHost(connectingTo: rig.folder.socketPath)
        #expect(await next.next(where: isBye) == .bye(.refused), "not listed any more")
        #expect(await eventually(2) {
            rig.wiring.menuLine == "An app (com.example.host) asked to dock but is not in dock.hosts in the settings file"
        })
    }

    @Test func aSocketThatCannotBeBoundIsTriedAgainWithBackoffWhileDockingIsOn() async throws {
        let rig = try DockRig(bind: false)
        defer { rig.tearDown() }
        // A file that is not a socket where `dock.sock` goes: the listener never removes one, so the bind fails.
        #expect(FileManager.default.createFile(atPath: rig.folder.socketPath, contents: Data("not a socket".utf8)))
        rig.wiring.bind(CodeSettings.Dock(enabled: true, hosts: [DockFixture.hostID]))
        rig.start()
        #expect(rig.shows == 1 && rig.placementAtFirstShow == .alone, "alone at once")
        #expect(rig.wiring.bindFailures == 1 && rig.wiring.listener?.isBound == false)
        #expect(rig.wiring.menuLine == "Dock unavailable: the socket could not be opened")
        // 1 s, then 2 s, then 4 s between tries.
        rig.clock.advance(by: 1)
        #expect(rig.wiring.bindFailures == 2)
        rig.clock.advance(by: 1.9)
        #expect(rig.wiring.bindFailures == 2, "the second retry waits 2 s")
        rig.clock.advance(by: 0.1)
        #expect(rig.wiring.bindFailures == 3)
        // The obstacle goes: the next try binds, a new guest takes over, the menu says so and a host can dock.
        try FileManager.default.removeItem(atPath: rig.folder.socketPath)
        let told = rig.stateChanges
        rig.clock.advance(by: 4)
        #expect(rig.wiring.bindFailures == 0 && rig.wiring.listener?.isBound == true && rig.folder.socketExists)
        #expect(rig.wiring.menuLine == "No host app connected")
        #expect(rig.stateChanges > told, "the menu was told")
        _ = try await rig.dock()
        #expect(rig.panel.isDockedNow && rig.panel.frame == DockFixture.dockedFrame)
        #expect(rig.shows == 1)
    }

    @Test func bindRetriesStopWhenDockingIsTurnedOffAndWaitAtMostAMinute() throws {
        let rig = try DockRig(bind: false)
        defer { rig.tearDown() }
        #expect(FileManager.default.createFile(atPath: rig.folder.socketPath, contents: Data("not a socket".utf8)))
        rig.wiring.bind(CodeSettings.Dock(enabled: true, hosts: [DockFixture.hostID]))
        rig.start()
        // 1 + 2 + 4 + 8 + 16 + 32 s, then a minute apart.
        rig.clock.advance(by: 63)
        #expect(rig.wiring.bindFailures == 7)
        rig.clock.advance(by: 59.9)
        #expect(rig.wiring.bindFailures == 7)
        rig.clock.advance(by: 0.1)
        #expect(rig.wiring.bindFailures == 8)
        rig.wiring.settingsChanged(CodeSettings.Dock(enabled: false, hosts: [DockFixture.hostID]))
        #expect(rig.wiring.bindFailures == 0 && rig.wiring.listener == nil)
        rig.clock.advance(by: 600)
        #expect(rig.wiring.bindFailures == 0 && rig.wiring.listener == nil, "off: no more tries")
        #expect(rig.wiring.menuLine == "Off: Pitbox stays alone at the screen edge")
    }

    @Test func quitSaysByeRemovesTheSocketAndLeavesThePanelWhereItIs() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        let host = try await rig.dock()
        rig.wiring.stop()
        #expect(await host.next(where: isBye) == .bye(.quit))
        #expect(!rig.folder.socketExists && rig.wiring.guest == nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.panel.isDockedNow && rig.panel.frame == DockFixture.dockedFrame, "the quit does not move the panel")
        rig.wiring.stop()
        #expect(rig.wiring.guest == nil, "a second stop does nothing")
    }

    // MARK: The docked area

    @Test func theDockedAreaCoversTheHostAndTheBlockWhileBothShow() async throws {
        let rig = try DockRig()
        defer { rig.tearDown() }
        rig.start()
        #expect(rig.wiring.hostRegion == nil && rig.wiring.dockedAreaFrame == nil, "alone")
        _ = try await rig.dock()
        #expect(rig.wiring.dockedAreaFrame == CGRect(x: 22902, y: 98, width: 2218, height: 1312))
        #expect(rig.wiring.hostRegion == ReservedRegion(displayID: 12, rect: CGRect(x: 23533, y: 30, width: 1587, height: 1312),
                                                        edge: .right))
        rig.panel.hide()
        #expect(rig.wiring.hostRegion == nil && rig.wiring.dockedAreaFrame == nil, "hidden")
    }
}
