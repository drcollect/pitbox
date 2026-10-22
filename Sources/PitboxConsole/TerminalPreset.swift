import Foundation

/// One entry of the "+" menu: what a new session runs. Presets come from the console's settings (`TerminalSettings`), which the app builds from its settings file.
struct TerminalPreset: Equatable {
    enum Kind: Equatable {
        /// The user's login shell (`$SHELL -l`).
        case shell
        /// A program, started by the login shell as `exec <argv>` so PATH and the user's profile apply.
        case program
        /// A shell snippet, run by the login shell (`-l -i -c <script>`).
        case script
        /// A tab Pitbox opened from a command sheet: Run or Type into terminal.
        /// Never from the settings: fixed `/bin/zsh` through the command spawn path (`Commands/`), the folder by
        /// descriptor, no restart, never saved in `console-state.json`, always covered in snapshots.
        case command
    }

    var id: String
    var name: String
    /// Program and arguments (never a shell string: they are quoted before the login shell sees them).
    var argv: [String]?
    /// Raw shell text, for pipelines and `cd x && y`.
    var script: String?
    /// Working directory, `~` allowed. Nil means the home folder (a plain shell is restored in its last folder).
    var cwd: String?
    /// Extra environment variables for this preset.
    var env: [String: String]
    var enabled: Bool
    /// Whether the tab comes back after a restart of the app.
    var restore: Bool
    /// Set for the tabs a command sheet opens (Run, Type into terminal, a server tab); nil for every settings
    /// preset. Such tabs are never saved in `console-state.json` and never take the keyboard by themselves.
    var commandRole: CommandTabRole? = nil

    var kind: Kind {
        if let commandRole, commandRole != .server { return .command }
        return argv != nil ? .program : (script != nil ? .script : .shell)
    }

    /// A tab from a command sheet (Run, Type, server).
    var isFromCommandSheet: Bool { commandRole != nil }

    /// The built-in plain shell. Always available, even when the settings do not list it.
    static let builtInShell = TerminalPreset(id: "shell", name: "Shell", argv: nil, script: nil, cwd: nil, env: [:],
                                             enabled: true, restore: true)

    /// `[a-z0-9][a-z0-9_-]{0,31}`
    static func isValidID(_ id: String) -> Bool {
        guard (1...32).contains(id.count), let first = id.unicodeScalars.first else { return false }
        func ok(_ u: Unicode.Scalar, separators: Bool) -> Bool {
            (u >= "a" && u <= "z") || (u >= "0" && u <= "9") || (separators && (u == "-" || u == "_"))
        }
        return ok(first, separators: false) && id.unicodeScalars.allSatisfy { ok($0, separators: true) }
    }

    /// `[A-Za-z_][A-Za-z0-9_]*`
    static func isValidEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func letter(_ u: Unicode.Scalar) -> Bool { (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || u == "_" }
        return letter(first) && name.unicodeScalars.allSatisfy { letter($0) || ($0 >= "0" && $0 <= "9") }
    }

    /// Lowercase slug for a name: "My Box (prod)" becomes "my-box-prod"; empty when nothing is left.
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return String(out.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Parses one preset object. Problems are appended to `warnings`; nil means the entry is unusable and is skipped.
    static func parse(_ raw: Any, index: Int, warnings: inout [String]) -> TerminalPreset? {
        let label = "presets[\(index)]"
        guard let object = raw as? [String: Any] else {
            warnings.append("\(label): expected an object")
            return nil
        }
        let name = (object["name"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        var id = (object["id"] as? String) ?? ""
        if id.isEmpty { id = slug(name) }
        guard isValidID(id) else {
            warnings.append("\(label): needs an id like \"my-box\" (a-z, 0-9, - and _, at most 32 characters)")
            return nil
        }
        var preset = TerminalPreset(id: id, name: name.isEmpty ? id : String(name.prefix(60)), argv: nil, script: nil,
                                    cwd: nil, env: [:], enabled: true, restore: true)
        if let argv = object["argv"] {
            if let list = argv as? [Any], !list.isEmpty, let strings = list as? [String],
               let first = strings.first, !first.isEmpty, !strings.contains(where: { $0.contains("\0") }) {
                preset.argv = strings
            } else {
                warnings.append("\(label) (\(id)): argv must be a non-empty list of strings")
                return nil
            }
        }
        if let script = object["script"] {
            if preset.argv != nil {
                warnings.append("\(label) (\(id)): both argv and script are set; using argv")
            } else if let text = script as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !text.contains("\0") {
                preset.script = text
            } else {
                warnings.append("\(label) (\(id)): script must be a non-empty string")
                return nil
            }
        }
        if let cwd = object["cwd"] {
            if let text = cwd as? String, !text.isEmpty, !text.contains("\0") {
                preset.cwd = text
            } else if !(cwd is NSNull) {
                warnings.append("\(label) (\(id)): cwd must be a path string; using the home folder")
            }
        }
        if let env = object["env"] {
            if let dictionary = env as? [String: Any] {
                for (key, value) in dictionary {
                    if isValidEnvName(key), let text = value as? String, !text.contains("\0") {
                        preset.env[key] = text
                    } else {
                        warnings.append("\(label) (\(id)): env entry \"\(key)\" ignored (names are letters, digits and _, values strings)")
                    }
                }
            } else if !(env is NSNull) {
                warnings.append("\(label) (\(id)): env must be an object")
            }
        }
        if let enabled = object["enabled"] as? Bool { preset.enabled = enabled }
        if let restore = object["restore"] as? Bool { preset.restore = restore }
        return preset
    }
}

/// Quoting for the one place a shell string is built from data: presets with `argv`.
enum ShellQuote {
    /// POSIX single-quote quoting: `a'b` becomes `'a'\''b'`. The same text is understood by sh, bash, zsh and fish.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func join(_ argv: [String]) -> String { argv.map(quote).joined(separator: " ") }

    /// Escapes a file path for typing into a shell prompt with backslashes (what dragging a file into Terminal.app
    /// does): `My File (1).png` becomes `My\ File\ \(1\).png`. Non-ASCII characters stay as they are.
    static func escapePath(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.utf8.count + 8)
        for scalar in path.unicodeScalars {
            if scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value) { continue }   // control characters cannot be typed
            let safe = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
                || "_-./:@%+=,".unicodeScalars.contains(scalar) || scalar.value >= 0xa0
            if !safe { out.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out
    }
}
