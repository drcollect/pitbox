import Foundation
import PitboxKit

/// What a command or Type tab starts: always `/bin/zsh`, with exactly the descriptor's
/// arguments (and the text after `-c` for Run), in an environment built from the allowlist at spawn time. Built from a
/// `CommandExecutionDescriptor` the sheet froze when it opened; anything outside the rules refuses to build, so nothing
/// starts (fail closed).
struct CommandLaunchSpec: Equatable {
    /// Always `/bin/zsh` (one shell): never `$SHELL` or the configured shell.
    var executable: String
    /// argv, `argv[0]` first: `/bin/zsh -f -i -o interactivecomments -o nobanghist -c <text>` for Run, the same
    /// without `-c <text>` for Type, `/bin/zsh -l -i -c <text>` for `commandShell: login`.
    var argv: [String]
    /// `NAME=value` strings, sorted by name.
    var environment: [String]

    /// The only shell a command tab runs.
    static let shellPath = "/bin/zsh"

    /// Names that may reach a command's shell. `SSH_AUTH_SOCK` only when the descriptor names it
    /// (a segment runs an ssh-family program), or with `commandShell: login`, which uses the terminal's own allowlist.
    static let allowedNames: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "TERM", "COLORTERM", "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION", "__CF_USER_TEXT_ENCODING", "SSH_AUTH_SOCK",
    ]

    enum BuildProblem: Error, Equatable {
        /// Not `/bin/zsh`, or arguments that do not match the kind.
        case shell
        /// The machine is not this Mac: nothing runs for another machine.
        case machine
        /// A name outside the allowlist, or a PATH with an empty or relative entry.
        case environment
        /// The text holds a NUL, or is empty for Run.
        case text

        var words: String {
            switch self {
            case .shell: return "the shell isn't the one \(AppIdentity.displayName) runs commands in"
            case .machine: return "this command isn't for this Mac"
            case .environment: return "the command's environment isn't the reviewed one"
            case .text: return "the command text can't be run"
            }
        }
    }

    /// A spec as given, unchecked: only for tests that prove the helper refuses what the app would never build.
    init(unchecked executable: String, argv: [String], environment: [String]) {
        self.executable = executable
        self.argv = argv
        self.environment = environment
    }

    /// The spec for `descriptor`, with values for the descriptor's environment names taken from `environment` now.
    init(descriptor: CommandExecutionDescriptor, environment: TerminalEnvironment) throws {
        guard descriptor.shellPath == Self.shellPath else { throw BuildProblem.shell }
        guard descriptor.machine == .thisMac else { throw BuildProblem.machine }
        guard !descriptor.text.contains("\0"), !descriptor.shellArguments.contains(where: { $0.contains("\0") }) else {
            throw BuildProblem.text
        }
        switch descriptor.kind {
        case .run:
            // The options end with `-c`; the text is the one argument after it.
            guard descriptor.shellArguments.last == "-c",
                  descriptor.shellArguments.dropLast().allSatisfy({ $0 != "-c" }) else { throw BuildProblem.shell }
            guard !descriptor.text.isEmpty else { throw BuildProblem.text }
            argv = [Self.shellPath] + descriptor.shellArguments + [descriptor.text]
        case .typeIntoTerminal:
            // An interactive shell: no `-c`, no text (the text is pasted later, never passed as an argument).
            guard !descriptor.shellArguments.contains("-c") else { throw BuildProblem.shell }
            argv = [Self.shellPath] + descriptor.shellArguments
        }
        guard Self.isCleanPath(descriptor.path) else { throw BuildProblem.environment }
        var values: [String: String] = [:]
        for name in descriptor.environmentNames {
            guard Self.allowedNames.contains(name) else { throw BuildProblem.environment }
            if let value = Self.value(of: name, path: descriptor.path, environment: environment), !value.contains("\0") {
                values[name] = value
            }
        }
        executable = Self.shellPath
        self.environment = values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }
    }

    /// The value of one allowed name at spawn time.
    static func value(of name: String, path: String, environment: TerminalEnvironment) -> String? {
        let parent = environment.parent
        func inherited(_ key: String) -> String? { parent[key].flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "HOME": return environment.home
        case "USER": return inherited("USER") ?? environment.userName
        case "LOGNAME": return inherited("LOGNAME") ?? environment.userName
        case "SHELL": return shellPath
        case "PATH": return path
        case "TMPDIR": return inherited("TMPDIR")
        case "LANG": return environment.languageValue()
        case "TERM": return "xterm-256color"
        case "COLORTERM": return "truecolor"
        case "TERM_PROGRAM": return AppIdentity.displayName
        case "TERM_PROGRAM_VERSION": return environment.appVersion
        case "__CF_USER_TEXT_ENCODING": return inherited("__CF_USER_TEXT_ENCODING")
        case "SSH_AUTH_SOCK": return inherited("SSH_AUTH_SOCK")
        default: return nil
        }
    }

    /// Every entry absolute, none empty, no NUL: a folder's own `bin/` can never be found through PATH.
    static func isCleanPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("\0") else { return false }
        return path.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { $0.hasPrefix("/") }
    }
}
