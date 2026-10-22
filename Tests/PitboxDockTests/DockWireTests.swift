import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxDock

private func host(_ text: String) -> DockWire.Decoded<HostMessage> {
    guard let value = try? StrictJSON.parse(Array(text.utf8)) else { return .notAMessage }
    return DockWire.decodeHost(value)
}

private func roundTrip(_ message: HostMessage) throws -> HostMessage? {
    let data = DockWire.encode(message)
    #expect(data.last == 0x0A)
    let value = try StrictJSON.parse(Array(data.dropLast()))
    guard case .message(let decoded, let unknown) = DockWire.decodeHost(value) else { return nil }
    #expect(unknown == 0)
    return decoded
}

private func roundTrip(_ message: GuestMessage) throws -> GuestMessage? {
    let data = DockWire.encode(message)
    let value = try StrictJSON.parse(Array(data.dropLast()))
    guard case .message(let decoded, let unknown) = DockWire.decodeGuest(value) else { return nil }
    #expect(unknown == 0)
    return decoded
}

@Suite struct DockWireTests {
    @Test func everyHostMessageRoundTrips() throws {
        let messages: [HostMessage] = [
            FakeHost.hello(features: [.speech, .fold], wakeWords: ["hey host", "computer"],
                           privateFolders: HostPrivateFolders(folders: ["/Users/alex/Library/Application Support/Host"],
                                                              socketFolders: ["/private/tmp/host-runner-501"])),
            .place(FakeHost.place(seq: 12, live: true, visible: false, edge: .left)),
            .place(HostPlace(seq: 0, displayID: 4_294_967_295, displayUUID: nil, edge: .right,
                             host: CGRect(x: -1440, y: -0.5, width: 300.25, height: 900), visible: true, level: .behind,
                             live: false, cell: HostPlace.Cell(width: 322.7, gutter: 0, padding: 0, row: 81), maxWidth: 0)),
            .appearance(DockAppearance(scheme: .dark, backdrop: .vibrancy)),
            .focus(.all), .focus(.named("Acme")),
            .speechOK(id: 3), .speechNo(id: 4, why: .dictation),
            .fold(true), .ping, .pong, .bye(.update),
        ]
        for message in messages { #expect(try roundTrip(message) == message) }
    }

    @Test func everyGuestMessageRoundTrips() throws {
        let messages: [GuestMessage] = [
            DockGuestHello(build: "1.2.3", features: DockFeature.all).message, .busy,
            .area(seq: 12, frame: CGRect(x: 2902, y: 98, width: 631, height: 1312), folded: false, visible: true),
            .claim(pid: 4242, windowNumber: 77), .release(pid: 4242, windowNumber: 77, parked: true), .mouseUp,
            .attention(needsYou: 1, finished: 2, running: 3), .speechBegin(id: 9), .speechEnd(id: 9),
            .ping, .pong, .bye(.quit),
        ]
        for message in messages { #expect(try roundTrip(message) == message) }
    }

    @Test func theSpecExamplePlaceReads() {
        // The example of the protocol document, with a display UUID filled in.
        let text = #"{"t":"place","seq":12,"displayID":1,"displayUUID":"37D8832A-2D66-02CA-B9F7-8F30A301B230","edge":"right","host":{"x":3533,"y":98,"w":1587,"h":1312},"visible":true,"level":"above","cell":{"width":301.4,"gutter":12,"padding":16,"row":69},"maxWidth":800}"#
        guard case .message(.place(let place), let unknown) = host(text) else { Issue.record("not a place"); return }
        #expect(unknown == 0)
        #expect(place.seq == 12 && place.edge == .right && place.level == .above && !place.live && place.visible)
        #expect(place.host == CGRect(x: 3533, y: 98, width: 1587, height: 1312))
        #expect(place.cell == HostPlace.Cell(width: 301.4, gutter: 12, padding: 16, row: 69))
        #expect(place.maxWidth == 800)
    }

    @Test func unknownFieldsAndWordsAreCountedNotObeyed() {
        let text = #"{"t":"place","seq":1,"displayID":1,"edge":"left","host":{"x":0,"y":0,"w":10,"h":10,"z":1},"visible":true,"level":"floating","live":false,"cell":{"width":300,"depth":3},"maxWidth":800,"color":"red","run":"rm -rf"}"#
        guard case .message(.place(let place), let unknown) = host(text) else { Issue.record("not a place"); return }
        #expect(unknown == 5, "host.z, level word, cell.depth, color, run")
        #expect(place.level == .above, "an unknown level word reads as the default")
        #expect(host(#"{"t":"appearance","scheme":"sepia","backdrop":"glass"}"#)
                == .message(.appearance(DockAppearance(scheme: .system, backdrop: .glass)), unknownFields: 1))
        #expect(host(#"{"t":"bye","why":"tired"}"#) == .message(.bye(.other), unknownFields: 1))
        #expect(host(#"{"t":"speech.no","id":2}"#) == .message(.speechNo(id: 2, why: .other), unknownFields: 0))
        #expect(host(#"{"t":"wave","hand":"left"}"#) == .unknownType)
        #expect(host(#"{"t":"area","seq":1,"frame":{"x":0,"y":0,"w":1,"h":1},"folded":false,"visible":true}"#) == .unknownType,
                "a guest message from the host is not a host message")
        #expect(host(#"{"type":"place"}"#) == .notAMessage)
        #expect(host(#"{"t":3}"#) == .notAMessage)
        #expect(host(#"[1]"#) == .notAMessage)
    }

