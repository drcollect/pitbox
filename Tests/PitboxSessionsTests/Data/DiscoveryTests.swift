import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

@Suite("SSH config")
struct SSHConfigTests {
    func facts(_ tree: FixtureTree) -> SSHConfigFacts {
        SSHConfigReader.read(configPath: tree.sshConfig.path, sshFolder: tree.ssh.path, home: tree.home.path, owner: getuid())
    }

    @Test func exactHostsFollowIncludes() throws {
        let tree = FixtureTree()
        try tree.write("""
        # comment
        Host buildbox box-1
          HostName 192.0.2.10
          User buildbox
        Host *.example.com !bad other?
        Host=eq-host
        Host = spaced-host "quoted host"
        Include conf.d/*.conf
        Include ~/extra.conf
        """, to: tree.sshConfig)
        try tree.write("Host included-host # trailing comment\n", to: tree.ssh.appendingPathComponent("conf.d/a.conf"))
        try tree.write("Host home-host\n", to: tree.home.appendingPathComponent("extra.conf"))
        let result = facts(tree)
        #expect(result.exactHosts == ["buildbox", "box-1", "eq-host", "spaced-host", "quoted host", "included-host", "home-host"])
        #expect(!result.hasMatch && result.filesRead == 3 && result.filesRefused == 0)
        #expect(result.isExactHost("buildbox") && !result.isExactHost("x.example.com"))
    }

    @Test func aMatchBlockAnywhereStopsSSHG() throws {
        let tree = FixtureTree()
        try tree.write("Host buildbox\nInclude more\n", to: tree.sshConfig)
        try tree.write("Match exec \"true\"\n  User x\n", to: tree.ssh.appendingPathComponent("more"))
        #expect(facts(tree).hasMatch)
    }

    @Test func unsafeFilesAreRefused() throws {
        let tree = FixtureTree()
        try tree.write("Host buildbox\n", to: tree.sshConfig)
        #expect(chmod(tree.sshConfig.path, 0o666) == 0)
        let result = facts(tree)
        #expect(result.exactHosts.isEmpty && result.filesRefused == 1)
        let missing = SSHConfigReader.read(configPath: tree.ssh.appendingPathComponent("nope").path, sshFolder: tree.ssh.path,
                                           home: tree.home.path, owner: getuid())
        #expect(missing.exactHosts.isEmpty)
    }

