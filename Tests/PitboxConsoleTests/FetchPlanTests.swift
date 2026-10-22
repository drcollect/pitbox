import Darwin
import Foundation
import Testing
import PitboxKit
@testable import PitboxConsole

/// Building a Fetch file plan: nothing that could act runs, refusals have their words.
@Suite(.timeLimit(.minutes(1)))
struct FetchPlanTests {
    private func request(_ remotePath: String, alias: String = "buildbox", replyUser: String? = nil,
                         destinationName: String? = nil) -> FetchFileRequest {
        FetchFileRequest(alias: alias, replyUser: replyUser, remotePath: remotePath, destinationName: destinationName)
    }

    private func refusal(_ runner: FetchRunner, _ request: FetchFileRequest, loginUser: String? = nil) async -> FetchPlanRefusal? {
        if case .failure(let refusal) = await runner.plan(for: request, loginUser: loginUser) { return refusal }
        return nil
    }

    @Test func aPlanHoldsTheExactCommandAndTheFreeName() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let runner = FetchRunner(environment: sandbox.environment())
        let remotePath = sandbox.remote + "/release-notes.md"
        let plan = try #require(await makePlan(runner, remotePath: remotePath, replyUser: "alex"))
        #expect(plan.alias == "buildbox")
        #expect(plan.loginUser == "buildbox", "the config's user by default")
        #expect(plan.configUser == "buildbox")
        #expect(plan.replyUser == "alex")
        #expect(plan.proxyNote == nil)
        #expect(plan.fileName == "release-notes.md")
        #expect(plan.previewName == "release-notes.md")
        #expect(plan.remotePath == remotePath)
        #expect(plan.arguments == [
            "/usr/bin/scp", "-o", "LogLevel=ERROR", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "UpdateHostKeys=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no", "-o", "ConnectTimeout=15", "--", "buildbox@buildbox:" + remotePath,
            "<Pitbox staging folder>/release-notes.md",
        ])
        #expect(plan.configFingerprint == runner.configReader.read().fingerprint)
        var info = stat()
        #expect(stat(sandbox.stagingParent, &info) == 0 && info.st_mode & 0o777 == 0o700, "the staging parent is private")
    }

    @Test func theRepliesNameAndTakenNamesShowInThePreview() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        sandbox.write(sandbox.downloads + "/notes.md", "mine")
        _ = symlink("/nowhere", sandbox.downloads + "/notes 2.md")   // a dangling link takes its name too
        let runner = FetchRunner(environment: sandbox.environment())
        let plan = try #require(await makePlan(runner, remotePath: "/srv/x/draft.md", destinationName: "notes.md"))
        #expect(plan.fileName == "notes.md")
        #expect(plan.previewName == "notes 3.md")
        #expect(plan.arguments.last == "<Pitbox staging folder>/notes.md")
    }

    @Test func theRepliesUserIsAVisibleChoiceOnly() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let runner = FetchRunner(environment: sandbox.environment())
        let asReply = try #require(await makePlan(runner, remotePath: "/srv/x.md", replyUser: "alex", loginUser: "alex"))
        #expect(asReply.loginUser == "alex")
        #expect(asReply.arguments.contains("alex@buildbox:/srv/x.md"))
        // "Try as buildbox" re-plans with the config's user.
        let asConfig = try #require(await makePlan(runner, remotePath: "/srv/x.md", replyUser: "alex", loginUser: "buildbox"))
        #expect(asConfig.arguments.contains("buildbox@buildbox:/srv/x.md"))
        // Nobody else, and never a reply user outside the grammar.
        #expect(await refusal(runner, request("/srv/x.md", replyUser: "alex"), loginUser: "root") == .configNeedsRunning)
        let odd = try #require(await makePlan(runner, remotePath: "/srv/x.md", replyUser: "Bad.User"))
        #expect(odd.replyUser == nil)
        #expect(await refusal(runner, request("/srv/x.md", replyUser: "Bad.User"), loginUser: "Bad.User") == .configNeedsRunning)
    }

    @Test func aConfigUserThatWouldBreakTheOperandIsRefused() async {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let runner = FetchRunner(environment: sandbox.environment(resolution: SSHResolution(user: "a@b")))
        #expect(await refusal(runner, request("/srv/x.md")) == .configNeedsRunning)
    }

    @Test func aProxyOfTheAliasIsShown() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let runner = FetchRunner(environment: sandbox.environment(
            resolution: SSHResolution(user: "buildbox", proxyCommand: "/usr/bin/nc %h %p")))
        let plan = try #require(await makePlan(runner, remotePath: "/srv/x.md"))
        #expect(plan.proxyNote == "your config runs a proxy command")
    }

    @Test func theRealSshGGivesTheUserAndTheJump() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig("Host buildbox\n  HostName 192.0.2.10\n  User buildbox\n  ProxyJump jumpy\n")
        let runner = FetchRunner(environment: sandbox.environment(resolution: nil))
        let plan = try #require(await makePlan(runner, remotePath: "/srv/x.md"))
        #expect(plan.loginUser == "buildbox")
        #expect(plan.proxyNote == "through jumpy")
    }

    @Test func theAliasMustBeAnExactHostOfTheConfig() async {
        let sandbox = FetchSandbox()
        sandbox.writeConfig("Host *\n  User x\nHost build*\nHost other\n")
        let runner = FetchRunner(environment: sandbox.environment())
        #expect(await refusal(runner, request("/srv/x.md")) == .aliasNotInConfig)
        #expect(await refusal(runner, request("/srv/x.md", alias: "-oProxyCommand=x")) == .aliasNotInConfig)
        #expect(await refusal(runner, request("/srv/x.md", alias: "con ductor")) == .aliasNotInConfig)
        #expect(await refusal(runner, request("/srv/x.md", alias: "other")) == nil)
        #expect(FetchPlanRefusal.aliasNotInConfig.words == "the server isn't an exact entry in your SSH config")
    }

    @Test func aMatchBlockStopsBeforeSshGRuns() async {
        let sandbox = FetchSandbox()
        sandbox.write(sandbox.sshFolder + "/extra.conf", "Match exec \"/usr/bin/true\"\n")
        sandbox.writeConfig(FetchSandbox.buildboxConfig + "Include extra.conf\n")
        let calls = FetchLogRecorder()
        var environment = sandbox.environment()
        environment.resolver = { alias in calls.record(alias); return SSHResolution(user: "buildbox") }
        let runner = FetchRunner(environment: environment)
        #expect(await refusal(runner, request("/srv/x.md")) == .configNeedsRunning)
        #expect(calls.lines.isEmpty, "ssh -G never ran")
        #expect(FetchPlanRefusal.configNeedsRunning.words == "couldn't read your SSH config without running it")
    }

    @Test func aFailingLookupOrAnUnreadableConfigIsRefused() async {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        var environment = sandbox.environment()
        environment.resolver = { _ in nil }
        #expect(await refusal(FetchRunner(environment: environment), request("/srv/x.md")) == .configNeedsRunning)
        sandbox.writeConfig(FetchSandbox.buildboxConfig + "Include ${HOME}/x\n")
        #expect(await refusal(FetchRunner(environment: sandbox.environment()), request("/srv/x.md")) == .configNeedsRunning)
    }

    @Test func deceptiveNamesAndPathsAreRefused() async {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let runner = FetchRunner(environment: sandbox.environment())
        for path in ["/srv/report.pdf.command", "/srv/notes.md.app", "/srv/-rf.md", "/srv/.zshrc", "/srv/r\u{0435}port.pdf",
                     "/srv/x\u{202E}dm.exe", "/srv/a:b.md", "../../.zshrc", "/srv/*.md", "/srv/dir/", "~"] {
            #expect(await refusal(runner, request(path)) == .deceptiveName, "\(path.debugDescription)")
        }
        #expect(await refusal(runner, request("/srv/ok.md", destinationName: "ok.md.app")) == .deceptiveName)
        #expect(await refusal(runner, request("/srv/ok.md", destinationName: ".bashrc")) == .deceptiveName)
        #expect(FetchPlanRefusal.deceptiveName.words == "the file name looks deceptive: not fetched")
    }

    @Test func downloadsMustBeARealFolder() async {
        let missing = FetchSandbox(createDownloads: false)
        missing.writeConfig()
        #expect(await refusal(FetchRunner(environment: missing.environment()), request("/srv/x.md")) == .downloadsUnavailable)

        let link = FetchSandbox(createDownloads: false)
        link.writeConfig()
        FetchSandbox.makeFolder(link.root + "/elsewhere")
        _ = symlink(link.root + "/elsewhere", link.downloads)
        #expect(await refusal(FetchRunner(environment: link.environment()), request("/srv/x.md")) == .downloadsUnavailable)

        let file = FetchSandbox(createDownloads: false)
        file.writeConfig()
        file.write(file.downloads, "not a folder")
        #expect(await refusal(FetchRunner(environment: file.environment()), request("/srv/x.md")) == .downloadsUnavailable)
        #expect(FetchPlanRefusal.downloadsUnavailable.words == "Downloads isn't available")
    }

    @Test func downloadsOnAnotherVolumeIsRefused() async {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        var environment = sandbox.environment()
        environment.downloads = "/dev"   // devfs: a real folder on another device; only opened, never written
        #expect(await refusal(FetchRunner(environment: environment), request("/srv/x.md")) == .otherVolume)
        #expect(FetchPlanRefusal.otherVolume.words == "Downloads is on another volume")
    }

    @Test func theVolumeMustKeepFiveGigabytesAfterTheLimit() async {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let limits = FetchLimits.tests
        let justEnough = limits.freeSpaceReserve + limits.maxFileBytes
        let enough = FetchRunner(environment: sandbox.environment(freeSpace: { _ in justEnough }))
        #expect(await refusal(enough, request("/srv/x.md")) == nil)
        let short = FetchRunner(environment: sandbox.environment(freeSpace: { _ in justEnough - 1 }))
        #expect(await refusal(short, request("/srv/x.md")) == .notEnoughSpace)
        #expect(FetchPlanRefusal.notEnoughSpace.words == "not enough free space for a fetch")
        let home = FetchFolders.openFolder(sandbox.home)
        defer { close(home) }
        #expect((FetchFolders.freeBytes(home) ?? 0) > 0, "the real fstatfs answers")
    }

    @Test func theSheetsHelpers() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let runner = FetchRunner(environment: sandbox.environment())
        let asReply = try #require(await makePlan(runner, remotePath: "/srv/x.md", replyUser: "alex", loginUser: "alex"))
        #expect(asReply.offersTryAsConfigUser(after: .failed(reason: "buildbox didn't accept your key for alex")))
        #expect(!asReply.offersTryAsConfigUser(after: .failed(reason: "no such file on buildbox")))
        #expect(!asReply.offersTryAsConfigUser(after: .cancelled))
        let asConfig = try #require(await makePlan(runner, remotePath: "/srv/x.md", replyUser: "alex"))
        #expect(!asConfig.offersTryAsConfigUser(after: .failed(reason: "buildbox didn't accept your key for buildbox")))
        #expect(asConfig.fileExtension == "md")
        #expect(FetchLimits().sheetLine == "up to 500 MB and 10 minutes")
    }

    @Test func theLiveEnvironmentIsTheTerminalsAllowlistWithTheCleanPath() {
        let terminal = fixtureEnvironment(parent: ["SSH_AUTH_SOCK": "/tmp/agent.sock", "PATH": "./bin:/usr/bin",
                                                   "DYLD_INSERT_LIBRARIES": "/x.dylib", "BASH_ENV": "/x", "ZDOTDIR": "/x",
                                                   "TMPDIR": "/tmp/t/", "SECRET_TOKEN": "x"])
        let environment = FetchEnvironment.processEnvironment(from: terminal)
        #expect(environment["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent.sock", "scp may use the ssh-agent")
        #expect(environment["HOME"] == "/Users/tester")
        #expect(environment["SHELL"] == "/bin/zsh")
        for name in ["DYLD_INSERT_LIBRARIES", "BASH_ENV", "ZDOTDIR", "SECRET_TOKEN"] { #expect(environment[name] == nil, "\(name)") }
        let live = FetchEnvironment.live
        #expect(live.downloads == live.home + "/Downloads")
        #expect(live.stagingParent == Paths.cachesDir.appendingPathComponent("fetch", isDirectory: true).path, "the app's caches folder")
        #expect(live.userConfig == live.home + "/.ssh/config")
        #expect(live.systemConfig == "/etc/ssh/ssh_config")
        #expect(live.extraSCPOptions.isEmpty && live.resolveOptions.isEmpty && live.resolver == nil)
        #expect(live.limits == FetchLimits())
    }

    @Test func sshGNeverGetsTheAgentSocket() async {
        let sandbox = FetchSandbox()
        let printer = sandbox.makeScript("print-env", "printf 'user %s\\nhostname %s\\n' \"$SSH_AUTH_SOCK\" \"$HOME\"")
        let resolution = await SSHLookup.resolve(alias: "buildbox", sshPath: printer, options: [],
                                                 environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock", "HOME": "/h"],
                                                 timeout: 10)
        #expect(resolution?.user == nil, "SSH_AUTH_SOCK was not passed")
        #expect(resolution?.hostName == "/h", "the rest of the environment was")
    }

    @Test func planLogsCarryLabelsAndNumbersOnly() async throws {
        let sandbox = FetchSandbox()
        sandbox.writeConfig()
        let log = FetchLogRecorder()
        let runner = FetchRunner(environment: sandbox.environment(), log: log.sink)
        _ = try #require(await makePlan(runner, remotePath: sandbox.remote + "/secret-name.md", replyUser: "alex"))
        _ = await refusal(runner, request("/srv/secret-name.md.app"))
        #expect(log.lines.count == 2)
        for line in log.lines {
            for value in ["buildbox", "alex", "secret-name", sandbox.root, "192.0.2.10", "/srv"] {
                #expect(!line.contains(value), "\(line)")
            }
            #expect(line.hasPrefix("fetch plan "))
        }
    }
}
