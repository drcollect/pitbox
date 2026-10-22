import CryptoKit
import Darwin
import Foundation
import PitboxKit

// Fetch file: Pitbox reads the SSH configuration files itself, so finding out
// whether an alias exists, and whether `ssh -G` would have to evaluate a `Match` block (`Match exec` runs a program),
// runs nothing. The same reading gives the fingerprint that is checked again before connecting.

/// One file the reader looked at: its path and, when it exists, size, modification time and SHA-256.
struct SSHConfigFileRecord: Equatable, Sendable {
    var path: String
    var exists: Bool
    var size: Int64 = 0
    var modifiedSeconds: Int = 0
    var modifiedNanoseconds: Int = 0
    var sha256: String = ""
}

/// What reading the SSH configuration found, without running anything.
struct SSHConfigReading: Equatable, Sendable {
    /// Why the files could not be read faithfully; any of these means "couldn't read your SSH config without running
    /// it", never a guess.
    enum Problem: String, Sendable {
        case unreadable, notAFile, tooLarge, tooManyFiles, tooDeep, unsupportedInclude, badQuotes
        /// A link (only root's own link in a root-only folder is followed: `TrustedConfigFile`).
        case link
        /// Owned by someone other than you or root.
        case owner
        /// Writable by group or others.
        case writable
    }

    /// Every token of every `Host` line of `~/.ssh/config` and the files it includes (not the system files). An alias
    /// counts only as one of these, exactly.
    var hostTokens: Set<String> = []
    /// A `Match` line in any file read, the user's or the system's.
    var hasMatch = false
    var problem: Problem?
    /// Every file looked at, in reading order.
    var records: [SSHConfigFileRecord] = []

