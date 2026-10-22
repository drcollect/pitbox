import AppKit
import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// Where spawn tests may create folders and files: a private folder in the user's temporary directory (never
/// `~/Downloads`, the repo or the real app-support folder). `PITBOX_COMMAND_TEST_ROOT` overrides it.
enum CommandTestPaths {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["PITBOX_COMMAND_TEST_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: CommandSandbox.canonicalPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pitbox-command-tests", isDirectory: true)
    }

    /// The helper SwiftPM built next to this test bundle (`<bin>/pitbox-command-helper`).
    static var helper: URL {
        var info = Dl_info()
        let bundleBinary: String
        if dladdr(#dsohandle, &info) != 0, let name = info.dli_fname {
            bundleBinary = String(cString: name)
        } else {
            bundleBinary = CommandLine.arguments.first ?? "."
        }
        // <bin>/PitboxPackageTests.xctest/Contents/MacOS/PitboxPackageTests
        var url = URL(fileURLWithPath: bundleBinary)
        while url.path != "/", !url.lastPathComponent.hasSuffix(".xctest") { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent().appendingPathComponent(CommandHelperLocator.name)
    }
}

/// A private folder for one spawn test under `CommandTestPaths.root`, removed when the value goes away.
final class CommandTempFolder {
    let url: URL
    var path: String { url.path }

    init(_ label: String = "t") {
        TerminalLog.enabled = false
        let base = CommandTestPaths.root
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = base.appendingPathComponent("\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func subfolder(_ name: String) -> URL {
        let sub = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return sub
    }

    @discardableResult
    func write(_ name: String, _ text: String) -> URL {
        let file = url.appendingPathComponent(name)
        try? Data(text.utf8).write(to: file)
        return file
    }
}

/// A descriptor for tests: the clean shell's Run form for `text`, in `folder`.
func testDescriptor(_ text: String, kind: CommandExecutionDescriptor.Kind = .run, folder: String,
                    shell: CommandExecutionDescriptor.Shell = .clean, sshAgent: Bool = false,
                    machine: CommandMachine = .thisMac) -> CommandExecutionDescriptor {
    let arguments: [String]
    switch (kind, shell) {
    case (.run, .clean): arguments = CommandExecutionDescriptor.cleanRunArguments + ["-c"]
    case (.typeIntoTerminal, .clean): arguments = CommandExecutionDescriptor.cleanTypeArguments
    case (.run, .login): arguments = ["-l", "-i", "-c"]
    case (.typeIntoTerminal, .login): arguments = ["-l", "-i"]
    }
    var names = CommandEnvironmentRules.cleanNames
    if sshAgent { names.append("SSH_AUTH_SOCK") }
    return CommandExecutionDescriptor(offerID: CommandOffer.ID(sessionIndex: 1, replyUUID: "u-1", number: 1), kind: kind,
                                      text: text, shell: shell, shellArguments: arguments,
                                      path: CommandExecutionDescriptor.cleanPath, environmentNames: names.sorted(),
                                      folderPath: folder, folderDevice: 0, folderInode: 0, machine: machine)
}

/// An environment for spawn tests: this Mac's home and user, the app's TMPDIR, nothing else of the app.
func commandTestEnvironment(parent extra: [String: String] = [:]) -> TerminalEnvironment {
    var environment = TerminalEnvironment.live
    var parent: [String: String] = [:]
    for name in ["USER", "LOGNAME", "TMPDIR", "__CF_USER_TEXT_ENCODING"] {
        if let value = environment.parent[name] { parent[name] = value }
    }
    for (key, value) in extra { parent[key] = value }
    environment.parent = parent
    return environment
}

/// Runs one command through a launcher on a real pty and records what the terminal side sees.
@MainActor
final class CommandProbe {
    let process: TerminalProcess
    private(set) var output: [UInt8] = []
    private(set) var exit: ProcessExit?
    private(set) var start: CommandStartResult?
    var text: String { String(decoding: output, as: UTF8.self) }

    init(_ descriptor: CommandExecutionDescriptor, folder: String, launcher: CommandLauncher,
         environment: TerminalEnvironment = commandTestEnvironment(),
         size: TerminalSize = TerminalSize(cols: 100, rows: 30, pixelWidth: 800, pixelHeight: 600)) throws {
        let spec = try CommandLaunchSpec(descriptor: descriptor, environment: environment)
        let binding = try FolderBinding.bind(folder).get()
        let started = try launcher(spec, binding, size)
        process = started.process
        process.onOutput = { [unowned self] bytes in output += bytes }
        process.onExit = { [unowned self] status in exit = status }
        started.awaitStart { [weak self] result in self?.start = result }
    }

