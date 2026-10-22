import Foundation
import Testing
@testable import PitboxConsole

struct EnvironmentTests {
    private func value(_ name: String, in env: [String]) -> String? {
        env.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    @Test func shellResolutionOrder() {
        let env = fixtureEnvironment(parent: ["SHELL": "/bin/bash"], accountShell: "/bin/zsh")
        #expect(env.resolveShell(configured: "/bin/zsh") == "/bin/zsh", "configured first")
        #expect(env.resolveShell(configured: nil) == "/bin/bash", "then $SHELL")
        #expect(fixtureEnvironment(parent: [:], accountShell: "/bin/bash").resolveShell(configured: nil) == "/bin/bash", "then the account's shell")
        #expect(fixtureEnvironment(parent: [:], accountShell: nil).resolveShell(configured: nil) == "/bin/zsh", "then /bin/zsh")
        #expect(fixtureEnvironment(parent: ["SHELL": "relative/zsh"], accountShell: nil, executables: ["/bin/sh"]).resolveShell(configured: nil) == "/bin/sh", "last resort")
        #expect(env.resolveShell(configured: "/nonexistent/fish") == "/bin/bash", "a configured shell that is not executable is skipped")
    }

    @Test func theEnvironmentIsAnAllowlistWithTerminalVariables() {
        let parent = ["PATH": "/opt/homebrew/bin:/usr/bin", "USER": "alex", "TMPDIR": "/var/folders/x/T/", "SSH_AUTH_SOCK": "/tmp/agent.sock",
                      "ANTHROPIC_API_KEY": "sk-secret", "PITBOX_REPO": "/repo", "TERM": "dumb", "TERM_PROGRAM": "Apple_Terminal",
                      "ITERM_SESSION_ID": "x", "AWS_SECRET_ACCESS_KEY": "s", "LC_ALL": "C", "DYLD_INSERT_LIBRARIES": "/evil.dylib"]
        let env = fixtureEnvironment(parent: parent)
        let vars = env.variables(shell: "/bin/zsh", preset: nil)
        #expect(value("TERM", in: vars) == "xterm-256color")
        #expect(value("COLORTERM", in: vars) == "truecolor")
        #expect(value("TERM_PROGRAM", in: vars) == "Pitbox")
        #expect(value("TERM_PROGRAM_VERSION", in: vars) == "9.9")
        #expect(value("LANG", in: vars) == "en_US.UTF-8")
        #expect(value("SHELL", in: vars) == "/bin/zsh" && value("HOME", in: vars) == "/Users/tester")
        #expect(value("PATH", in: vars) == "/opt/homebrew/bin:/usr/bin")
        #expect(value("TMPDIR", in: vars) == "/var/folders/x/T/" && value("SSH_AUTH_SOCK", in: vars) == "/tmp/agent.sock")
        #expect(value("USER", in: vars) == "alex" && value("LOGNAME", in: vars) == "tester", "LOGNAME falls back to the account name")
        for leaked in ["ANTHROPIC_API_KEY", "PITBOX_REPO", "ITERM_SESSION_ID", "AWS_SECRET_ACCESS_KEY", "LC_ALL", "DYLD_INSERT_LIBRARIES"] {
            #expect(value(leaked, in: vars) == nil, "\(leaked) must not reach the shell")
        }
        #expect(vars == vars.sorted(), "stable order")
        #expect(value("PATH", in: fixtureEnvironment(parent: [:]).variables(shell: "/bin/zsh", preset: nil)) == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func languageIsAlwaysUTF8() {
        #expect(fixtureEnvironment(parent: ["LANG": "de_DE.UTF-8"]).languageValue() == "de_DE.UTF-8", "an existing UTF-8 LANG is kept")
        #expect(fixtureEnvironment(parent: ["LANG": "C"]).languageValue() == "en_US.UTF-8", "a non-UTF-8 LANG is replaced")
        #expect(fixtureEnvironment(parent: [:], language: "de", region: "DE").languageValue() == "de_DE.UTF-8")
        #expect(fixtureEnvironment(parent: [:], language: "en", region: "PT").languageValue() == "en_US.UTF-8", "en_PT does not exist here")
        #expect(fixtureEnvironment(parent: [:], language: nil, region: nil).languageValue() == "en_US.UTF-8")
    }

    @Test func directoriesExpandAndFallBackToHome() {
        let env = fixtureEnvironment()
        #expect(env.resolveDirectory(nil) == ("/Users/tester", false))
        #expect(env.resolveDirectory("~") == ("/Users/tester", false))
        #expect(env.resolveDirectory("~/proj") == ("/Users/tester/proj", false))
        #expect(env.resolveDirectory("/tmp") == ("/tmp", false))
        #expect(env.resolveDirectory("/tmp/../tmp") == ("/tmp", false))
        #expect(env.resolveDirectory("/missing") == ("/Users/tester", true))
        #expect(env.resolveDirectory("relative") == ("/Users/tester", true))
    }

    @Test func loginShellAndPresetLaunchSpecs() {
        let env = fixtureEnvironment()
        let settings = TerminalSettings.standard
        let plain = env.launchSpec(preset: .builtInShell, settings: settings, cwd: "/tmp")
        #expect(plain.spec.executable == "/bin/zsh" && plain.spec.argv == ["zsh", "-l"], "a login shell, like Terminal.app")
        #expect(plain.spec.cwd == "/tmp" && plain.cwdFellBack == false)

        var program = TerminalPreset.builtInShell
        program.id = "ssh"; program.argv = ["ssh", "-o", "X Y", "host'name"]; program.cwd = "~/proj"
        let launched = env.launchSpec(preset: program, settings: settings, cwd: "/tmp")
        #expect(launched.spec.argv == ["zsh", "-l", "-i", "-c", #"exec 'ssh' '-o' 'X Y' 'host'\''name'"#], "quoted, run by the login shell")
        #expect(launched.spec.cwd == "/Users/tester/proj", "a preset's own folder wins")
        #expect(launched.spec.kind == .program && launched.spec.presetID == "ssh" && launched.spec.shellName == "zsh")

        var script = TerminalPreset.builtInShell
        script.script = "cd /tmp && ls"
        #expect(env.launchSpec(preset: script, settings: settings).spec.argv == ["zsh", "-l", "-i", "-c", "cd /tmp && ls"])

        var custom = settings
        custom.shell = "/bin/bash"
        #expect(env.launchSpec(preset: .builtInShell, settings: custom).spec.argv == ["bash", "-l"])

        var extra = TerminalPreset.builtInShell
        extra.env = ["FOO": "bar", "TERM_PROGRAM": "Custom"]
        let vars = env.launchSpec(preset: extra, settings: settings).spec.env
        #expect(vars.contains("FOO=bar") && vars.contains("TERM_PROGRAM=Custom"), "presets may add or override variables")

        let missing = env.launchSpec(preset: .builtInShell, settings: settings, cwd: "/gone")
        #expect(missing.spec.cwd == "/Users/tester" && missing.cwdFellBack)
    }

    @Test func onlyTheSettingsValueReachesTheLaunchCode() {
        // The launch code takes a preset and the settings value, nothing a session wrote: there is no parameter through
        // which anything else could reach it. What the console's own tabs run comes from the app's settings only.
        let env = fixtureEnvironment()
        let spec = env.launchSpec(preset: .builtInShell, settings: .standard).spec
        #expect(spec.executable == "/bin/zsh")
    }
}

struct ProcessInspectorTests {
    @Test func readsThisProcess() throws {
        let pid = getpid()
        let cwd = try #require(ProcessInspector.currentDirectory(of: pid))
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        #expect(ProcessInspector.name(of: pid)?.isEmpty == false)
        let args = try #require(ProcessInspector.arguments(of: pid))
        #expect(args.first == CommandLine.arguments.first)
        #expect(ProcessInspector.exists(pid) && !ProcessInspector.exists(0) && !ProcessInspector.exists(-5))
    }

