import Darwin
import Dispatch
import Foundation
import PitboxKit

/// How command and Type tabs start their shell. One internal switch: `CommandSpawnPath.configured`.
enum CommandSpawnPath: String, Equatable, Sendable {
    /// The default. The app opens the pty itself and `posix_spawn`s `/usr/bin/sandbox-exec -p <profile>
    /// pitbox-command-helper …` with the slave as stdin/stdout/stderr, in a new session (`POSIX_SPAWN_SETSID`), as its
    /// own macOS-permission identity (`responsibility_spawnattrs_setdisclaim`, fail closed without it). The helper
    /// takes the pty as its controlling terminal (`TIOCSCTTY`, what forkpty's child does), enters the bound folder by
    /// descriptor and execs zsh. The shell is the app's own child on the app's own master: no relay, exact exit status.
    case helper
    /// Plain `forkpty` from the app: the folder by descriptor and the same arguments and environment, but the shell
    /// carries Pitbox's macOS permissions and runs without the Seatbelt profile (as terminal tabs do). Only for a
    /// Mac where the helper path fails its attended checks (a controlling terminal, its own identity, the sandbox);
    /// docs/THREAT_MODEL.md T16 must then say so.
    case forkpty

    /// THE switch, off (`.helper`) by default. Change it only together with docs/THREAT_MODEL.md (T16).
    static let configured: CommandSpawnPath = .helper
}

/// Why a command or Type tab did not start. Nothing ran in every case.
enum CommandStartFailure: Error, Equatable {
    /// The helper is missing or failed its check (`CommandHelperLocator`).
    case helper(CommandHelperLocator.Problem)
    /// This macOS cannot give the command its own permission identity (`responsibility_spawnattrs_setdisclaim`).
    case identityUnavailable
    /// The bound folder changed, vanished or could not be entered.
    case folder(FolderBindingProblem)
    /// The spec could not be built from the descriptor.
    case spec(CommandLaunchSpec.BuildProblem)
    /// No pseudo-terminal (`errno`).
    case terminal(Int32)
    /// `posix_spawn` or `forkpty` failed (`errno`).
    case spawn(Int32)
    /// The helper (or the forked child) reported a failure before the shell started: its stage and `errno`.
    case beforeShell(stage: UInt8, code: Int32)
    /// No word from the helper within `CommandStartWatcher.timeout`; the process was killed.
    case timedOut
    /// The sandbox profile could not be built (Pitbox's own folder cannot be written into it safely).
    case sandbox
    /// `/usr/bin/sandbox-exec`, which every command starts under, is missing or not executable.
    case sandboxUnavailable

    /// For the tab's bar and the sheet's `refused` event.
    var words: String {
        switch self {
        case .helper(let problem): return problem.words
        case .identityUnavailable: return "this Mac can't start the command as its own app"
        case .folder(let problem): return problem.words
        case .spec(let problem): return problem.words
        case .terminal: return "no terminal could be opened for the command"
        case .spawn: return "the command's shell couldn't be started"
        case .beforeShell(let stage, _):
            switch stage {
            case CommandHelperStage.folder: return "the folder couldn't be entered; nothing ran"
            case CommandHelperStage.terminal, CommandHelperStage.session: return "the terminal couldn't be set up; nothing ran"
            default: return "the command's shell couldn't be started; nothing ran"
            }
        case .timedOut: return "the command's shell didn't start in time; nothing ran"
        case .sandbox: return "the command's sandbox couldn't be set up; nothing ran"
        case .sandboxUnavailable: return "this Mac has no command sandbox (sandbox-exec), so nothing can run"
        }
    }