    func waitForText(_ needle: String, timeout: TimeInterval = 10) async -> Bool {
        await waitUntil(timeout) { self.text.contains(needle) }
    }

    func waitForExit(timeout: TimeInterval = 10) async -> ProcessExit? {
        _ = await waitUntil(timeout) { self.exit != nil }
        return exit
    }

    func waitForStart(timeout: TimeInterval = 10) async -> CommandStartResult? {
        _ = await waitUntil(timeout) { self.start != nil }
        return start
    }
}

/// The helper path with the helper SwiftPM built and the Seatbelt profile of `policy` (by default the strict one over
/// the test run's app-support folder, `PITBOX_APP_SUPPORT`).
func helperLauncher(policy: CommandSandbox.Policy = .testPolicy()) -> CommandLauncher {
    CommandSpawner.launcher(path: .helper, helper: { CommandHelperLocator.check(CommandTestPaths.helper) },
                            profile: { CommandSandbox.profile(policy) })
}

extension CommandSandbox.Policy {
    /// The policy with a stand-in own folder and, by default, the user's real Application Support tree for sockets.
    static func testPolicy(ownFolder: URL = Paths.appSupport, socketRoot: URL = CommandSandbox.applicationSupportRoot,
                           announcedFolders: [String] = [], announcedSocketFolders: [String] = [], denyFolders: [String] = [],
                           allowSocketFolders: [String] = []) -> CommandSandbox.Policy {
        CommandSandbox.Policy(ownFolder: ownFolder.path, socketRoot: socketRoot.path, home: "/Users/tester",
                              announcedFolders: announcedFolders, announcedSocketFolders: announcedSocketFolders,
                              denyFolders: denyFolders, allowSocketFolders: allowSocketFolders)
    }
}

/// The documented fallback: plain forkpty.
func forkptyLauncher() -> CommandLauncher {
    CommandSpawner.launcher(path: .forkpty, helper: { .failure(.missing) }, profile: { "" })
}

/// A stand-in folder for the sandbox tests (an Application Support tree, a host's folder): short, under `/private/tmp`
/// (Unix socket paths are limited to 104 bytes), private, removed by `remove()`.
final class SandboxStandIn {
    let url: URL

    init(_ prefix: String) throws {
        url = URL(fileURLWithPath: "/private/tmp/\(prefix)-\(getuid())-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// A private subfolder.
    func folder(_ name: String) throws -> URL {
        let sub = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return sub
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Lines of zsh that probe the sandbox from inside a command tab, one result line `LABEL=VALUE` each.
enum SandboxProbe {
    /// `LABEL=CONNECTED` when a Unix-socket connect to `path` succeeds, else `LABEL=DENIED`.
    static func connect(_ path: String, _ label: String) -> String {
        #"/usr/bin/python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])' "#
            + ShellQuote.quote(path) + #" >/dev/null 2>&1 && print -r -- "\#(label)=CONNECTED" || print -r -- "\#(label)=DENIED""#
    }

    /// `LABEL=OK` when the zsh `command` succeeds, else `LABEL=DENIED`.
    static func run(_ command: String, _ label: String) -> String {
        "\(command) >/dev/null 2>&1 && print -r -- \"\(label)=OK\" || print -r -- \"\(label)=DENIED\""
    }

    /// `LABEL=READ` when `path` can be read, else `LABEL=DENIED`.
    static func read(_ path: String, _ label: String) -> String {
        "cat \(ShellQuote.quote(path)) >/dev/null 2>&1 && print -r -- \"\(label)=READ\" || print -r -- \"\(label)=DENIED\""
    }

    /// The result lines of a probe's output (whole lines only, so an echo of the script never counts).
    static func results(_ output: String) -> [String: String] {
        var found: [String: String] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {   // "\r\n" is one Character
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].allSatisfy({ $0.isUppercase }), ["READ", "DENIED", "CONNECTED", "OK"].contains(parts[1]) else { continue }
            found[parts[0]] = parts[1]
        }
        return found
    }
}