    /// H4: every file is read with O_NOFOLLOW and the owner and mode rules; a refused file or one past the limits
    /// keeps `ssh -G` from running (the HostName stays unknown).
    @Test func aRefusedOrUnreachedFileStopsSSHG() throws {
        let clean = FixtureTree()
        try clean.write("Host buildbox\nInclude conf.d/*\n", to: clean.sshConfig)
        try clean.write("Host other\n", to: clean.ssh.appendingPathComponent("conf.d/a.conf"))
        #expect(facts(clean).allowsHostLookup && facts(clean).filesRead == 2)

        let linked = FixtureTree()
        try linked.write("Host linked-host\n", to: linked.home.appendingPathComponent("dotfiles/extra.conf"))
        try FileManager.default.createDirectory(at: linked.ssh, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linked.ssh.appendingPathComponent("extra.conf").path,
                                                   withDestinationPath: linked.home.appendingPathComponent("dotfiles/extra.conf").path)
        try linked.write("Host buildbox\nInclude extra.conf\n", to: linked.sshConfig)
        let viaLink = facts(linked)
        #expect(viaLink.filesRefused == 1 && !viaLink.allowsHostLookup && !viaLink.exactHosts.contains("linked-host"))
        #expect(viaLink.isExactHost("buildbox"), "the alias itself is still known; only its HostName stays unknown")

        let whole = FixtureTree()
        try whole.write("Host buildbox\n", to: whole.home.appendingPathComponent("dotfiles/config"))
        try FileManager.default.createDirectory(at: whole.ssh, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: whole.sshConfig.path,
                                                   withDestinationPath: whole.home.appendingPathComponent("dotfiles/config").path)
        #expect(facts(whole).filesRefused == 1 && facts(whole).exactHosts.isEmpty && !facts(whole).allowsHostLookup)

        // L4 of the security review: a link anywhere on the path, a linked `~/.ssh` folder too, is refused.
        let folderLink = FixtureTree()
        try folderLink.write("Host buildbox\n", to: folderLink.home.appendingPathComponent("dotfiles/ssh/config"))
        try FileManager.default.removeItem(at: folderLink.ssh)
        try FileManager.default.createSymbolicLink(atPath: folderLink.ssh.path,
                                                   withDestinationPath: folderLink.home.appendingPathComponent("dotfiles/ssh").path)
        #expect(facts(folderLink).filesRefused == 1 && facts(folderLink).exactHosts.isEmpty && !facts(folderLink).allowsHostLookup)

        let crowded = FixtureTree()
        var many = "Host buildbox\n"
        for index in 0..<40 {
            many += "Include f\(index).conf\n"
            try crowded.write("Host h\(index)\n", to: crowded.ssh.appendingPathComponent("f\(index).conf"))
        }
        try crowded.write(many, to: crowded.sshConfig)
        #expect(facts(crowded).filesSkipped > 0 && !facts(crowded).allowsHostLookup, "files past the 32-file limit were never read")

        let globbed = FixtureTree()
        for index in 0..<40 { try globbed.write("Host g\(index)\n", to: globbed.ssh.appendingPathComponent("d/\(index).conf")) }
        try globbed.write("Host buildbox\nInclude d/*.conf\n", to: globbed.sshConfig)
        #expect(facts(globbed).filesSkipped > 0 && !facts(globbed).allowsHostLookup, "one pattern naming more than the limit")

        let deep = FixtureTree()
        try deep.write("Host buildbox\nInclude self\n", to: deep.sshConfig)
        try deep.write("Include next\n", to: deep.ssh.appendingPathComponent("self"))
        var chain = ""
        for index in 0..<20 { chain = "n\(index)"; try deep.write("Include n\(index + 1)\n", to: deep.ssh.appendingPathComponent(chain)) }
        try deep.write("Include n0\n", to: deep.ssh.appendingPathComponent("next"))
        #expect(facts(deep).filesSkipped > 0 && !facts(deep).allowsHostLookup, "nesting past 16 levels")

        // M2 of the security review: an argument only ssh expands names a file Pitbox cannot know, even when the text
        // as written matches nothing (ssh would read `hosts/<this Mac's name>.conf`, `$HOME/x`, alex's file).
        for include in ["Include hosts/%l.conf", "Include ${HOME}/.ssh/extra.conf", "Include \"$XDG_CONFIG_HOME/ssh/config\"",
                        "Include ~alex/work/ssh.conf"] {
            let expanded = FixtureTree()
            try expanded.write("Host buildbox\n\(include)\n", to: expanded.sshConfig)
            #expect(facts(expanded).filesSkipped == 1 && !facts(expanded).allowsHostLookup, "\(include)")
        }

        let missing = FixtureTree()
        try missing.write("Host buildbox\nInclude not-there.conf conf.d/*.conf\n", to: missing.sshConfig)
        #expect(facts(missing).allowsHostLookup, "an include that matches nothing is no problem (ssh skips it too)")
    }

    /// An `Include` that reaches an external or network volume (as written or by a wildcard) is never looked up there;
    /// it counts as a file that could not be read, so `ssh -G` does not run.
    @Test func anIncludeOnAnExternalVolumeStopsSSHG() throws {
        for include in ["Include /Volumes/pitbox-test-volume/config", "Include \"/Volumes/pitbox test volume/*.conf\"",
                        "Include /Vol*/pitbox-test-volume/config"] {
            let tree = FixtureTree()
            try tree.write("Host buildbox\n\(include)\n", to: tree.sshConfig)
            let result = facts(tree)
            #expect(result.filesRefused == 1 && !result.allowsHostLookup, "\(include)")
            #expect(result.isExactHost("buildbox"), "\(include): the alias itself is still known; only its HostName stays unknown")
        }
    }