    /// A short label for the log (no paths, no text).
    var logLabel: String {
        switch self {
        case .helper(.missing): return "helper-missing"
        case .helper(.doubtful): return "helper-doubtful"
        case .identityUnavailable: return "no-disclaim"
        case .folder: return "folder"
        case .spec: return "spec"
        case .terminal: return "openpty"
        case .spawn: return "spawn"
        case .beforeShell(let stage, _): return "stage-\(stage)"
        case .timedOut: return "timeout"
        case .sandbox: return "sandbox"
        case .sandboxUnavailable: return "no-sandbox-exec"
        }
    }
}

/// The stage codes of the helper's failure record (`Sources/pitbox-command-helper/main.swift`, `Stage`).
enum CommandHelperStage {
    static let usage: UInt8 = 1
    static let program: UInt8 = 2
    static let statusPipe: UInt8 = 3
    static let terminal: UInt8 = 4
    static let session: UInt8 = 5
    static let folder: UInt8 = 6
    static let exec: UInt8 = 7
    /// The first byte of a failure record.
    static let magic: UInt8 = 0xC4
}

/// A shell that was spawned: its pid (the app's own child), the pty master, and the read end of the start-status pipe.
struct SpawnedCommand {
    var pid: pid_t
    var master: Int32
    var statusPipe: Int32
}

/// Whether a command's shell really started: the exec of /bin/zsh happened, or why nothing ran.
enum CommandStartResult: Equatable {
    case started
    case failed(CommandStartFailure)
}

/// What a command session gets back from its launcher: the process (I/O on the pty master), and whether the shell
/// really started, reported once on the main thread.
struct StartedCommand {
    var process: TerminalProcess
    var awaitStart: (@escaping @MainActor (CommandStartResult) -> Void) -> Void
}

/// Starts a command or Type tab's shell: the spec, the folder (consumed: its descriptor is closed after the spawn) and
/// the terminal size. The real one is `CommandSpawner.live`; tests substitute fakes.
typealias CommandLauncher = (_ spec: CommandLaunchSpec, _ folder: FolderBinding, _ size: TerminalSize) throws -> StartedCommand

/// The spawn paths of `CommandSpawnPath`.
enum CommandSpawner {
    /// The launcher the console uses: the configured path, the bundled helper, and the profile for `policy`, which is
    /// read at every spawn (the app builds it from its settings and `SandboxMemory`).
    static func live(policy: @escaping () -> CommandSandbox.Policy) -> CommandLauncher {
        launcher(path: .configured, helper: { CommandHelperLocator.bundled() }, profile: { CommandSandbox.profile(policy()) })
    }

    /// The sandbox wrapper every command of the helper path starts under.
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// Nil when the configured path can start commands now; else why not, for the sheet (Run and Type off up front,
    /// instead of failing at the click).
    static func liveProblem() -> String? { liveProblem(sandboxExec: sandboxExecPath) }

    /// `liveProblem()` with the sandbox wrapper at `sandboxExec` (tests pass a missing or non-executable one).
    static func liveProblem(sandboxExec: String) -> String? {
        guard CommandSpawnPath.configured == .helper else { return nil }
        if responsibilityDisclaimer() == nil { return CommandStartFailure.identityUnavailable.words }
        if !isExecutableFile(sandboxExec) { return CommandStartFailure.sandboxUnavailable.words }
        if case .failure(let problem) = CommandHelperLocator.bundled() { return problem.words }
        return nil
    }

    /// Whether `path` is a regular file (after links) this process may execute.
    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    /// A launcher for one path, helper and profile (tests use the helper SwiftPM built and a scratch app-support folder).
    /// A profile of nil (it could not be built) starts nothing.
    static func launcher(path: CommandSpawnPath, helper: @escaping () -> Result<URL, CommandHelperLocator.Problem>,
                         profile: @escaping () -> String?) -> CommandLauncher {
        { spec, folder, size in
            defer { folder.close() }
            if let problem = folder.verify() { throw CommandStartFailure.folder(problem) }
            let spawned: SpawnedCommand
            switch path {
            case .helper:
                let helperURL: URL
                switch helper() {
                case .success(let url): helperURL = url
                case .failure(let problem): throw CommandStartFailure.helper(problem)
                }
                guard let profileText = profile() else { throw CommandStartFailure.sandbox }
                spawned = try spawnWithHelper(spec, folder: folder, size: size, helper: helperURL, profile: profileText)
            case .forkpty:
                spawned = try spawnWithForkpty(spec, folder: folder, size: size)
            }
            let process = PTYProcess(adopting: spawned.pid, master: spawned.master, size: size)
            let watcher = CommandStartWatcher(statusPipe: spawned.statusPipe, pid: spawned.pid)
            return StartedCommand(process: process, awaitStart: { watcher.await($0) })
        }
    }

