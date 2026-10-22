import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// The command tabs' spawn path on real pseudo-terminals: the helper path and the forkpty fallback. Harmless commands
/// only, in private folders under `CommandTestPaths.root`.
@MainActor
@Suite(.serialized)
struct CommandsSpawnTests {
    @Test(.timeLimit(.minutes(1))) func theHelperIsBuiltNextToTheTestsAndPassesItsCheck() throws {
        let helper = CommandTestPaths.helper
        #expect(FileManager.default.isExecutableFile(atPath: helper.path), "SwiftPM builds pitbox-command-helper")
        #expect((try? CommandHelperLocator.check(helper).get()) == helper)
        #expect(CommandSpawner.responsibilityDisclaimer() != nil, "this macOS has responsibility_spawnattrs_setdisclaim")
    }

    @Test(.timeLimit(.minutes(1))) func aCommandRunsTheCleanShellExactlyInTheBoundFolder() async throws {
        let folder = CommandTempFolder("run")
        let script = #"print -r -- "dir=$(pwd -P)"; [[ -o interactive ]] && print i=1; [[ -o interactivecomments ]] && print ic=1; [[ -o banghist ]] || print nobang=1; [[ -o rcs ]] || print norcs=1; print -r -- "hist=${HISTFILE-unset}"; print -r -- "zero=$0"; exit 3"#
        let probe = try CommandProbe(testDescriptor(script, folder: folder.path), folder: folder.path, launcher: helperLauncher())
        #expect(try #require(await probe.waitForStart()) == .started)
        #expect(await probe.waitForExit() == .exited(3))
        let real = try #require(CommandSandbox.canonicalPath(folder.path))
        #expect(probe.text.contains("dir=\(real)"), "the shell starts in the bound folder")
        for marker in ["i=1", "ic=1", "nobang=1", "norcs=1", "hist=unset", "zero=/bin/zsh"] {
            #expect(probe.text.contains(marker), "missing \(marker)")
        }
    }

    @Test(.timeLimit(.minutes(1))) func theEnvironmentIsTheAllowlistAndNothingElse() async throws {
        let folder = CommandTempFolder("env")
        let environment = commandTestEnvironment(parent: ["SSH_AUTH_SOCK": "/private/tmp/agent.sock", "DYLD_INSERT_LIBRARIES": "/x",
                                                          "ZDOTDIR": "/y", "BASH_ENV": "/z"])
        let probe = try CommandProbe(testDescriptor("/usr/bin/env", folder: folder.path), folder: folder.path,
                                     launcher: helperLauncher(), environment: environment)
        #expect(await probe.waitForExit() == .exited(0))
        let names = Set(probe.text.split(whereSeparator: { $0.isNewline }).compactMap { line -> String? in
            guard let equals = line.firstIndex(of: "=") else { return nil }
            return String(line[..<equals])
        })
        // zsh adds PWD, OLDPWD, SHLVL and _ itself; everything else must be the allowlist.
        let expected = Set(CommandEnvironmentRules.cleanNames).subtracting(["TMPDIR", "__CF_USER_TEXT_ENCODING"])
        #expect(expected.isSubset(of: names), "missing: \(expected.subtracting(names).sorted())")
        let extra = names.subtracting(CommandEnvironmentRules.cleanNames).subtracting(["PWD", "OLDPWD", "SHLVL", "_"])
        #expect(extra.isEmpty, "unexpected names: \(extra.sorted())")
        #expect(probe.text.contains("PATH=\(CommandExecutionDescriptor.cleanPath)"))
        #expect(probe.text.contains("SHELL=/bin/zsh"))
        #expect(!probe.text.contains("SSH_AUTH_SOCK"), "no ssh-agent unless an ssh-family program runs")
    }