    @Test func badFieldsDropTheLine() {
        let base = #""t":"place","seq":1,"displayID":1,"edge":"right","visible":true,"level":"above","cell":{"width":300},"maxWidth":800"#
        let good = "{" + base + #","host":{"x":0,"y":0,"w":10,"h":10}}"#
        guard case .message = host(good) else { Issue.record("the base place is good"); return }
        let bad: [(String, String)] = [
            (#","host":{"x":0,"y":0,"w":0,"h":10}"#, "place.host"),
            (#","host":{"x":0,"y":0,"w":-5,"h":10}"#, "place.host"),
            (#","host":{"x":1e300,"y":0,"w":5,"h":10}"#, "place.host"),
            (#","host":{"x":0,"y":0,"w":10}"#, "place.host"),
            (#","host":"wide""#, "place.host"),
            (#","host":{"x":200000,"y":0,"w":5,"h":10}"#, "place.host"),
            (#","host":{"x":0,"y":0,"w":5,"h":100001}"#, "place.host"),
        ]
        for (hostField, label) in bad {
            #expect(host("{" + base + hostField + "}") == .badFields(label), "\(hostField)")
        }
        let rect = #","host":{"x":0,"y":0,"w":10,"h":10}"#
        #expect(host("{" + base.replacingOccurrences(of: #""seq":1"#, with: #""seq":-1"#) + rect + "}") == .badFields("place.seq"))
        #expect(host("{" + base.replacingOccurrences(of: #""seq":1"#, with: #""seq":1.5"#) + rect + "}") == .badFields("place.seq"))
        #expect(host("{" + base.replacingOccurrences(of: #""seq":1"#, with: #""seq":1000000000000000"#) + rect + "}")
                == .badFields("place.seq"), "ints stop below 10^15")
        guard case .message(.place(let largest), _) = host("{" + base.replacingOccurrences(of: #""seq":1"#,
                                                                                          with: #""seq":999999999999999"#) + rect + "}") else {
            Issue.record("the largest int reads")
            return
        }
        #expect(largest.seq == 999_999_999_999_999)
        #expect(host("{" + base.replacingOccurrences(of: #""edge":"right""#, with: #""edge":"top""#) + rect + "}") == .badFields("place.edge"))
        #expect(host("{" + base.replacingOccurrences(of: #""visible":true"#, with: #""visible":"yes""#) + rect + "}") == .badFields("place.visible"))
        #expect(host("{" + base.replacingOccurrences(of: #""cell":{"width":300}"#, with: #""cell":{"width":0}"#) + rect + "}") == .badFields("place.cell"))
        #expect(host("{" + base.replacingOccurrences(of: #""displayID":1"#, with: #""displayID":4294967296"#) + rect + "}") == .badFields("place.displayID"))
        #expect(host(#"{"t":"focus","key":""}"#) == .badFields("focus.key"))
        #expect(host(#"{"t":"focus","key":"two\nlines"}"#) == .badFields("focus.key"))
        #expect(host(#"{"t":"fold"}"#) == .badFields("fold.folded"))
        #expect(host(#"{"t":"speech.ok","id":"one"}"#) == .badFields("speech.ok.id"))
    }

    @Test func helloIsCheckedFieldByField() {
        #expect(host(#"{"t":"hello","proto":[1,1],"role":"host","app":"Host","build":"7","features":[]}"#)
                == .message(.hello(DockHello(proto: 1...1, minor: nil, role: .host, app: "Host", build: "7", features: [],
                                             wakeWords: [], privateFolders: HostPrivateFolders())), unknownFields: 0))
        for proto in ["[2,1]", "[0,1]", "[1]", "[1,2,3]", "\"1\"", "[1,\"2\"]", "[1,10000]"] {
            let text = #"{"t":"hello","proto":"# + proto + #","role":"host","app":"Host","build":"7","features":[]}"#
            #expect(host(text) == .badFields("hello.proto"), "\(proto)")
        }
        #expect(host(#"{"t":"hello","proto":[1,1],"role":"guest","app":"Host","build":"7","features":[]}"#) == .badFields("hello.role"))
        #expect(host(#"{"t":"hello","proto":[1,1],"role":"host","app":"","build":"7","features":[]}"#) == .badFields("hello.app"))
        #expect(host(#"{"t":"hello","proto":[1,1],"role":"host","app":"Host","build":"7","features":"all"}"#) == .badFields("hello.features"))
        // Unknown features and invalid list entries are dropped and counted.
        let text = #"{"t":"hello","proto":[1,3],"minor":2,"role":"host","app":"Host","build":"7","features":["focus","teleport",4],"wakeWords":["hey host","",7,"hey host"],"private":{"folders":["/a"],"socketFolders":[],"keys":"x"}}"#
        guard case .message(.hello(let hello), let unknown) = host(text) else { Issue.record("hello"); return }
        #expect(hello.proto == 1...3 && hello.minor == 2)
        #expect(hello.features == [.focus])
        #expect(hello.wakeWords == ["hey host"])
        #expect(hello.privateFolders == HostPrivateFolders(folders: ["/a"], socketFolders: []))
        #expect(unknown == 6, "teleport, 4, the empty word, 7, the repeated word, private.keys")
    }

    @Test func oneLineTextAndHostNames() {
        #expect(DockWire.isOneLine("Host", maxBytes: 10))
        #expect(!DockWire.isOneLine("", maxBytes: 10))
        #expect(!DockWire.isOneLine("   ", maxBytes: 10))
        #expect(!DockWire.isOneLine("a\u{85}b", maxBytes: 10))
        #expect(!DockWire.isOneLine("a\u{2028}b", maxBytes: 10))
        #expect(!DockWire.isOneLine(String(repeating: "é", count: 6), maxBytes: 10), "bytes, not characters")
        #expect(DockGuest.cleanHostName("  My   Host\u{202E}App ") == "My HostApp")
        #expect(DockGuest.cleanHostName("\u{7}") == nil)
        let long = String(repeating: "x", count: 60)
        #expect(DockGuest.cleanHostName(long)?.count == 40)
    }

    @Test func refusalWordsForTheMenu() {
        #expect(DockRefusal.version(ours: 1...1, theirs: 2...3).menuLine(hostName: "Host")
                == "Can't dock with Host: Pitbox speaks protocol 1, Host speaks 2-3")
        #expect(DockRefusal.version(ours: 1...1, theirs: 2...2).menuLine()
                == "Can't dock with the host app: Pitbox speaks protocol 1, the host app speaks 2")
        #expect(DockRefusal.notListed(bundleID: "com.example.other").menuLine()
                == "An app (com.example.other) asked to dock but is not in dock.hosts in the settings file")
        #expect(DockRefusal.notListed(bundleID: nil).menuLine().hasPrefix("An app asked"))
        #expect(!DockRefusal.notAnApp.menuLine().isEmpty && !DockRefusal.otherUser.menuLine().isEmpty)
    }
}

@Suite struct DockFramingTests {
    private func lines(_ outputs: [DockLineFramer.Output]) -> [String] {
        outputs.compactMap { if case .line(let bytes) = $0 { return String(decoding: bytes, as: UTF8.self) } else { return nil } }
    }

    @Test func linesSplitAcrossReadsAndCRLF() {
        var framer = DockLineFramer()
        #expect(framer.feed(Array("{\"t\":\"pi".utf8), at: 0).isEmpty)
        #expect(lines(framer.feed(Array("ng\"}\r\n{\"t\":\"pong\"}\n\n  \n{".utf8), at: 0)) == ["{\"t\":\"ping\"}", "{\"t\":\"pong\"}"])
        #expect(framer.blankLines == 2)
        #expect(framer.pendingCount == 1)
    }

    @Test func sixteenKiBIsTheMostALineHolds() {
        var framer = DockLineFramer()
        let longest = [UInt8](repeating: 0x61, count: DockProtocol.maxLineBytes)
        #expect(lines(framer.feed(longest + [0x0A], at: 0)).count == 1)
        var tooLong = DockLineFramer()
        let outputs = tooLong.feed([UInt8](repeating: 0x61, count: DockProtocol.maxLineBytes + 1), at: 0)
        #expect(outputs == [.violation("line too long")], "seen before any newline arrives")
        #expect(tooLong.failed)
        #expect(tooLong.feed(Array("{}\n".utf8), at: 0).isEmpty, "nothing after a violation")
    }

    @Test func fiftyLinesASecondWithABurstOfFifty() {
        var framer = DockLineFramer()
        let fifty = [UInt8](String(repeating: "{}\n", count: 50).utf8)
        #expect(lines(framer.feed(fifty, at: 10)).count == 50)
        #expect(framer.feed(Array("{}\n".utf8), at: 10) == [.violation("rate")], "the 51st in the same instant")
        var steady = DockLineFramer()
        for tick in 0..<500 {
            // 50 a second, for 10 s: never a violation.
            #expect(lines(steady.feed(Array("{}\n".utf8), at: 10 + Double(tick) * 0.02)).count == 1)
        }
        var refilled = DockLineFramer()
        _ = refilled.feed(fifty, at: 0)
        #expect(lines(refilled.feed(Array("{}\n{}\n".utf8), at: 0.04)).count == 2, "two tokens back after 40 ms")
        #expect(refilled.feed(Array("{}\n".utf8), at: 0.04) == [.violation("rate")])
    }

    @Test func theTokenBucketPacesASender() {
        var bucket = TokenBucket(capacity: 2, perSecond: 4)
        var taken: [Bool] = []
        for _ in 0..<3 { taken.append(bucket.take(at: 0)) }
        #expect(taken == [true, true, false])
        let next = bucket.nextToken(after: 0)
        #expect(abs(next - 0.25) < 1e-9)
        let atQuarter = bucket.take(at: 0.25)
        let earlier = bucket.take(at: 0.1)
        #expect(atQuarter)
        #expect(!earlier, "an earlier time adds nothing")
        taken = []
        for _ in 0..<3 { taken.append(bucket.take(at: 10)) }
        #expect(taken == [true, true, false], "never more than the capacity")
    }
}