    /// `v1-<hex>`: the SHA-256 over every record, so it changes when a file read changes size, time or content, when
    /// one appears or goes, or when an `Include` starts matching another file.
    var fingerprint: String {
        var text = "fetch-ssh-config-v1\n"
        for record in records {
            if record.exists {
                text += "\(record.path)\u{0}\(record.size)\u{0}\(record.modifiedSeconds).\(record.modifiedNanoseconds)"
                text += "\u{0}\(record.sha256)\n"
            } else {
                text += "\(record.path)\u{0}missing\n"
            }
        }
        return "v1-" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads `~/.ssh/config` with its `Include`s, and the system file `/etc/ssh/ssh_config` with its own (`ssh -G` reads both),
/// the way ssh does: keywords case-insensitive, `keyword=value`, single and double quotes, `#` comments, `Include` with
/// several arguments, `~` and globs (in lexical order), relative paths against `~/.ssh` or the system folder, nesting up
/// to 16 levels. Bounded: at most 64 files of at most 1 MB each. Every file is read as `TrustedConfigFile` reads it: a
/// link is refused (root's own link in a root-only folder excepted), and it must be a regular file owned by you or
/// root, not writable by group or others. Every `Include` is expanded by `CheckedGlob` under the network check before
/// any lookup: one that reaches a refused root (`/net`, `/Volumes`, an automount point, …) is a file that could not be
/// read.
struct SSHConfigReader {
    /// `~/.ssh/config`.
    var userConfig: URL
    /// `/etc/ssh/ssh_config`, or nil (tests, where `ssh -G -F` reads no system file either).
    var systemConfig: URL?
    /// The user's home folder, for `~` and for relative includes (`~/.ssh`).
    var home: String
    /// Whose files are trusted besides root's.
    var owner: uid_t = getuid()
    /// The network check for every `Include` (the mount table read at most once a second; tests pass their own).
    var pathGuard: NetworkPathGuard = .recent()

    static let maxFiles = 64
    static let maxDepth = 16
    static let maxFileBytes = 1 << 20

    func read() -> SSHConfigReading {
        var reading = SSHConfigReading()
        readFile(userConfig.path, isUserFile: true, depth: 0, into: &reading)
        if reading.problem == nil, let system = systemConfig {
            readFile(system.path, isUserFile: false, depth: 0, into: &reading)
        }
        return reading
    }

    // MARK: Files

    private func readFile(_ path: String, isUserFile: Bool, depth: Int, into reading: inout SSHConfigReading) {
        guard reading.problem == nil else { return }
        guard depth <= Self.maxDepth else { reading.problem = .tooDeep; return }
        guard reading.records.count < Self.maxFiles else { reading.problem = .tooManyFiles; return }
        // An included file is checked against the network roots too (the two configuration files themselves are not).
        switch Self.load(path, owner: owner, guard: depth > 0 ? pathGuard : nil) {
        case .missing:
            reading.records.append(SSHConfigFileRecord(path: path, exists: false))
        case .failed(let problem):
            reading.problem = problem
        case .loaded(let record, let data):
            reading.records.append(record)
            // Lines end at LF bytes only, as ssh's getline sees them (a CR is whitespace to ssh).
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
                guard reading.problem == nil else { return }
                parse(String(decoding: line, as: UTF8.self), isUserFile: isUserFile, depth: depth, into: &reading)
            }
        }
    }

    private enum Loaded {
        case missing
        case failed(SSHConfigReading.Problem)
        case loaded(SSHConfigFileRecord, Data)
    }

    /// `TrustedConfigFile`'s read with this reader's size limit: a missing file is recorded, any refusal is a problem.
    private static func load(_ path: String, owner: uid_t, guard pathGuard: NetworkPathGuard?) -> Loaded {
        switch TrustedConfigFile.read(path, owner: owner, maxBytes: maxFileBytes, guard: pathGuard) {
        case .failure(.missing): return .missing
        case .failure(.link): return .failed(.link)
        case .failure(.notAFile): return .failed(.notAFile)
        case .failure(.owner): return .failed(.owner)
        case .failure(.writableByOthers): return .failed(.writable)
        case .failure(.tooLarge): return .failed(.tooLarge)
        case .failure(.unreadable): return .failed(.unreadable)
        case .success(let contents):
            let hash = SHA256.hash(data: contents.data).map { String(format: "%02x", $0) }.joined()
            let record = SSHConfigFileRecord(path: path, exists: true, size: Int64(contents.data.count),
                                             modifiedSeconds: contents.modifiedSeconds,
                                             modifiedNanoseconds: contents.modifiedNanoseconds, sha256: hash)
            return .loaded(record, contents.data)
        }
    }

    // MARK: Lines

    private func parse(_ line: String, isUserFile: Bool, depth: Int, into reading: inout SSHConfigReading) {
        guard let (keyword, rest) = Self.keyword(of: line) else { return }
        switch keyword {
        case "match":
            reading.hasMatch = true
        case "host" where isUserFile:
            guard let tokens = Self.arguments(rest) else { reading.problem = .badQuotes; return }
            reading.hostTokens.formUnion(tokens)
        case "include":
            guard let tokens = Self.arguments(rest) else { reading.problem = .badQuotes; return }
            for token in tokens {
                guard reading.problem == nil else { return }
                include(token, isUserFile: isUserFile, depth: depth, into: &reading)
            }
        default:
            break
        }
    }

    private func include(_ token: String, isUserFile: Bool, depth: Int, into reading: inout SSHConfigReading) {
        // Tokens (`%d`) and variables (`${HOME}`) would need ssh to expand them; `~user` likewise. Refuse rather than
        // guess which file ssh would read.
        guard !token.isEmpty, !token.contains("%"), !token.contains("$") else { reading.problem = .unsupportedInclude; return }
        var pattern = token
        if pattern == "~" || pattern.hasPrefix("~/") {
            guard isUserFile else { reading.problem = .unsupportedInclude; return }   // ssh refuses `~` in system files
            pattern = home + pattern.dropFirst()
        } else if pattern.hasPrefix("~") {
            reading.problem = .unsupportedInclude
            return
        } else if !pattern.hasPrefix("/") {
            let base = isUserFile ? home + "/.ssh" : (systemConfig?.deletingLastPathComponent().path ?? "/etc/ssh")
            pattern = base + "/" + pattern
        }
        // glob under the network check: a pattern that reaches a refused root was never looked up, and counts as a file
        // that could not be read, as a glob error does.
        guard case .matches(let matches) = CheckedGlob.expand(pattern, guard: pathGuard) else {
            reading.problem = .unreadable
            return
        }
        for path in matches {
            guard reading.problem == nil else { return }
            readFile(path, isUserFile: isUserFile, depth: depth + 1, into: &reading)
        }
    }

    // MARK: Tokens (ssh's readconf.c and argv_split)

    // Scalars, not Characters: ssh splits bytes, so a combining mark after a space must not glue the space to a word.
    private static let lineSpace: Set<Unicode.Scalar> = [" ", "\t", "\r"]
    private static let trailingSpace: Set<Unicode.Scalar> = [" ", "\t", "\r", "\n", "\u{0C}"]

    /// The keyword (ASCII-lowercased, as ssh's `lowercase`) and the rest of the line after it (one `=` and the
    /// whitespace around it skipped); nil for blank lines and comments.
    static func keyword(of line: String) -> (String, String)? {
        var scalars = Array(line.unicodeScalars)
        while let last = scalars.last, trailingSpace.contains(last) { scalars.removeLast() }
        var index = 0
        while index < scalars.count, lineSpace.contains(scalars[index]) { index += 1 }
        guard index < scalars.count, scalars[index] != "#" else { return nil }
        let start = index
        while index < scalars.count, !lineSpace.contains(scalars[index]), scalars[index] != "=" { index += 1 }
        let keyword = String(String.UnicodeScalarView(scalars[start..<index].map(asciiLowercased)))
        while index < scalars.count, lineSpace.contains(scalars[index]) { index += 1 }
        if index < scalars.count, scalars[index] == "=" {
            index += 1
            while index < scalars.count, lineSpace.contains(scalars[index]) { index += 1 }
        }
        return keyword.isEmpty ? nil : (keyword, String(String.UnicodeScalarView(scalars[index...])))
    }

    /// Splits arguments like ssh's `argv_split`: spaces and tabs separate, single and double quotes group, a backslash
    /// escapes a quote, a backslash or (outside quotes) a space, and `#` at the start of a token ends the line. Nil for
    /// an unclosed quote (ssh rejects the file).
    static func arguments(_ text: String) -> [String]? {
        let scalars = Array(text.unicodeScalars)
        var tokens: [String] = []
        var index = 0
        while index < scalars.count {
            if scalars[index] == " " || scalars[index] == "\t" { index += 1; continue }
            if scalars[index] == "#" { break }
            var token = String.UnicodeScalarView()
            var quote: Unicode.Scalar?
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\\", index + 1 < scalars.count,
                   ["'", "\"", "\\"].contains(scalars[index + 1]) || (quote == nil && scalars[index + 1] == " ") {
                    token.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if quote == nil, scalar == " " || scalar == "\t" { break }
                if quote == nil, scalar == "\"" || scalar == "'" {
                    quote = scalar
                } else if let open = quote, scalar == open {
                    quote = nil
                } else {
                    token.append(scalar)
                }
                index += 1
            }
            if quote != nil { return nil }
            tokens.append(String(token))
        }
        return tokens
    }

    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        (0x41...0x5A).contains(scalar.value) ? Unicode.Scalar(scalar.value + 0x20) ?? scalar : scalar
    }
}
