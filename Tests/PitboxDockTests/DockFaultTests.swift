import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxDock

/// Fault tests on fakes: a host that breaks the framing or the handshake is disconnected with a label,
/// never obeyed and never able to crash the app; harmless oddities are ignored and counted.
@MainActor
@Suite struct DockFaultTests {
    /// Docks a host, sends `bad`, and expects the guest to say `bye(protocol)`, close, and go alone with `label`.
    private func expectViolation(_ bad: [UInt8], label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        #expect(h.guest.state.isDocked, sourceLocation: sourceLocation)
        host.sendRaw(bad)
        let rest = await host.remainingMessages()
        #expect(rest.contains(.bye(.protocol)), sourceLocation: sourceLocation)
        #expect(host.sawEndOfFile, sourceLocation: sourceLocation)
        #expect(await waitUntil { h.guest.state == .alone }, sourceLocation: sourceLocation)
        #expect(h.guest.lastEndReason == .violation(label), sourceLocation: sourceLocation)
        #expect(h.places.last == .some(nil), "back to the screen edge", sourceLocation: sourceLocation)
    }

    @Test func aMalformedLineIsADisconnect() async throws {
        try await expectViolation(Array("{\"t\":\"place\",\n".utf8), label: "malformed")
        try await expectViolation(Array("not json at all\n".utf8), label: "malformed")
        try await expectViolation(Array("[\"t\",\"place\"]\n".utf8), label: "not a message")
        try await expectViolation(Array("{\"t\":7}\n".utf8), label: "not a message")
        try await expectViolation([0x7B, 0x22, 0x74, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D, 0x0A], label: "not UTF-8")
    }

    @Test func anOversizedLineIsADisconnectBeforeItEnds() async throws {
        try await expectViolation([UInt8](repeating: 0x20, count: DockProtocol.maxLineBytes + 1), label: "line too long")
    }

