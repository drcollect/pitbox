import AppKit
import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// A command tab's process that does nothing by itself and records everything it is sent, Stop included.
final class FakeCommandProcess: TerminalProcess {
    private static var counter: pid_t = 40_000
    let pid: pid_t
    var onOutput: (([UInt8]) -> Void)?
    var onExit: ((ProcessExit) -> Void)?
    private(set) var isRunning = true
    private(set) var written: [UInt8] = []
    private(set) var interrupts = 0
    private(set) var kills = 0
    private(set) var terminates = 0
    var modes: TerminalInputModes? = TerminalInputModes(echo: true, canonical: true)
    var foreground: ForegroundInfo?

    init() {
        Self.counter += 1
        pid = Self.counter
        foreground = ForegroundInfo(pgid: pid + 1, name: "zsh", isSessionLeader: false, cwd: nil)
    }

    var writtenText: String { String(decoding: written, as: UTF8.self) }

    func write(_ bytes: [UInt8]) { written += bytes }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {}
    func terminate() { terminates += 1 }
    func hangUp() {}
    func inspect() -> ForegroundInfo? { isRunning ? foreground : nil }
    func interruptForeground() { interrupts += 1 }
    func killSession() { kills += 1 }
    func inputModes() -> TerminalInputModes? { isRunning ? modes : nil }

    func emit(_ text: String) { onOutput?(Array(text.utf8)) }
    func end(_ status: ProcessExit) {
        isRunning = false
        onExit?(status)
    }
}

/// Records every command spawn: the spec, the folder, the size, and holds the start result until the test says.
@MainActor
final class FakeCommandLauncher {
    private(set) var specs: [CommandLaunchSpec] = []
    private(set) var sizes: [TerminalSize] = []
    private(set) var processes: [FakeCommandProcess] = []
    private(set) var folderPaths: [String] = []
    /// The result given at once; nil holds it until `resolveStart`.
    var immediateResult: CommandStartResult? = .started
    var failWith: CommandStartFailure?
    private var pending: [(@MainActor (CommandStartResult) -> Void)] = []

    var launch: CommandLauncher {
        { [unowned self] spec, folder, size in
            defer { folder.close() }
            if let failure = failWith { throw failure }
            if let problem = folder.verify() { throw CommandStartFailure.folder(problem) }
            let process = FakeCommandProcess()
            specs.append(spec)
            sizes.append(size)
            processes.append(process)
            folderPaths.append(folder.path)
            let result = immediateResult
            return StartedCommand(process: process, awaitStart: { [weak self] completion in
                MainActor.assumeIsolated {
                    if let result { completion(result) } else { self?.pending.append(completion) }
                }
            })
        }
    }

    func resolveStart(_ result: CommandStartResult) {
        let waiting = pending
        pending = []
        for completion in waiting { completion(result) }
    }
}

/// The console with command tabs over fakes (or the real helper), its hooks scripted by the test.
@MainActor
final class CommandConsoleHarness {
    let dir = TempDir()
    let clock = ManualClock()
    let launcher = FakeLauncher()
    let commands = FakeCommandLauncher()
    let console: ConsoleHost
    let view: ConsoleView
    let window: OffscreenWindow
    let home: CommandTempFolder
    private(set) var keyboardRequests: [Bool] = []
    /// How often the console asked to be revealed and held, and to release its hold.
    private(set) var reveals = 0
    private(set) var releases = 0
    private(set) var events: [CommandOfferEvent] = []
    /// What the reveal hook answers (nil: no answer at all).
    var revealAnswer: Bool? = true
    /// Called before `ready(true)`: the test can resize the console here (the drawer opening).
    var onReveal: (() -> Void)?
    var consoleVisible = true

    var manager: TerminalSessionManager { view.manager }

    /// `mode: .terminal` (the default here) keeps the plain shell tab the terminal's own tests start from; `.pitbox` is
    /// the app's console (it starts empty).
    init(settingsJSON: String? = nil, size: CGSize = CGSize(width: 618, height: 318), realHelper: Bool = false,
         appSupport: URL? = nil, mode: ConsoleMode = .terminal, pathProblem: @escaping () -> String? = { nil }) {
        home = CommandTempFolder("home")
        var environment = commandTestEnvironment()
        environment.home = home.path
        var requests: ((Bool) -> Void)?
        let commandLauncher = realHelper ? helperLauncher(policy: .testPolicy(ownFolder: appSupport ?? Paths.appSupport))
            : commands.launch
        console = ConsoleHost(settings: testSettings(settingsJSON), keyboardRequester: { requests?($0) }, paths: dir.paths,
                              launcher: launcher.launch, clock: clock, environment: environment, commandLauncher: commandLauncher,
                              commandPathProblem: pathProblem, mode: mode)
        view = console.makeConsoleView()
        view.strip.pointerLocation = { nil }
        window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.pretendVisible = true
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        requests = { [unowned self] in keyboardRequests.append($0) }
        console.commandHooks = ConsoleCommandHooks(
            consoleVisible: { [unowned self] in consoleVisible },
            revealAndHoldConsole: { [unowned self] ready in
                reveals += 1
                onReveal?()
                if let answer = revealAnswer { ready(answer) }
            },
            releaseConsoleHold: { [unowned self] in releases += 1 })
    }

    func layout(_ size: CGSize) {
        window.setContentSize(size)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
    }

    /// A request as the sheet would make it after the user's click.
    func request(_ text: String, role: CommandTabRole = .run, folder: String? = nil, headline: String = "service token setup",
                 shell: CommandExecutionDescriptor.Shell = .clean, typedText: String? = nil) throws -> CommandTabRequest {
        let path = folder ?? home.path
        let kind: CommandExecutionDescriptor.Kind = role == .typeIntoTerminal ? .typeIntoTerminal : .run
        let binding = try FolderBinding.bind(path).get()
        let origin = CommandTabOrigin(headline: headline, profileName: "A Work", machineLabel: "this Mac",
                                      folderShort: FolderBinding.shortPath(path, home: home.path),
                                      replyTime: Date(timeIntervalSince1970: 1_000_000), offer: nil)
        var request = CommandTabRequest(role: role, descriptor: testDescriptor(text, kind: kind, folder: path, shell: shell),
                                        folder: binding, origin: origin, runID: UUID(), typedText: typedText)
        // The sheet passes its policy reading; a request built without one may not run (fails closed).
        request.runAllowed = { true }
        return request
    }

    /// Starts a tab through the console, as the sheet's Run or Type handler does.
    func start(_ request: CommandTabRequest) {
        console.startCommandTab(request) { [unowned self] event in events.append(event) }
    }

    var commandSessions: [TerminalSession] { manager.sessions.filter { $0.command != nil } }
}
