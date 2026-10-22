import Darwin
import Foundation
import Testing
@testable import PitboxDock

private func mode(_ path: String) -> mode_t? {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode : nil
}

/// A socket bound at `path`, listening or not, held open until `close()`.
private struct OtherSocket {
    let fd: Int32

    init(at path: String, listening: Bool) throws {
        fd = try POSIX.makeSocket()
        let address = try POSIX.makeUnixAddress(path)
        #expect(POSIX.bind(fd, to: address) == 0)
        if listening { #expect(listen(fd, 4) == 0) }
    }

    func close() { Darwin.close(fd) }
}

private func listener(_ folder: DockTestFolder, path: String? = nil) -> DockListener {
    DockListener(socketPath: path ?? folder.socketPath, inspector: FakeInspector(), clock: SystemDockClock.shared,
                 ownUID: getuid())
}

@Suite struct DockListenerBindTests {
    @Test func bindsA0600SocketInA0700Folder() throws {
        let folder = try DockTestFolder()
        defer { folder.remove() }
        let path = folder.path + "/AS/dock.sock"
        let made = listener(folder, path: path)
        try made.bind(configuration: .init())
        defer { made.stop() }
        #expect(made.isBound)
        #expect(mode(folder.path + "/AS").map { $0 & 0o777 } == 0o700)
        #expect(mode(path).map { POSIX.fileType($0) } == mode_t(S_IFSOCK))
        #expect(mode(path).map { $0 & 0o777 } == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path + "/AS")
        #expect(names == ["dock.sock"], "created under a private name and renamed: nothing else is left")
        try made.bind(configuration: .init())  // twice is harmless
        #expect(made.isBound)
    }

    @Test func anOpenFolderIsTightenedAndASymlinkedOneRefused() throws {
        let folder = try DockTestFolder()
        defer { folder.remove() }
        #expect(chmod(folder.path, 0o755) == 0)
        let made = listener(folder)
        try made.bind(configuration: .init())
        made.stop()
        #expect(mode(folder.path).map { $0 & 0o777 } == 0o700)

        let other = try DockTestFolder()
        defer { other.remove() }
        #expect(symlink(other.path, folder.path + "/link") == 0)
        let linked = listener(folder, path: folder.path + "/link/dock.sock")
        #expect(throws: DockListenerError.unsafeFolder) { try linked.bind(configuration: .init()) }
        #expect(!FileManager.default.fileExists(atPath: other.path + "/dock.sock"))
    }

    @Test func aStaleSocketIsRemovedAfterAFailedConnect() throws {
        let folder = try DockTestFolder()
        defer { folder.remove() }
        // A socket file left by a crashed run: bound once, nobody listens.
        let stale = try OtherSocket(at: folder.socketPath, listening: false)
        stale.close()
        #expect(mode(folder.socketPath).map { POSIX.fileType($0) } == mode_t(S_IFSOCK))
        let made = listener(folder)
        try made.bind(configuration: .init())
        defer { made.stop() }
        let client = try FakeHost(connectingTo: folder.socketPath)
        _ = client
    }

    @Test func aLiveSocketIsNeverRemoved() throws {
        let folder = try DockTestFolder()
        defer { folder.remove() }
        let live = try OtherSocket(at: folder.socketPath, listening: true)
        defer { live.close() }
        let made = listener(folder)
        #expect(throws: DockListenerError.inUse) { try made.bind(configuration: .init()) }
        #expect(!made.isBound)
        // The live listener still answers on its socket.
        let client = try FakeHost(connectingTo: folder.socketPath)
        let accepted = accept(live.fd, nil, nil)
        #expect(accepted >= 0)
        if accepted >= 0 { close(accepted) }
        _ = client
    }

    @Test func somethingElseAtThePathIsNeverRemoved() throws {
        let folder = try DockTestFolder()
        defer { folder.remove() }
        #expect(FileManager.default.createFile(atPath: folder.socketPath, contents: Data("keep".utf8)))
        #expect(throws: DockListenerError.notASocket) { try listener(folder).bind(configuration: .init()) }
        #expect(FileManager.default.contents(atPath: folder.socketPath) == Data("keep".utf8))

        unlink(folder.socketPath)
        #expect(symlink("/tmp", folder.socketPath) == 0)
        #expect(throws: DockListenerError.notASocket) { try listener(folder).bind(configuration: .init()) }
        #expect(mode(folder.socketPath).map { POSIX.fileType($0) } == mode_t(S_IFLNK))
    }

    @Test func aPathTooLongForASocketFailsCleanly() throws {
        let folder = try DockTestFolder()
        defer { folder.remove() }
        let path = folder.path + "/" + String(repeating: "x", count: 100) + ".sock"
        #expect(throws: DockListenerError.pathTooLong) { try listener(folder, path: path).bind(configuration: .init()) }
    }

