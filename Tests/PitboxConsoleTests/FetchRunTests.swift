import Darwin
import Foundation
import Testing
import PitboxKit
@testable import PitboxConsole

/// A counter shared with `@Sendable` closures.
final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Running Fetch file for real, offline: the real /usr/bin/scp with `-S <fake ssh>` serving the sandbox's remote folder
/// through the local sftp-server.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct FetchRunTests {
    // MARK: The copy

    @Test func aFileIsCopiedQuarantinedAndMovedIntoDownloads() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let remotePath = sandbox.writeRemote("release-notes.md", bytes: 42_000)
        chmod(remotePath, 0o755)
        let log = FetchLogRecorder()
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH), log: log.sink)
        let plan = try #require(await makePlan(runner, remotePath: remotePath, replyUser: "alex"))
        let probe = await runFetch(runner, plan)
        #expect(probe.outcome == .saved(fileName: "release-notes.md", bytes: 42_000))

        let saved = sandbox.downloads + "/release-notes.md"
        #expect(sandbox.data(saved) == sandbox.data(remotePath), "the same bytes")
        var info = stat()
        #expect(lstat(saved, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o644, "mode 0644 whatever the server's mode")
        let parts = try #require(quarantineValue(atPath: saved)).split(separator: ";").map(String.init)
        #expect(parts.count == 4)
        #expect(parts.first == "0081")
        #expect(parts.count > 1 && parts[1].count == 8 && UInt32(parts[1], radix: 16) != nil, "the time in hex")
        #expect(parts.count > 2 && parts[2] == "Pitbox")
        #expect(parts.count > 3 && UUID(uuidString: parts[3]) != nil)
        #expect(sandbox.entries(sandbox.stagingParent).isEmpty, "the staging folder is gone")
        #expect(runner.runningCount == 0)

        for line in log.lines {
            for value in ["buildbox", "alex", "release-notes", sandbox.root, "192.0.2.10"] {
                #expect(!line.contains(value), "\(line)")
            }
        }
        #expect(log.lines.contains { $0.hasPrefix("fetch finished run=#1 result=saved bytes=42000 copy=1") })
    }

    @Test func aTakenNameGetsTheNextFreeNumberAndNothingIsReplaced() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        sandbox.write(sandbox.downloads + "/release-notes.md", "mine")
        let remotePath = sandbox.writeRemote("release-notes.md", text: "from the server")
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH))
        let plan = try #require(await makePlan(runner, remotePath: remotePath))
        #expect(plan.previewName == "release-notes 2.md")
        #expect(await runFetch(runner, plan).outcome == .saved(fileName: "release-notes 2.md", bytes: 15))
        #expect(await runFetch(runner, plan).outcome == .saved(fileName: "release-notes 3.md", bytes: 15),
                "the rename decides at the end, not the preview")
        #expect(sandbox.data(sandbox.downloads + "/release-notes.md") == Data("mine".utf8))
        #expect(sandbox.entries(sandbox.downloads) == ["release-notes 2.md", "release-notes 3.md", "release-notes.md"])
    }

    @Test func aRemoteLinkIsFollowedOnTheServer() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        sandbox.writeRemote("target.md", text: "linked")
        _ = symlink(sandbox.remote + "/target.md", sandbox.remote + "/link.md")
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH))
        let plan = try #require(await makePlan(runner, remotePath: sandbox.remote + "/link.md"))
        #expect(await runFetch(runner, plan).outcome == .saved(fileName: "link.md", bytes: 6))
        var info = stat()
        #expect(lstat(sandbox.downloads + "/link.md", &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG)
    }

    // MARK: Limits

    @Test func theSizeLimitStopsScpAndLeavesNoPartialFile() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        var limits = FetchLimits.tests
        limits.maxFileBytes = 1_048_576
        let remotePath = sandbox.writeRemote("big.bin", bytes: 3 * 1_048_576)
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH, limits: limits))
        let plan = try #require(await makePlan(runner, remotePath: remotePath))
        #expect(await runFetch(runner, plan).outcome == .failed(reason: "stopped: larger than 1 MB"))
        #expect(sandbox.entries(sandbox.downloads).isEmpty)
        #expect(sandbox.entries(sandbox.stagingParent).isEmpty, "scp's partial file went with the staging folder")
        #expect(FetchFailure.tooLarge.words(alias: "a", user: "u", fileName: "f", limits: FetchLimits()) == "stopped: larger than 500 MB")
    }

    /// The size limit's unit: `ulimit -f` counts 1024-byte blocks in this Mac's /bin/sh, so the wrapper's limit is
    /// exactly the bytes asked for, and scp is stopped by SIGXFSZ (leaving its partial file, which the runner removes).
    @Test func theWrapperLimitIsInBytesOfTheRequestedSize() async {
        let sandbox = FetchSandbox()
        let remotePath = sandbox.writeRemote("big.bin", bytes: 3 * 1_048_576)
        let scp = FetchCommand.arguments(user: "u", alias: "buildbox", remotePath: remotePath, stagingFolder: sandbox.root,
                                         fileName: "partial.bin", connectTimeout: 15, extraOptions: ["-S", sandbox.sftpSSH])
        let spawn = FetchCommand.spawnArguments(scpArguments: scp, maxFileBytes: 1_048_576)
        #expect(spawn.prefix(4) == ["/bin/sh", "-c", "ulimit -f 1024 && exec /usr/bin/scp \"$@\"", "sh"])
        #expect(Array(spawn.dropFirst(4)) == Array(scp.dropFirst()), "scp's arguments are positional parameters")
        let result = await runTool(spawn[0], Array(spawn.dropFirst()))
        #expect(result.status == .signaled(SIGXFSZ))
        var info = stat()
        #expect(stat(sandbox.root + "/partial.bin", &info) == 0)
        #expect(info.st_size == 1_048_576)
    }

    @Test func cancelMidCopyStopsScpAndRemovesEverything() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let remotePath = sandbox.writeRemote("big.bin", bytes: 2 * 1_048_576)
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.gatedSSH))
        let plan = try #require(await makePlan(runner, remotePath: remotePath))
        let probe = await runFetch(runner, plan) { size, probe in
            guard size > 0, !probe.acted else { return }
            probe.acted = true
            probe.handle?.cancel()
        }
        #expect(probe.outcome == .cancelled)
        #expect(probe.progress.contains { $0 > 0 }, "it was mid-copy")
        #expect((probe.progress.last ?? 0) < 2 * 1_048_576)
        #expect(sandbox.entries(sandbox.downloads).isEmpty)
        #expect(sandbox.entries(sandbox.stagingParent).isEmpty)
        #expect(runner.runningCount == 0)
        #expect(await waitForNoProcess(mentioning: sandbox.root), "scp and its ssh are gone")
    }

    @Test func nothingStagedWithinTheConnectDeadlineIsATimeout() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        var limits = FetchLimits.tests
        limits.connectDeadline = 0.5
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.hangingSSH, limits: limits))
        let plan = try #require(await makePlan(runner, remotePath: sandbox.writeRemote("x.md", text: "x")))
        let started = MonotonicClock.now()
        #expect(await runFetch(runner, plan).outcome == .failed(reason: "timed out"))
        // The deadline ended it, not the hanging ssh (it sleeps over 900 s): measured against the configured deadline
        // with a margin no loaded machine needs, and never before it.
        let elapsed = MonotonicClock.now() - started
        #expect(elapsed >= limits.connectDeadline, "not before the deadline: \(elapsed) s")
        #expect(elapsed < limits.connectDeadline + 60, "the deadline fired: \(elapsed) s")
        #expect(sandbox.entries(sandbox.stagingParent).isEmpty)
        #expect(await waitForNoProcess(mentioning: "sleep \(sandbox.hangSeconds)"), "the hanging ssh was killed with its group")
    }

    @Test func theWholeFetchHasADeadline() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        var limits = FetchLimits.tests
        // The gated ssh holds the copy mid-way; the staged file exists, so only this can fire. 4 s leaves scp's start and
        // the first 0.5 s progress poll room under load (2.5 s failed about 1 run in 3 with the full suite running).
        limits.totalDeadline = 4
        let remotePath = sandbox.writeRemote("big.bin", bytes: 2 * 1_048_576)
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.gatedSSH, limits: limits))
        let plan = try #require(await makePlan(runner, remotePath: remotePath))
        let started = Date()
        let probe = await runFetch(runner, plan)
        let elapsed = Date().timeIntervalSince(started)
        #expect(probe.outcome == .failed(reason: "timed out"))
        #expect(elapsed >= 3.9, "not before the deadline: \(elapsed) s")
        // Not asserted: whether scp had copied anything yet. Under load scp can start late, and the deadline must fire
        // either way (this line once failed with every suite running).
        #expect(sandbox.entries(sandbox.downloads).isEmpty)
        #expect(sandbox.entries(sandbox.stagingParent).isEmpty)
    }

    @Test func freeSpaceFallingBelowTheReserveStopsTheFetch() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let calls = FetchCounter()
        let remotePath = sandbox.writeRemote("big.bin", bytes: 2 * 1_048_576)
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.gatedSSH, freeSpace: { _ in
            calls.next() <= 4 ? 1 << 40 : 4_999_999_999
        }))
        let plan = try #require(await makePlan(runner, remotePath: remotePath))
        #expect(await runFetch(runner, plan).outcome == .failed(reason: "stopped: less than 5 GB free"))
        #expect(sandbox.entries(sandbox.downloads).isEmpty)
        #expect(sandbox.entries(sandbox.stagingParent).isEmpty)
    }

    // MARK: Checked again before connecting, and after the copy

    @Test func aConfigChangedSinceThePlanStartsNothing() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH))
        let plan = try #require(await makePlan(runner, remotePath: sandbox.writeRemote("x.md", text: "x")))
        sandbox.writeConfig(FetchSandbox.buildboxConfig + "  ForwardAgent yes\n")
        #expect(await runFetch(runner, plan).outcome == .failed(reason: "your SSH config changed; review again"))
        #expect(sandbox.entries(sandbox.stagingParent).isEmpty, "no staging folder was made")
        #expect(sandbox.entries(sandbox.downloads).isEmpty)

        // Only the time changes: still a change (size, time and hash).
        let fresh = try #require(await makePlan(runner, remotePath: sandbox.remote + "/x.md"))
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 0), timespec(tv_sec: 1_700_000_000, tv_nsec: 0)]
        _ = utimensat(AT_FDCWD, sandbox.userConfig, &times, 0)
        #expect(await runFetch(runner, fresh).outcome == .failed(reason: "your SSH config changed; review again"))
    }

    @Test func downloadsSwappedDuringTheCopyFails() async throws {
        for asLink in [false, true] {
            let sandbox = FetchSandbox()
            sandbox.writeConfig()
            let remotePath = sandbox.writeRemote("big.bin", bytes: 1_048_576)
            let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.gatedSSH))
            let plan = try #require(await makePlan(runner, remotePath: remotePath))
            let old = sandbox.home + "/Downloads-old"
            let probe = await runFetch(runner, plan) { size, probe in
                guard size > 0, !probe.acted else { return }
                probe.acted = true
                _ = rename(sandbox.downloads, old)
                if asLink { _ = symlink(old, sandbox.downloads) } else { FetchSandbox.makeFolder(sandbox.downloads) }
                sandbox.openGate()   // only now can the copy finish
            }
            #expect(probe.outcome == .failed(reason: "Downloads changed"), "as a link: \(asLink)")
            #expect(sandbox.entries(old).isEmpty, "nothing went into the folder bound at the start")
            if !asLink { #expect(sandbox.entries(sandbox.downloads).isEmpty) }
            #expect(sandbox.entries(sandbox.stagingParent).isEmpty)
        }
    }

    @Test func aQuarantineThatCannotBeSetOrReadBackFails() async throws {
        let failingWrite = FetchQuarantineIO(set: { _, _ in EPERM }, get: FetchQuarantineIO.system.get)
        let otherValue = FetchQuarantineIO(set: FetchQuarantineIO.system.set, get: { _ in Array("0081;0;Other;x".utf8) })
        for io in [failingWrite, otherValue] {
            let sandbox = FetchSandbox()
            sandbox.writeConfig()
            let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH, quarantine: io))
            let plan = try #require(await makePlan(runner, remotePath: sandbox.writeRemote("x.md", text: "x")))
            #expect(await runFetch(runner, plan).outcome == .failed(reason: "couldn't mark the file as downloaded: not fetched"))
            #expect(sandbox.entries(sandbox.downloads).isEmpty)
            #expect(sandbox.entries(sandbox.stagingParent).isEmpty)
        }
    }

    @Test func aPlanIsNeverTrustedAsACommand() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH))
        let plan = try #require(await makePlan(runner, remotePath: sandbox.writeRemote("x.md", text: "x"), replyUser: "alex"))
        var weaker = plan
        weaker.arguments.removeAll { $0 == "BatchMode=yes" }
        var otherUser = plan
        otherUser.loginUser = "root"
        var otherName = plan
        otherName.fileName = "x.md.app"
        var otherHost = plan
        otherHost.alias = "-oProxyCommand=sh"
        let words = "this fetch no longer matches what you reviewed; review again"
        for tampered in [weaker, otherUser, otherName, otherHost] {
            #expect(await runFetch(runner, tampered).outcome == .failed(reason: words))
        }
        #expect(sandbox.entries(sandbox.downloads).isEmpty)
    }

    // MARK: How many at once

    @Test func oneFetchPerSessionAndTwoOverall() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig(FetchSandbox.buildboxConfig + "Host second\nHost third\n")
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.gatedSSH))
        let remotePath = sandbox.writeRemote("big.bin", bytes: 2 * 1_048_576)
        func plan(_ alias: String) async throws -> FetchPlan {
            let request = FetchFileRequest(alias: alias, replyUser: nil, remotePath: remotePath, destinationName: nil)
            guard case .success(let plan) = await runner.plan(for: request, loginUser: nil) else { throw CancellationError() }
            return plan
        }
        let first = startFetch(runner, try await plan("buildbox"))
        let sameSession = await runFetch(runner, try await plan("buildbox"))
        #expect(sameSession.outcome == .failed(reason: "a fetch from buildbox is already running"))
        let second = startFetch(runner, try await plan("second"))
        let third = await runFetch(runner, try await plan("third"))
        #expect(third.outcome == .failed(reason: "two fetches are already running; try again when one has finished"))
        #expect(runner.runningCount == 2)

        first.handle?.cancel()
        second.handle?.cancel()
        #expect(await waitUntil(20) { first.outcome != nil && second.outcome != nil })
        #expect(first.outcome == .cancelled && second.outcome == .cancelled)
        #expect(runner.runningCount == 0, "both slots are free again")
        let again = startFetch(runner, try await plan("third"))
        #expect(await waitUntil(5) { !again.progress.isEmpty || again.outcome != nil })
        #expect(again.outcome == nil, "a new fetch runs once a slot is free")
        again.handle?.cancel()
        #expect(await waitUntil(20) { again.outcome != nil })
    }

    @Test func theOutcomeArrivesExactlyOnce() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH))
        let plan = try #require(await makePlan(runner, remotePath: sandbox.writeRemote("x.md", text: "x")))
        let probe = await runFetch(runner, plan)
        probe.handle?.cancel()
        probe.handle?.cancel()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(probe.outcomes == [.saved(fileName: "x.md", bytes: 1)])
    }

    /// A caller that keeps the handle while its callbacks capture it (the sheet) is not kept alive by a finished fetch.
    @Test func aFinishedFetchLetsGoOfItsCallbacks() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH))
        let plan = try #require(await makePlan(runner, remotePath: sandbox.writeRemote("x.md", text: "x")))
        weak var weakOwner: FetchCounter?
        let probe: FetchProbe = await {
            let owner = FetchCounter()
            weakOwner = owner
            return await runFetch(runner, plan) { _, _ in _ = owner.next() }
        }()
        #expect(probe.outcome == .saved(fileName: "x.md", bytes: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(probe.handle != nil, "the caller still holds the handle")
        #expect(weakOwner == nil, "the job dropped the progress and completion callbacks when it ended")
    }

    @Test func leftoverStagingFoldersAreSweptButOthersStay() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let old = sandbox.stagingParent + "/fetch-" + String(repeating: "0", count: 32)
        FetchSandbox.makeFolder(old)
        sandbox.write(old + "/partial.bin", "left behind")
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 0), timespec(tv_sec: 1_700_000_000, tv_nsec: 0)]
        _ = utimensat(AT_FDCWD, old, &times, 0)
        FetchSandbox.makeFolder(sandbox.stagingParent + "/not-ours")
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH))
        let plan = try #require(await makePlan(runner, remotePath: sandbox.writeRemote("x.md", text: "x")))
        #expect(await runFetch(runner, plan).outcome == .saved(fileName: "x.md", bytes: 1))
        #expect(sandbox.entries(sandbox.stagingParent) == ["not-ours"])
    }

    // MARK: Failures in Pitbox's words

    /// What a real ssh printed on this Mac (OpenSSH 10.2p1, LogLevel=ERROR, measured with a local sshd): the words name
    /// the alias and the login user, never the reply's host.
    @Test func sshFailuresReadAsTheirReasons() async throws {
        let cases: [(String, String)] = [
            ("alex@192.0.2.10: Permission denied (publickey).", "buildbox didn't accept your key for alex"),
            ("alex@192.0.2.10: Permission denied (publickey,password).",
             "buildbox asked for a password (use Run in terminal)"),
            ("alex@192.0.2.10: Permission denied (publickey,keyboard-interactive).",
             "buildbox asked for a password (use Run in terminal)"),
            ("No ED25519 host key is known for 192.0.2.10 and you have requested strict checking.\nHost key verification failed.",
             "the host key for buildbox is unknown or changed: not fetched"),
            ("@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key for 192.0.2.10 has changed and you have requested strict checking.\nHost key verification failed.",
             "the host key for buildbox is unknown or changed: not fetched"),
            ("ssh: connect to host 192.0.2.10 port 22: Operation timed out", "timed out"),
            ("ssh: connect to host 192.0.2.10 port 22: Connection refused", "buildbox refused the connection"),
            ("ssh: Could not resolve hostname x.invalid: nodename nor servname provided, or not known",
             "couldn't look up buildbox's address"),
            ("kex_exchange_identification: read: Connection reset by peer", "couldn't connect to buildbox"),
        ]
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let remotePath = sandbox.writeRemote("x.md", text: "x")
        for (stderr, words) in cases {
            let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.failingSSH(stderr)))
            let plan = try #require(await makePlan(runner, remotePath: remotePath, replyUser: "alex", loginUser: "alex"))
            #expect(await runFetch(runner, plan).outcome == .failed(reason: words), "\(stderr)")
        }
        #expect(sandbox.entries(sandbox.stagingParent).isEmpty)
    }

    @Test func remoteFileFailuresReadAsTheirReasons() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        FetchSandbox.makeFolder(sandbox.remote + "/folder.md")
        chmod(sandbox.writeRemote("locked.md", text: "x"), 0o000)
        let runner = FetchRunner(environment: sandbox.environment(ssh: sandbox.sftpSSH))
        for (name, words) in [("missing.md", "no such file on buildbox"),
                              ("folder.md", "that's a folder or not a plain file on buildbox"),
                              ("locked.md", "no permission to read that file on buildbox")] {
            let plan = try #require(await makePlan(runner, remotePath: sandbox.remote + "/" + name))
            #expect(await runFetch(runner, plan).outcome == .failed(reason: words), "\(name)")
        }
        #expect(sandbox.entries(sandbox.downloads).isEmpty)
    }

    // MARK: Helpers

    private func waitForNoProcess(mentioning needle: String) async -> Bool {
        for _ in 0..<40 {
            if await processesMentioning(needle).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
