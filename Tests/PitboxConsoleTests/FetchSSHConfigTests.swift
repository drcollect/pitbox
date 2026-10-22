import Darwin
import Foundation
import Testing
import PitboxKit
@testable import PitboxConsole

/// Reading the SSH configuration without running anything.
struct FetchSSHConfigTests {
    private func reader(_ sandbox: FetchSandbox, system: String? = nil) -> SSHConfigReader {
        SSHConfigReader(userConfig: URL(fileURLWithPath: sandbox.userConfig),
                        systemConfig: system.map { URL(fileURLWithPath: $0) }, home: sandbox.home)
    }

    @Test func hostTokensAreReadLikeSsh() {
        let sandbox = FetchSandbox()
        sandbox.writeConfig("""
        # a comment
        Host buildbox other
          HostName 192.0.2.10
        HOST="quoted name" plain # trailing comment
        host = eq\r
        Host 'single' "dou ble"
          User x
        """)
        let reading = reader(sandbox).read()
        #expect(reading.problem == nil)
        #expect(reading.hostTokens == ["buildbox", "other", "quoted name", "plain", "eq", "single", "dou ble"])
        #expect(!reading.hasMatch)
    }

    @Test func wildcardsAndNegationsAreNeverAnExactAlias() {
        let sandbox = FetchSandbox()
        sandbox.writeConfig("Host *\n  User x\nHost build*\nHost !buildbox\n")
        let reading = reader(sandbox).read()
        #expect(!reading.hostTokens.contains("buildbox"))
    }

    @Test func includesFollowSshsPathRules() {
        let sandbox = FetchSandbox()
        sandbox.write(sandbox.sshFolder + "/config.d/b.conf", "Host from-b\n")
        sandbox.write(sandbox.sshFolder + "/config.d/a.conf", "Host from-a\nInclude nested.conf\n")
        sandbox.write(sandbox.sshFolder + "/nested.conf", "Host from-nested\n")
        sandbox.write(sandbox.home + "/elsewhere/tilde.conf", "Host from-tilde\n")
        sandbox.write(sandbox.root + "/absolute.conf", "Host from-absolute\n")
        sandbox.writeConfig("""
        Include config.d/*
        Include ~/elsewhere/tilde.conf \(sandbox.root)/absolute.conf
        Include missing-*.conf does-not-exist.conf
        Host buildbox
        """)
        let reading = reader(sandbox).read()
        #expect(reading.problem == nil)
        #expect(reading.hostTokens == ["from-a", "from-nested", "from-b", "from-tilde", "from-absolute", "buildbox"])
        let order = reading.records.map { ($0.path as NSString).lastPathComponent }
        #expect(order == ["config", "a.conf", "nested.conf", "b.conf", "tilde.conf", "absolute.conf"], "glob order, depth first")
    }

    @Test func aMatchBlockAnywhereIsFound() {
        let sandbox = FetchSandbox()
        sandbox.write(sandbox.sshFolder + "/extra.conf", "  match exec \"true\"\n    User x\n")
        sandbox.writeConfig("Host buildbox\nInclude extra.conf\n")
        #expect(reader(sandbox).read().hasMatch)

        let system = FetchSandbox()
        system.writeConfig("Host buildbox\n")
        let systemFile = system.write(system.root + "/etc/ssh_config", "Include ssh_config.d/*\n")
        system.write(system.root + "/etc/ssh_config.d/100.conf", "Match=host x exec /bin/date\n")
        let reading = reader(system, system: systemFile).read()
        #expect(reading.hasMatch, "ssh -G reads the system files too")
        #expect(reading.records.count == 3)
    }

    /// This Mac's own system files (`/etc/ssh/ssh_config`, its `ssh_config.d/*` and the linked `crypto.conf`; read only,
    /// never the user's config) read without a problem and without `Match`. If a macOS update adds a `Match` block
    /// there, Fetch file switches off on this Mac ("couldn't read your SSH config without running it"), and this says so.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/etc/ssh/ssh_config")))
    func thisMacsSystemFilesReadWithoutMatch() {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let reading = reader(sandbox, system: "/etc/ssh/ssh_config").read()
        #expect(reading.problem == nil)
        #expect(!reading.hasMatch, "a Match block in the system files switches Fetch file off")
        #expect(reading.records.contains { $0.path == "/etc/ssh/ssh_config" && $0.exists })
    }

    @Test func hostLinesOfTheSystemFileAreNotAliases() {
        let sandbox = FetchSandbox()
        sandbox.writeConfig("Host mine\n")
        let system = sandbox.write(sandbox.root + "/etc/ssh_config", "Host buildbox\n  SendEnv LANG\n")
        let reading = reader(sandbox, system: system).read()
        #expect(reading.hostTokens == ["mine"])
    }

