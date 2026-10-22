import CoreGraphics
import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxDock

@MainActor
@Suite struct DockGuestStartTests {
    @Test func withoutAHostAppTheGuestIsAloneAtOnce() throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        #expect(h.guest.state == .alone)
        #expect(h.places == [nil], "one alone placement, from inside start()")
        #expect(h.guest.statusLine == "No host app connected")
    }

    @Test func aRunningHostThatPlacesWithinOneSecondDocksWithoutAJump() async throws {
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock, running: ["com.example.host"])
        defer { h.tearDown() }
        h.start()
        #expect(h.guest.state == .waitingForHost)
        #expect(h.places.isEmpty, "nothing shown yet")
        #expect(h.guest.statusLine == "Waiting for the host app…")
        let host = try await h.connect(app: "Host")
        clock.advance(by: 0.5)
        host.send(.place(FakeHost.place(seq: 4)))
        #expect(await waitUntil { h.guest.state.isDocked })
        #expect(h.places == [FakeHost.place(seq: 4)], "the first placement is the docked one")
        clock.advance(by: 5)
        #expect(h.places.count == 1, "the start timer was cancelled")
        #expect(h.guest.warning == nil)
        #expect(h.guest.statusLine == "Docked with Host")
    }

    @Test func aRunningHostWithoutPlaceIsLeftAfterOneSecondAndWarnedAfterFive() async throws {
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock, running: ["com.example.host"])
        defer { h.tearDown() }
        h.start()
        clock.advance(by: 0.99)
        #expect(h.places.isEmpty)
        clock.advance(by: 0.01)
        #expect(h.guest.state == .alone)
        #expect(h.places == [nil], "alone after 1 s")
        clock.advance(by: 3.9)
        #expect(h.guest.warning == nil)
        clock.advance(by: 0.1)
        #expect(h.guest.warning == .hostWithoutDockSupport)
        #expect(h.guest.statusLine == "The host app is running without dock support: two apps may park the same windows. Update or quit one")
        #expect(await h.guest.requestSpeech() == .no(.notDocked), "a host app may be listening: no voice")

        // The host connects late: it still docks, and the warning goes.
        let host = try await h.dock(place: FakeHost.place(seq: 9))
        _ = host
        #expect(h.guest.state.place?.seq == 9)
        #expect(h.guest.warning == nil)
        #expect(h.places == [nil, FakeHost.place(seq: 9)])
    }

    @Test func aHostThatConnectsLateStillDocks() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        #expect(h.places == [nil])
        try await Task.sleep(nanoseconds: 50_000_000)
        let host = try await h.dock()
        _ = host
        #expect(h.guest.state.isDocked)
        #expect(h.places == [nil, FakeHost.place()])
    }

    @Test func aHostAppThatLaunchesWithoutConnectingIsWarnedAboutAfterFiveSeconds() async throws {
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock)
        defer { h.tearDown() }
        h.start()
        h.apps.launch("com.example.unlisted")
        clock.advance(by: 6)
        #expect(h.guest.warning == nil, "only listed hosts count")
        h.apps.launch("com.example.host")
        clock.advance(by: 4.9)
        #expect(h.guest.warning == nil)
        clock.advance(by: 0.1)
        #expect(h.guest.warning == .hostWithoutDockSupport)
        h.apps.quit("com.example.host")
        #expect(h.guest.warning == nil, "the warning goes with the app")
    }
}

