import Darwin
import Dispatch
import Foundation
import PitboxKit

/// Why a tab's program could not start. `description` is for the tab itself (the user's own screen: it names the
/// program); the log takes `logLabel` only, never the path.
enum PTYError: Error, CustomStringConvertible {
    case notExecutable(String)
    case forkFailed(Int32)

    var description: String {
        switch self {
        case .notExecutable(let path): return "\(path) is not an executable file"
        case .forkFailed(let code): return "could not create a pseudo-terminal (\(String(cString: strerror(code))))"
        }
    }

    /// A fixed label and numbers: what a log line may carry.
    var logLabel: String {
        switch self {
        case .notExecutable: return "not-executable"
        case .forkFailed(let code): return "pty-failed errno=\(code)"
        }
    }

    /// The log label of any start failure: `PTYError`'s own, else a fixed word (an error's text may name a path).
    static func logLabel(of error: Error) -> String {
        (error as? PTYError)?.logLabel ?? "other-error"
    }
}

/// A child process on a pseudo-terminal: the real `TerminalProcess`.
///
/// The child is started with `forkpty`, so it leads its own session with the pty as its controlling terminal: job control,
/// Ctrl-C and SIGWINCH work (a plain `posix_spawn` did not give shells a working controlling terminal when tried). Between
/// the fork and the exec the child only calls async-signal-safe functions on memory prepared beforehand: it restores the
/// default signal dispositions and an empty signal mask (an app that ignores SIGPIPE must not hand that to the user's
/// shell), closes every inherited descriptor above 2 (the app's sockets and files stay out of the shell), and changes
/// directory.
///
/// All descriptor work happens on one serial queue. Output is read there, batched, and delivered on the main thread in
/// time slices (a flood cannot freeze the UI); when the backlog passes 1 MB reading pauses until the terminal has caught
/// up, so the child blocks in `write` like it would in any terminal. The process is always reaped: its exit is noticed
/// with a process source, the pty is drained, `waitpid` collects the status, and only then is `onExit` delivered, after
/// the last output.
final class PTYProcess: TerminalProcess, @unchecked Sendable {
    let pid: pid_t
    var onOutput: (([UInt8]) -> Void)?
    var onExit: ((ProcessExit) -> Void)?

    private let master: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    private var exitSource: DispatchSourceProcess?
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var writeBuffer: [UInt8] = []
    private var writeOffset = 0
    private var lastSize: TerminalSize
    // Queue-confined state.
    private var finished = false
    /// The read source is suspended (backpressure or end of output). Only the queue suspends and resumes it, so the
    /// count can never go out of balance, and a suspended source is always resumed before it is cancelled.
    private var readIsSuspended = false
    private var reachedEndOfOutput = false

    // Shared with the main thread, guarded by `lock`.
    private let lock = NSLock()
    private var pending: [[UInt8]] = []
    private var pendingHead = 0
    private var pendingBytes = 0
    private var drainScheduled = false
    /// Reading is paused because the backlog passed the high-water mark.
    private var throttled = false
    private var exitStatus: ProcessExit?
    private var exitDelivered = false
    private var running = true

    private static let highWater = 1 << 20
    private static let lowWater = 256 << 10
    private static let killGrace: TimeInterval = 1.5

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Starts `spec` on a new pseudo-terminal of `size`.
    convenience init(spec: LaunchSpec, size: TerminalSize) throws {
        guard access(spec.executable, X_OK) == 0 else { throw PTYError.notExecutable(spec.executable) }
        let (pid, master) = try Self.spawn(spec, size: size)
        self.init(adopting: pid, master: master, size: size)
    }

    /// Takes over a child that already runs on the pseudo-terminal whose master is `master` (the command tabs' spawn
    /// path, `Commands/CommandSpawner.swift`). The child must be this process's own child, so it can be reaped; the
    /// descriptor belongs to this object from now on.
    init(adopting pid: pid_t, master: Int32, size: TerminalSize) {
        self.pid = pid
        self.master = master
        self.lastSize = size
        self.queue = DispatchQueue(label: "pitbox.console.pty.\(pid)")
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        queue.async { [self] in startIO() }
    }