    @Test func parsesTheKernelArgumentLayout() {
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/usr/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("/opt/tools/claude".utf8) + [0] + Array("--resume".utf8) + [0]
        bytes += Array("HOME=/Users/x".utf8) + [0]
        #expect(ProcessInspector.parseProcessArguments(bytes) == ["node", "/opt/tools/claude", "--resume"])
        #expect(ProcessInspector.parseProcessArguments([1, 0]) == nil)
        #expect(ProcessInspector.parseProcessArguments([0xff, 0xff, 0xff, 0x7f, 0, 0]) == nil, "absurd argc")
    }

    @Test func interpretersShowTheScriptName() {
        #expect(ForegroundNaming.isInterpreter("node") && ForegroundNaming.isInterpreter("python3.12") && !ForegroundNaming.isInterpreter("vim"))
        #expect(ForegroundNaming.displayName(processName: "node", arguments: ["node", "/opt/tools/claude", "--resume"]) == "claude")
        #expect(ForegroundNaming.displayName(processName: "bash", arguments: ["bash", "-e", "./deploy.sh"]) == "deploy.sh")
        #expect(ForegroundNaming.displayName(processName: "python3", arguments: ["python3"]) == "python3")
    }

    @Test func exitStatusDecoding() {
        #expect(ProcessExit(waitStatus: 0) == .exited(0) && ProcessExit(waitStatus: 0).isClean)
        #expect(ProcessExit(waitStatus: 3 << 8) == .exited(3))
        #expect(ProcessExit(waitStatus: 9) == .signaled(9))
        #expect(ProcessExit(waitStatus: 0x7f) == .unknown)
        #expect(ProcessExit.exited(2).summary == "Process exited with status 2")
        #expect(ProcessExit.signaled(9).summary == "Process ended by signal 9 (SIGKILL)")
    }
}
