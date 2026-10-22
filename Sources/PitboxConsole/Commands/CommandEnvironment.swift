import Darwin
import Foundation
import PitboxKit

/// The shell, PATH and environment names of a run (clean or login, the `commandShell` setting), decided by the sheet
/// when it opens and frozen in its `FrozenCommand`. Values are filled in at spawn time (`CommandLaunchSpec`).
enum CommandEnvironmentRules {
    /// The names every clean-shell run gets.
    static let cleanNames = ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "TERM", "COLORTERM",
                             "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "__CF_USER_TEXT_ENCODING"]
    /// `commandShell: login`: the terminal's own allowlist (`TerminalEnvironment.variables`), the ssh-agent included.
    static let loginNames = cleanNames + ["SSH_AUTH_SOCK"]
    /// Programs that get `SSH_AUTH_SOCK` in the clean shell, with the note "uses your ssh-agent".
    static let sshFamily: Set<String> = ["ssh", "scp", "sftp", "rsync", "mosh", "sshfs", "rclone", "git"]

    /// The clean shell's options, before `-c <text>` for Run.
    static func arguments(kind: CommandExecutionDescriptor.Kind, shell: CommandExecutionDescriptor.Shell) -> [String] {
        switch (kind, shell) {
        case (.run, .clean): return CommandExecutionDescriptor.cleanRunArguments + ["-c"]
        case (.typeIntoTerminal, .clean): return CommandExecutionDescriptor.cleanTypeArguments
        case (.run, .login): return ["-l", "-i", "-c"]
        case (.typeIntoTerminal, .login): return ["-l", "-i"]
        }
    }

    /// True when a segment runs an ssh-family program, or the classifier noted the ssh-agent.
    static func usesSSHAgent(_ assessment: CommandAssessment) -> Bool {
        assessment.segments.contains { sshFamily.contains($0.program ?? "") }
            || assessment.notes.contains { $0.kind == .usesSSHAgent }
    }

    /// The environment names of a run.
    static func names(shell: CommandExecutionDescriptor.Shell, sshAgent: Bool) -> [String] {
        switch shell {
        case .clean: return (cleanNames + (sshAgent ? ["SSH_AUTH_SOCK"] : [])).sorted()
        case .login: return loginNames.sorted()
        }
    }

    // MARK: PATH

    /// Why an `extraPath` entry was ignored (logged as a label, never as the path).
    enum ExtraPathProblem: String, Equatable {
        case relative, missing, notAFolder = "not-a-folder", writableByOthers = "writable-by-others", unusable
    }

    /// The fixed PATH plus every `extraPath` folder that passes `check`, in order, without duplicates.
    static func cleanPath(extraPath: [String], check: (String) -> ExtraPathProblem? = checkFolder) -> (path: String, ignored: [ExtraPathProblem]) {
        var entries = CommandExecutionDescriptor.cleanPath.split(separator: ":").map(String.init)
        var ignored: [ExtraPathProblem] = []
        for entry in extraPath {
            if let problem = check(entry) { ignored.append(problem); continue }
            let normalized = FolderBinding.lexicallyNormalized(entry)
            if !entries.contains(normalized) { entries.append(normalized) }
        }
        return (entries.joined(separator: ":"), ignored)
    }

    /// An `extraPath` folder must be absolute, exist, be a folder, and not be writable by group or others.
    static func checkFolder(_ path: String) -> ExtraPathProblem? {
        guard path.hasPrefix("/") else { return .relative }
        guard !path.contains(":"), !path.contains("\0"), !path.contains("\n") else { return .unusable }
        var info = stat()
        guard stat(path, &info) == 0 else { return .missing }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .notAFolder }
        guard info.st_mode & 0o022 == 0 else { return .writableByOthers }
        return nil
    }

    /// `commandShell: login`: the terminal's own PATH (the app's, else the fallback), relative and empty entries left
    /// out.
    static func loginPath(environment: TerminalEnvironment) -> String {
        let raw = environment.parent["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? TerminalEnvironment.fallbackPath
        let entries = raw.split(separator: ":", omittingEmptySubsequences: true).map(String.init).filter { $0.hasPrefix("/") }
        return entries.isEmpty ? TerminalEnvironment.fallbackPath : entries.joined(separator: ":")
    }
}