    // MARK: Spawning

    /// A NULL-terminated C array of C strings, allocated before the fork.
    private final class CStringArray {
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

    private static func spawn(_ spec: LaunchSpec, size: TerminalSize) throws -> (pid_t, Int32) {
        // Everything the child needs is prepared here: no allocation (and no reference counting on our own objects)
        // happens after the fork.
        let argv = CStringArray(spec.argv)
        let envp = CStringArray(spec.env)
        let argvBase = argv.base
        let envpBase = envp.base
        guard let path = strdup(spec.executable) else { throw PTYError.forkFailed(ENOMEM) }
        let cwd = strdup(spec.cwd)
        defer { free(path); free(cwd) }
        let maxFD = Int32(clamping: max(getdtablesize(), 256))
        var window = winsize(size)
        var attributes = defaultTermios()
        var master: Int32 = -1
        let pid = withExtendedLifetime((argv, envp)) { () -> pid_t in
            let pid = forkpty(&master, nil, &attributes, &window)
            if pid == 0 { execChild(path: path, argv: argvBase, envp: envpBase, cwd: cwd, maxFD: maxFD) }
            return pid
        }
        if pid < 0 { throw PTYError.forkFailed(errno) }
        return (pid, master)
    }

    /// Runs in the forked child. Only async-signal-safe calls, on memory that already exists. Never returns.
    @inline(never)
    private static func execChild(path: UnsafeMutablePointer<CChar>, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                  envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, cwd: UnsafeMutablePointer<CChar>?,
                                  maxFD: Int32) -> Never {
        var empty = sigset_t()
        sigemptyset(&empty)
        sigprocmask(SIG_SETMASK, &empty, nil)
        var signalNumber: Int32 = 1
        while signalNumber < 32 {
            if signalNumber != SIGKILL && signalNumber != SIGSTOP { signal(signalNumber, SIG_DFL) }
            signalNumber += 1
        }
        if let cwd { _ = chdir(cwd) }
        var descriptor: Int32 = 3
        while descriptor < maxFD {
            close(descriptor)
            descriptor += 1
        }
        _ = execve(path, argv, envp)
        _exit(127)
    }

    /// The system's default terminal settings plus IUTF8 (backspace erases whole UTF-8 characters), like Terminal.app.
    static func defaultTermios() -> termios {
        var attributes = termios()
        var first: Int32 = -1
        var second: Int32 = -1
        if openpty(&first, &second, nil, nil, nil) == 0 {
            tcgetattr(second, &attributes)
            close(first)
            close(second)
        }
        attributes.c_iflag |= tcflag_t(IUTF8)
        return attributes
    }

    // MARK: I/O (serial queue)

