import Dispatch
import Foundation

/// Runs `ssh -G [options] -- <alias>` (prints the effective settings and exits; it never connects) and parses what it
/// printed. Only called when no SSH config file has a `Match` block. Bounded: stopped after `timeout` seconds,
/// at most 256 KB of output kept. Nothing waits on a thread: the child is watched with dispatch sources.
enum SSHLookup {
    static func resolve(alias: String, sshPath: String, options: [String], environment: [String: String],
                        timeout: TimeInterval) async -> SSHResolution? {
        let queue = DispatchQueue(label: "pitbox.console.fetch.lookup")
        var lookupEnvironment = environment
        lookupEnvironment.removeValue(forKey: "SSH_AUTH_SOCK")   // printing settings needs no agent
        return await withCheckedContinuation { (continuation: CheckedContinuation<SSHResolution?, Never>) in
            queue.async {
                let child: FetchChildProcess
                do {
                    child = try FetchChildProcess.spawn(
                        executable: sshPath, arguments: [sshPath, "-G"] + options + ["--", alias],
                        environment: lookupEnvironment, captureStdout: true, queue: queue) { exit, output in
                            guard exit == .exited(0) else { return continuation.resume(returning: nil) }
                            continuation.resume(returning: SSHResolution(output: String(decoding: output.stdout, as: UTF8.self)))
                        }
                } catch {
                    return continuation.resume(returning: nil)
                }
                queue.asyncAfter(deadline: .now() + timeout) { child.killGroup() }
            }
        }
    }
}