@MainActor
@Suite struct DockGuestLinkTests {
    @Test func placeCarriesLiveAndVisibleThrough() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        host.send(.place(FakeHost.place(seq: 2, live: true)))
        host.send(.place(FakeHost.place(seq: 3, live: true, host: CGRect(x: 3500, y: 98, width: 1620, height: 1312))))
        host.send(.place(FakeHost.place(seq: 4, live: false, host: CGRect(x: 3500, y: 98, width: 1620, height: 1312))))
        host.send(.place(FakeHost.place(seq: 5, visible: false)))
        #expect(await waitUntil { h.places.count == 6 })
        #expect(h.places.compactMap { $0?.live } == [false, true, true, false, false],
                "the live flag reaches the panel so it holds the guard region mid-drag")
        #expect(h.places.last??.visible == false, "the host hides its strip: the guest hides too")
        #expect(h.guest.state.isDocked, "hidden is still docked")
    }

    @Test func theHostsLookFocusFoldAndWordsArrive() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let folders = HostPrivateFolders(folders: ["/Users/alex/Library/Application Support/Host"],
                                         socketFolders: ["/private/tmp/host-runner-501"])
        let host = try await h.dock(wakeWords: ["hey host"], privateFolders: folders)
        #expect(h.wakeWords == [["hey host"]])
        #expect(h.privateFolders == [folders], "after the checks and the handshake, once")
        host.send(.appearance(DockAppearance(scheme: .dark, backdrop: .vibrancy)))
        host.send(.focus(.named("Acme")))
        host.send(.focus(.all))
        host.send(.fold(true))
        host.send(.fold(false))
        #expect(await waitUntil { h.folds.count == 2 })
        #expect(h.appearances == [DockAppearance(scheme: .dark, backdrop: .vibrancy)])
        #expect(h.focuses == [.named("Acme"), .all])
        #expect(h.folds == [true, false])

        host.send(.bye(.quit))
        #expect(await waitUntil { h.guest.state == .alone })
        #expect(h.appearances.last == .system)
        #expect(h.focuses.last == .all)
        #expect(h.wakeWords.last == [])
        #expect(h.places.last == .some(nil))
        #expect(h.privateFolders == [folders], "remembered by the app; nothing is taken back")
    }

    @Test func endOfFileGoesAloneWithinOneSecond() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        var host: FakeHost? = try await h.dock()
        #expect(host != nil)
        let began = Date()
        host = nil  // closes the socket
        #expect(await waitUntil(timeout: 1) { h.guest.state == .alone })
        #expect(Date().timeIntervalSince(began) < 1)
        #expect(h.guest.lastEndReason == .endOfFile)
        #expect(h.places.last == .some(nil))
    }

    @Test func killNineOfTheHostProcessGoesAloneWithinOneSecond() async throws {
        // The host's socket stays open in this process; only its process dies: kqueue NOTE_EXIT alone must notice.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier
        let h = try GuestHarness(inspector: FakeInspector(passingFacts(pid: pid)))
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        #expect(h.guest.state.isDocked)
        let began = Date()
        #expect(kill(pid, SIGKILL) == 0)
        #expect(await waitUntil(timeout: 1) { h.guest.state == .alone })
        #expect(Date().timeIntervalSince(began) < 1)
        #expect(h.guest.lastEndReason == .processExited)
        _ = host
        child.waitUntilExit()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/nc"), "needs nc -U"))
    func aRealHostProcessKilledWithNineGoesAloneWithinOneSecond() async throws {
        // A real process holds the host's end of the socket: LOCAL_PEERPID names it, and kill -9 ends it.
        let inspector = RealPeerFakeBundleInspector()
        let h = try GuestHarness(inspector: inspector)
        defer { h.tearDown() }
        h.start()
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-U", h.folder.socketPath]
        let input = Pipe()
        let output = Pipe()
        nc.standardInput = input
        nc.standardOutput = output
        nc.standardError = FileHandle.nullDevice
        try nc.run()
        defer { if nc.isRunning { nc.terminate() } }
        input.fileHandleForWriting.write(DockWire.encode(FakeHost.hello()))
        input.fileHandleForWriting.write(DockWire.encode(.place(FakeHost.place())))
        #expect(await waitUntil(timeout: 3) { h.guest.state.isDocked })
        #expect(inspector.inspected.first?.pid == nc.processIdentifier, "LOCAL_PEERPID names the real peer")
        #expect(inspector.inspected.first?.uid == getuid())
        let began = Date()
        #expect(kill(nc.processIdentifier, SIGKILL) == 0)
        #expect(await waitUntil(timeout: 1) { h.guest.state == .alone })
        #expect(Date().timeIntervalSince(began) < 1)
        nc.waitUntilExit()
        try? input.fileHandleForWriting.close()
    }

    @Test func aHungHostKeepsTheAreaAndIsNotRespondingAfterFifteenSeconds() async throws {
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock)
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        let place = FakeHost.place()
        clock.advance(by: 4.9)
        #expect(await host.next(timeout: 0.05) == nil, "no ping before 5 s of silence")
        clock.advance(by: 0.1)
        #expect(await host.next() == .ping)
        clock.advance(by: 5)
        #expect(await host.next() == .ping, "again every 5 s while silent")
        clock.advance(by: 4.9)
        #expect(await waitUntil(timeout: 0.1) { h.guest.state == .hostNotResponding(place, DockFeature.all) } == false)
        clock.advance(by: 0.1)
        #expect(await waitUntil { h.guest.state == .hostNotResponding(place, DockFeature.all) })
        #expect(h.guest.statusLine == "Host not responding")
        #expect(h.places == [nil, place], "the area is kept: no alone placement while the process lives")
        #expect(await h.guest.requestSpeech() == .no(.hostNotResponding))
        clock.advance(by: 120)
        #expect(h.guest.state == .hostNotResponding(place, DockFeature.all), "never dropped for silence alone")

        host.send(.pong)
        #expect(await waitUntil { h.guest.state == .docked(place, DockFeature.all) })
    }

    @Test func aSleepOfTheMacIsNeverTakenForAHang() async throws {
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock)
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        let place = FakeHost.place()
        clock.advance(by: 5)
        #expect(await host.next() == .ping, "a ping is outstanding when the Mac goes to sleep")
        clock.jump(by: 3600)
        #expect(await host.next() == .ping, "after the wake: a fresh ping")
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(h.guest.state == .docked(place, DockFeature.all), "not declared hung on waking")
        clock.advance(by: 9.9)
        #expect(h.guest.state == .docked(place, DockFeature.all))
        clock.advance(by: 0.1)
        #expect(await waitUntil { h.guest.state == .hostNotResponding(place, DockFeature.all) },
                "a host that stays silent 10 s after the fresh ping is not responding")
    }

    @Test func pingsAreAnswered() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        host.send(.ping)
        #expect(await host.next(where: { $0 == .pong }) == .pong)
    }

    @Test func areaAnswersThePlaceOnce() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock(place: FakeHost.place(seq: 7))
        let frame = CGRect(x: 2902, y: 98, width: 631, height: 1312)
        h.guest.sendArea(frame: frame, folded: false, visible: true)
        h.guest.sendArea(frame: frame, folded: false, visible: true)
        #expect(await host.next() == .area(seq: 7, frame: frame, folded: false, visible: true))
        host.send(.place(FakeHost.place(seq: 8)))
        #expect(await waitUntil { h.guest.state.place?.seq == 8 })
        h.guest.sendArea(frame: frame, folded: false, visible: true)
        #expect(await host.next() == .area(seq: 8, frame: frame, folded: false, visible: true), "the same frame answers a new place")
        h.guest.sendArea(frame: CGRect(x: 3509, y: 98, width: 24, height: 1312), folded: true, visible: true)
        #expect(await host.next() == .area(seq: 8, frame: CGRect(x: 3509, y: 98, width: 24, height: 1312), folded: true, visible: true))
        h.guest.sendArea(frame: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1), folded: false, visible: true)
        host.send(.ping)
        #expect(await host.next() == .pong, "a non-finite frame is never sent")
    }

    @Test func theGuestPacesItsOwnLinesAndKeepsOnlyTheNewestArea() async throws {
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock)
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        // 40 areas at one instant: a burst of 25 lines at most (the hello took one), the rest waits as one newest area.
        for step in 1...40 {
            h.guest.sendArea(frame: CGRect(x: 2902, y: 98, width: 600 + CGFloat(step), height: 1312), folded: false, visible: true)
        }
        // Read the expected burst with a generous deadline, then check nothing more comes.
        var burst: [GuestMessage] = []
        let deadline = Date().addingTimeInterval(2)
        while burst.count < DockSession.sendBurst - 1, Date() < deadline, let message = await host.next(timeout: 0.5) {
            burst.append(message)
        }
        #expect(burst.count == DockSession.sendBurst - 1)
        #expect(await host.next(timeout: 0.1) == nil, "the rest waits for the bucket (the clock stands still)")
        clock.advance(by: 1)
        #expect(await host.next() == .area(seq: 1, frame: CGRect(x: 2902, y: 98, width: 640, height: 1312), folded: false,
                                           visible: true), "the newest of the held areas, once")
        #expect(await host.next(timeout: 0.1) == nil)
    }

    @Test func aSecondSessionThatRacesTheFirstGetsBusy() async throws {
        // A session handed over while the guest still holds the previous one is told `busy`, not `refused`.
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let first = try await h.dock()
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let started = try #require(ProcessAncestry.identity(of: getpid())?.started)
        let racing = DockSession(id: 999, fd: fds[0], host: VerifiedHost(pid: getpid(), started: started,
                                                                         bundleID: "com.example.host"),
                                 hello: DockGuestHello(build: "test", features: DockFeature.all), clock: SystemDockClock.shared)
        racing.start()
        h.guest.attach(racing)
        let other = FakeHost(adopting: fds[1])
        let lines = await other.remainingMessages()
        #expect(lines.count == 2 && lines.last == .busy, "its hello, then busy: \(lines)")
        #expect(other.sawEndOfFile)
        first.send(.ping)
        #expect(await first.next(where: { $0 == .pong }) == .pong, "the first host stays docked")
    }

    @Test func atMostSixteenFoldersPerHelloAndSixtyFourInAll() async throws {
        // A host cannot grow the sandbox memory without bound by reconnecting with new folders.
        let tmp = try DockTestFolder()
        defer { tmp.remove() }
        let base = try #require(DockFolderRule.canonicalPath(tmp.path))
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        var passed: [String] = []
        for round in 0..<5 {
            // 20 new folders per hello (the wire keeps 16); the last host also repeats one passed before, first.
            let again = round == 4 ? ["\(tmp.path)/r0-f0"] : []
            let names = again + (0..<20).map { "\(tmp.path)/r\(round)-f\($0)" }
            let calls = h.privateFolders.count
            let host = try await h.dock(privateFolders: HostPrivateFolders(folders: names))
            #expect(h.guest.session?.currentStats().unknownFields == names.count - 16, "beyond 16 in one hello: dropped")
            #expect(h.privateFolders.count == calls + 1)
            passed += h.privateFolders.last?.folders ?? []
            host.send(.bye(.quit))
            #expect(await waitUntil { h.guest.state == .alone })
        }
        #expect(Set(passed).count == DockGuest.maxRememberedFolders, "64 distinct folders in all")
        #expect(h.guest.cappedFolders == 15, "the fifth host's new folders are not remembered")
        #expect(h.privateFolders.last?.folders == ["\(base)/r0-f0"], "a folder passed before is passed again")
        // The live announcement is never capped: the fifth host's 16 folders (the wire's limit) all reach it.
        #expect(h.announcements.count == 5)
        let fifth = try #require(h.announcements.last).folders
        #expect(fifth.count == 16 && fifth.first == "\(base)/r0-f0" && fifth.contains("\(base)/r4-f14"))
    }

    @Test func beforeThePlaceNoAreaGoesOutAndAfterByeNothing() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.connect()
        // Connected, no place yet: no area, but claims and attention go.
        h.guest.sendArea(frame: CGRect(x: 0, y: 0, width: 10, height: 10), folded: false, visible: true)
        h.guest.mouseUp()
        #expect(await host.next() == .mouseUp)
        h.guest.bye(.quit)
        #expect(await host.remainingMessages() == [.bye(.quit)])
        h.guest.sendAttention(needsYou: 1, finished: 0, running: 0)
        h.guest.claim(pid: 4242, windowNumber: 1)
        #expect(h.guest.state == .alone)
    }

    @Test func attentionAtMostOnceASecondNewestWins() async throws {
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock)
        defer { h.tearDown() }
        h.start()
        h.guest.sendAttention(needsYou: 9, finished: 9, running: 9)  // alone: kept for later
        let host = try await h.dock()
        #expect(await host.next() == .attention(needsYou: 9, finished: 9, running: 9), "sent when a host docks")
        clock.advance(by: 1)
        h.guest.sendAttention(needsYou: 1, finished: 0, running: 2)
        #expect(await host.next() == .attention(needsYou: 1, finished: 0, running: 2))
        h.guest.sendAttention(needsYou: 2, finished: 0, running: 2)
        h.guest.sendAttention(needsYou: 3, finished: -4, running: 2)
        #expect(await host.next(timeout: 0.05) == nil, "not twice within a second")
        clock.advance(by: 1)
        #expect(await host.next() == .attention(needsYou: 3, finished: 0, running: 2), "the newest, made safe")
        clock.advance(by: 1)
        h.guest.sendAttention(needsYou: 3, finished: 0, running: 2)
        host.send(.ping)
        #expect(await host.next() == .pong, "unchanged counts are not sent again")
    }

    @Test func dropClaimsAreMirroredOnlyWithTheFeature() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        h.guest.claim(pid: 4242, windowNumber: 77)
        h.guest.mouseUp()
        h.guest.release(pid: 4242, windowNumber: 77, parked: true)
        h.guest.claim(pid: 0, windowNumber: 1)
        #expect(await host.next() == .claim(pid: 4242, windowNumber: 77))
        #expect(await host.next() == .mouseUp)
        #expect(await host.next() == .release(pid: 4242, windowNumber: 77, parked: true))

        let other = try GuestHarness()
        defer { other.tearDown() }
        other.start()
        let plain = try await other.dock(features: [.speech])
        other.guest.claim(pid: 4242, windowNumber: 77)
        other.guest.mouseUp()
        plain.send(.ping)
        #expect(await plain.next() == .pong, "no claim went out")
    }

    @Test func theDockTickTurnsTheLinkOff() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock(wakeWords: ["hey host"])
        h.guest.setEnabled(false)
        #expect(await host.remainingMessages() == [.bye(.settings)])
        #expect(host.sawEndOfFile)
        #expect(h.guest.state == .alone)
        #expect(h.places.last == .some(nil))
        #expect(h.wakeWords.last == [])
        #expect(h.guest.statusLine == nil)
        let refused = try FakeHost(connectingTo: h.folder.socketPath)
        #expect(await refused.next() == .bye(.settings))
        #expect(await h.guest.requestSpeech() == .ok, "docking off: speak directly")

        h.guest.setEnabled(true)
        let again = try await h.dock()
        _ = again
        #expect(h.guest.state.isDocked)
    }

    @Test func aHostTakenOffTheListIsClosed() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        h.guest.setHosts(["com.example.other"])
        #expect(await host.remainingMessages() == [.bye(.settings)])
        #expect(h.guest.state == .alone)
        let next = try FakeHost(connectingTo: h.folder.socketPath)
        #expect(await next.next() == .bye(.refused))
    }

    @Test func stopSaysByeAndRemovesTheSocket() async throws {
        let h = try GuestHarness()
        defer { h.folder.remove() }   // the guest is stopped by the test itself
        h.start()
        let host = try await h.dock()
        h.guest.stop()
        #expect(await host.remainingMessages() == [.bye(.quit)])
        #expect(!FileManager.default.fileExists(atPath: h.folder.socketPath))
        #expect(h.guest.state == .alone)
    }
}