    /// The same for a mount-table point (a folder of the test's own stands in for one), reached as written, through a
    /// link of yours or by a wildcard: refused, and the file there is never read.
    @Test func anIncludeOnAMountTablePointIsRefusedBeforeAnyLookup() throws {
        let tree = FixtureTree()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let real = Darwin.realpath(tree.root.path, &buffer) != nil ? String(cString: buffer) : tree.root.path
        let mount = real + "/automounted"
        try tree.write("Host far\n", to: URL(fileURLWithPath: mount + "/ssh/far.conf"))
        try FileManager.default.createSymbolicLink(atPath: tree.ssh.appendingPathComponent("remote").path, withDestinationPath: mount + "/ssh")
        let pathGuard = NetworkPathGuard(mountRoots: [mount])
        func read(_ pathGuard: NetworkPathGuard) -> SSHConfigFacts {
            SSHConfigReader.read(configPath: tree.sshConfig.path, sshFolder: tree.ssh.path, home: tree.home.path, owner: getuid(),
                                 guard: pathGuard)
        }
        for include in ["Include \(mount)/ssh/far.conf", "Include remote/*.conf", "Include ../auto*/ssh/far.conf"] {
            try tree.write("Host buildbox\n\(include)\n", to: tree.sshConfig)
            let result = read(pathGuard)
            #expect(result.filesRefused == 1 && !result.allowsHostLookup && !result.isExactHost("far"), "\(include)")
        }
        // Without that mount point the folder is an ordinary local one, and is read.
        try tree.write("Host buildbox\nInclude \(mount)/ssh/far.conf\n", to: tree.sshConfig)
        #expect(read(.fixed).isExactHost("far") && read(.fixed).allowsHostLookup)
    }

    @Test func theFingerprintChangesWithTheFiles() throws {
        let tree = FixtureTree()
        try tree.write("Host a\n", to: tree.sshConfig)
        let first = facts(tree)
        try tree.write("Host a b\n", to: tree.sshConfig)
        #expect(facts(tree).fingerprint != first.fingerprint)
    }

    @Test func aliasGrammar() {
        #expect(SSHConfigReader.isValidAlias("buildbox") && SSHConfigReader.isValidAlias("kb-vps.1_x"))
        #expect(!SSHConfigReader.isValidAlias("-oProxyCommand=x") && !SSHConfigReader.isValidAlias("a b"))
        #expect(!SSHConfigReader.isValidAlias("") && !SSHConfigReader.isValidAlias(String(repeating: "a", count: 65)))
    }

    @Test func sshGOutputGivesTheHostName() {
        #expect(SSHHostNameLookup.parse("user buildbox\nhostname 192.0.2.10\nport 22\n") == "192.0.2.10")
        #expect(SSHHostNameLookup.parse("hostname box.example.com") == "box.example.com")
        #expect(SSHHostNameLookup.parse("hostname bad;name") == nil)
        #expect(SSHHostNameLookup.parse("port 22") == nil)
    }
}

