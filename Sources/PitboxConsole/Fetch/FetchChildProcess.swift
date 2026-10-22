import Darwin
import Dispatch
import Foundation

/// Bytes kept from a child's output: the first `headLimit` bytes and the last `tailLimit` (errors sit at either end).
struct BoundedBytes {
    let headLimit: Int
    let tailLimit: Int
    private(set) var head = Data()
    private(set) var tail = Data()
    private(set) var truncated = false

    init(headLimit: Int, tailLimit: Int = 0) { self.headLimit = headLimit; self.tailLimit = tailLimit }

    mutating func append(_ bytes: Data) {
        var rest = bytes[...]
        if head.count < headLimit {
            let room = headLimit - head.count
            head.append(rest.prefix(room))
            rest = rest.dropFirst(room)
        }
        guard !rest.isEmpty else { return }
        guard tailLimit > 0 else { truncated = true; return }
        tail.append(rest)
        if tail.count > tailLimit { tail.removeFirst(tail.count - tailLimit); truncated = true }
    }

    /// Head and tail as text (lossy UTF-8), with a line break between them when bytes were dropped.
    var text: String {
        let headText = String(decoding: head, as: UTF8.self)
        guard !tail.isEmpty else { return headText }
        return headText + (truncated ? "\n" : "") + String(decoding: tail, as: UTF8.self)
    }
}

enum FetchSpawnError: Error, Equatable {
    case failed(Int32)
}