    @Test func aLineOfExactlySixteenKiBIsRead() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        let head = #"{"t":"ping","pad":""#
        let tail = #""}"#
        let pad = String(repeating: "a", count: DockProtocol.maxLineBytes - head.utf8.count - tail.utf8.count)
        let line = head + pad + tail
        #expect(line.utf8.count == DockProtocol.maxLineBytes)
        host.sendRaw(line + "\n")
        #expect(await host.next(where: { $0 == .pong }) == .pong, "read and answered")
        #expect(h.guest.session?.currentStats().unknownFields == 1)
        #expect(h.guest.state.isDocked)
    }

    @Test func aFloodOfLinesIsADisconnect() async throws {
        try await expectViolation(Array(String(repeating: "{\"t\":\"pong\"}\n", count: 60).utf8), label: "rate")
    }

    @Test func nestingDeeperThanEightIsADisconnect() async throws {
        let deep = "{\"t\":\"pong\",\"x\":" + String(repeating: "[", count: 8) + String(repeating: "]", count: 8) + "}\n"
        try await expectViolation(Array(deep.utf8), label: "nesting")
    }

    @Test func nestingOfEightIsFine() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        host.sendRaw("{\"t\":\"ping\",\"x\":" + String(repeating: "[", count: 7) + String(repeating: "]", count: 7) + "}\n")
        #expect(await host.next(where: { $0 == .pong }) == .pong)
    }

    @Test func aDuplicatedKeyDropsTheLineOnly() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.connect()
        // Which seq would win is exactly the question a duplicate raises: neither does.
        host.sendRaw(#"{"t":"place","seq":1,"seq":2,"displayID":1,"edge":"right","host":{"x":0,"y":0,"w":10,"h":10},"visible":true,"level":"above","cell":{"width":300},"maxWidth":800}"# + "\n")
        host.send(.ping)
        #expect(await host.next(where: { $0 == .pong }) == .pong, "the link stays")
        #expect(!h.guest.state.isDocked, "the duplicated place was dropped")
        #expect(h.guest.session?.currentStats().duplicateKeys == 1)
        host.send(.place(FakeHost.place(seq: 3)))
        #expect(await waitUntil { h.guest.state.place?.seq == 3 })
    }

    @Test func unknownTypesAndFieldsAreIgnoredAndCounted() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        host.sendRaw(#"{"t":"wave","hand":"left"}"# + "\n")
        host.sendRaw(#"{"t":"run","command":"rm -rf ~"}"# + "\n")
        host.sendRaw(#"{"t":"fold","folded":true,"andAlso":"open a file"}"# + "\n")
        host.send(.ping)
        #expect(await host.next(where: { $0 == .pong }) == .pong)
        #expect(await waitUntil { h.folds == [true] }, "the known part of the line is used")
        let stats = try #require(h.guest.session?.currentStats())
        #expect(stats.unknownTypes == 2)
        #expect(stats.unknownFields == 1)
        #expect(h.guest.state.isDocked)
    }

    @Test func aMessageWithBadFieldsIsDroppedAfterTheHandshake() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock()
        host.sendRaw(#"{"t":"place","seq":2,"displayID":1,"edge":"top","host":{"x":0,"y":0,"w":10,"h":10},"visible":true,"level":"above","cell":{"width":300},"maxWidth":800}"# + "\n")
        host.send(.ping)
        #expect(await host.next(where: { $0 == .pong }) == .pong)
        #expect(h.guest.state.place?.seq == 1, "the bad place changed nothing")
        #expect(h.guest.session?.currentStats().badFields == 1)
    }

    @Test func aFeatureNotInUseIsIgnored() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock(features: [.appearance])
        host.send(.focus(.named("Acme")))
        host.send(.fold(true))
        host.send(.appearance(DockAppearance(scheme: .dark, backdrop: .solid)))
        #expect(await waitUntil { h.appearances.contains(DockAppearance(scheme: .dark, backdrop: .solid)) })
        #expect(h.focuses.isEmpty && h.folds.isEmpty)
        #expect(h.guest.session?.currentStats().featureOff == 2)
        #expect(h.guest.features == [.appearance])
    }

    @Test func noCommonVersionRefusesWithTheProtocolWords() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.connect(hello: false)
        host.sendHello(proto: 2...3, app: "Host", privateFolders: HostPrivateFolders(folders: ["/Users/alex/Host"]))
        let rest = await host.remainingMessages()
        #expect(rest == [.bye(.version)])
        #expect(host.sawEndOfFile)
        #expect(await waitUntil { h.guest.state == .refused(.version(ours: 1...1, theirs: 2...3)) })
        #expect(h.guest.statusLine == "Can't dock with Host: Pitbox speaks protocol 1, Host speaks 2-3",
                "the line names the host from its hello")
        #expect(h.privateFolders.isEmpty, "nothing of a host that did not dock is remembered")
        #expect(!h.guest.isConnected)
    }

    @Test func aVersionRefusalIsNeverCalledAHostWithoutDockSupport() async throws {
        // The 5 s check armed at start must not fire after a host that spoke the protocol.
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock, running: ["com.example.host"])
        defer { h.tearDown() }
        h.start()
        let host = try await h.connect(hello: false)
        host.sendHello(proto: 2...2)
        #expect(await host.remainingMessages() == [.bye(.version)])
        #expect(await waitUntil { h.guest.state == .refused(.version(ours: 1...1, theirs: 2...2)) })
        clock.advance(by: 6)
        #expect(h.guest.warning == nil)
        #expect(h.guest.statusLine == "Can't dock with Host: Pitbox speaks protocol 1, Host speaks 2")
    }

    @Test func tooBroadPrivateFoldersAreDroppedAndCounted() async throws {
        // A verified host cannot deny the whole disk (or the home folder) to Pitbox's commands.
        let tmp = try DockTestFolder()
        defer { tmp.remove() }
        #expect(symlink("/", tmp.path + "/to-root") == 0)
        let announced = HostPrivateFolders(
            folders: ["/", "/Users/alex", "/Users/alex/Library", "/Users/alex/Library/Application Support", "/Users",
                      "/usr/local/host", "/private/tmp", "/tmp", tmp.path + "/to-root", tmp.path + "/to-root/usr",
                      "/Users/alex/Library/Application Support/Host/../../..", "relative/path",
                      "/Users/alex/Library/Application Support/Host"],
            socketFolders: ["/private/var/folders", tmp.path + "/runner", "/tmp"])
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock(privateFolders: announced)
        _ = host
        let canonicalTmp = try #require(DockFolderRule.canonicalPath(tmp.path))
        #expect(h.privateFolders == [HostPrivateFolders(folders: ["/Users/alex/Library/Application Support/Host"],
                                                        socketFolders: [canonicalTmp + "/runner"])],
                "only specific app-private folders, in canonical form")
        #expect(h.guest.session?.currentStats().refusedFolders == 14)
    }

    @Test func anAnnouncementWithOnlyBroadFoldersPassesNothing() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.dock(privateFolders: HostPrivateFolders(folders: ["/"], socketFolders: ["/Users/alex"]))
        _ = host
        #expect(h.privateFolders.isEmpty, "no call at all")
        #expect(h.guest.session?.currentStats().refusedFolders == 2)
    }

    @Test func theHighestCommonMajorIsUsed() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.connect(hello: false)
        host.sendHello(proto: 1...4)
        #expect(await waitUntil { h.guest.isConnected })
        // This build speaks 1 only: 1 it is.
        #expect(h.guest.isConnected)
        host.send(.place(FakeHost.place()))
        #expect(await waitUntil { h.guest.state.isDocked })
    }

    @Test func theFirstLineMustBeHello() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.connect(hello: false)
        host.send(.place(FakeHost.place()))
        #expect(await host.remainingMessages() == [.bye(.protocol)])
        #expect(await waitUntil { h.guest.lastEndReason == .violation("hello expected") })
        #expect(!h.guest.state.isDocked)
    }

    @Test func aHelloInTheWrongRoleOrTwiceIsADisconnect() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        let host = try await h.connect(hello: false)
        host.sendRaw(#"{"t":"hello","proto":[1,1],"role":"guest","app":"Fake","build":"1","features":[]}"# + "\n")
        #expect(await host.remainingMessages() == [.bye(.protocol)])
        #expect(await waitUntil { h.guest.lastEndReason == .violation("bad hello") })

        let again = try await h.connect()
        again.sendHello()
        #expect(await again.remainingMessages().contains(.bye(.protocol)))
        #expect(await waitUntil { h.guest.lastEndReason == .violation("second hello") })
    }

    @Test func noHelloWithinTwoSecondsClosesTheLink() async throws {
        let clock = ManualDockClock()
        let h = try GuestHarness(clock: clock)
        defer { h.tearDown() }
        h.start()
        let host = try await h.connect(hello: false)
        clock.advance(by: 1.9)
        #expect(await host.nextLine(timeout: 0.05) == nil)
        #expect(!host.sawEndOfFile, "still open at 1.9 s")
        clock.advance(by: 0.1)
        #expect(await host.remainingMessages() == [.bye(.timeout)])
        #expect(host.sawEndOfFile)
        #expect(await waitUntil { h.guest.lastEndReason == .handshakeTimeout })
    }

    @Test func garbageBeforeAnyHelloIsADisconnectNotACrash() async throws {
        let h = try GuestHarness()
        defer { h.tearDown() }
        h.start()
        for junk in ["\u{0}\u{1}\u{2}\n", "{}\n", "null\n", "\"hello\"\n", "{\"t\":\"hello\"}\n"] {
            let host = try await h.connect(hello: false)
            host.sendRaw(junk)
            #expect(await host.waitForClose(), "\(junk.debugDescription)")
        }
        #expect(h.guest.state == .alone)
    }
}
