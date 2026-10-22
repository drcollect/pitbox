import Darwin
import Foundation
import PitboxKit

/// The exact `Host` tokens of the user's `~/.ssh/config` and the files it `Include`s, for "Open a terminal on <host>".
/// Read by Pitbox itself; nothing is run (no `ssh -G`). A pattern (`*`, `?`, a `!` negation) never counts, and neither
/// does anything outside the alias grammar. Every file is read as `TrustedConfigFile` reads it (a link is refused; a
/// regular file owned by you or root, not writable by group or others, at most 256 KB). Every `Include` is expanded by
/// `CheckedGlob` under the network check before any lookup. A refused file, an `Include` that reaches a refused root
/// (`/net`, `/Volumes`, an automount point, …), one past the 64-file or 16-level limit, or one only ssh can expand (`%`
/// tokens, `${VAR}`, `~user`) is a problem: then no alias counts as exact (fail closed). Reading takes up to 64 files:
/// callers ask off the main thread.
enum SSHConfigHosts {
    /// OpenSSH's own limit on nested `Include`s.
    static let maxDepth = 16
    static let maxFiles = 64
    static let maxFileBytes = 256 * 1024

    /// What one reading found.
    struct Reading: Equatable {
        var hosts: Set<String> = []
        /// A file was refused or never reached: the hosts are not the whole story.
        var hasProblem = false
    }

    /// `^[A-Za-z0-9._-]{1,64}$` with no leading `-`.
    static func isWellFormedAlias(_ alias: String) -> Bool {
        guard (1...64).contains(alias.utf8.count), alias.first != "-" else { return false }
        return alias.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    /// True when `alias` is well formed and an exact `Host` token of a config read without a problem (case as written).
    static func isExactAlias(_ alias: String, home: String, uid: uid_t = getuid(),
                             guard pathGuard: NetworkPathGuard = .recent()) -> Bool {
        guard isWellFormedAlias(alias) else { return false }
        let reading = read(home: home, uid: uid, guard: pathGuard)
        return !reading.hasProblem && reading.hosts.contains(alias)
    }

    /// Every exact `Host` token in `<home>/.ssh/config` and its includes, and whether a file was refused or skipped.
    /// `pathGuard` is the network check for every `Include` (the mount table read at most once a second).
    static func read(home: String, uid: uid_t = getuid(), guard pathGuard: NetworkPathGuard = .recent()) -> Reading {
        let sshDirectory = home + "/.ssh"
        var state = ReadState(home: home, sshDirectory: sshDirectory, uid: uid, pathGuard: pathGuard)
        state.read(sshDirectory + "/config", depth: 0)
        return state.reading
    }

    /// Splits one config line into its keyword and arguments, OpenSSH style: whitespace or one `=` after the keyword,
    /// double quotes group words, a word starting with `#` ends the line.
    static func tokens(of line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var hadQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if inQuotes {
                if character == "\"" { inQuotes = false } else { current.append(character) }
            } else if character == "\"" {
                inQuotes = true
                hadQuotes = true
            } else if character == " " || character == "\t" || (character == "=" && out.isEmpty) {
                if !current.isEmpty || hadQuotes { out.append(current) }
                current = ""
                hadQuotes = false
            } else if character == "#", current.isEmpty, !hadQuotes {
                break
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        if !current.isEmpty || hadQuotes { out.append(current) }
        return out
    }

    private struct ReadState {
        let home: String
        let sshDirectory: String
        let uid: uid_t
        let pathGuard: NetworkPathGuard
        var reading = Reading()
        var filesRead = 0
        var seen: Set<String> = []

        mutating func read(_ path: String, depth: Int) {
            guard !seen.contains(path) else { return }
            guard depth <= SSHConfigHosts.maxDepth, filesRead < SSHConfigHosts.maxFiles else {
                reading.hasProblem = true
                return
            }
            seen.insert(path)
            let text: String
            // An included file is checked against the network roots too (the configuration file itself is yours).
            switch TrustedConfigFile.read(path, owner: uid, maxBytes: SSHConfigHosts.maxFileBytes,
                                          guard: depth > 0 ? pathGuard : nil) {
            case .failure(.missing):
                return
            case .failure:
                reading.hasProblem = true
                return
            case .success(let contents):
                text = String(decoding: contents.data, as: UTF8.self)
            }
            filesRead += 1
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let words = SSHConfigHosts.tokens(of: String(raw))
                guard let keyword = words.first?.lowercased() else { continue }
                let arguments = words.dropFirst()
                switch keyword {
                case "host":
                    for token in arguments where !token.contains("*") && !token.contains("?") && !token.hasPrefix("!") {
                        if SSHConfigHosts.isWellFormedAlias(token) { reading.hosts.insert(token) }
                    }
                case "include":
                    for pattern in arguments {
                        // A token only ssh expands: Pitbox cannot know the file, so the reading is incomplete.
                        guard !SSHIncludeToken.needsSSH(pattern) else {
                            reading.hasProblem = true
                            continue
                        }
                        guard let files = expand(pattern) else {
                            // It reaches a refused root: never looked up, so the reading is incomplete.
                            reading.hasProblem = true
                            continue
                        }
                        for file in files { read(file, depth: depth + 1) }
                    }
                default:
                    break
                }
            }
        }

        /// `~` and relative paths (relative to `~/.ssh`, as OpenSSH reads user includes), then `glob(3)` under the network
        /// check (`CheckedGlob`). Nil when the pattern reaches a refused root (nothing was looked up there).
        func expand(_ pattern: String) -> [String]? {
            var path = pattern
            if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
            if !path.hasPrefix("/") { path = sshDirectory + "/" + path }
            switch CheckedGlob.expand(path, guard: pathGuard) {
            case .refused: return nil
            case .failed: return []
            case .matches(let files): return files.sorted()
            }
        }
    }
}