    @Test func stopRemovesOnlyItsOwnSocket() throws {
        let folder = try DockTestFolder()
        defer { folder.remove() }
        let made = listener(folder)
        try made.bind(configuration: .init())
        made.stop()
        #expect(!made.isBound)
        #expect(mode(folder.socketPath) == nil, "removed")

        let again = listener(folder)
        try again.bind(configuration: .init())
        // Something replaced the socket meanwhile: stop leaves it.
        unlink(folder.socketPath)
        #expect(FileManager.default.createFile(atPath: folder.socketPath, contents: Data("other".utf8)))
        again.stop()
        #expect(FileManager.default.contents(atPath: folder.socketPath) == Data("other".utf8))
    }
}

@MainActor
@Suite struct DockListenerAcceptTests {
    @Test func aSecondHostGetsBusyAndIsClosed() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let first = try await h.dock()
        #expect(h.guest.state.isDocked)

        let second = try FakeHost(connectingTo: h.folder.socketPath)
        #expect(await second.next() == .busy)
        #expect(await second.waitForClose())
        #expect(h.guest.state.isDocked, "the first host stays docked")
        first.send(.ping)
        #expect(await first.next(where: { $0 == .pong }) == .pong)
    }

    @Test func whileDockingIsOffEveryConnectionGetsByeSettings() async throws {
        let h = try GuestHarness(enabled: false)
        defer { h.tearDown() }
        h.start()
        #expect(h.places == [nil])
        let host = try FakeHost(connectingTo: h.folder.socketPath)
        #expect(await host.next() == .bye(.settings))
        #expect(await host.waitForClose())
        #expect(h.guest.state == .alone)
        #expect(h.guest.statusLine == nil)
    }

    @Test func aRefusedPeerGetsByeRefusedAndNoHello() async throws {
        let inspector = FakeInspector(passingFacts(bundleID: "com.example.other"))
        let h = try GuestHarness(inspector: inspector)
        defer { h.tearDown() }
        h.start()
        let host = try FakeHost(connectingTo: h.folder.socketPath)
        #expect(await host.next() == .bye(.refused))
        #expect(await host.waitForClose())
        #expect(await waitUntil { h.guest.state == .refused(.notListed(bundleID: "com.example.other")) })
        #expect(h.guest.statusLine == "An app (com.example.other) asked to dock but is not in dock.hosts in the settings file")
        #expect(h.privateFolders.isEmpty && h.wakeWords.isEmpty)

        // Not an app: refused the same way.
        inspector.set(DockPeerFacts(uid: getuid(), pid: getpid(), started: nil, bundle: nil))
        let loose = try FakeHost(connectingTo: h.folder.socketPath)
        #expect(await loose.next() == .bye(.refused))
        #expect(await waitUntil { h.guest.state == .refused(.notAnApp) })

        // Another user: closed without a word.
        var foreign = passingFacts()
        foreign.uid = getuid() + 1
        inspector.set(foreign)
        let stranger = try FakeHost(connectingTo: h.folder.socketPath)
        #expect(await stranger.nextLine() == nil)
        #expect(stranger.sawEndOfFile)

        // A listed host still docks afterwards.
        inspector.set(passingFacts())
        let good = try await h.dock()
        _ = good
        #expect(h.guest.state.isDocked)
    }

    @Test func aHostThatConnectsWhileTheAppStartsIsAnsweredAtOnceAndDocksWithoutAJump() async throws {
        let h = try GuestHarness(running: ["com.example.host"])
        defer { h.tearDown() }
        // Bound (and accepting) at launch, before the guest is wired: the host gets its hello within the handshake time.
        let host = try FakeHost(connectingTo: h.folder.socketPath)
        guard case .hello = await host.next(timeout: 1) else { Issue.record("no hello before start"); return }
        host.sendHello()
        host.send(.place(FakeHost.place(seq: 2)))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.places.isEmpty, "nothing happens before the app wires the guest")
        h.start()
        #expect(h.guest.state == .waitingForHost, "a connected host means: wait for its place")
        #expect(await waitUntil { h.guest.state.isDocked })
        #expect(h.places == [FakeHost.place(seq: 2)], "docked straight away, never alone first")
    }

    @Test func aRefusalBeforeTheGuestStartsIsShownOnceItStarts() async throws {
        let h = try GuestHarness(inspector: FakeInspector(passingFacts(bundleID: "com.example.other")))
        defer { h.tearDown() }
        let host = try FakeHost(connectingTo: h.folder.socketPath)
        #expect(await host.next() == .bye(.refused))
        h.start()
        #expect(h.guest.state == .refused(.notListed(bundleID: "com.example.other")))
    }

    @Test func withoutABoundSocketTheGuestStaysAloneWithAWarning() async throws {
        let h = try GuestHarness(running: ["com.example.host"], bind: false)
        defer { h.tearDown() }
        h.start()
        #expect(h.guest.state == .alone)
        #expect(h.places == [nil])
        #expect(h.guest.warning == .socketUnavailable)
        #expect(h.guest.statusLine == "Dock unavailable: the socket could not be opened")
    }
}
