import Darwin
import Foundation
import PitboxKit

/// What the app knows from the user's SSH configuration without running anything.
struct SSHConfigFacts: Equatable, Sendable {
    /// Every exact `Host` token (no `*`, `?` or `!`) of the config and its includes, in file order, without repeats.
    var exactHosts: [String] = []
    /// A `Match` block exists somewhere: `ssh -G` is never run (`Match exec` would run a program).
    var hasMatch = false
    /// Changes when any file read (or the list of files an `Include` names) changes.
    var fingerprint = ""
    var filesRead = 0
    /// Files that were refused (`TrustedConfigFile`: a link, not a regular file, another owner, writable by others, too
    /// large, unreadable), and `Include`s that reach a refused root (`CheckedGlob`: never looked up).
    var filesRefused = 0
    /// Files an `Include` named that were never read: past the 32-file or 16-level limit, more matches of one pattern
    /// than the limit, or an argument only ssh can expand (`%` tokens, `${VAR}`, `~user`).
    var filesSkipped = 0

    func isExactHost(_ alias: String) -> Bool { exactHosts.contains(alias) }

    /// Every file was read without a problem and none has a `Match` block: only then may `ssh -G` read the same files
    /// (a `Match exec` in a file Pitbox could not read would run a program). Otherwise the HostName stays unknown.
    var allowsHostLookup: Bool { !hasMatch && filesRefused == 0 && filesSkipped == 0 }
}

/// Reads `~/.ssh/config` and the files its `Include` lines name (globs expanded, `~` and paths relative to `~/.ssh`
/// resolved, at most 16 levels and 32 files). Every file is read as `TrustedConfigFile` reads it: a link is refused,
/// and it must be a regular file owned by the user or root, not writable by group or others, at most 256 KB. Every
/// `Include` is expanded by `CheckedGlob` under the network check before any lookup: one that reaches `/net`, `/home`,
/// `/Volumes`, `/Network`, an automount point or a network filesystem counts as a refused file. A missing file is no
/// problem (ssh skips it too); a refused file or one past the limits is. Nothing is run.
enum SSHConfigReader {
    static let maxFiles = 32
    static let maxDepth = 16
    static let maxBytes = 256 * 1024

    /// An alias the app may use: `^[A-Za-z0-9._-]{1,64}$` with no leading `-`.
    static func isValidAlias(_ text: String) -> Bool {
        let bytes = text.utf8
        guard (1...64).contains(bytes.count), bytes.first != 0x2D else { return false }
        return bytes.allSatisfy { CodeIDs.isAlphanumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
    }

    /// - Parameter pathGuard: the network check for every `Include` (the mount table read at most once a second).
    static func read(configPath: String, sshFolder: String, home: String, owner: uid_t,
                     guard pathGuard: NetworkPathGuard = .recent()) -> SSHConfigFacts {
        var facts = SSHConfigFacts()
        var seenHosts = Set<String>()
        var visited = Set<String>()
        var fingerprint: [String] = []

        func visit(_ path: String, depth: Int) {
            guard !visited.contains(path) else { return }
            guard depth <= maxDepth, facts.filesRead + facts.filesRefused < maxFiles else {
                facts.filesSkipped += 1
                fingerprint.append("skipped")
                return
            }
            visited.insert(path)
            let text: String
            // An included file is checked against the network roots too (the configuration file itself is yours).
            switch TrustedConfigFile.read(path, owner: owner, maxBytes: maxBytes, guard: depth > 0 ? pathGuard : nil) {
            case .failure(.missing):
                fingerprint.append("missing")
                return
            case .failure:
                facts.filesRefused += 1
                fingerprint.append("refused")
                return
            case .success(let contents):
                text = String(decoding: contents.data, as: UTF8.self)
                fingerprint.append("\(contents.device):\(contents.inode):\(contents.data.count):\(contents.modifiedSeconds).\(contents.modifiedNanoseconds)")
            }
            facts.filesRead += 1
            for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
                let tokens = tokens(rawLine)
                guard let keyword = tokens.first?.lowercased() else { continue }
                let arguments = Array(tokens.dropFirst())
                switch keyword {
                case "host":
                    for token in arguments where !token.contains("*") && !token.contains("?") && !token.hasPrefix("!") {
                        if seenHosts.insert(token).inserted { facts.exactHosts.append(token) }
                    }
                case "match":
                    facts.hasMatch = true
                case "include":
                    for pattern in arguments {
                        // A token only ssh expands: Pitbox cannot know the file, so it counts as never read.
                        guard !SSHIncludeToken.needsSSH(pattern) else {
                            facts.filesSkipped += 1
                            fingerprint.append("unexpanded")
                            continue
                        }
                        guard let (matches, more) = expand(pattern, sshFolder: sshFolder, home: home, guard: pathGuard) else {
                            // It reaches a refused root: never looked up, and ssh would look there.
                            facts.filesRefused += 1
                            fingerprint.append("refused")
                            continue
                        }
                        fingerprint.append("include:\(matches.count)")
                        if more {
                            facts.filesSkipped += 1
                            fingerprint.append("skipped")
                        }
                        for match in matches { visit(match, depth: depth + 1) }
                    }
                default:
                    break
                }
            }
        }

        visit(configPath, depth: 0)
        facts.fingerprint = fingerprint.joined(separator: "|")
        return facts
    }