    @Test(.timeLimit(.minutes(1))) func theSSHAgentIsPassedOnlyWhenTheDescriptorNamesIt() async throws {
        let folder = CommandTempFolder("agent")
        let environment = commandTestEnvironment(parent: ["SSH_AUTH_SOCK": "/private/tmp/agent.sock"])
        let probe = try CommandProbe(testDescriptor(#"print -r -- "sock=$SSH_AUTH_SOCK""#, folder: folder.path, sshAgent: true),
                                     folder: folder.path, launcher: helperLauncher(), environment: environment)
        #expect(await probe.waitForExit() == .exited(0))
        #expect(probe.text.contains("sock=/private/tmp/agent.sock"))
    }

    @Test(.timeLimit(.minutes(1))) func theShellHasAControllingTerminalAndItsOwnIdentity() async throws {
        let folder = CommandTempFolder("tty")
        // `print done` keeps zsh from exec'ing the last command in place, so sleep runs as a job of the shell.
        let script = #"print -r -- "tty=$(tty)"; [[ -o monitor ]] && print jobs=1; sleep 30; print done"#
        let probe = try CommandProbe(testDescriptor(script, folder: folder.path), folder: folder.path, launcher: helperLauncher())
        #expect(await probe.waitForText("jobs=1"), "job control is on")
        #expect(probe.text.contains("tty=/dev/ttys"), "the pty is the shell's terminal")
        #expect(await waitUntil(5) { probe.process.inspect()?.isSessionLeader == false })
        let pid = probe.process.pid
        let foreground = try #require(probe.process.inspect())
        #expect(!foreground.isSessionLeader && foreground.pgid != pid, "sleep runs as its own foreground group")
        #expect(CommandSpawner.responsiblePID(for: pid) == pid, "the shell is its own responsible process, not the tests'")
        #expect(CommandSpawner.responsiblePID(for: pid) != CommandSpawner.responsiblePID(for: getpid()))
        probe.process.interruptForeground()
        #expect(await probe.waitForExit() == .exited(130), "Stop's SIGINT ends the job and the shell")
        #expect(!probe.text.contains("done"))
    }

    /// Measured on macOS 26.5.1: Seatbelt never lets a sandboxed process exec a setuid program, whatever the profile
    /// allows (`ps`, `top`, `sudo`, `su`, `crontab`, `at`, `traceroute`, `login`). Command tabs keep the strict
    /// profile and the sheet says so for such programs.
    @Test(.timeLimit(.minutes(1))) func setuidProgramsCannotStartInsideTheSandbox() async throws {
        let folder = CommandTempFolder("setuid")
        let probe = try CommandProbe(testDescriptor(#"/bin/ps -o pid= -p $$; print -r -- "rc=$?""#, folder: folder.path),
                                     folder: folder.path, launcher: helperLauncher())
        #expect(await probe.waitForExit() == .exited(0))
        #expect(probe.text.contains("operation not permitted"))
        #expect(probe.text.contains("rc=127"))
    }

    @Test(.timeLimit(.minutes(1))) func ctrlCFromTheKeyboardReachesTheJob() async throws {
        let folder = CommandTempFolder("ctrlc")
        let probe = try CommandProbe(testDescriptor("print ready; sleep 30; print AFTER", folder: folder.path), folder: folder.path,
                                     launcher: helperLauncher())
        #expect(await probe.waitForText("ready"))
        #expect(await waitUntil(5) { probe.process.inspect()?.isSessionLeader == false })
        probe.process.write([0x03])
        #expect(await probe.waitForExit() == .exited(130))
        #expect(!probe.text.contains("AFTER"), "the rest of the script did not run")
    }

    @Test(.timeLimit(.minutes(1))) func readTakesInputWrittenToThePty() async throws {
        let folder = CommandTempFolder("read")
        let probe = try CommandProbe(testDescriptor(#"read -r "?Name: " n; print -r -- "got=$n""#, folder: folder.path),
                                     folder: folder.path, launcher: helperLauncher())
        #expect(await probe.waitForText("Name: "))
        probe.process.write(Array("hello\r".utf8))
        #expect(await probe.waitForExit() == .exited(0))
        #expect(probe.text.contains("got=hello"))
    }

    @Test(.timeLimit(.minutes(1))) func hiddenInputIsSeenOnTheTerminalFlags() async throws {
        let folder = CommandTempFolder("hidden")
        let probe = try CommandProbe(testDescriptor(#"read -s "?Secret: " s; print -r -- "len=${#s}""#, folder: folder.path),
                                     folder: folder.path, launcher: helperLauncher())
        #expect(await probe.waitForText("Secret: "))
        #expect(await waitUntil(5) { probe.process.inputModes()?.asksForHiddenInput == true })
        probe.process.write(Array("abc\r".utf8))
        #expect(await probe.waitForExit() == .exited(0))
        #expect(probe.text.contains("len=3"))
        #expect(!probe.text.contains("abc"), "nothing typed was echoed")
    }

    @Test(.timeLimit(.minutes(1))) func theSecondStopKillsAJobThatIgnoresInterrupts() async throws {
        let folder = CommandTempFolder("kill")
        let probe = try CommandProbe(testDescriptor("trap '' INT; print ready; /bin/sleep 30", folder: folder.path),
                                     folder: folder.path, launcher: helperLauncher())
        #expect(await probe.waitForText("ready"))
        probe.process.interruptForeground()
        #expect(await probe.waitForExit(timeout: 0.6) == nil, "SIGINT is ignored")
        probe.process.killSession()
        #expect(await probe.waitForExit() == .signaled(SIGKILL))
    }

    @Test(.timeLimit(.minutes(1))) func privateFilesAndSocketsAreClosedButOtherFilesAreNot() async throws {
        let folder = CommandTempFolder("sandbox")
        // A stand-in for Paths.appSupport with a private file and a listening dock socket. Short path: sun_path.
        let state = URL(fileURLWithPath: "/private/tmp/pitbox-\(getuid())-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: state) }
        try Data("private".utf8).write(to: state.appendingPathComponent("grants.json"))
        let socketPath = state.appendingPathComponent("dock.sock").path
        let listener = try UnixListener(path: socketPath)
        defer { listener.close() }
        folder.write("mine.txt", "visible")
        let script = """
        cat \(ShellQuote.quote(state.path + "/grants.json")) >/dev/null 2>&1 && print READ_PRIVATE || print DENIED_PRIVATE
        cat mine.txt >/dev/null 2>&1 && print READ_OWN || print DENIED_OWN
        /usr/bin/python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); print("CONNECTED")' \(ShellQuote.quote(socketPath)) 2>/dev/null || print SOCKET_DENIED
        \(SandboxProbe.run("print -r -- x > " + ShellQuote.quote(state.path + "/written.txt"), "OWNWRITE"))
        """
        let probe = try CommandProbe(testDescriptor(script, folder: folder.path), folder: folder.path,
                                     launcher: helperLauncher(policy: .testPolicy(ownFolder: state)))
        #expect(await probe.waitForExit(timeout: 20) == .exited(0))
        #expect(probe.text.contains("DENIED_PRIVATE") && !probe.text.contains("READ_PRIVATE"))
        #expect(probe.text.contains("READ_OWN"))
        #expect(probe.text.contains("SOCKET_DENIED") && !probe.text.contains("CONNECTED"))
        #expect(SandboxProbe.results(probe.text)["OWNWRITE"] == "DENIED", "no write into Pitbox's own folder")
        #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("written.txt").path))
    }

    /// Measured: renaming a parent of a protected folder (the Application Support tree's parent, the tree
    /// itself, an announced socket folder or its parent) is denied, so Pitbox's folder, `dock.sock`, the settings file
    /// and the announced folders never come under a path no rule names; every access through the would-be new path
    /// fails.
    @Test(.timeLimit(.minutes(1))) func renamingAParentOfAProtectedFolderIsDenied() async throws {
        let folder = CommandTempFolder("rename")
        let base = try SandboxStandIn("pbmv")
        let moved = URL(fileURLWithPath: base.url.path + "-moved")
        defer { base.remove(); try? FileManager.default.removeItem(at: moved) }
        let root = try base.folder("AS"), run = try base.folder("run")
        let own = root.appendingPathComponent("Pitbox"), host = root.appendingPathComponent("Host")
        let runner = run.appendingPathComponent("hostrunner")
        for place in [own, host, runner] {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Data("private".utf8).write(to: own.appendingPathComponent("grants.json"))
        try Data("{}".utf8).write(to: host.appendingPathComponent("state.json"))
        let listeners = try [own.appendingPathComponent("dock.sock"), host.appendingPathComponent("ctl.sock"),
                             runner.appendingPathComponent("r.sock")].map { try UnixListener(path: $0.path) }
        defer { listeners.forEach { $0.close() } }
        let b = base.url.path, m = moved.path
        let q = ShellQuote.quote
        let script = [
            SandboxProbe.run("mv \(q(b)) \(q(m))", "MVBASE"),
            SandboxProbe.connect(m + "/AS/Pitbox/dock.sock", "BASEDOCK"),
            SandboxProbe.read(m + "/AS/Pitbox/grants.json", "BASEGRANTS"),
            SandboxProbe.run("print -r -- x > \(q(m + "/AS/Pitbox/settings.json"))", "BASESETTINGS"),
            SandboxProbe.connect(m + "/AS/Host/ctl.sock", "BASECTL"),
            SandboxProbe.run("mv \(q(b + "/AS")) \(q(b + "/ASX"))", "MVROOT"),
            SandboxProbe.connect(b + "/ASX/Pitbox/dock.sock", "ROOTDOCK"),
            SandboxProbe.run("print -r -- x > \(q(b + "/ASX/Pitbox/settings.json"))", "ROOTSETTINGS"),
            SandboxProbe.read(b + "/ASX/Host/state.json", "ROOTSTATE"),
            SandboxProbe.run("mv \(q(runner.path)) \(q(b + "/run/x"))", "MVRUNNER"),
            SandboxProbe.connect(b + "/run/x/r.sock", "RUNNERSOCK"),
            SandboxProbe.run("mv \(q(run.path)) \(q(b + "/runx"))", "MVRUN"),
            SandboxProbe.connect(b + "/runx/hostrunner/r.sock", "RUNSOCK"),
            SandboxProbe.connect(own.path + "/dock.sock", "DOCK"),
        ].joined(separator: "\n")
        let policy = CommandSandbox.Policy.testPolicy(ownFolder: own, socketRoot: root, announcedFolders: [host.path],
                                                      announcedSocketFolders: [runner.path])
        let probe = try CommandProbe(testDescriptor(script, folder: folder.path), folder: folder.path,
                                     launcher: helperLauncher(policy: policy))
        #expect(await probe.waitForExit(timeout: 30) == .exited(0))
        let results = SandboxProbe.results(probe.text)
        #expect(results.count == 14, "every probe reported: \(probe.text)")
        for label in ["MVBASE", "MVROOT", "MVRUNNER", "MVRUN"] { #expect(results[label] == "DENIED", "\(label): the rename") }
        for label in ["BASEDOCK", "BASEGRANTS", "BASESETTINGS", "BASECTL", "ROOTDOCK", "ROOTSETTINGS", "ROOTSTATE", "RUNNERSOCK",
                      "RUNSOCK", "DOCK"] {
            #expect(results[label] == "DENIED", "\(label): nothing reachable through a new path")
        }
        for place in [own, host, runner] { #expect(FileManager.default.fileExists(atPath: place.path), "still in place") }
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: own.appendingPathComponent("settings.json").path))
    }

    /// Measured: a socket or a folder under the Application Support tree cannot be moved out of it (or
    /// deleted), so another app's socket stays closed; regular files there stay writable, movable and deletable, and
    /// folders can still be made.
    @Test(.timeLimit(.minutes(1))) func socketsAndFoldersCannotLeaveTheTreeButRegularFilesStayUsable() async throws {
        let folder = CommandTempFolder("moveout")
        let root = try SandboxStandIn("pbmo")
        defer { root.remove() }
        let other = try root.folder("Other"), sub = try root.folder("Other/Sub"), empty = try root.folder("Other/Empty")
        let own = try root.folder("Pitbox")
        let listeners = try [other.appendingPathComponent("s.sock"), other.appendingPathComponent("t.sock"),
                             sub.appendingPathComponent("u.sock")].map { try UnixListener(path: $0.path) }
        defer { listeners.forEach { $0.close() } }
        try Data("old".utf8).write(to: other.appendingPathComponent("f.txt"))
        let o = other.path, c = folder.path
        let q = ShellQuote.quote
        let script = [
            SandboxProbe.run("mv \(q(o + "/s.sock")) \(q(c + "/moved.sock"))", "MVSOCK"),
            SandboxProbe.connect(c + "/moved.sock", "MOVEDSOCK"),
            SandboxProbe.run("rm -f \(q(o + "/t.sock"))", "RMSOCK"),
            SandboxProbe.run("mv \(q(sub.path)) \(q(c + "/Sub"))", "MVDIR"),
            SandboxProbe.connect(c + "/Sub/u.sock", "MOVEDDIRSOCK"),
            SandboxProbe.run("rmdir \(q(empty.path))", "RMDIR"),
            SandboxProbe.run("print -r -- new > \(q(o + "/f.txt"))", "WRITEFILE"),
            SandboxProbe.run("mv \(q(o + "/f.txt")) \(q(o + "/g.txt"))", "MVFILE"),
            SandboxProbe.run("rm \(q(o + "/g.txt"))", "RMFILE"),
            SandboxProbe.run("mkdir \(q(o + "/New"))", "MKDIR"),
        ].joined(separator: "\n")
        let policy = CommandSandbox.Policy.testPolicy(ownFolder: own, socketRoot: root.url)
        let probe = try CommandProbe(testDescriptor(script, folder: folder.path), folder: folder.path,
                                     launcher: helperLauncher(policy: policy))
        #expect(await probe.waitForExit(timeout: 30) == .exited(0))
        let results = SandboxProbe.results(probe.text)
        #expect(results.count == 10, "every probe reported: \(probe.text)")
        for label in ["MVSOCK", "MOVEDSOCK", "RMSOCK", "MVDIR", "MOVEDDIRSOCK", "RMDIR"] {
            #expect(results[label] == "DENIED", "\(label): sockets and folders stay in the tree")
        }
        for label in ["WRITEFILE", "MVFILE", "RMFILE", "MKDIR"] { #expect(results[label] == "OK", "\(label): regular files stay usable") }
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: o + "/s.sock") && fm.fileExists(atPath: o + "/t.sock") && fm.fileExists(atPath: sub.path + "/u.sock"))
        #expect(fm.fileExists(atPath: empty.path) && fm.fileExists(atPath: o + "/New"))
        #expect(!fm.fileExists(atPath: o + "/f.txt") && !fm.fileExists(atPath: o + "/g.txt"))
        #expect(!fm.fileExists(atPath: c + "/moved.sock") && !fm.fileExists(atPath: c + "/Sub"))
    }

    /// The stricter profile, measured with the real helper: under a stand-in Application Support tree,
    /// another app's socket is closed, a socket in an allowed folder is open, Pitbox's own folder stays closed for files
    /// and sockets even when it is listed as allowed, and other apps' files there stay readable (only sockets are closed).
    @Test(.timeLimit(.minutes(1))) func socketsUnderApplicationSupportAreClosedExceptInAllowedFolders() async throws {
        let folder = CommandTempFolder("support")
        let root = try SandboxStandIn("pbas")
        defer { root.remove() }
        let other = try root.folder("Other"), allowed = try root.folder("Tool"), own = try root.folder("Pitbox")
        try Data("theirs".utf8).write(to: other.appendingPathComponent("notes.txt"))
        try Data("private".utf8).write(to: own.appendingPathComponent("grants.json"))
        let listeners = try [other, allowed, own].map { try UnixListener(path: $0.appendingPathComponent("s.sock").path) }
        defer { listeners.forEach { $0.close() } }
        folder.write("mine.txt", "visible")
        let script = [
            SandboxProbe.connect(other.appendingPathComponent("s.sock").path, "OTHER"),
            SandboxProbe.connect(allowed.appendingPathComponent("s.sock").path, "TOOL"),
            SandboxProbe.connect(own.appendingPathComponent("s.sock").path, "OWN"),
            SandboxProbe.read(own.appendingPathComponent("grants.json").path, "OWNFILE"),
            SandboxProbe.read(other.appendingPathComponent("notes.txt").path, "OTHERFILE"),
            SandboxProbe.read("mine.txt", "MINE"),
        ].joined(separator: "\n")
        let policy = CommandSandbox.Policy.testPolicy(ownFolder: own, socketRoot: root.url,
                                                      allowSocketFolders: [allowed.path, own.path])
        let probe = try CommandProbe(testDescriptor(script, folder: folder.path), folder: folder.path,
                                     launcher: helperLauncher(policy: policy))
        #expect(await probe.waitForExit(timeout: 20) == .exited(0))
        let results = SandboxProbe.results(probe.text)
        #expect(results.count == 6, "every probe reported: \(probe.text)")
        #expect(results["OTHER"] == "DENIED", "another app's socket under Application Support")
        #expect(results["TOOL"] == "CONNECTED", "a socket in a sandboxAllowSocketFolders folder")
        #expect(results["OWN"] == "DENIED", "Pitbox's own folder, although listed as allowed")
        #expect(results["OWNFILE"] == "DENIED")
        #expect(results["OTHERFILE"] == "READ", "only sockets are closed under Application Support")
        #expect(results["MINE"] == "READ")
    }

    /// A dock host's announced folders and the settings' deny list, measured: an announced private folder is closed for
    /// files and sockets, an announced socket folder for sockets, a sandboxDenyFolders entry for files and sockets, and
    /// listing them as allowed re-opens none of them.
    @Test(.timeLimit(.minutes(1))) func announcedAndDeniedFoldersStayClosedEvenWhenListedAsAllowed() async throws {
        let folder = CommandTempFolder("announced")
        let root = try SandboxStandIn("pbhs")
        defer { root.remove() }
        let host = try root.folder("Host"), run = try root.folder("Run"), own = try root.folder("Pitbox")
        let outside = try SandboxStandIn("pbdn")
        defer { outside.remove() }
        let denied = try outside.folder("D")
        for (place, name) in [(host, "state.json"), (run, "pid.txt"), (denied, "secret.txt")] {
            try Data("x".utf8).write(to: place.appendingPathComponent(name))
        }
        let listeners = try [host, run, denied].map { try UnixListener(path: $0.appendingPathComponent("s.sock").path) }
        defer { listeners.forEach { $0.close() } }
        let script = [
            SandboxProbe.read(host.appendingPathComponent("state.json").path, "HOSTFILE"),
            SandboxProbe.connect(host.appendingPathComponent("s.sock").path, "HOSTSOCK"),
            SandboxProbe.read(run.appendingPathComponent("pid.txt").path, "RUNFILE"),
            SandboxProbe.connect(run.appendingPathComponent("s.sock").path, "RUNSOCK"),
            SandboxProbe.read(denied.appendingPathComponent("secret.txt").path, "DENYFILE"),
            SandboxProbe.connect(denied.appendingPathComponent("s.sock").path, "DENYSOCK"),
        ].joined(separator: "\n")
        let policy = CommandSandbox.Policy.testPolicy(ownFolder: own, socketRoot: root.url, announcedFolders: [host.path],
                                                      announcedSocketFolders: [run.path], denyFolders: [denied.path],
                                                      allowSocketFolders: [host.path, run.path, denied.path])
        let probe = try CommandProbe(testDescriptor(script, folder: folder.path), folder: folder.path,
                                     launcher: helperLauncher(policy: policy))
        #expect(await probe.waitForExit(timeout: 20) == .exited(0))
        let results = SandboxProbe.results(probe.text)
        #expect(results.count == 6, "every probe reported: \(probe.text)")
        #expect(results["HOSTFILE"] == "DENIED" && results["HOSTSOCK"] == "DENIED", "an announced private folder")
        #expect(results["RUNFILE"] == "READ" && results["RUNSOCK"] == "DENIED", "an announced socket folder: sockets only")
        #expect(results["DENYFILE"] == "DENIED" && results["DENYSOCK"] == "DENIED", "a sandboxDenyFolders entry")
    }

    @Test func aProfileThatCannotBeBuiltStartsNothing() throws {
        let folder = CommandTempFolder("noprofile")
        let launcher = CommandSpawner.launcher(path: .helper, helper: { CommandHelperLocator.check(CommandTestPaths.helper) },
                                               profile: { nil })
        let binding = try FolderBinding.bind(folder.path).get()
        let marker = folder.url.appendingPathComponent("ran").path
        let spec = try CommandLaunchSpec(descriptor: testDescriptor("touch \(ShellQuote.quote(marker))", folder: folder.path),
                                         environment: commandTestEnvironment())
        #expect(throws: CommandStartFailure.sandbox) { _ = try launcher(spec, binding, .standard) }
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(CommandStartFailure.sandbox.words == "the command's sandbox couldn't be set up; nothing ran")
        // An own folder that cannot be written into SBPL safely builds no profile at all.
        let quoted = CommandSandbox.Policy(ownFolder: "/tmp/a\"b", socketRoot: "/tmp", home: "/Users/tester")
        #expect(CommandSandbox.profile(quoted) == nil)
        let newline = CommandSandbox.Policy(ownFolder: "/tmp/own", socketRoot: "/tmp/x\ny", home: "/Users/tester")
        #expect(CommandSandbox.profile(newline) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aSwappedFolderStartsNothing() throws {
        let folder = CommandTempFolder("swap")
        let original = folder.subfolder("project")
        let binding = try FolderBinding.bind(original.path).get()
        try FileManager.default.moveItem(at: original, to: folder.url.appendingPathComponent("moved"))
        folder.subfolder("project")   // a new folder at the same path
        #expect(binding.verify() == .changed)
        let spec = try CommandLaunchSpec(descriptor: testDescriptor("touch ran", folder: original.path), environment: commandTestEnvironment())
        #expect(throws: CommandStartFailure.folder(.changed)) { _ = try helperLauncher()(spec, binding, .standard) }
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("project/ran").path))
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("moved/ran").path))
    }

    @Test(.timeLimit(.minutes(1))) func aRemovedFolderStartsNothing() throws {
        let folder = CommandTempFolder("gone")
        let doomed = folder.subfolder("doomed")
        let binding = try FolderBinding.bind(doomed.path).get()
        try FileManager.default.removeItem(at: doomed)
        #expect(binding.verify() == .changed)
    }

    @Test(.timeLimit(.minutes(1))) func aFolderTheShellCannotEnterFailsClosedOnBothPaths() async throws {
        for (label, launcher) in [("helper", helperLauncher()), ("forkpty", forkptyLauncher())] {
            let folder = CommandTempFolder("noenter-\(label)")
            let locked = folder.subfolder("locked")
            let binding = try FolderBinding.bind(locked.path).get()
            chmod(locked.path, 0o000)
            defer { chmod(locked.path, 0o700) }
            let marker = folder.url.appendingPathComponent("ran").path
            let spec = try CommandLaunchSpec(descriptor: testDescriptor("print RAN > \(ShellQuote.quote(marker))", folder: locked.path),
                                             environment: commandTestEnvironment())
            let started = try launcher(spec, binding, .standard)
            var exitStatus: ProcessExit?
            started.process.onExit = { exitStatus = $0 }
            var result: CommandStartResult?
            started.awaitStart { result = $0 }
            #expect(await waitUntil(10) { result != nil })
            guard case .failed(.beforeShell(let stage, let code)) = try #require(result) else {
                Issue.record("\(label): expected a failure before the shell")
                continue
            }
            #expect(stage == CommandHelperStage.folder && code == EACCES, "\(label)")
            #expect(await waitUntil(10) { exitStatus != nil })
            #expect(exitStatus == .exited(126), "\(label)")
            #expect(!FileManager.default.fileExists(atPath: marker), "\(label): nothing ran")
        }
    }