    private func startIO() {
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [self] in handleReadable() }
        // The descriptor is closed here and nowhere else, after the process was reaped.
        read.setCancelHandler { [master] in close(master) }
        readSource = read
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [self] in finishAfterExit() }
        exitSource = exit
        read.resume()
        exit.resume()
    }

    private func handleReadable() {
        guard !finished, !reachedEndOfOutput else { return }
        var total = 0
        while total < 256 * 1024 {
            let n = readBuffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if n > 0 {
                enqueue(Array(readBuffer[0..<n]))
                total += n
                if n < readBuffer.count { return }
            } else if n == 0 {
                return endOfOutput()
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return
            } else {
                return endOfOutput()   // EIO: the slave side is gone
            }
        }
    }

    /// Every slave descriptor closed: no more output can come. The process may still be running (it can close its
    /// terminal and carry on), so the descriptor stays open and the read source is only suspended. The exit source
    /// normally ends the session; polling is a backstop for a missed process event.
    private func endOfOutput() {
        guard !reachedEndOfOutput else { return }
        reachedEndOfOutput = true
        suspendRead()
        pollForExit()
    }

    private func pollForExit() {
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard !finished else { return }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                drainMaster()
                complete(with: ProcessExit(waitStatus: status))
            } else {
                pollForExit()
            }
        }
    }

    private func suspendRead() {
        guard !readIsSuspended, let read = readSource else { return }
        read.suspend()
        readIsSuspended = true
    }

    private func resumeRead() {
        guard readIsSuspended, let read = readSource else { return }
        read.resume()
        readIsSuspended = false
    }

    private func enqueue(_ chunk: [UInt8]) {
        lock.lock()
        pending.append(chunk)
        pendingBytes += chunk.count
        let overflow = pendingBytes >= Self.highWater
        if overflow { throttled = true }
        lock.unlock()
        if overflow { suspendRead() }
        scheduleDrain()
    }

    /// The main thread caught up: reading may continue (unless the output already ended).
    private func unthrottle() {
        guard !finished, !reachedEndOfOutput else { return }
        resumeRead()
    }

    /// Reads whatever is left in the pty (without blocking) into the pending output.
    private func drainMaster() {
        var leftover = 0
        while leftover < 16 << 20 {
            let n = readBuffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if n > 0 { enqueue(Array(readBuffer[0..<n])); leftover += n } else if n < 0, errno == EINTR { continue } else { break }
        }
    }

    /// The process exited (its exit source fired): read what is left, reap, report. `waitpid` may block for an instant
    /// (the exit event can precede the zombie state), never longer: the process is gone.
    private func finishAfterExit() {
        guard !finished else { return }
        drainMaster()
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        complete(with: result == pid ? ProcessExit(waitStatus: status) : .unknown)
    }

    private func complete(with exit: ProcessExit) {
        guard !finished else { return }
        finished = true
        writeBuffer.removeAll()
        exitSource?.cancel()
        exitSource = nil
        if let write = writeSource {
            if !writeSourceActive { write.resume() }   // a suspended source cannot be cancelled or released
            write.cancel()
        }
        writeSource = nil
        writeSourceActive = false
        lock.lock()
        running = false
        exitStatus = exit
        lock.unlock()
        if let read = readSource {
            if readIsSuspended { read.resume(); readIsSuspended = false }
            read.cancel()   // its cancel handler closes the descriptor
        } else {
            close(master)
        }
        readSource = nil
        scheduleDrain()
    }

    // MARK: Delivery (main thread)

    private func scheduleDrain() {
        lock.lock()
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { [self] in drain() } }
    }

    private func drain() {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            lock.lock()
            if pendingHead >= pending.count {
                pending.removeAll(keepingCapacity: true)
                pendingHead = 0
                drainScheduled = false
                let report = exitStatus != nil && !exitDelivered ? exitStatus : nil
                if report != nil { exitDelivered = true }
                lock.unlock()
                if let report {
                    let callback = onExit
                    onOutput = nil
                    onExit = nil
                    callback?(report)
                }
                return
            }
            let chunk = pending[pendingHead]
            pendingHead += 1
            pendingBytes -= chunk.count
            if pendingHead > 64 { pending.removeFirst(pendingHead); pendingHead = 0 }
            let resume = throttled && pendingBytes <= Self.lowWater
            if resume { throttled = false }
            lock.unlock()
            if resume { queue.async { [self] in unthrottle() } }
            onOutput?(chunk)
            if DispatchTime.now().uptimeNanoseconds - start > 4_000_000 {
                DispatchQueue.main.async { [self] in drain() }   // drainScheduled stays true
                return
            }
        }
    }

    // MARK: TerminalProcess

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            guard !finished else { return }
            writeBuffer.append(contentsOf: bytes)
            flushWrites()
        }
    }

    private func flushWrites() {
        while writeOffset < writeBuffer.count {
            let n = writeBuffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(master, base.advanced(by: writeOffset), raw.count - writeOffset)
            }
            if n > 0 { writeOffset += n; continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
                    source.setEventHandler { [self] in flushWrites() }
                    writeSource = source
                }
                if !writeSourceActive { writeSourceActive = true; writeSource?.resume() }
                return
            }
            break   // the pty is gone: drop the rest
        }
        writeBuffer.removeAll(keepingCapacity: true)
        writeOffset = 0
        if writeSourceActive { writeSourceActive = false; writeSource?.suspend() }
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        let size = TerminalSize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        queue.async { [self] in
            guard !finished, size != lastSize, cols > 0, rows > 0 else { return }
            lastSize = size
            var window = winsize(size)
            _ = ioctl(master, TIOCSWINSZ, &window)   // the kernel signals SIGWINCH to the foreground group
        }
    }

    func terminate() {
        queue.async { [self] in
            guard !finished else { return }
            signalSession(SIGHUP)
            queue.asyncAfter(deadline: .now() + Self.killGrace) { [self] in
                guard !finished else { return }
                signalSession(SIGKILL)
            }
        }
    }

    func hangUp() {
        queue.sync { [self] in
            guard !finished else { return }
            signalSession(SIGHUP)
        }
    }

    /// Signals the session's first process, its group, and the foreground group (the running job). A stopped job needs
    /// SIGCONT before it can act on SIGHUP.
    private func signalSession(_ signal: Int32) {
        let foreground = tcgetpgrp(master)
        var targets: [pid_t] = [pid]
        if foreground > 1, foreground != pid { targets.append(foreground) }
        for target in targets {
            kill(-target, signal)
            kill(target, signal)
            if signal == SIGHUP { kill(-target, SIGCONT) }
        }
    }

    func inspect() -> ForegroundInfo? {
        queue.sync { [self] () -> ForegroundInfo? in
            guard !finished else { return nil }
            let foreground = tcgetpgrp(master)
            guard foreground > 0 else { return nil }
            var name = ProcessInspector.name(of: foreground)
            if let base = name, ForegroundNaming.isInterpreter(base), let arguments = ProcessInspector.arguments(of: foreground) {
                name = ForegroundNaming.displayName(processName: base, arguments: arguments)
            }
            return ForegroundInfo(pgid: foreground, name: name, isSessionLeader: foreground == pid,
                                  cwd: ProcessInspector.currentDirectory(of: pid))
        }
    }

    // MARK: Command tabs (Stop, hidden input)

    /// SIGINT to the job in the foreground of the terminal (the bar's first Stop); to the session's first
    /// process when nothing else is in the foreground.
    func interruptForeground() {
        queue.async { [self] in
            guard !finished else { return }
            let foreground = tcgetpgrp(master)
            if foreground > 1 { kill(-foreground, SIGINT) } else { kill(pid, SIGINT) }
        }
    }

    /// SIGKILL to the session's first process, its group and the foreground group (the bar's second Stop).
    func killSession() {
        queue.async { [self] in
            guard !finished else { return }
            signalSession(SIGKILL)
        }
    }

    /// The terminal's echo and canonical-mode flags right now (`tcgetattr` on the master), or nil after the exit.
    /// Echo off in canonical mode is how `read -s`, `sudo` and ssh passphrases ask for hidden input.
    func inputModes() -> TerminalInputModes? {
        queue.sync { [self] () -> TerminalInputModes? in
            guard !finished else { return nil }
            var attributes = termios()
            guard tcgetattr(master, &attributes) == 0 else { return nil }
            return TerminalInputModes(echo: attributes.c_lflag & tcflag_t(ECHO) != 0,
                                      canonical: attributes.c_lflag & tcflag_t(ICANON) != 0)
        }
    }
}

extension winsize {
    init(_ size: TerminalSize) {
        self.init(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.cols),
                  ws_xpixel: UInt16(clamping: size.pixelWidth), ws_ypixel: UInt16(clamping: size.pixelHeight))
    }
}

/// Names for the foreground program in a tab title.
enum ForegroundNaming {
    /// Programs that run a script: the interesting name is the script's, not `node` or `bash`.
    static let interpreters: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "perl", "java", "sh", "bash", "zsh", "fish", "dash", "env", "npx",
        "tsx", "ts-node",
    ]

    static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || (name.hasPrefix("python") && name.dropFirst(6).allSatisfy { $0.isNumber || $0 == "." })
    }

    /// `node /opt/tools/claude --resume` becomes `claude`; without a usable script argument the process name stays.
    static func displayName(processName: String, arguments: [String]) -> String {
        for argument in arguments.dropFirst() {
            if argument.hasPrefix("-") { continue }
            let base = URL(fileURLWithPath: argument).lastPathComponent
            if !base.isEmpty, base != "/" { return base }
        }
        return processName
    }
}
