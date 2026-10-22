import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// A filesystem of invented entries that records every call, for "no lookup reached the network". Parents of every
/// entry are folders.
final class RecordingPathFileSystem: LocalPathFileSystem, @unchecked Sendable {
    enum Entry: Equatable { case folder, file, link(String) }

    private let lock = NSLock()
    private var entries: [String: Entry] = ["/": .folder]
    private var recorded: [String] = []

    init(_ list: [String: Entry] = [:]) {
        for (path, entry) in list {
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/", !parent.isEmpty, entries[parent] == nil {
                entries[parent] = .folder
                parent = (parent as NSString).deletingLastPathComponent
            }
            entries[path] = entry
        }
    }

    /// Every path asked about, in order.
    var calls: [String] { lock.withLock { recorded } }

    func lstat(_ path: String) -> LocalPathLookup {
        lock.withLock {
            recorded.append(path)
            switch entries[path] {
            case .folder?: return .found(LocalPathStat(kind: .directory, device: 1, inode: 7))
            case .file?: return .found(LocalPathStat(kind: .regular, device: 1, inode: 8))
            case .link?: return .found(LocalPathStat(kind: .link, device: 1, inode: 9))
            case nil: return .missing
            }
        }
    }

    func readlink(_ path: String) -> String? {
        lock.withLock {
            recorded.append(path)
            if case .link(let target)? = entries[path] { return target }
            return nil
        }
    }
}

/// C1 and M7 of the threat-model check: no filesystem call on a path from a reply, a session file or a program's
/// output reaches `/net`, `/home`, `/Volumes`, `/Network` or an automount point (docs/THREAT_MODEL.md, T33).
@MainActor
struct NetworkLookupTests {
    /// The mount table this test pretends: an automount trigger outside the fixed roots.
    static let pathGuard = NetworkPathGuard(mountRoots: ["/Users/alex/automounted"])
    static let networkTargets = ["/net/host/f", "/Volumes/x/f", "/Network/Servers/box/f", "/home/u/f",
                                 "/private/var/automount/x/f", "/Users/alex/automounted/f", "/Users/alex/to-net/f"]

    static func fileSystem() -> RecordingPathFileSystem {
        RecordingPathFileSystem(["/Users/alex/project/old.txt": .file, "/Users/alex/project/sub": .folder,
                                 "/Users/alex/project/latest": .link("old.txt"), "/Users/alex/to-net": .link("/net/host")])
    }

    static func reachedNetwork(_ calls: [String]) -> [String] { calls.filter { pathGuard.refuses($0) } }

    // MARK: Write targets (CommandFiles)

