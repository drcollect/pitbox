import Foundation
import PitboxKit

/// Everything needed to start a process for a session: program, arguments, environment, working directory.
struct LaunchSpec: Equatable {
    var executable: String
    var argv: [String]
    /// `NAME=value` strings.
    var env: [String]
    var cwd: String
    var presetID: String
    var kind: TerminalPreset.Kind
    /// File name of the login shell (`zsh`), used to tell "the shell is idle" from "a program is running".
    var shellName: String
}

/// Builds the child's shell, environment and working directory.
///
/// The app is started by LaunchServices with a minimal environment, so the child gets a small allowlist of the app's own
/// variables plus the terminal ones (`TERM`, `COLORTERM`, `TERM_PROGRAM`, a UTF-8 `LANG`). Everything else in the app's
/// environment stays out. The shell is started as a login shell (`-l`), which is what sources the user's profile and so
/// sets up `PATH`, exactly as Terminal.app does.
///
/// All inputs are plain values so tests can drive every branch.
struct TerminalEnvironment {
    /// The app's own environment.
    var parent: [String: String]
    var home: String
    var userName: String
    /// The account's login shell from the user database.
    var accountShell: String?
    var languageCode: String?
    var regionCode: String?
    var appVersion: String
    var isExecutable: (String) -> Bool
    var localeExists: (String) -> Bool
    var isDirectory: (String) -> Bool

    /// Variables copied from the app's environment when present. Nothing else is inherited.
    static let inherited = ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"]
    static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    static var live: TerminalEnvironment {
        let info = ProcessInfo.processInfo
        let account = getpwuid(getuid())
        let home = account.flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let locale = Locale.current
        return TerminalEnvironment(
            parent: info.environment,
            home: home.isEmpty ? NSHomeDirectory() : home,
            userName: account.flatMap { String(validatingCString: $0.pointee.pw_name) } ?? NSUserName(),
            accountShell: account.flatMap { String(validatingCString: $0.pointee.pw_shell) },
            languageCode: locale.language.languageCode?.identifier,
            regionCode: locale.region?.identifier,
            appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1",
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            localeExists: { FileManager.default.fileExists(atPath: "/usr/share/locale/\($0)") },
            isDirectory: {
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
            })
    }

    /// The login shell: the configured one, `$SHELL`, the account's shell, then `/bin/zsh` (and `/bin/sh` as a last
    /// resort). Only absolute paths of executable files qualify.
    func resolveShell(configured: String?) -> String {
        for candidate in [configured, parent["SHELL"], accountShell, "/bin/zsh"] {
            if let path = candidate, path.hasPrefix("/"), !path.contains("\0"), isExecutable(path) { return path }
        }
        return "/bin/sh"
    }

    /// A UTF-8 `LANG`: the app's own if it already is UTF-8, else `<language>_<REGION>.UTF-8` when that locale exists on
    /// this Mac, else `en_US.UTF-8`.
    func languageValue() -> String {
        if let lang = parent["LANG"] {
            let upper = lang.uppercased()
            if upper.hasSuffix("UTF-8") || upper.hasSuffix("UTF8") { return lang }
        }
        if let language = languageCode, let region = regionCode {
            let candidate = "\(language)_\(region).UTF-8"
            if localeExists(candidate) { return candidate }
        }
        return "en_US.UTF-8"
    }

    /// Expands `~`, requires an absolute path that is a folder, otherwise the home folder. `fellBack` tells the caller
    /// to mention it.
    func resolveDirectory(_ requested: String?) -> (path: String, fellBack: Bool) {
        guard var path = requested, !path.isEmpty else { return (home, false) }
        if path == "~" { path = home }
        else if path.hasPrefix("~/") { path = home + String(path.dropFirst(1)) }
        guard path.hasPrefix("/"), !path.contains("\0") else { return (home, true) }
        path = (path as NSString).standardizingPath
        return isDirectory(path) ? (path, false) : (home, true)
    }

    /// The child's environment as `NAME=value` strings, sorted by name.
    func variables(shell: String, preset: TerminalPreset?) -> [String] {
        var env: [String: String] = [:]
        for name in Self.inherited {
            if let value = parent[name], !value.isEmpty, !value.contains("\0") { env[name] = value }
        }
        env["HOME"] = home
        if env["USER"] == nil { env["USER"] = userName }
        if env["LOGNAME"] == nil { env["LOGNAME"] = userName }
        env["SHELL"] = shell
        env["PATH"] = (parent["PATH"]?.isEmpty == false ? parent["PATH"] : nil) ?? Self.fallbackPath
        env["LANG"] = languageValue()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = AppIdentity.displayName
        env["TERM_PROGRAM_VERSION"] = appVersion
        for (name, value) in preset?.env ?? [:] where TerminalPreset.isValidEnvName(name) { env[name] = value }
        return env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
    }

    /// Program, arguments, environment and folder for a new session.
    /// - Parameter cwd: the folder to start in (a plain shell's last folder); presets that pin a `cwd` use their own.
    func launchSpec(preset: TerminalPreset, settings: TerminalSettings, cwd: String? = nil) -> (spec: LaunchSpec, cwdFellBack: Bool) {
        let shell = resolveShell(configured: settings.shell)
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let requested = preset.kind == .shell ? (cwd ?? preset.cwd) : (preset.cwd ?? cwd)
        let folder = resolveDirectory(requested)
        let argv: [String]
        var executable = shell
        switch preset.kind {
        case .shell: argv = [shellName, "-l"]
        case .program: argv = [shellName, "-l", "-i", "-c", "exec " + ShellQuote.join(preset.argv ?? [])]
        case .script: argv = [shellName, "-l", "-i", "-c", preset.script ?? ""]
        case .command:
            // Command and Type tabs start through `Commands/CommandSpawner`, never here. Should one ever reach this
            // path, it runs `false` and nothing else (fail closed).
            executable = "/usr/bin/false"
            argv = ["false"]
        }
        let spec = LaunchSpec(executable: executable, argv: argv, env: variables(shell: shell, preset: preset), cwd: folder.path,
                              presetID: preset.id, kind: preset.kind, shellName: shellName)
        return (spec, folder.fellBack)
    }
}
