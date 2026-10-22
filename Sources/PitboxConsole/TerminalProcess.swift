import Darwin
import Foundation

/// How a process ended.
enum ProcessExit: Equatable {
    case exited(Int32)
    case signaled(Int32)
    /// The status could not be collected (the process was reaped by someone else).
    case unknown

    /// Decodes a `waitpid` status word (`WIFEXITED`, `WEXITSTATUS`, `WIFSIGNALED`, `WTERMSIG`).
    init(waitStatus status: Int32) {
        let low = status & 0x7f
        if low == 0 { self = .exited((status >> 8) & 0xff) }
        else if low != 0x7f { self = .signaled(low) }
        else { self = .unknown }
    }

    /// Exit status 0.
    var isClean: Bool { self == .exited(0) }

    /// One line for the hint printed into the terminal.
    var summary: String {
        switch self {
        case .exited(0): return "Process exited"
        case .exited(let code): return "Process exited with status \(code)"
        case .signaled(let signal): return "Process ended by signal \(signal)\(Self.signalName(signal).map { " (\($0))" } ?? "")"
        case .unknown: return "Process ended"
        }
    }

    static func signalName(_ signal: Int32) -> String? {
        let names: [Int32: String] = [
            SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL", SIGTRAP: "SIGTRAP",
            SIGABRT: "SIGABRT", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL", SIGBUS: "SIGBUS", SIGSEGV: "SIGSEGV",
            SIGSYS: "SIGSYS", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM", SIGTERM: "SIGTERM",
        ]
        return names[signal]
    }
}

/// What is in the foreground of a session's terminal right now.
struct ForegroundInfo: Equatable {
    /// The foreground process group (its leader's pid).
    var pgid: pid_t
    /// The foreground program's name; for interpreters (`node`, `python`, `bash`, ...) the script's file name.
    var name: String?
    /// True when the foreground group is the session's own first process: the idle shell, or the program a preset
    /// `exec`ed. False when the shell is running something (a job).
    var isSessionLeader: Bool
    /// The session's first process's working directory.
    var cwd: String?
}

/// The process behind a session. `PTYProcess` is the real one; tests use a fake so the session logic can be checked
/// without starting anything.
protocol TerminalProcess: AnyObject {
    var pid: pid_t { get }
    var isRunning: Bool { get }
    /// Output from the process, in order, on the main thread.
    var onOutput: (([UInt8]) -> Void)? { get set }
    /// Called once on the main thread, after all output was delivered.
    var onExit: ((ProcessExit) -> Void)? { get set }
    /// Sends input to the process. Internal to the module: nothing outside the terminal's own views calls it.
    func write(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)
    /// SIGHUP to the session (then SIGKILL after a grace period). The exit is reported through `onExit`.
    func terminate()
    /// SIGHUP now, without waiting: for the app quitting.
    func hangUp()
    func inspect() -> ForegroundInfo?
    /// SIGINT to the foreground job (a command tab's first Stop). Default: nothing.
    func interruptForeground()
    /// SIGKILL to the session and its groups (a command tab's second Stop). Default: nothing.
    func killSession()
    /// Echo and canonical mode of the terminal now, for "asks for hidden input". Default: unknown (nil).
    func inputModes() -> TerminalInputModes?
}

extension TerminalProcess {
    func interruptForeground() {}
    func killSession() {}
    func inputModes() -> TerminalInputModes? { nil }
}

/// Two flags of the terminal's line discipline (`c_lflag`).
struct TerminalInputModes: Equatable {
    /// Typed characters are echoed.
    var echo: Bool
    /// Input is read a line at a time (not raw, as full-screen programs and zsh's line editor set it).
    var canonical: Bool

    /// Echo off while reading lines: a password-style prompt (`read -s`, `sudo`, ssh passphrases, `security … -w`).
    var asksForHiddenInput: Bool { !echo && canonical }
}

/// Starts processes for sessions. The real implementation forks a pseudo-terminal; tests substitute their own.
typealias ProcessLauncher = (_ spec: LaunchSpec, _ size: TerminalSize) throws -> TerminalProcess

/// A terminal's size in cells and pixels.
struct TerminalSize: Equatable {
    var cols: Int
    var rows: Int
    var pixelWidth: Int
    var pixelHeight: Int

    static let standard = TerminalSize(cols: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
}
