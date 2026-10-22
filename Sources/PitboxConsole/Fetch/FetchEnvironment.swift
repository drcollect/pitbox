import Darwin
import Foundation
import PitboxKit

/// The limits of Fetch file. Tests shrink them so every limit runs in seconds.
struct FetchLimits: Equatable, Sendable {
    /// The hard ceiling on the copied file, applied as RLIMIT_FSIZE before scp starts: 500 MB (500 × 1024 × 1024).
    var maxFileBytes: Int64 = 500 * 1_048_576
    /// ssh's `ConnectTimeout` for each connection (15 s).
    var connectTimeoutSeconds = 15
    /// Pitbox's own backstop: when nothing has been staged by then (no connection, no login or no remote file),
    /// scp is stopped as "timed out". Twice the connect timeout leaves room for a jump host.
    var connectDeadline: TimeInterval = 30
    /// The whole fetch, start to finish (10 minutes in all).
    var totalDeadline: TimeInterval = 600
    /// The free space the volume must keep: 5 GB. Before the start, the size limit comes on top.
    var freeSpaceReserve: Int64 = 5_000_000_000
    /// How often the staged file and the free space are looked at (every 0.5 s); progress is reported as often.
    var pollInterval: TimeInterval = 0.5
    /// At most this many fetches at once overall, and one per session.
    var maxRunning = 2
    var maxPerSession = 1
    /// `ssh -G` must answer within this, or the config counts as unreadable.
    var resolveTimeout: TimeInterval = 5
    /// Staging folders left behind (Pitbox quit or crashed mid-fetch) are removed once they are this old.
    var staleStagingAge: TimeInterval = 20 * 60
}

/// Reads and writes `com.apple.quarantine` through a file descriptor. Tests replace it to make the write fail.
struct FetchQuarantineIO: Sendable {
    /// Returns 0 on success, else an errno value.
    var set: @Sendable (_ fd: Int32, _ value: [UInt8]) -> Int32
    /// The stored value, or nil when there is none or it cannot be read.
    var get: @Sendable (_ fd: Int32) -> [UInt8]?

    static let system = FetchQuarantineIO(
        set: { fd, value in
            let rc = value.withUnsafeBytes { fsetxattr(fd, FetchQuarantine.attributeName, $0.baseAddress, $0.count, 0, 0) }
            return rc == 0 ? 0 : errno
        },
        get: { fd in
            let size = fgetxattr(fd, FetchQuarantine.attributeName, nil, 0, 0, 0)
            guard size > 0, size <= 4096 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = buffer.withUnsafeMutableBytes { fgetxattr(fd, FetchQuarantine.attributeName, $0.baseAddress, $0.count, 0, 0) }
            return read == size ? buffer : nil
        })
}

/// Everything a `FetchRunner` takes from this Mac, so tests run fully offline: they point every folder into a
/// temporary home, read a test SSH config, and hand scp `-S <fake ssh>` (a script that serves the "remote" temp folder
/// with the local `/usr/libexec/sftp-server`).
struct FetchEnvironment: Sendable {
    /// The user's home folder (`~` in `Include` lines; `~/.ssh` for relative includes).
    var home: String
    /// `~/Downloads`, opened with `O_DIRECTORY | O_NOFOLLOW`.
    var downloads: String
    /// `Paths.cachesDir/fetch` (`~/Library/Caches/Pitbox/fetch`): the private staging folders are made in here (0700),
    /// on Downloads' volume.
    var stagingParent: String
    /// `~/.ssh/config`.
    var userConfig: String
    /// `/etc/ssh/ssh_config` (`ssh -G` reads it too, so its `Match` blocks count); nil in tests, which run `ssh -G -F`.
    var systemConfig: String?
    /// The `ssh` that answers `-G`.
    var sshPath = "/usr/bin/ssh"
    /// Options for `ssh -G` before `--` (tests: `-F <test config>`).
    var resolveOptions: [String] = []
    /// Replaces running `ssh -G` (tests that do not need the real program).
    var resolver: SSHResolver?
    /// Options added to scp before `--` (tests: `-S <fake ssh>`, `-F <test config>`). Empty in the app.
    var extraSCPOptions: [String] = []
    /// The environment scp and `ssh -G` get: the terminal's allowlist with the clean PATH; `SSH_AUTH_SOCK`
    /// reaches scp only (the ssh-agent works), never `ssh -G`.
    var processEnvironment: [String: String]
    var limits = FetchLimits()
    /// Free bytes on the volume of a folder descriptor (`fstatfs`), nil when unknown.
    var freeSpace: @Sendable (_ fd: Int32) -> Int64? = FetchFolders.freeBytes
    var quarantine = FetchQuarantineIO.system

    /// The app's environment: the real home, `/etc/ssh/ssh_config`, the real `ssh -G`.
    static var live: FetchEnvironment {
        let terminal = TerminalEnvironment.live
        let home = terminal.home
        return FetchEnvironment(home: home, downloads: home + "/Downloads",
                                stagingParent: Paths.cachesDir.appendingPathComponent("fetch", isDirectory: true).path,
                                userConfig: home + "/.ssh/config", systemConfig: "/etc/ssh/ssh_config",
                                processEnvironment: processEnvironment(from: terminal))
    }

    /// The terminal's environment allowlist (HOME, USER, LOGNAME, SHELL, TMPDIR, LANG, TERM, COLORTERM,
    /// TERM_PROGRAM, TERM_PROGRAM_VERSION, __CF_USER_TEXT_ENCODING, and SSH_AUTH_SOCK when the app has one) with the
    /// clean shell's fixed PATH instead of the app's.
    static func processEnvironment(from terminal: TerminalEnvironment) -> [String: String] {
        var environment: [String: String] = [:]
        for entry in terminal.variables(shell: "/bin/zsh", preset: nil) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[entry.startIndex..<equals])] = String(entry[entry.index(after: equals)...])
        }
        environment["PATH"] = CommandExecutionDescriptor.cleanPath
        return environment
    }
}