    /// A config line as tokens: the keyword, then its arguments. Like OpenSSH: the keyword ends at whitespace or `=`
    /// (`Keyword args`, `Keyword=args`, `Keyword = args`), double quotes group an argument, and an unquoted `#` that
    /// starts a token ends the line.
    static func tokens(_ line: Substring) -> [String] {
        var rest = line.drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first, first != "#" else { return [] }
        let keyword = rest.prefix { $0 != " " && $0 != "\t" && $0 != "=" }
        guard !keyword.isEmpty else { return [] }
        rest = rest.dropFirst(keyword.count).drop { $0 == " " || $0 == "\t" }
        if rest.first == "=" { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        var tokens = [String(keyword)]
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in rest {
            if inQuotes {
                if character == "\"" {
                    inQuotes = false
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" {
                inQuotes = true
                hasToken = true
                continue
            }
            if character == " " || character == "\t" {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            if character == "#", !hasToken { break }
            current.append(character)
            hasToken = true
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    // MARK: Internals

    /// The files an `Include` pattern names, sorted (glob order), at most `maxFiles`; `more` when it named more. Nil
    /// when the pattern reaches a refused root (`CheckedGlob`: nothing was looked up there).
    private static func expand(_ pattern: String, sshFolder: String, home: String,
                               guard pathGuard: NetworkPathGuard) -> (paths: [String], more: Bool)? {
        var path = pattern
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + path.dropFirst(1)
        } else if !path.hasPrefix("/") {
            path = (sshFolder.hasSuffix("/") ? sshFolder : sshFolder + "/") + path
        }
        guard !path.contains("\0") else { return ([], false) }
        switch CheckedGlob.expand(path, guard: pathGuard) {
        case .refused:
            return nil
        case .failed:
            return ([], false)
        case .matches(let paths):
            return paths.count > maxFiles ? (Array(paths.prefix(maxFiles)), true) : (paths, false)
        }
    }
}

/// Looks up the HostName of an SSH alias with `ssh -G <alias>`, which prints the resolved configuration and never
/// connects. Called only for a valid alias that is an exact `Host` token of a config whose every file was read
/// without a problem and has no `Match` block (`SSHConfigFacts.allowsHostLookup`). The child gets no input, a small
/// fixed environment and 3 seconds.
enum SSHHostNameLookup {
    static let timeout: TimeInterval = 3

    static func hostName(alias: String, home: String, user: String) -> String? {
        guard SSHConfigReader.isValidAlias(alias) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // `-F` makes ssh read exactly the file the app scanned for `Match` blocks and nothing else: with a config file
        // on the command line ssh ignores the system-wide /etc/ssh/ssh_config, whose `Match exec` this check never saw.
        process.arguments = ["-G", "-F", home + "/.ssh/config", alias]
        process.environment = ["HOME": home, "USER": user, "LOGNAME": user, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0, data.count <= 256 * 1024 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// The `hostname` line of `ssh -G` output, when it is a plausible host name or address.
    static func parse(_ output: String) -> String? {
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "hostname" else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let allowed = value.utf8.allSatisfy { CodeIDs.isAlphanumeric($0) || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F || $0 == 0x3A || $0 == 0x25 }
            return (1...253).contains(value.utf8.count) && allowed ? value : nil
        }
        return nil
    }
}