    @Test func whatCannotBeReadFaithfullyIsAProblem() throws {
        func problem(_ config: String, prepare: (FetchSandbox) -> Void = { _ in }) -> SSHConfigReading.Problem? {
            let sandbox = FetchSandbox()
            prepare(sandbox)
            sandbox.writeConfig(config)
            return reader(sandbox).read().problem
        }
        #expect(problem("Include %d/x.conf\n") == .unsupportedInclude)
        #expect(problem("Include ${HOME}/x.conf\n") == .unsupportedInclude)
        #expect(problem("Include ~root/x.conf\n") == .unsupportedInclude)
        #expect(problem("Host \"unclosed\n") == .badQuotes)
        #expect(problem("Include self.conf\n") { $0.write($0.sshFolder + "/self.conf", "Include self.conf\n") } == .tooDeep)
        #expect(problem("Include locked.conf\n") { $0.write($0.sshFolder + "/locked.conf", "Host x\n", mode: 0o000) } == .unreadable)
        #expect(problem("Include folder*\n") { FetchSandbox.makeFolder($0.sshFolder + "/folder.d") } == .notAFile)
        #expect(problem("Include fifo\n") { _ = mkfifo($0.sshFolder + "/fifo", 0o600) } == .notAFile)
        #expect(problem("Include big.conf\n") {
            $0.write($0.sshFolder + "/big.conf", String(repeating: "# padding\n", count: 110_000))
        } == .tooLarge)
        var many = ""
        for index in 0..<70 { many += "Include f\(index).conf\n" }
        #expect(problem(many) { sandbox in
            for index in 0..<70 { sandbox.write(sandbox.sshFolder + "/f\(index).conf", "Host h\(index)\n") }
        } == .tooManyFiles)
    }

    /// H4: a link, someone else's file or one others can write is a problem (Fetch file refuses), wherever it is.
    @Test func linksForeignAndWritableFilesAreProblems() throws {
        let linked = FetchSandbox()
        let real = linked.write(linked.root + "/dotfiles/ssh.conf", "Host buildbox\n")
        try FileManager.default.createSymbolicLink(atPath: linked.sshFolder + "/extra.conf", withDestinationPath: real)
        linked.writeConfig("Host mine\nInclude extra.conf\n")
        #expect(reader(linked).read().problem == .link, "a linked include")
        let whole = FetchSandbox()
        let target = whole.write(whole.root + "/dotfiles/config", "Host buildbox\n")
        FetchSandbox.makeFolder(whole.sshFolder)
        try FileManager.default.createSymbolicLink(atPath: whole.userConfig, withDestinationPath: target)
        #expect(reader(whole).read().problem == .link, "a linked ~/.ssh/config")

        let foreign = FetchSandbox()
        foreign.writeConfig("Host buildbox\n")
        var other = reader(foreign)
        other.owner = getuid() &+ 1
        #expect(other.read().problem == .owner, "neither yours (as the reader is told) nor root's")

        let writable = FetchSandbox()
        writable.write(writable.sshFolder + "/extra.conf", "Host x\n", mode: 0o620)
        writable.writeConfig("Host buildbox\nInclude extra.conf\n")
        #expect(reader(writable).read().problem == .writable)
    }

    /// An `Include` that reaches an external or network volume is never looked up there: Fetch file refuses, as for a
    /// file it could not read.
    @Test func anIncludeOnARefusedRootIsAProblem() throws {
        for include in ["Include /Volumes/pitbox-test-volume/config", "Include /Vol*/pitbox-test-volume/*.conf"] {
            let sandbox = FetchSandbox()
            sandbox.writeConfig("Host buildbox\n\(include)\n")
            #expect(reader(sandbox).read().problem == .unreadable, "\(include)")
        }
        // A mount-table point (a folder of the test's own stands in for one) and a link of yours into it.
        let sandbox = FetchSandbox()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let real = Darwin.realpath(sandbox.root, &buffer) != nil ? String(cString: buffer) : sandbox.root
        let mount = real + "/automounted"
        sandbox.write(mount + "/ssh/far.conf", "Host far\n")
        try FileManager.default.createSymbolicLink(atPath: sandbox.sshFolder + "/remote", withDestinationPath: mount + "/ssh")
        for include in ["Include \(mount)/ssh/far.conf", "Include remote/*.conf"] {
            sandbox.writeConfig("Host buildbox\n\(include)\n")
            var checked = reader(sandbox)
            checked.pathGuard = NetworkPathGuard(mountRoots: [mount])
            #expect(checked.read().problem == .unreadable, "\(include)")
        }
        sandbox.writeConfig("Host buildbox\nInclude \(mount)/ssh/far.conf\n")
        var plain = reader(sandbox)
        plain.pathGuard = .fixed
        #expect(plain.read().problem == nil && plain.read().hostTokens.contains("far"), "an ordinary local folder is read")
    }

    @Test func aMissingConfigHasNoAliases() {
        let sandbox = FetchSandbox()
        let reading = reader(sandbox).read()
        #expect(reading.problem == nil)
        #expect(reading.hostTokens.isEmpty)
        #expect(reading.records == [SSHConfigFileRecord(path: sandbox.userConfig, exists: false)])
    }

    @Test func theFingerprintChangesWithSizeTimeOrContent() throws {
        let sandbox = FetchSandbox()
        sandbox.write(sandbox.sshFolder + "/config.d/a.conf", "Host a\n")
        sandbox.writeConfig("Include config.d/*\nHost buildbox\n")
        let reader = reader(sandbox)
        let first = reader.read().fingerprint
        #expect(reader.read().fingerprint == first, "stable while nothing changes")
        #expect(first.hasPrefix("v1-") && first.count == 67)

        // Same size, other content.
        sandbox.write(sandbox.sshFolder + "/config.d/a.conf", "Host b\n")
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 0), timespec(tv_sec: 1_700_000_000, tv_nsec: 0)]
        let second = reader.read().fingerprint
        #expect(second != first)

        // Only the time.
        _ = utimensat(AT_FDCWD, sandbox.userConfig, &times, 0)
        let third = reader.read().fingerprint
        #expect(third != second)

        // A new file an Include matches.
        sandbox.write(sandbox.sshFolder + "/config.d/c.conf", "Host c\n")
        #expect(reader.read().fingerprint != third)
    }

    @Test func tokensSplitLikeArgvSplit() {
        #expect(SSHConfigReader.keyword(of: "  Host = a b ")?.0 == "host")
        #expect(SSHConfigReader.keyword(of: "  Host = a b ")?.1 == "a b")
        #expect(SSHConfigReader.keyword(of: "# Host a") == nil)
        #expect(SSHConfigReader.keyword(of: "   ") == nil)
        #expect(SSHConfigReader.arguments("a \"b c\" 'd e' f\\ g h\\\"i x\\y #j k") == ["a", "b c", "d e", "f g", "h\"i", "x\\y"])
        #expect(SSHConfigReader.arguments("\"open") == nil)
        // ssh splits bytes: a combining mark after the space does not glue it to the keyword.
        #expect(SSHConfigReader.keyword(of: "Match \u{0301}exec true")?.0 == "match")
        #expect(SSHConfigReader.arguments("buildbox \u{0301}x") == ["buildbox", "\u{0301}x"])
    }

    @Test func crlfFilesReadLikeLfFiles() {
        let sandbox = FetchSandbox()
        sandbox.writeConfig("Host buildbox\r\n  User x\r\nMatch host y\r\n")
        let reading = reader(sandbox).read()
        #expect(reading.hostTokens == ["buildbox"])
        #expect(reading.hasMatch)
    }

    // MARK: ssh -G

    @Test func sshGOutputIsParsed() {
        let resolution = SSHResolution(output: """
        user buildbox
        hostname 192.0.2.10
        port 22
        proxyusefdpass no
        proxyjump jumpy
        proxycommand none
        """)
        #expect(resolution == SSHResolution(hostName: "192.0.2.10", user: "buildbox", proxyJump: "jumpy"))
        #expect(resolution.proxyNote == "through jumpy")
        #expect(SSHResolution(proxyCommand: "/usr/bin/nc %h %p").proxyNote == "your config runs a proxy command")
        #expect(SSHResolution(proxyJump: "j\u{1B}[2J").proxyNote == "through a jump host")
        #expect(SSHResolution(knownHostsCommand: "/x").proxyNote == "your config runs a known-hosts command")
        #expect(SSHResolution(user: "x").proxyNote == nil)
    }

    /// The real `ssh -G -F <sandbox config>`: prints the settings and exits, never connects.
    @Test(.timeLimit(.minutes(1))) func theRealSshGIsReadThroughTheLookup() async {
        let sandbox = FetchSandbox()
        sandbox.writeConfig("Host buildbox\n  HostName 192.0.2.10\n  User buildbox\n  ProxyJump jumpy\n")
        let resolution = await SSHLookup.resolve(alias: "buildbox", sshPath: "/usr/bin/ssh",
                                                 options: ["-F", sandbox.userConfig],
                                                 environment: ["PATH": "/usr/bin:/bin", "HOME": sandbox.home],
                                                 timeout: 10)
        #expect(resolution?.hostName == "192.0.2.10")
        #expect(resolution?.user == "buildbox")
        #expect(resolution?.proxyJump == "jumpy")
        #expect(resolution?.proxyCommand == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aFailingSshGGivesNoResolution() async {
        let sandbox = FetchSandbox()
        sandbox.writeConfig("Host buildbox\n  NoSuchKeyword yes\n")
        let resolution = await SSHLookup.resolve(alias: "buildbox", sshPath: "/usr/bin/ssh",
                                                 options: ["-F", sandbox.userConfig],
                                                 environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        #expect(resolution == nil)
        let hanging = sandbox.hangingSSH
        let timeout: TimeInterval = 0.3
        let started = MonotonicClock.now()
        let timedOut = await SSHLookup.resolve(alias: "buildbox", sshPath: hanging, options: [],
                                               environment: ["PATH": "/usr/bin:/bin"], timeout: timeout)
        #expect(timedOut == nil)
        // Stopped by the 0.3 s timeout: never before it, and within 5 s of it (the hanging ssh sleeps over 900 s; the
        // 5 s margin covers killing its process group and a busy machine).
        let elapsed = MonotonicClock.now() - started
        #expect(elapsed >= timeout, "not before the timeout: \(elapsed) s")
        #expect(elapsed < timeout + 5, "stopped at the timeout: \(elapsed) s")
    }
}