    @Test func writeTargetsOnANetworkRootAreNeverLookedUpAndKeepTheirTick() async {
        let fs = Self.fileSystem()
        let local = ["/Users/alex/project/old.txt", "/Users/alex/project/sub", "/Users/alex/project/latest", "/Users/alex/project/new.txt"]
        let facts = await CommandFiles.lookUp(Self.networkTargets + local, fs: fs, guard: Self.pathGuard)
        #expect(Self.reachedNetwork(fs.calls).isEmpty, "a lookup reached the network: \(Self.reachedNetwork(fs.calls))")
        for path in Self.networkTargets { #expect(facts[path] == .file, "\(path) counts as an existing file (its tick stays)") }
        // Local paths still get their facts.
        #expect(facts["/Users/alex/project/old.txt"] == .file)
        #expect(facts["/Users/alex/project/sub"] == .directory)
        #expect(facts["/Users/alex/project/latest"] == .link(target: "old.txt"))
        #expect(facts["/Users/alex/project/new.txt"] == .missing)
    }

    @Test func aWriteToANetworkPathNeedsTheReplaceTick() async {
        let fs = Self.fileSystem()
        let context = CommandContext(facts: SheetFixtures.facts(cwd: "/Users/alex/project"))
        for text in ["echo x > /net/host/f", "echo x > /Users/alex/to-net/f"] {
            let first = CommandClassifier.assess(text: text, context: context, options: CommandClassifierOptions())
            let facts = await CommandFiles.lookUp(first.localTargets, fs: fs, guard: Self.pathGuard)
            var second = context
            second.pathFacts = facts
            let assessed = CommandClassifier.assess(text: text, context: second, options: CommandClassifierOptions())
            #expect(assessed.flags.contains { $0.rule == .r21 }, "\(text): a red line to tick, never a mere note")
        }
        #expect(Self.reachedNetwork(fs.calls).isEmpty)
    }

    // MARK: The session's folder (the sheet, the binding)

    @Test func theSheetNeverLooksUpANetworkFolderOrTarget() async throws {
        let fs = Self.fileSystem()
        let h = SheetHarness(realClassifier: ())
        h.controller.pathFileSystem = fs
        h.controller.pathGuard = { Self.pathGuard }
        h.controller.lookUpFacts = { await CommandFiles.lookUp($0, fs: fs, guard: Self.pathGuard) }
        await h.present(SheetFixtures.offer("echo x > /net/host/f", facts: SheetFixtures.facts(cwd: "/Volumes/x/project")))
        #expect(Self.reachedNetwork(fs.calls).isEmpty, "a lookup reached the network: \(Self.reachedNetwork(fs.calls))")
        let sheet = try #require(h.sheet)
        #expect(sheet.state.folder.path == "/Volumes/x/project" && !sheet.state.folder.isHomeFallback,
                "the session's folder is shown, not silently swapped for the home folder")
        #expect(sheet.state.folder.problem == CommandSheetModel.refusedVolumeFolderWords,
                "decided again when the sheet opens: the session works on a refused root (L2 of the p8 review)")
        #expect(sheet.state.workFolderRefused)
        #expect(sheet.frozen?.folder == nil, "nothing is bound, so nothing can run there")
        #expect(h.model?.run.state.isOn == false)
        #expect(sheet.state.assessment.flags.contains { $0.rule == .r21 })
    }

    @Test func theRunFolderOfAnOfferIsCheckedBeforeAnyLookup() {
        let fs = Self.fileSystem()
        let home = "/Users/tester"
        func folder(_ cwd: String) -> (path: String, fallback: Bool) {
            CommandSheetController.folder(for: SheetFixtures.offer("ls", facts: SheetFixtures.facts(cwd: cwd)), home: home,
                                          guard: Self.pathGuard, fs: fs)
        }
        for cwd in ["/home/u/project", "/Volumes/x", "/net/host/p", "/Network/Servers/box", "/Users/alex/automounted/p",
                    "/Users/alex/to-net/p"] {
            #expect(folder(cwd) == (cwd, false), "\(cwd): kept for the binding to refuse with its reason")
        }
        #expect(Self.reachedNetwork(fs.calls).isEmpty, "\(Self.reachedNetwork(fs.calls))")
        #expect(folder("/Users/alex/project/sub") == ("/Users/alex/project/sub", false), "a local folder is used")
        #expect(folder("/Users/alex/project/gone") == (home, true), "a missing one falls back to the home folder, said beforehand")
    }

    @Test func aNetworkFolderIsRefusedWithItsReasonAndNeverOpened() throws {
        let fs = Self.fileSystem()
        for path in ["/Volumes/x/project", "/net/host", "/home/u", "/Network/Servers/box", "/Users/alex/automounted/p",
                     "/Users/alex/to-net/p"] {
            guard case .failure(let problem) = FolderBinding.bind(path, fs: fs, guard: { Self.pathGuard }) else {
                Issue.record("\(path) was bound")
                continue
            }
            #expect(problem == .network, "\(path)")
        }
        #expect(Self.reachedNetwork(fs.calls).isEmpty, "\(Self.reachedNetwork(fs.calls))")
        #expect(FolderBindingProblem.network.words == "the folder is on a network or another volume; Pitbox runs nothing there")

        // On this Mac: a link in a local folder that leads to a network root is refused, never followed.
        let folder = CommandTempFolder("netlink")
        let link = folder.url.appendingPathComponent("to-net")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/net/pitbox-test.invalid")
        if case .failure(let problem) = FolderBinding.bind(link.path) { #expect(problem == .network) } else { Issue.record("bound") }
        // A bound folder whose path now leads to a network root fails the click-time check without a lookup there.
        let project = folder.subfolder("project")
        let binding = try FolderBinding.bind(project.path).get()
        try FileManager.default.moveItem(at: project, to: folder.url.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(atPath: project.path, withDestinationPath: "/Volumes/pitbox-test-volume")
        #expect(binding.verify() == .network)
    }

    // MARK: Links in console output (LinkPolicy)

    @Test func aPathLinkOnANetworkRootIsNeverLookedUp() {
        let fs = Self.fileSystem()
        for link in Self.networkTargets + ["file:///net/host/f", "file:///Volumes/x/f", "/net/host/f:12", "/private/var/automount/net/host/x"] {
            #expect(LinkPolicy.action(for: link, directory: nil, fs: fs, guard: Self.pathGuard) == .ignore, "\(link)")
        }
        #expect(LinkPolicy.action(for: "notes.txt:3", directory: "/Volumes/x/project", fs: fs, guard: Self.pathGuard) == .ignore)
        #expect(LinkPolicy.action(for: "~/f", directory: nil, home: "/home/u", fs: fs, guard: Self.pathGuard) == .ignore)
        #expect(Self.reachedNetwork(fs.calls).isEmpty, "a lookup reached the network: \(Self.reachedNetwork(fs.calls))")
    }

    @Test func anOSC8LinkThatShowsAnotherAddressOpensNothing() {
        let target = "https://real.example.org/page"
        #expect(LinkPolicy.action(for: target, directory: nil, shownText: ["https://fake.example.com"]) == .misleading)
        #expect(LinkPolicy.action(for: target, directory: nil, shownText: ["www.fake.example.com/page"]) == .misleading)
        #expect(LinkPolicy.action(for: target, directory: nil, shownText: ["https://real.example.org/other"]) == .misleading)
        #expect(LinkPolicy.action(for: target + "?delete=all", directory: nil, shownText: [target]) == .misleading,
                "a hidden query is another address")
        #expect(LinkPolicy.action(for: "http://real.example.org/page", directory: nil, shownText: [target]) == .misleading)
        #expect(LinkPolicy.action(for: "file:///Users/alex/run.sh", directory: nil, shownText: ["https://docs.example.com"]) == .misleading)
        #expect(LinkPolicy.action(for: target, directory: nil, shownText: ["docs", "https://fake.example.com"]) == .misleading,
                "every run of the link is weighed")
        // What it shows is what it opens: the user's own click, as before.
        let opens = LinkPolicy.Action.open(URL(string: target)!)
        #expect(LinkPolicy.action(for: target, directory: nil, shownText: [target]) == opens)
        #expect(LinkPolicy.action(for: target, directory: nil, shownText: ["HTTPS://REAL.example.org/page/"]) == opens)
        #expect(LinkPolicy.action(for: target, directory: nil, shownText: ["www.real.example.org/page"]) == .misleading)
        #expect(LinkPolicy.action(for: "https://www.real.example.org/page", directory: nil, shownText: ["www.real.example.org/page"])
                == .open(URL(string: "https://www.real.example.org/page")!))
        #expect(LinkPolicy.action(for: target, directory: nil, shownText: ["the docs page"]) == opens, "words claim no address")
        #expect(LinkPolicy.action(for: target, directory: nil, shownText: ["main.swift:12"]) == opens, "a file name claims no address")
        #expect(LinkPolicy.action(for: "mailto:a@example.com", directory: nil, shownText: ["mailto:b@example.com"]) == .misleading)
    }

    /// N1 of the security review's fix check: shown text with spaces is weighed piece by piece; any piece that reads as
    /// another address opens nothing.
    @Test func everyPieceOfTheShownTextIsWeighed() {
        #expect(LinkPolicy.action(for: "https://evil.example/login", directory: nil, shownText: ["https://bank.example /login"])
                == .misleading)
        #expect(LinkPolicy.action(for: "https://bank.example/login", directory: nil, shownText: ["https://bank.example /login"])
                == .misleading, "a piece is weighed alone: `https://bank.example` is not the address with `/login`")
        #expect(LinkPolicy.action(for: "https://b.example/", directory: nil, shownText: ["visit https://a.example"]) == .misleading)
        #expect(LinkPolicy.action(for: "https://evil.example/", directory: nil, shownText: ["https:// bank.example/login"]) == .misleading,
                "a scheme with no host is another address")
        #expect(LinkPolicy.action(for: "https://evil.example/", directory: nil, shownText: ["mail\u{00A0}mailto:a@example.com"])
                == .misleading, "any space separates pieces")
        // Pieces that claim no address, or name the target itself, open as before.
        let docs = URL(string: "https://a.example/docs")!
        #expect(LinkPolicy.action(for: "https://a.example/docs", directory: nil, shownText: ["docs"]) == .open(docs))
        #expect(LinkPolicy.action(for: "https://a.example/docs", directory: nil, shownText: ["the docs page"]) == .open(docs))
        #expect(LinkPolicy.action(for: "https://a.example", directory: nil, shownText: ["visit https://a.example"])
                == .open(URL(string: "https://a.example")!))
        #expect(LinkPolicy.action(for: "https://a.example/docs", directory: nil, shownText: [" https://a.example/docs  (PDF) "]) == .open(docs))
    }

    /// M1, R2 and R4 of the p8 review: plain `https://bank.example/` at the end of a row (up to the right margin, one
    /// column short of it, or before trailing blanks), a hard line break, then a link showing `login` at column 0 (or plain
    /// `lo` and a linked `gin`); or the break inside the address (`https:` | `//bank…`, `https:/` | `/bank…`, `www` |
    /// `.bank…`). On screen that is one wrapped address; the link's shown text is that whole address, so nothing opens.
    @Test func anAddressEndingARowBeforeALinkReadsAsOneWord() throws {
        let h = ManagerHarness()
        let session = try #require(h.manager.sessions.first)
        let cols = session.view.terminalSize.cols
        try #require(cols > 40)
        let address = "https://bank.example/"
        func link(_ target: String, _ text: String) -> String { "\u{1b}]8;;\(target)\u{07}\(text)\u{1b}]8;;\u{07}" }
        session.view.feed(text: "\r\n" + String(repeating: " ", count: cols - address.count) + address + "\r\n")
        session.view.feed(text: link("https://evil.example/m1", "login") + " now\r\n")
        session.view.feed(text: String(repeating: " ", count: cols - address.count - 1) + address + "\r\n")
        session.view.feed(text: link("https://evil.example/r2", "login") + "\r\n")
        session.view.feed(text: "short " + address + String(repeating: " ", count: 10) + "\r\n")
        session.view.feed(text: link("https://evil.example/r2b", "login") + "\r\n")
        session.view.feed(text: address + "\r\nlo" + link("https://evil.example/r2c", "gin") + "\r\n")
        // R4: the break inside the claim, where neither half claims an address alone.
        session.view.feed(text: "https:\r\n" + link("https://evil.example/r4a", "//bank.example/login") + "\r\n")
        session.view.feed(text: "https:/\r\n" + link("https://evil.example/r4b", "/bank.example/login") + "\r\n")
        session.view.feed(text: "www\r\n" + link("https://evil.example/r4c", ".bank.example/login") + "\r\n")
        let cases = [("m1", "https://bank.example/login"), ("r2", "https://bank.example/login"),
                     ("r2b", "https://bank.example/login"), ("r2c", "https://bank.example/login"),
                     ("r4a", "https://bank.example/login"), ("r4b", "https://bank.example/login"),
                     ("r4c", "www.bank.example/login")]
        for (target, shown) in cases {
            #expect(session.view.shownTexts(ofLink: "https://evil.example/" + target) == [shown], "\(target)")
            session.requestOpenLink(source: session.view, link: "https://evil.example/" + target, params: [:])
        }
        #expect(h.links == cases.map { _ in .misleading })
    }

    /// R1 and R3 of the p8 review: honest links open. A rule line full to the margin above a link at column 0, linked
    /// addresses one per row, a link at the end of a row with text below, and a link inside brackets and punctuation.
    @Test func honestLinksAroundLineBreaksAndBracketsOpen() throws {
        let h = ManagerHarness()
        let session = try #require(h.manager.sessions.first)
        let cols = session.view.terminalSize.cols
        try #require(cols > 40)
        func link(_ target: String, _ text: String? = nil) -> String {
            "\u{1b}]8;;\(target)\u{07}\(text ?? target)\u{1b}]8;;\u{07}"
        }
        session.view.feed(text: "\r\n" + String(repeating: "=", count: cols) + "\r\n" + link("https://a.example/rule") + "\r\n")
        session.view.feed(text: String(repeating: "\u{2500}", count: cols) + "\r\n" + link("https://a.example/box") + " docs\r\n")
        session.view.feed(text: link("https://a.example/1") + "\r\n" + link("https://a.example/2") + "\r\n")
        session.view.feed(text: "see " + link("https://a.example/end") + "\r\nand more\r\n")
        session.view.feed(text: "see (" + link("https://a.example/paren") + "). Or <" + link("https://a.example/angle") + ">, \"")
        session.view.feed(text: link("https://a.example/quote") + "\" [" + link("https://a.example/square") + "] \u{201C}")
        session.view.feed(text: link("https://a.example/curly") + "\u{201D}, " + link("https://a.example/wiki/Foo_(bar)") + ".\r\n")
        let targets = ["rule", "box", "1", "2", "end", "paren", "angle", "quote", "square", "curly", "wiki/Foo_(bar)"]
            .map { "https://a.example/" + $0 }
        #expect(session.view.shownTexts(ofLink: targets[0]) == [targets[0]], "a rule line claims no address")
        #expect(session.view.shownTexts(ofLink: targets[2]) == [targets[2]] && session.view.shownTexts(ofLink: targets[3]) == [targets[3]],
                "one linked address per row")
        #expect(session.view.shownTexts(ofLink: targets[4]) == [targets[4]], "a link at the end of a row stays itself")
        #expect(session.view.shownTexts(ofLink: targets[5]) == ["(" + targets[5] + ")."])
        for target in targets {
            session.requestOpenLink(source: session.view, link: target, params: [:])
        }
        #expect(h.links == targets.map { .open(URL(string: $0)!) })
    }

    /// R3: brackets, quotes and punctuation around an address are not part of it; they cannot hide a claim either.
    @Test func bracketsAndPunctuationAroundAnAddressAreLeftOut() {
        let docs = "https://a.example/docs"
        for shown in ["(\(docs))", "<\(docs)>", "\"\(docs)\"", "'\(docs)'", "[\(docs)]", "\(docs),", "\(docs).", "(\(docs)).",
                      "\u{201C}\(docs)\u{201D}", "\u{00AB}\(docs)\u{00BB}", "\(docs)!", "(<\(docs)>)"] {
            #expect(LinkPolicy.action(for: docs, directory: nil, shownText: [shown]) == .open(URL(string: docs)!), "\(shown)")
        }
        let wiki = "https://a.example/wiki/Foo_(bar)"
        for shown in [wiki, "(\(wiki))", "\(wiki).", "[\(wiki)]"] {
            #expect(LinkPolicy.action(for: wiki, directory: nil, shownText: [shown]) == .open(URL(string: wiki)!), "\(shown)")
        }
        for shown in ["(https://bank.example)", "\"https://bank.example/docs\"", "<https://bank.example>", "(www.bank.example).",
                      "[\(docs)/other]", "'mailto:b@example.com'"] {
            #expect(LinkPolicy.action(for: docs, directory: nil, shownText: [shown]) == .misleading, "\(shown)")
        }
        #expect(LinkPolicy.claimsAddress("(https://a.example)") && !LinkPolicy.claimsAddress("(docs)") && !LinkPolicy.claimsAddress("()"))
    }

    /// L1 of the p8 review: look-alike, fullwidth and hidden letters do not make a piece claim nothing; a piece with
    /// `://` anywhere is an address claim.
    @Test func lookAlikeSchemesAreStillAddressClaims() {
        let target = "https://evil.example/"
        for shown in ["\u{04BB}ttps://bank.example", "\u{FF48}\u{FF54}\u{FF54}\u{FF50}\u{FF53}://bank.example",
                      "https\u{FF1A}//bank.example", "https\u{FF1A}\u{FF0F}\u{FF0F}bank.example",
                      "\u{041D}\u{0422}\u{0422}\u{0420}S://bank.example", "h\u{200B}ttps://bank.example",
                      "\u{FF57}\u{FF57}\u{FF57}.bank.example", "www\u{2024}bank.example", "\u{051D}\u{051D}\u{051D}.bank.example",
                      "w\u{200B}ww.bank.example", "WWW.bank.example", "see:https://bank.example", "(https://bank.example)",
                      "\u{FF4D}\u{FF41}\u{FF49}\u{FF4C}\u{FF54}\u{FF4F}:b@example.com", "m\u{0430}ilto:b@example.com"] {
            #expect(LinkPolicy.action(for: target, directory: nil, shownText: [shown]) == .misleading, "\(shown.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        // Words, file names and other scripts claim nothing; the target itself still opens.
        let opens = LinkPolicy.Action.open(URL(string: target)!)
        for shown in ["docs", "main.swift:12", "\u{0434}\u{043E}\u{043A}\u{0443}\u{043C}\u{0435}\u{043D}\u{0442}\u{044B}",
                      "\u{FF44}\u{FF4F}\u{FF43}\u{FF53}", "https://evil.example/", "HTTPS://EVIL.example"] {
            #expect(LinkPolicy.action(for: target, directory: nil, shownText: [shown]) == opens, "\(shown)")
        }
    }

    @Test func theConsoleWeighsWhatTheLinkShowsOnScreen() throws {
        let h = ManagerHarness()
        let session = try #require(h.manager.sessions.first)
        session.view.feed(text: "a \u{1b}]8;;https://real.example.org/page\u{07}https://fake.example.com\u{1b}]8;;\u{07} b\r\n")
        session.view.feed(text: "c \u{1b}]8;id=1;https://real.example.org/docs\u{07}the docs\u{1b}]8;;\u{07}\r\n")
        session.view.feed(text: "d \u{1b}]8;;https://real.example.org/same\u{07}https://real.example.org/same\u{1b}]8;;\u{07}\r\n")
        // M1 of the security review: plain `https://` printed right before a link that shows `bank.example/login`
        // reads as one address on screen; the link goes elsewhere.
        session.view.feed(text: "e https://\u{1b}]8;;https://evil.example/\u{07}bank.example/login\u{1b}]8;;\u{07} f\r\n")
        // N1: a space inside the link's own text, and plain `https://` before a link whose text starts with a space.
        session.view.feed(text: "g \u{1b}]8;;https://evil.example/login\u{07}https://bank.example /login\u{1b}]8;;\u{07} h\r\n")
        session.view.feed(text: "i https://\u{1b}]8;;https://evil.example/next\u{07} bank.example/login\u{1b}]8;;\u{07}\r\n")
        #expect(session.view.shownTexts(ofLink: "https://real.example.org/page") == ["https://fake.example.com"])
        #expect(session.view.shownTexts(ofLink: "https://real.example.org/docs") == ["the docs"])
        #expect(session.view.shownTexts(ofLink: "https://evil.example/") == ["https://bank.example/login"])
        #expect(session.view.shownTexts(ofLink: "https://evil.example/login") == ["https://bank.example /login"])
        #expect(session.view.shownTexts(ofLink: "https://evil.example/next") == ["https:// bank.example/login"])
        // SwiftTerm hands the session the target on a Cmd-click (`requestOpenLink`); the session adds what was shown.
        session.requestOpenLink(source: session.view, link: "https://real.example.org/page", params: [:])
        session.requestOpenLink(source: session.view, link: "https://real.example.org/docs", params: ["id": "1"])
        session.requestOpenLink(source: session.view, link: "https://real.example.org/same", params: [:])
        session.requestOpenLink(source: session.view, link: "https://evil.example/", params: [:])
        session.requestOpenLink(source: session.view, link: "https://evil.example/login", params: [:])
        session.requestOpenLink(source: session.view, link: "https://evil.example/next", params: [:])
        #expect(h.links == [.misleading, .open(URL(string: "https://real.example.org/docs")!),
                            .open(URL(string: "https://real.example.org/same")!), .misleading, .misleading, .misleading])
    }
}

