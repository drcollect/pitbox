import Foundation
import PitboxKit

/// The scp command a Fetch file runs, and the fixed wrapper that applies the size limit.
enum FetchCommand {
    static let scpPath = "/usr/bin/scp"
    static let shellPath = "/bin/sh"
    /// Stands for the staging folder in the plan the sheet shows, until the run creates the folder.
    static let stagingPlaceholder = "<\(AppIdentity.displayName) staging folder>"

    /// The options before `--`: a fixed list, with one change measured on this Mac (OpenSSH 10.2p1): `-q` is replaced
    /// by `-o LogLevel=ERROR`. scp hands `-q` to ssh, and a quiet ssh drops its fatal lines ("Permission denied
    /// (publickey).", "Host key verification failed."), so every failure would read "Connection closed" and the
    /// failure reasons could not be told apart. `LogLevel=ERROR` keeps exactly those lines and still hides the server's
    /// banner; without a terminal on stdout scp shows no progress meter either way. `extra` (tests only:
    /// `-S <fake ssh>`, `-F <config>`) goes right before `--`.
    static func options(connectTimeout: Int, extra: [String] = []) -> [String] {
        ["-o", "LogLevel=ERROR", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
         "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
         "-o", "ConnectTimeout=\(connectTimeout)"] + extra
    }

    /// The exact scp argument list, argv[0] first: `-- '<user>@<alias>:<path>' '<staging folder>/<name>'` after the
    /// options. `stagingFolder` is the placeholder in a plan and the real folder at the start.
    static func arguments(user: String, alias: String, remotePath: String, stagingFolder: String, fileName: String,
                          connectTimeout: Int, extraOptions: [String] = []) -> [String] {
        [scpPath] + options(connectTimeout: connectTimeout, extra: extraOptions)
            + ["--", "\(user)@\(alias):\(remotePath)", "\(stagingFolder)/\(fileName)"]
    }

    /// `ulimit -f` counts 1024-byte blocks in this Mac's `/bin/sh` (bash 3.2, measured). A shell counting
    /// 512-byte blocks would only halve the limit; a test checks the unit.
    static func sizeLimitBlocks(maxFileBytes: Int64) -> Int64 { max(1, maxFileBytes / 1024) }

    /// The fixed wrapper script: sets RLIMIT_FSIZE (soft and hard) and only then replaces itself with scp. `&&`, not `;`:
    /// if the limit cannot be set, scp never runs. The arguments are positional parameters, never parsed by the shell.
    static func sizeLimitScript(maxFileBytes: Int64) -> String {
        "ulimit -f \(sizeLimitBlocks(maxFileBytes: maxFileBytes)) && exec \(scpPath) \"$@\""
    }

    /// What is spawned: `/bin/sh -c '<script>' sh <scp arguments without argv[0]>`.
    static func spawnArguments(scpArguments: [String], maxFileBytes: Int64) -> [String] {
        [shellPath, "-c", sizeLimitScript(maxFileBytes: maxFileBytes), "sh"] + scpArguments.dropFirst()
    }
}