    // MARK: The helper path

    typealias Disclaimer = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Int32

    /// `responsibility_spawnattrs_setdisclaim` from libsystem (a private call, looked up at run time, so the build
    /// needs no private header). Nil when this macOS does not have it: then nothing is spawned.
    static func responsibilityDisclaimer() -> Disclaimer? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Disclaimer.self)
    }

    typealias ResponsibleLookup = @convention(c) (pid_t) -> pid_t

    /// The process macOS holds responsible for `pid` (its privacy prompts and grants), or nil. For tests.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let result = unsafeBitCast(symbol, to: ResponsibleLookup.self)(pid)
        return result > 0 ? result : nil
    }

    static func spawnWithHelper(_ spec: CommandLaunchSpec, folder: FolderBinding, size: TerminalSize, helper: URL,
                                profile: String) throws -> SpawnedCommand {
        guard let disclaim = responsibilityDisclaimer() else { throw CommandStartFailure.identityUnavailable }
        var opened = try PseudoTerminal.open(size: size)
        defer { opened.closeSlave() }
        let status = try StatusPipe.make()
        // Sources above 9, so no dup2 below is ever a no-op that would keep a close-on-exec flag.
        let folderCopy = fcntl(folder.descriptor, F_DUPFD_CLOEXEC, 10)
        guard folderCopy >= 0 else {
            let code = errno
            opened.closeMaster(); status.closeBoth()
            throw CommandStartFailure.folder(.cannotOpen(code))
        }
        defer { close(folderCopy) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, opened.slave, 0)
        posix_spawn_file_actions_adddup2(&actions, opened.slave, 1)
        posix_spawn_file_actions_adddup2(&actions, opened.slave, 2)
        posix_spawn_file_actions_adddup2(&actions, folderCopy, 3)
        posix_spawn_file_actions_adddup2(&actions, status.write, 4)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        guard disclaim(&attributes, 1) == 0 else {
            opened.closeMaster(); status.closeBoth()
            throw CommandStartFailure.identityUnavailable
        }

        let argv = [sandboxExecPath, "-p", profile, helper.path, "1", spec.executable] + spec.argv
        let arguments = CStringArray(argv)
        let environment = CStringArray(spec.environment)
        var pid: pid_t = 0
        let result = withExtendedLifetime((arguments, environment)) {
            posix_spawn(&pid, sandboxExecPath, &actions, &attributes, arguments.base, environment.base)
        }
        close(status.write)
        guard result == 0 else {
            opened.closeMaster(); close(status.read)
            throw CommandStartFailure.spawn(result)
        }
        return SpawnedCommand(pid: pid, master: opened.master, statusPipe: status.read)
    }

    // MARK: The forkpty fallback

    static func spawnWithForkpty(_ spec: CommandLaunchSpec, folder: FolderBinding, size: TerminalSize) throws -> SpawnedCommand {
        let status = try StatusPipe.make()
        let arguments = CStringArray(spec.argv)
        let environment = CStringArray(spec.environment)
        guard let path = strdup(spec.executable) else {
            status.closeBoth()
            throw CommandStartFailure.spawn(ENOMEM)
        }
        defer { free(path) }
        let folderDescriptor = folder.descriptor
        let statusWrite = status.write
        let maxFD = Int32(clamping: max(getdtablesize(), 256))
        var window = winsize(size)
        var attributes = PTYProcess.defaultTermios()
        var master: Int32 = -1
        let argvBase = arguments.base
        let envpBase = environment.base
        let pid = withExtendedLifetime((arguments, environment)) { () -> pid_t in
            let pid = forkpty(&master, nil, &attributes, &window)
            if pid == 0 {
                forkedChild(path: path, argv: argvBase, envp: envpBase, folder: folderDescriptor, status: statusWrite,
                            maxFD: maxFD)
            }
            return pid
        }
        close(status.write)
        guard pid > 0 else {
            let code = errno
            close(status.read)
            throw CommandStartFailure.spawn(code)
        }
        return SpawnedCommand(pid: pid, master: master, statusPipe: status.read)
    }

    /// Runs in the forked child: only async-signal-safe calls on memory prepared before the fork. The same steps as the
    /// helper after its exec: default signals, the folder by descriptor (or a failure record and exit 126), every
    /// other descriptor closed, the status pipe closed by the exec.
    @inline(never)
    private static func forkedChild(path: UnsafeMutablePointer<CChar>, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                    envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, folder: Int32, status: Int32,
                                    maxFD: Int32) -> Never {
        var empty = sigset_t()
        sigemptyset(&empty)
        sigprocmask(SIG_SETMASK, &empty, nil)
        var signalNumber: Int32 = 1
        while signalNumber < 32 {
            if signalNumber != SIGKILL && signalNumber != SIGSTOP { signal(signalNumber, SIG_DFL) }
            signalNumber += 1
        }
        if fchdir(folder) != 0 { childFail(status, CommandHelperStage.folder, errno, exit: 126) }
        var descriptor: Int32 = 3
        while descriptor < maxFD {
            if descriptor != status { close(descriptor) }
            descriptor += 1
        }
        _ = execve(path, argv, envp)
        childFail(status, CommandHelperStage.exec, errno, exit: 127)
    }

    private static func childFail(_ status: Int32, _ stage: UInt8, _ code: Int32, exit: Int32) -> Never {
        let value = UInt32(bitPattern: code)
        var record: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (CommandHelperStage.magic, stage, UInt8(value & 0xff),
                                                                  UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff),
                                                                  UInt8((value >> 24) & 0xff))
        _ = withUnsafeBytes(of: &record) { write(status, $0.baseAddress, $0.count) }
        _exit(exit)
    }
}