/// M5, L2b and the log items of the threat-model check.
@MainActor
struct HardeningTests {
    final class Threads: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Bool] = []
        func add(_ value: Bool) { lock.withLock { seen.append(value) } }
        var values: [Bool] { lock.withLock { seen } }
    }

    @Test func theServerAliasIsCheckedOffTheMainThread() async throws {
        let h = CommandConsoleHarness()
        let ssh = h.home.subfolder(".ssh")
        try Data("Host buildbox\n  HostName 192.0.2.10\n".utf8).write(to: ssh.appendingPathComponent("config"))
        chmod(ssh.appendingPathComponent("config").path, 0o600)
        let threads = Threads()
        h.console.exactAliasCheck = { alias, home in
            threads.add(Thread.isMainThread)
            return SSHConfigHosts.isExactAlias(alias, home: home)
        }
        #expect(await h.console.openServerTab(alias: "buildbox") == nil)
        #expect(await h.console.openServerTab(alias: "other") == "that server isn't an exact entry in your SSH config")
        #expect(threads.values == [false, false], "the SSH config is never read on the main thread")
        #expect(h.manager.sessions.last?.preset.argv == ["ssh", "buildbox"], "the same answer as before: the tab opens")
    }

    @Test func theFetchedFilesOpenNeverArmsUnderARestingPointer() async throws {
        var opened: [URL] = []
        let runner = FakeFetchRunner { _ in .success(CommandsFetchSheetTests.plan()) }
        let h = SheetHarness(assess: CommandsFetchSheetTests.assessment, fetchRunner: runner)
        h.controller.fetchedFileOpening = { _ in .open }
        h.controller.openFetchedFile = { opened.append($0) }
        await h.present(SheetFixtures.offer(CommandsFetchSheetTests.text, facts: SheetFixtures.facts(place: .ssh, alias: "buildbox"),
                                            caption: nil))
        _ = await waitUntil(5) { if case .planned? = h.sheet?.state.fetch?.phase { return true }; return false }
        let downloads = URL(fileURLWithPath: h.folder.path).appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: downloads.appendingPathComponent("notes.md"))
        h.advance(1)
        let fetch = try #require(h.view?.fetchButton)
        h.click(fetch)
        #expect(await waitUntil(5) { runner.started.count == 1 })
        // The pointer rests where Fetch file was; Open appears under it.
        let open = try #require(h.view?.openFetchedButton)
        open.pointerEntered()
        runner.completions.first?(.saved(fileName: "notes.md", bytes: 1))
        #expect(h.model?.openFetched.state == .on)
        h.advance(1)
        h.click(open, enter: false)
        #expect(opened.isEmpty, "a pointer resting there since before Open armed presses nothing")
        open.pointerExited()
        h.click(open)
        #expect(opened.count == 1, "a pointer that came onto it after arming does")
    }

    @Test func openATerminalNeverArmsUnderARestingPointer() async throws {
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text)
            a.commandClass = .otherMachine
            a.machine = .remote(host: "buildbox")
            return a
        })
        h.exactAliases = ["buildbox"]
        await h.present(SheetFixtures.offer("ssh buildbox 'uptime'", facts: SheetFixtures.facts(place: .ssh, alias: "buildbox")))
        #expect(await waitUntil(5) { h.model?.server.state == .on })
        let server = try #require(h.view?.serverButton)
        server.pointerEntered()
        h.advance(1)
        h.click(server, enter: false)
        #expect(h.host.serverAliases.isEmpty, "a resting pointer opens no terminal")
        server.pointerExited()
        h.click(server)
        #expect(h.host.serverAliases == ["buildbox"])
        #expect(!server.isAccessibilitySelectorAllowed(#selector(NSView.accessibilityPerformPress)))
    }

    @Test func aTabThatCannotStartLogsALabelNotThePath() throws {
        let program = "/Users/alex/private-tools/zsh"
        let lines = Threads.Lines()
        let recorder = TerminalLog.addRecorder { lines.add($0) }
        defer { TerminalLog.removeRecorder(recorder) }
        let h = ManagerHarness(start: false)
        h.launcher.failWith = PTYError.notExecutable(program)
        h.manager.startIfNeeded()
        let all = lines.values
        #expect(all.contains { $0.hasSuffix("could not start: not-executable") }, "\(all.count) lines")
        #expect(!all.contains { $0.contains("private-tools") }, "a log line names the program's path")
        // The user's own tab still says which program (their screen, not the log).
        guard case .failed(let message)? = h.manager.sessions.first?.state else { Issue.record("not failed"); return }
        #expect(message.contains(program))
        #expect(PTYError.forkFailed(EAGAIN).logLabel == "pty-failed errno=\(EAGAIN)")
        #expect(PTYError.logLabel(of: CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: program])) == "other-error")
    }
}

extension HardeningTests.Threads {
    /// Recorded log lines (from any thread).
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.withLock { stored.append(line) } }
        var values: [String] { lock.withLock { stored } }
    }
}
