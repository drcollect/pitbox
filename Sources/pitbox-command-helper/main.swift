import Darwin

// pitbox-command-helper: the exec shim of Pitbox's command tabs.
//
// The app starts it for a command tab or a Type tab with posix_spawn: in a new session (POSIX_SPAWN_SETSID), as its own
// macOS-permission identity (responsibility_spawnattrs_setdisclaim), wrapped in `/usr/bin/sandbox-exec -p <profile>`.
// It inherits exactly these descriptors (POSIX_SPAWN_CLOEXEC_DEFAULT closes every other one):
//   0, 1, 2  the slave side of the tab's pseudo-terminal (the app keeps the master: no byte relay);
//   3        the folder the sheet bound when it opened (O_DIRECTORY);
//   4        the write end of the start-status pipe, which the app reads.
// It does what forkpty's child does after the fork (login_tty: a session of its own, then TIOCSCTTY, so the shell gets
// its controlling terminal, job control and Ctrl-C), enters the folder through its descriptor, and replaces itself with
// /bin/zsh, keeping the arguments and the environment it was given. The shell is therefore the app's own child: the app
// reaps it and reads its exact exit status. Nothing else happens here: no file is opened, nothing is read or written
// but the status pipe, nothing is logged.
//
// Any failure ends the helper before the shell starts (fail closed): it writes one record to fd 4 (0xC4, the stage,
// errno as 4 little-endian bytes) and exits with status 126 (127 when the exec itself failed). On success the exec
// closes fd 4 (close-on-exec), and the app reads end-of-file.
//
// Arguments: pitbox-command-helper 1 <program> <argv0> [arguments...]. The program must be /bin/zsh.

/// Where the start failed, as recorded on the status pipe. The app's `CommandStartFailure` mirrors these values.
enum Stage: UInt8 {
    case usage = 1
    case program = 2
    case statusPipe = 3
    case terminal = 4
    case session = 5
    case folder = 6
    case exec = 7
}

let statusDescriptor: Int32 = 4
let folderDescriptor: Int32 = 3

/// Writes the failure record and ends the helper. Only async-signal-safe calls, no allocation.
func fail(_ stage: Stage, _ code: Int32) -> Never {
    let value = UInt32(bitPattern: code)
    var record: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0xC4, stage.rawValue, UInt8(value & 0xff),
                                                              UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff),
                                                              UInt8((value >> 24) & 0xff))
    _ = withUnsafeBytes(of: &record) { write(statusDescriptor, $0.baseAddress, $0.count) }
    _exit(stage == .exec ? 127 : 126)
}

let arguments = CommandLine.arguments

// The status pipe must be there: without it a failure could not be reported, so nothing runs at all.
var statusInfo = stat()
guard fstat(statusDescriptor, &statusInfo) == 0, (statusInfo.st_mode & S_IFMT) == S_IFIFO else { _exit(126) }

guard arguments.count >= 4, arguments[1] == "1" else { fail(.usage, EINVAL) }
// One shell: the helper starts /bin/zsh and nothing else, whatever it is asked.
guard arguments[2] == "/bin/zsh" else { fail(.program, EPERM) }

// The terminal: fd 0 must be the pty, and the helper must lead its own session (the app's POSIX_SPAWN_SETSID).
guard isatty(0) == 1 else { fail(.terminal, ENOTTY) }
guard getsid(0) == getpid() else { fail(.session, EPERM) }
guard ioctl(0, TIOCSCTTY, 0) == 0 else { fail(.terminal, errno) }
guard tcgetsid(0) == getpid() else { fail(.terminal, ENOTTY) }

// The folder the user saw, by descriptor. A failed change of folder ends here: nothing runs elsewhere.
var folderInfo = stat()
guard fstat(folderDescriptor, &folderInfo) == 0 else { fail(.folder, errno) }
guard (folderInfo.st_mode & S_IFMT) == S_IFDIR else { fail(.folder, ENOTDIR) }
guard fchdir(folderDescriptor) == 0 else { fail(.folder, errno) }
close(folderDescriptor)

// Nothing but the terminal reaches the shell: close anything above the status pipe (posix_spawn closed them already;
// this is a second guard), and let the exec close the status pipe itself.
let highest = min(max(getdtablesize(), 256), 65_536)
var descriptor: Int32 = statusDescriptor + 1
while descriptor < highest {
    close(descriptor)
    descriptor += 1
}
guard fcntl(statusDescriptor, F_SETFD, FD_CLOEXEC) == 0 else { fail(.statusPipe, errno) }

// Default signal dispositions and an empty mask, whatever came before (the app asked posix_spawn for the same).
var signalNumber: Int32 = 1
while signalNumber < NSIG {
    if signalNumber != SIGKILL && signalNumber != SIGSTOP { signal(signalNumber, SIG_DFL) }
    signalNumber += 1
}
var emptyMask = sigset_t()
sigemptyset(&emptyMask)
sigprocmask(SIG_SETMASK, &emptyMask, nil)

// The shell, with exactly the arguments the app passed (argv[0] first) and the environment it was given.
let program = arguments[2]
var shellArguments: [UnsafeMutablePointer<CChar>?] = arguments[3...].map { strdup($0) }
shellArguments.append(nil)
execve(program, &shellArguments, environ)
fail(.exec, errno)