/// A pseudo-terminal opened by the app, with the system's default settings plus IUTF8 and the tab's size.
struct PseudoTerminal {
    private(set) var master: Int32
    private(set) var slave: Int32

    static func open(size: TerminalSize) throws -> PseudoTerminal {
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(size)
        var attributes = PTYProcess.defaultTermios()
        guard openpty(&master, &slave, nil, &attributes, &window) == 0 else { throw CommandStartFailure.terminal(errno) }
        // Above 9 and close-on-exec, so nothing else the app spawns inherits them and the spawn's dup2 always applies.
        let highMaster = fcntl(master, F_DUPFD_CLOEXEC, 10)
        let highSlave = fcntl(slave, F_DUPFD_CLOEXEC, 10)
        Darwin.close(master)
        Darwin.close(slave)
        guard highMaster >= 0, highSlave >= 0 else {
            let code = errno
            if highMaster >= 0 { Darwin.close(highMaster) }
            if highSlave >= 0 { Darwin.close(highSlave) }
            throw CommandStartFailure.terminal(code)
        }
        return PseudoTerminal(master: highMaster, slave: highSlave)
    }

    mutating func closeSlave() {
        if slave >= 0 { Darwin.close(slave); slave = -1 }
    }

    mutating func closeMaster() {
        if master >= 0 { Darwin.close(master); master = -1 }
    }
}

/// The start-status pipe: the child writes a failure record or nothing; the exec closes its end (close-on-exec).
struct StatusPipe {
    var read: Int32
    var write: Int32