    @Test(.timeLimit(.minutes(1))) func theHelperRefusesAnyProgramButZsh() async throws {
        let folder = CommandTempFolder("program")
        let binding = try FolderBinding.bind(folder.path).get()
        let spec = CommandLaunchSpec(unchecked: "/bin/sh", argv: ["/bin/sh", "-c", "touch ran"], environment: ["PATH=/usr/bin:/bin"])
        let started = try helperLauncher()(spec, binding, .standard)
        var result: CommandStartResult?
        started.awaitStart { result = $0 }
        #expect(await waitUntil(10) { result != nil })
        #expect(result == .failed(.beforeShell(stage: CommandHelperStage.program, code: EPERM)))
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("ran").path))
    }

    @Test(.timeLimit(.minutes(1))) func theForkptyFallbackRunsTheSameDescriptor() async throws {
        let folder = CommandTempFolder("fallback")
        let probe = try CommandProbe(testDescriptor(#"print -r -- "dir=$(pwd -P)"; [[ -o interactive ]] && print i=1; exit 4"#, folder: folder.path),
                                     folder: folder.path, launcher: forkptyLauncher())
        #expect(try #require(await probe.waitForStart()) == .started)
        #expect(await probe.waitForExit() == .exited(4))
        let real = try #require(CommandSandbox.canonicalPath(folder.path))
        #expect(probe.text.contains("dir=\(real)"))
        #expect(probe.text.contains("i=1"))
        #expect(CommandSpawnPath.configured == .helper, "the fallback is off by default")
    }

    @Test func aMissingOrDoubtfulHelperFailsClosed() throws {
        let folder = CommandTempFolder("nohelper")
        #expect(CommandHelperLocator.check(folder.url.appendingPathComponent("nope")) == .failure(.missing))
        let writable = folder.write("helper", "#!/bin/sh\n")
        chmod(writable.path, 0o777)
        if case .failure(.doubtful) = CommandHelperLocator.check(writable) {} else { Issue.record("a world-writable helper is refused") }
        let link = folder.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: CommandTestPaths.helper)
        if case .failure(.doubtful) = CommandHelperLocator.check(link) {} else { Issue.record("a link is refused") }
        let launcher = CommandSpawner.launcher(path: .helper, helper: { .failure(.missing) }, profile: { "" })
        let binding = try FolderBinding.bind(folder.path).get()
        let spec = try CommandLaunchSpec(descriptor: testDescriptor("true", folder: folder.path), environment: commandTestEnvironment())
        #expect(throws: CommandStartFailure.helper(.missing)) { _ = try launcher(spec, binding, .standard) }
        #expect(CommandHelperLocator.bundled(mainExecutable: nil) == .failure(.missing))
    }

    @Test func theSandboxProfileUsesCanonicalPaths() {
        let tag = UUID().uuidString.prefix(8)
        let policy = CommandSandbox.Policy(ownFolder: "/tmp/own-\(tag)", socketRoot: "/tmp/support-\(tag)", home: "/Users/tester")
        #expect(CommandSandbox.profile(policy) == """
        (version 1)
        (allow default)
        (deny file-read* file-write* (subpath "/private/tmp/own-\(tag)"))
        (deny network-outbound (remote unix-socket (subpath "/private/tmp/support-\(tag)")))
        (deny network-outbound (remote unix-socket (subpath "/private/tmp/own-\(tag)")))
        (deny file-write-unlink (require-all (subpath "/private/tmp/support-\(tag)") (require-any (vnode-type SOCKET) (vnode-type DIRECTORY))))
        (deny file-write-unlink (literal "/private"))
        (deny file-write-unlink (literal "/private/tmp"))

        """, "the fixed rules: Pitbox's own folder, sockets under the Application Support tree, no moving them out, no renaming a parent")
        #expect(CommandSandbox.canonicalPath("/tmp/does-not-exist-\(UUID().uuidString)/x")?.hasPrefix("/private/tmp/") == true)
        #expect(CommandSandbox.ancestors("/a/b/c") == ["/a", "/a/b"] && CommandSandbox.ancestors("/a").isEmpty)
        #expect(CommandSandbox.quoted(#"a"b\c"#) == #""a\"b\\c""#)
    }

    /// The exact profile for sample inputs: file denies first (own folder, announced, deny list), then the broad socket
    /// deny, the allows, and the specific socket denies again (SBPL: the last matching rule wins), then the rename rules
    /// (no socket or folder moved out of the tree or an announced socket folder; no parent of a protected folder
    /// renamed), each folder canonical and once, `~/` expanded; bad entries and an allow that would undo the tree are
    /// left out.
    @Test func theStricterProfileForSampleInputs() {
        let t = UUID().uuidString.prefix(8)
        let policy = CommandSandbox.Policy(
            ownFolder: "/tmp/r-\(t)/Pitbox", socketRoot: "/tmp/r-\(t)", home: "/Users/tester",
            announcedFolders: ["/tmp/r-\(t)/Host", "/tmp/r-\(t)/Pitbox", "relative/Host", "/tmp/q\"uote", "/tmp/r-\(t)/x/../Host"],
            announcedSocketFolders: ["/tmp/run-\(t)", "/tmp/run-\(t)/"],
            denyFolders: ["~/Secret", "/tmp/new\nline", "~alex/x", "", "/tmp/r-\(t)/a/./../b"],
            allowSocketFolders: ["/tmp/r-\(t)/Tool", "/tmp/r-\(t)/Host", "/tmp/r-\(t)", "/private", "/tmp/back\\slash"])
        let lines: [String] = [
            "(version 1)",
            "(allow default)",
            #"(deny file-read* file-write* (subpath "/private/tmp/r-\#(t)/Pitbox"))"#,
            #"(deny file-read* file-write* (subpath "/private/tmp/r-\#(t)/Host"))"#,
            #"(deny file-read* file-write* (subpath "/Users/tester/Secret"))"#,
            #"(deny network-outbound (remote unix-socket (subpath "/private/tmp/r-\#(t)")))"#,
            #"(allow network-outbound (remote unix-socket (subpath "/private/tmp/r-\#(t)/Tool")))"#,
            #"(allow network-outbound (remote unix-socket (subpath "/private/tmp/r-\#(t)/Host")))"#,
            #"(deny network-outbound (remote unix-socket (subpath "/private/tmp/r-\#(t)/Pitbox")))"#,
            #"(deny network-outbound (remote unix-socket (subpath "/private/tmp/r-\#(t)/Host")))"#,
            #"(deny network-outbound (remote unix-socket (subpath "/Users/tester/Secret")))"#,
            #"(deny network-outbound (remote unix-socket (subpath "/private/tmp/run-\#(t)")))"#,
            #"(deny file-write-unlink (require-all (subpath "/private/tmp/r-\#(t)") (require-any (vnode-type SOCKET) (vnode-type DIRECTORY))))"#,
            #"(deny file-write-unlink (require-all (subpath "/private/tmp/run-\#(t)") (require-any (vnode-type SOCKET) (vnode-type DIRECTORY))))"#,
            #"(deny file-write-unlink (literal "/private"))"#,
            #"(deny file-write-unlink (literal "/private/tmp"))"#,
            #"(deny file-write-unlink (literal "/private/tmp/r-\#(t)"))"#,
            #"(deny file-write-unlink (literal "/Users"))"#,
            #"(deny file-write-unlink (literal "/Users/tester"))"#,
        ]
        var logged: [String] = []
        let lock = NSLock()
        let recorder = CommandLog.addRecorder { _, line in lock.withLock { logged.append(line) } }
        defer { CommandLog.removeRecorder(recorder) }
        #expect(CommandSandbox.profile(policy) == lines.joined(separator: "\n") + "\n")
        let refusals = lock.withLock { logged.filter { $0.hasPrefix("sandbox entry refused") } }
        #expect(refusals.sorted() == [
            "sandbox entry refused list=allow-sockets reason=quote",
            "sandbox entry refused list=allow-sockets reason=too-broad",
            "sandbox entry refused list=allow-sockets reason=too-broad",
            "sandbox entry refused list=announced reason=dot-dot",
            "sandbox entry refused list=announced reason=not-absolute",
            "sandbox entry refused list=announced reason=quote",
            "sandbox entry refused list=deny reason=control-character",
            "sandbox entry refused list=deny reason=dot-dot",
            "sandbox entry refused list=deny reason=empty",
            "sandbox entry refused list=deny reason=not-absolute",
        ], "a label per refused entry, never the entry")
    }

    @Test func theStandardPolicyClosesPitboxsFolderAndTheUsersApplicationSupportSockets() throws {
        let profile = try #require(CommandSandbox.profile(.standard))
        let own = try #require(CommandSandbox.canonicalPath(Paths.appSupport.path))
        let root = try #require(CommandSandbox.canonicalPath(CommandSandbox.applicationSupportRoot.path))
        #expect(root.hasSuffix("/Library/Application Support"))
        #expect(profile.contains(#"(deny file-read* file-write* (subpath "\#(own)"))"#))
        #expect(profile.contains(#"(deny network-outbound (remote unix-socket (subpath "\#(root)")))"#))
        #expect(profile.contains(#"(deny network-outbound (remote unix-socket (subpath "\#(own)")))"#))
        #expect(profile.contains(#"(deny file-write-unlink (require-all (subpath "\#(root)") (require-any (vnode-type SOCKET) (vnode-type DIRECTORY))))"#))
        let library = (root as NSString).deletingLastPathComponent
        #expect(profile.contains(#"(deny file-write-unlink (literal "\#(library)"))"#), "~/Library cannot be renamed")
        #expect(!profile.contains(#"(literal "/")"#), "/ is never named")
        #expect(!profile.contains("(allow network-outbound"))
        #expect(CommandSandbox.Policy.standard == CommandSandbox.Policy())
    }

    @Test func theLaunchSpecRefusesWhatTheRulesDoNotAllow() throws {
        let env = commandTestEnvironment()
        var descriptor = testDescriptor("echo hi", folder: "/tmp")
        descriptor.shellPath = "/bin/bash"
        #expect(throws: CommandLaunchSpec.BuildProblem.shell) { _ = try CommandLaunchSpec(descriptor: descriptor, environment: env) }
        descriptor = testDescriptor("echo hi", folder: "/tmp", machine: .server)
        #expect(throws: CommandLaunchSpec.BuildProblem.machine) { _ = try CommandLaunchSpec(descriptor: descriptor, environment: env) }
        descriptor = testDescriptor("echo hi", folder: "/tmp", machine: .unclear)
        #expect(throws: CommandLaunchSpec.BuildProblem.machine) { _ = try CommandLaunchSpec(descriptor: descriptor, environment: env) }
        descriptor = testDescriptor("echo hi", folder: "/tmp")
        descriptor.environmentNames.append("DYLD_INSERT_LIBRARIES")
        #expect(throws: CommandLaunchSpec.BuildProblem.environment) { _ = try CommandLaunchSpec(descriptor: descriptor, environment: env) }
        descriptor = testDescriptor("echo hi", folder: "/tmp")
        descriptor.path = "/usr/bin::bin"
        #expect(throws: CommandLaunchSpec.BuildProblem.environment) { _ = try CommandLaunchSpec(descriptor: descriptor, environment: env) }
        descriptor = testDescriptor("echo hi", folder: "/tmp")
        descriptor.shellArguments = ["-f", "-c", "-i", "-c"]
        #expect(throws: CommandLaunchSpec.BuildProblem.shell) { _ = try CommandLaunchSpec(descriptor: descriptor, environment: env) }
        descriptor = testDescriptor("echo hi", kind: .typeIntoTerminal, folder: "/tmp")
        let typeSpec = try CommandLaunchSpec(descriptor: descriptor, environment: env)
        #expect(typeSpec.argv == ["/bin/zsh", "-f", "-i", "-o", "interactivecomments", "-o", "nobanghist"], "Type passes no text")
        let runSpec = try CommandLaunchSpec(descriptor: testDescriptor("echo hi", folder: "/tmp"), environment: env)
        #expect(runSpec.argv == ["/bin/zsh", "-f", "-i", "-o", "interactivecomments", "-o", "nobanghist", "-c", "echo hi"])
    }
}

/// A listening Unix socket for the sandbox test.
final class UnixListener {
    private var fd: Int32
    let path: String

    init(path: String) throws {
        self.path = path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        unlink(path)
    }
}
