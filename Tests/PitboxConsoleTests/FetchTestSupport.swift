import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

// Fetch file tests run fully offline. Every folder lives in a throwaway home; scp gets `-S <fake ssh>`, a script that
// execs the local /usr/libexec/sftp-server, so the "server" is a temp folder and nothing leaves the Mac. Nothing
// touches the real ~/Downloads, ~/.ssh, the Keychain or the ssh-agent (SSH_AUTH_SOCK is never passed). Set
// PITBOX_FETCH_TEST_TMP to keep the temp folders somewhere specific.

/// A throwaway home for one test: `home/` (with `.ssh/config`, `Downloads/`, `Library/Caches/Pitbox/fetch`),
/// `remote/` (the server's files) and `bin/` (fake ssh programs). Removed when the value goes away.
final class FetchSandbox: @unchecked Sendable {
    let root: String

    init(createDownloads: Bool = true) {
        TerminalLog.enabled = false
        let base = ProcessInfo.processInfo.environment["PITBOX_FETCH_TEST_TMP"] ?? NSTemporaryDirectory()
        let folder = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("fetch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        root = folder.resolvingSymlinksInPath().path
        for path in [home, sshFolder, remote, bin] { Self.makeFolder(path) }
        if createDownloads { Self.makeFolder(downloads) }
    }

    deinit {
        // Make every folder and file removable again (tests chmod some to 000).
        if let items = FileManager.default.enumerator(atPath: root) {
            for case let item as String in items { chmod(root + "/" + item, 0o700) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    var home: String { root + "/home" }
    var downloads: String { home + "/Downloads" }
    var stagingParent: String { home + "/Library/Caches/Pitbox/fetch" }
    var sshFolder: String { home + "/.ssh" }
    var userConfig: String { sshFolder + "/config" }
    var remote: String { root + "/remote" }
    var bin: String { root + "/bin" }

    static let buildboxConfig = "Host buildbox\n  HostName 192.0.2.10\n  User buildbox\n"

    static func makeFolder(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    @discardableResult
    func write(_ path: String, _ text: String, mode: mode_t = 0o600) -> String {
        Self.makeFolder((path as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        chmod(path, mode)
        return path
    }

    @discardableResult
    func writeConfig(_ text: String = FetchSandbox.buildboxConfig) -> String { write(userConfig, text) }

    /// A file on the "server" with `bytes` pseudo-random bytes (or the given text); returns its absolute path.
    @discardableResult
    func writeRemote(_ name: String, bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let path = remote + "/" + name
        FileManager.default.createFile(atPath: path, contents: data)
        return path
    }

    @discardableResult
    func writeRemote(_ name: String, text: String) -> String {
        let path = remote + "/" + name
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        return path
    }

    func makeScript(_ name: String, _ body: String) -> String {
        let path = bin + "/" + name
        FileManager.default.createFile(atPath: path, contents: Data(("#!/bin/sh\n" + body + "\n").utf8))
        chmod(path, 0o755)
        return path
    }

    /// scp's "ssh": the local sftp-server, serving this Mac's files (the remote paths point into `remote/`).
    var sftpSSH: String { makeScript("sftp-ssh", "exec /usr/libexec/sftp-server") }

    /// The same, but after 24 replies (the handshake, the open and about 250 KB of data) it holds until `openGate()`, so
    /// a copy is reliably still running when a test acts, however late the main queue delivers the progress report.
    var gatedSSH: String {
        makeScript("gated-ssh", """
        /usr/libexec/sftp-server | {
          n=0
          while :; do
            chunk=$(/bin/dd bs=16384 count=1 2>/dev/null | /usr/bin/base64)
            [ -z "$chunk" ] && exit 0
            printf '%s' "$chunk" | /usr/bin/base64 -D
            n=$((n + 1))
            if [ "$n" -ge 24 ]; then
              while [ ! -e '\(gatePath)' ]; do /bin/sleep 0.05; done
            fi
          done
        }
        """)
    }

    var gatePath: String { root + "/gate" }
    func openGate() { FileManager.default.createFile(atPath: gatePath, contents: Data()) }

    /// An "ssh" that never answers (a server that does not respond); its sleep, unique to this sandbox, is
    /// recognisable in `ps`.
    var hangingSSH: String { makeScript("hanging-ssh", "exec /bin/sleep \(hangSeconds)") }
    let hangSeconds = String(format: "%d.%06d", Int.random(in: 900...999), Int.random(in: 0...999_999))

    /// An "ssh" that prints what a real ssh printed on this Mac (OpenSSH 10.2p1) and fails.
    func failingSSH(_ stderr: String, status: Int32 = 255) -> String {
        let quoted = stderr.replacingOccurrences(of: "'", with: "'\\''")
        return makeScript("failing-ssh-\(UUID().uuidString.prefix(6))", "printf '%s\\n' '\(quoted)' >&2\nexit \(status)")
    }

    /// An environment pointing everything into this sandbox. `ssh` is the fake scp uses; `resolution` replaces
    /// `ssh -G` (nil runs the real `ssh -G -F <sandbox config>`).
    func environment(ssh: String? = nil, extraSCPOptions: [String] = [],
                     resolution: SSHResolution? = SSHResolution(hostName: "192.0.2.10", user: "buildbox"),
                     limits: FetchLimits = .tests, freeSpace: (@Sendable (Int32) -> Int64?)? = nil,
                     quarantine: FetchQuarantineIO = .system) -> FetchEnvironment {
        var environment = FetchEnvironment(home: home, downloads: downloads, stagingParent: stagingParent,
                                           userConfig: userConfig, systemConfig: nil,
                                           processEnvironment: ["HOME": home, "PATH": CommandExecutionDescriptor.cleanPath,
                                                                "LANG": "en_US.UTF-8"])
        environment.resolveOptions = ["-F", userConfig]
        if let resolution { environment.resolver = { _ in resolution } }
        environment.extraSCPOptions = (ssh.map { ["-S", $0] } ?? []) + extraSCPOptions
        environment.limits = limits
        environment.freeSpace = freeSpace ?? { _ in 1 << 40 }   // independent of this Mac's real free space
        environment.quarantine = quarantine
        precondition(!environment.downloads.hasPrefix(NSHomeDirectory() + "/Downloads"), "never the real Downloads")
        return environment
    }

    func entries(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    func data(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }
}

extension FetchLimits {
    /// Short limits so the tests run in seconds; the size limit stays 500 MB unless a test lowers it.
    static var tests: FetchLimits {
        var limits = FetchLimits()
        limits.connectDeadline = 10
        limits.totalDeadline = 60
        limits.pollInterval = 0.1
        return limits
    }
}

/// Collects the runner's log lines, to show they carry labels and numbers only.
final class FetchLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ line: String) { lock.withLock { recorded.append(line) } }
    var lines: [String] { lock.withLock { recorded } }
    var sink: @Sendable (String) -> Void { { [self] in record($0) } }
}

/// What one started fetch reported, on the main actor.
@MainActor
final class FetchProbe {
    /// Bytes staged at each report; the first is often 0 (scp creates the file before data arrives).
    var progress: [Int64] = []
    var outcomes: [FetchFileOutcome] = []
    var handle: FetchHandle?
    /// Set by a test's progress hook once it has acted (cancelled, swapped a folder).
    var acted = false
    var outcome: FetchFileOutcome? { outcomes.first }
}

/// Starts `plan` and waits for its outcome. `onProgress` runs on each progress report with the handle (to cancel or
/// to change things mid-copy).
@MainActor
func startFetch(_ runner: FetchRunner, _ plan: FetchPlan,
                onProgress: (@MainActor (Int64, FetchProbe) -> Void)? = nil) -> FetchProbe {
    let probe = FetchProbe()
    probe.handle = runner.start(plan, progress: { size in
        probe.progress.append(size)
        onProgress?(size, probe)
    }, completion: { probe.outcomes.append($0) })
    return probe
}

@MainActor
func runFetch(_ runner: FetchRunner, _ plan: FetchPlan, timeout: TimeInterval = 30,
              onProgress: (@MainActor (Int64, FetchProbe) -> Void)? = nil) async -> FetchProbe {
    let probe = startFetch(runner, plan, onProgress: onProgress)
    _ = await waitUntil(timeout) { !probe.outcomes.isEmpty }
    return probe
}

/// A plan for `buildbox` and a file in the sandbox's remote folder; records an issue when the plan is refused.
func makePlan(_ runner: FetchRunner, remotePath: String, replyUser: String? = nil, destinationName: String? = nil,
              loginUser: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) async -> FetchPlan? {
    let request = FetchFileRequest(alias: "buildbox", replyUser: replyUser, remotePath: remotePath,
                                   destinationName: destinationName)
    switch await runner.plan(for: request, loginUser: loginUser) {
    case .success(let plan): return plan
    case .failure(let refusal):
        Issue.record("plan refused: \(refusal)", sourceLocation: sourceLocation)
        return nil
    }
}

/// Runs a small program to the end without blocking a thread (for `ssh-keygen` and `ps` in tests).
func runTool(_ path: String, _ arguments: [String], environment: [String: String] = ["PATH": "/usr/bin:/bin"]) async
    -> (status: ProcessExit, stdout: String, stderr: String) {
    let queue = DispatchQueue(label: "fetch.tests.tool")
    return await withCheckedContinuation { continuation in
        queue.async {
            do {
                _ = try FetchChildProcess.spawn(executable: path, arguments: [path] + arguments, environment: environment,
                                                captureStdout: true, queue: queue) { exit, output in
                    continuation.resume(returning: (exit, String(decoding: output.stdout, as: UTF8.self), output.stderr))
                }
            } catch {
                continuation.resume(returning: (.unknown, "", "spawn failed"))
            }
        }
    }
}

/// The command lines of running processes that contain `needle` (to show a stopped fetch left nothing running).
func processesMentioning(_ needle: String) async -> [String] {
    let listing = await runTool("/bin/ps", ["-axww", "-o", "command="])
    return listing.stdout.split(separator: "\n").map(String.init).filter { $0.contains(needle) && !$0.contains("/bin/ps") }
}

/// The quarantine value stored on a file, read by path (tests only).
func quarantineValue(atPath path: String) -> String? {
    let size = getxattr(path, FetchQuarantine.attributeName, nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    let read = buffer.withUnsafeMutableBytes { getxattr(path, FetchQuarantine.attributeName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
    return read == size ? String(decoding: buffer, as: UTF8.self) : nil
}