    static func make() throws -> StatusPipe {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw CommandStartFailure.spawn(errno) }
        let read = fcntl(fds[0], F_DUPFD_CLOEXEC, 10)
        let write = fcntl(fds[1], F_DUPFD_CLOEXEC, 10)
        close(fds[0])
        close(fds[1])
        guard read >= 0, write >= 0 else {
            let code = errno
            if read >= 0 { close(read) }
            if write >= 0 { close(write) }
            throw CommandStartFailure.spawn(code)
        }
        return StatusPipe(read: read, write: write)
    }

    func closeBoth() {
        close(read)
        close(write)
    }
}

/// A NULL-terminated C array of C strings, allocated before a spawn or a fork.
final class CStringArray {
    let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { base[index] = strdup(string) }
        base[strings.count] = nil
    }

    deinit {
        for index in 0..<count { free(base[index]) }
        base.deallocate()
    }
}

/// Reads the start-status pipe without parking a thread: a read source collects bytes until end-of-file. Nothing read
/// means the exec of the shell happened; a record means the helper (or the forked child) failed and nothing ran. No
/// answer within `timeout` kills the process. The result reaches the main thread exactly once.
final class CommandStartWatcher: @unchecked Sendable {
    static let timeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "pitbox.console.command-start")
    private let statusPipe: Int32
    private let pid: pid_t
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var bytes: [UInt8] = []
    private var result: CommandStartResult?
    private var waiters: [@MainActor (CommandStartResult) -> Void] = []

    init(statusPipe: Int32, pid: pid_t) {
        self.statusPipe = statusPipe
        self.pid = pid
        _ = fcntl(statusPipe, F_SETFL, fcntl(statusPipe, F_GETFL) | O_NONBLOCK)
        queue.async { [self] in begin() }
    }

    /// `completion` gets the result on the main thread, once.
    func await(_ completion: @escaping @MainActor (CommandStartResult) -> Void) {
        queue.async { [self] in
            if let result { Self.deliver(result, to: [completion]) } else { waiters.append(completion) }
        }
    }

    private func begin() {
        let read = DispatchSource.makeReadSource(fileDescriptor: statusPipe, queue: queue)
        read.setEventHandler { [self] in readAvailable() }
        read.setCancelHandler { [statusPipe] in close(statusPipe) }
        source = read
        read.resume()
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + Self.timeout)
        deadline.setEventHandler { [self] in
            guard result == nil else { return }
            kill(pid, SIGKILL)
            finish(.failed(.timedOut))
        }
        timer = deadline
        deadline.resume()
    }

    private func readAvailable() {
        guard result == nil else { return }
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(statusPipe, $0.baseAddress, $0.count) }
            if n > 0 {
                if bytes.count < 64 { bytes += buffer[0..<n] }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            break   // end of file (or an error): the writer's end is closed
        }
        finish(bytes.isEmpty ? .started : .failed(Self.failure(from: bytes)))
    }

    static func failure(from record: [UInt8]) -> CommandStartFailure {
        guard record.count >= 6, record[0] == CommandHelperStage.magic else { return .beforeShell(stage: 0, code: 0) }
        let code = UInt32(record[2]) | UInt32(record[3]) << 8 | UInt32(record[4]) << 16 | UInt32(record[5]) << 24
        return .beforeShell(stage: record[1], code: Int32(bitPattern: code))
    }

    private func finish(_ outcome: CommandStartResult) {
        guard result == nil else { return }
        result = outcome
        timer?.cancel()
        timer = nil
        source?.cancel()   // closes the read end
        source = nil
        let pending = waiters
        waiters = []
        Self.deliver(outcome, to: pending)
    }

    private static func deliver(_ outcome: CommandStartResult,
                                to completions: [@MainActor (CommandStartResult) -> Void]) {
        guard !completions.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { for completion in completions { completion(outcome) } }
        }
    }
}