/// A program Fetch file starts (`ssh -G`, the size-limited scp). Started with `posix_spawn` from an argument list: its
/// own process group, stdin from `/dev/null`, stdout captured or discarded, stderr captured (bounded),
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` (it inherits none of Pitbox's files or sockets), default signal dispositions, an
/// empty signal mask and an explicit environment.
///
/// Its exit and output are watched with dispatch sources on the owner's serial queue, so no thread ever waits for it.
/// When it exits, the rest of its process group (scp's ssh) is killed before the leader is reaped, while the group id
/// cannot have been reused, then its output is drained and `onExit` runs once, on that queue. Every method must be called
/// on that queue.
final class FetchChildProcess: @unchecked Sendable {
    struct Output {
        var stdout: Data
        var stderr: String
    }

    let pid: pid_t
    private let queue: DispatchQueue
    private var onExit: ((ProcessExit, Output) -> Void)?
    private var exitSource: DispatchSourceProcess?
    private var outSource: DispatchSourceRead?
    private var errSource: DispatchSourceRead?
    private var outFD: Int32
    private var errFD: Int32
    private var stdoutBytes = BoundedBytes(headLimit: 256 * 1024)
    private var stderrBytes = BoundedBytes(headLimit: 16 * 1024, tailLimit: 16 * 1024)
    private var reaped = false
    private var reapAttempts = 0

    /// Starts `arguments[0]`'s program (`executable` is the file run; `arguments` is argv, argv[0] first).
    /// `workingDirectory` is a folder descriptor the child starts in.
    static func spawn(executable: String, arguments: [String], environment: [String: String], captureStdout: Bool,
                      workingDirectory: Int32? = nil, queue: DispatchQueue,
                      onExit: @escaping (ProcessExit, Output) -> Void) throws -> FetchChildProcess {
        dispatchPrecondition(condition: .onQueue(queue))
        var errPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        guard pipe(&errPipe) == 0 else { throw FetchSpawnError.failed(errno) }
        if captureStdout, pipe(&outPipe) != 0 {
            let code = errno
            closeAll(errPipe)
            throw FetchSpawnError.failed(code)
        }
        // Close-on-exec everywhere at once: no other spawn on another thread can inherit these; dup2 onto 1 and 2
        // clears the flag for the child's own copies.
        for fd in errPipe + outPipe where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if captureStdout {
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let folder = workingDirectory { posix_spawn_file_actions_addfchdir(&actions, folder) }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP
        posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.keys.sorted().map { strdup("\($0)=\(environment[$0] ?? "")") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        closeAll([errPipe[1], outPipe[1]])
        guard rc == 0 else {
            closeAll([errPipe[0], outPipe[0]])
            throw FetchSpawnError.failed(rc)
        }
        let child = FetchChildProcess(pid: pid, outFD: outPipe[0], errFD: errPipe[0], queue: queue, onExit: onExit)
        child.startWatching()
        return child
    }

    private init(pid: pid_t, outFD: Int32, errFD: Int32, queue: DispatchQueue,
                 onExit: @escaping (ProcessExit, Output) -> Void) {
        self.pid = pid
        self.outFD = outFD
        self.errFD = errFD
        self.queue = queue
        self.onExit = onExit
    }

    /// The leader has not been reaped yet.
    var isRunning: Bool { !reaped }

    /// SIGKILL to the whole process group (scp and its ssh). Does nothing once the leader was reaped, or when it is no
    /// longer this process's child, so a reused pid can never be hit.
    func killGroup() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !reaped, isStillOurChild() else { return }
        if killpg(pid, SIGKILL) != 0 { _ = kill(pid, SIGKILL) }
    }

    /// The pid still names our child (running, or a zombie we have not collected), so it cannot have been reused.
    private func isStillOurChild() -> Bool {
        var info = siginfo_t()
        var rc: Int32
        repeat { rc = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) } while rc != 0 && errno == EINTR
        return rc == 0
    }

    // MARK: Watching (on the queue)

    private func startWatching() {
        for fd in [outFD, errFD] where fd >= 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in readAvailable(fd) }
            source.setCancelHandler { close(fd) }   // the only place these descriptors are closed
            if fd == outFD { outSource = source } else { errSource = source }
            source.resume()
        }
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [self] in reap() }
        exitSource = exit
        exit.resume()
        // An exit before the source was armed still leaves a zombie: look once now.
        queue.async { [self] in reap(onlyIfExited: true) }
    }

    private func readAvailable(_ fd: Int32) {
        guard fd == outFD || fd == errFD else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let chunk = Data(buffer[0..<n])
                if fd == outFD { stdoutBytes.append(chunk) } else { stderrBytes.append(chunk) }
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN {
                return
            } else {
                endOfOutput(fd)   // EOF or an error: nothing more will come from this pipe
                return
            }
        }
    }

    private func endOfOutput(_ fd: Int32) {
        if fd == outFD { outFD = -1; outSource?.cancel(); outSource = nil }
        if fd == errFD { errFD = -1; errSource?.cancel(); errSource = nil }
    }

    /// Collects the leader once it has exited. It first looks without collecting (`WNOWAIT`): while the leader is a
    /// zombie its pid, and so its group id, cannot be reused, so the rest of the group can be killed safely.
    private func reap(onlyIfExited: Bool = false) {
        guard !reaped else { return }
        var info = siginfo_t()
        let peek = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if peek != 0 {
            if errno == EINTR { return retryReap() }
            // ECHILD: something else collected it, and the pid may be reused already: no signal goes to it.
            return finish(.unknown)
        }
        guard info.si_pid == pid else {
            // Still running. The exit event can come a moment before the zombie can be collected: look again.
            if !onlyIfExited { retryReap() }
            return
        }
        _ = killpg(pid, SIGKILL)   // leftovers of the group (scp's ssh, a proxy command)
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        finish(result == pid ? ProcessExit(waitStatus: status) : .unknown)
    }

    private func retryReap() {
        reapAttempts += 1
        let delay = reapAttempts < 400 ? 0.005 : 0.05
        queue.asyncAfter(deadline: .now() + delay) { [self] in reap() }
    }

    private func finish(_ exit: ProcessExit) {
        reaped = true
        exitSource?.cancel()
        exitSource = nil
        for fd in [outFD, errFD] where fd >= 0 { readAvailable(fd) }   // what the pipes still hold, without waiting
        for fd in [outFD, errFD] where fd >= 0 { endOfOutput(fd) }
        let output = Output(stdout: stdoutBytes.head, stderr: stderrBytes.text)
        let callback = onExit
        onExit = nil
        callback?(exit, output)
    }

    private static func closeAll(_ fds: [Int32]) { for fd in fds where fd >= 0 { close(fd) } }
}