@Suite("Claude processes")
struct ProcessDiscoveryTests {
    let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)

    @Test func theUserDataDirNamesTheCopy() {
        func profile(_ arguments: [String]?) -> CodeProfile {
            ClaudeProcessDiscovery.profile(arguments: arguments, applicationSupport: support, profiles: .test)
        }
        #expect(profile(["/Apps/a/Claude.app/Contents/MacOS/Claude"]) == .a)
        #expect(profile(["/x/Claude", "--user-data-dir=/Users/someone/Library/Application Support/Claude-Work"]) == .b)
        #expect(profile(["/x/Claude", "--user-data-dir", "/Users/someone/Library/Application Support/Claude-Lab"]) == .c)
        #expect(profile(["/x/Claude", "--user-data-dir=/Users/someone/Library/Application Support/Claude-3p"]).letter == "?")
        // A known name somewhere else is not that copy.
        #expect(profile(["/x/Claude", "--user-data-dir=/tmp/Claude-Work"]).letter == "?")
        #expect(profile(nil).letter == "?")
        #expect(!profile(nil).isReadable)
        // A copy the settings file does not list is never read, even in the right folder (the safe rule).
        #expect(ClaudeProcessDiscovery.profile(arguments: ["/x/Claude", "--user-data-dir=\(support.path)/Claude-Work"],
                                               applicationSupport: support).letter == "?")
    }

    @Test func procArgsLayout() {
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/Apps/Claude".utf8) + [0, 0, 0]
        for argument in ["/Apps/Claude", "--user-data-dir=/x y/Claude-Work", "--flag"] { bytes += Array(argument.utf8) + [0] }
        bytes += Array("SECRET_ENV=1".utf8) + [0]
        #expect(ClaudeProcessDiscovery.parseProcArgs(bytes) == ["/Apps/Claude", "--user-data-dir=/x y/Claude-Work", "--flag"])
        #expect(ClaudeProcessDiscovery.parseProcArgs([0, 0]) == nil)
        #expect(ClaudeProcessDiscovery.parseProcArgs([5, 0, 0, 0, 65, 0, 66, 0]) == nil)
    }

    @Test func readsThisProcessesOwnArguments() throws {
        let arguments = try #require(ClaudeProcessDiscovery.arguments(pid: getpid()))
        #expect(!arguments.isEmpty)
        #expect(arguments.count == CommandLine.arguments.count)
    }

    @Test func copiesAreSortedAAndBThenUnknown() {
        let found = ClaudeProcessDiscovery.resolve([
            ClaudeProcessCandidate(pid: 9, arguments: ["/x", "--user-data-dir=/elsewhere/Thing"]),
            ClaudeProcessCandidate(pid: 7, arguments: ["/x", "--user-data-dir=\(support.path)/Claude-Work"]),
            ClaudeProcessCandidate(pid: 8, arguments: ["/x"]),
        ], applicationSupport: support, profiles: .test)
        #expect(found.map(\.profile.letter) == ["A", "B", "?"])
        #expect(found.map(\.pid) == [8, 7, 9])
    }
}

@Suite("Run records and the click-time verdict")
struct RecordsAndVerdictTests {
    @MainActor @Test func runRecordsKeepHashesOnly() {
        let records = CodeRunRecords()
        let facts = CommandSessionFacts(place: .local, homeDirectory: "/Users/someone", userName: "someone")
        let offer = CommandOffer(id: .init(sessionIndex: 3, replyUUID: "u", number: 1), text: "echo \(secretWord)", total: 1,
                                 blockKind: .tagged("bash"), displayLines: [], caption: nil,
                                 source: .init(sessionID: sessionA, headline: "h", replyTime: fixtureNow),
                                 replyReadCompletely: true, folder: .init(path: "/Users/someone", isHomeFallback: false),
                                 context: CommandContext(facts: facts), replyText: "")
        #expect(CodeRunRecords.textHash(offer.text).count == 16)
        #expect(records.lastRun(of: offer) == nil)
        records.note(.started(runID: UUID()), for: offer, at: fixtureNow)
        #expect(records.count == 0)
        records.note(.finished(runID: UUID(), exitStatus: 0, seconds: 3), for: offer, at: fixtureNow)
        let run = records.lastRun(of: offer)
        #expect(run?.exitStatus == 0 && run?.seconds == 3 && run?.sessionIndex == 3)
        #expect(!String(describing: run as Any).contains(secretWord))
    }

    @Test func linesAfterTheReplyDecide() {
        func verdict(_ lines: [String], partial: String = "", complete: Bool = true) -> CommandOfferFreshness {
            let text = lines.map { $0 + "\n" }.joined() + partial
            return CodeOfferFreshnessChecker.verdict(after: Array(text.utf8), complete: complete)
        }
        #expect(verdict([]) == .fresh)
        #expect(verdict([Line.system(uuid: "s", at: fixtureNow)]) == .fresh)
        #expect(verdict([Line.user("thanks", uuid: "u2", at: fixtureNow)]) == .stale)
        #expect(verdict([Line.text("more", uuid: "a9", at: fixtureNow)]) == .stale)
        #expect(verdict([Line.toolResult("t", uuid: "r", at: fixtureNow)]) == .fresh)
        #expect(verdict([Line.text("side", uuid: "s1", at: fixtureNow, sidechain: true)]) == .fresh)
        #expect(verdict(["{\"broken\":"]) == .unknown)
        #expect(verdict([], partial: "{\"type\":\"user\"") == .unknown)
        #expect(verdict([Line.system(uuid: "s", at: fixtureNow)], complete: false) == .unknown)
    }
}