@MainActor
@Suite struct DockGuestSpeechTests {
    private func answer(_ h: GuestHarness) -> Task<SpeechAnswer, Never> {
        Task { @MainActor in await h.guest.requestSpeech() }
    }

    @Test func aloneTheGuestSpeaksDirectly() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        #expect(await h.guest.requestSpeech() == .ok)
        h.guest.endSpeech()  // nothing to end
    }

    @Test func okThenEndAfterThePhrase() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        let asked = answer(h)
        guard case .speechBegin(let id) = await host.next() else { Issue.record("no begin"); return }
        host.send(.speechOK(id: id))
        #expect(await asked.value == .ok)
        h.guest.endSpeech()
        #expect(await host.next() == .speechEnd(id: id))
        h.guest.endSpeech()
        host.send(.ping)
        #expect(await host.next() == .pong, "one end per ok")
    }

    @Test func speechNoIsNo() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        let asked = answer(h)
        guard case .speechBegin(let id) = await host.next() else { Issue.record("no begin"); return }
        host.send(.speechNo(id: id, why: .talk))
        #expect(await asked.value == .no(.host(.talk)))
        h.guest.endSpeech()
        host.send(.ping)
        #expect(await host.next() == .pong, "no end after a no")
    }

    @Test func aMissingOkIsNoAndALateOkIsUndoneAtOnce() async throws {
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock)
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        let asked = answer(h)
        guard case .speechBegin(let id) = await host.next() else { Issue.record("no begin"); return }
        clock.advance(by: 1.9)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(h.guest.pendingSpeech != nil, "still waiting at 1.9 s")
        clock.advance(by: 0.1)
        #expect(await asked.value == .no(.timeout))
        host.send(.speechOK(id: id))
        #expect(await host.next() == .speechEnd(id: id), "the host paused for nothing: resume it now")
    }

    @Test func anOkWithoutEndIsEndedByTheBackstop() async throws {
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock)
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        let asked = answer(h)
        guard case .speechBegin(let id) = await host.next() else { Issue.record("no begin"); return }
        host.send(.speechOK(id: id))
        #expect(await asked.value == .ok)
        clock.advance(by: 4)  // pings may come meanwhile; the host answers nothing
        clock.advance(by: DockGuest.speechEndBackstop)
        #expect(await host.next(where: { $0 == .speechEnd(id: id) }) == .speechEnd(id: id))
    }

    @Test func withoutTheFeatureThereIsNoVoiceWhileDocked() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock(features: [.fold])
        #expect(await h.guest.requestSpeech() == .no(.unsupported))
        host.send(.ping)
        #expect(await host.next() == .pong, "no speech.begin went out")
    }

    @Test func theHostLeavingAnswersAWaitingRequest() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        var host: FakeHost? = try await h.dock()
        let asked = answer(h)
        guard case .speechBegin = await host?.next() else { Issue.record("no begin"); return }
        host = nil
        #expect(await asked.value == .no(.hostGone))
    }

    @Test func oneRequestAtATime() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        let first = answer(h)
        guard case .speechBegin(let id) = await host.next() else { Issue.record("no begin"); return }
        #expect(await h.guest.requestSpeech() == .no(.busy))
        host.send(.speechOK(id: id))
        #expect(await first.value == .ok)
        // A new request while the last ok was never ended ends it first.
        let second = answer(h)
        #expect(await host.next() == .speechEnd(id: id))
        guard case .speechBegin(let next) = await host.next() else { Issue.record("no second begin"); return }
        #expect(next != id)
        host.send(.speechNo(id: next, why: .locked))
        #expect(await second.value == .no(.host(.locked)))
    }
}
