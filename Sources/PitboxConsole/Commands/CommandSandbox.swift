import Darwin
import Foundation
import PitboxKit

/// The Seatbelt profile command and Type tabs run under (docs/THREAT_MODEL.md, "The run path as built"): everything is
/// allowed except the files and sockets listed below. The user's other files, the Keychain, the ssh-agent (its socket
/// lives under `/private/tmp`) and the network stay reachable, so their Keychain pattern and `scp` work.
///
/// What is denied, all on canonical paths (Seatbelt matches resolved paths, so `/tmp/x` must be written
/// `/private/tmp/x`; `realpath(3)`, never Foundation's `resolvingSymlinksInPath()`, which strips `/private`):
/// - file reads and writes, and Unix-socket connects, under Pitbox's own folder (`Paths.appSupport`, which holds
///   `dock.sock`), under every private folder a verified dock host announced (remembered by `SandboxMemory`), and under
///   the settings' `sandboxDenyFolders`;
/// - Unix-socket connects anywhere under `~/Library/Application Support/` (other apps' control sockets) and under the
///   socket folders a host announced, except under the settings' `sandboxAllowSocketFolders` (a file-only escape
///   hatch), which never re-opens Pitbox's own folder or any denied or announced folder;
/// - renaming, moving or deleting (`file-write-unlink`) a socket or a folder under `~/Library/Application Support/` or
///   under an announced socket folder (else a command could move another app's socket, or its folder, out of the tree
///   and connect to it there), and renaming any parent folder (except `/`) of a protected folder (else `mv
///   "~/Library/Application Support" …` would put Pitbox's folder, `dock.sock` and the announced folders under a path
///   no rule names: Seatbelt matches the path a file has at the moment of access). Regular files under the tree stay
///   readable, writable, movable and deletable; folders can still be created there, not removed.
///
/// Measured on macOS 26.5.1: the file rule alone does NOT stop `connect()` to a socket in the folder (a sandboxed shell
/// connected); the `network-outbound` rule does (EPERM). SBPL lets the last matching rule win, so the profile is
/// written as: the broad socket deny, then the allows, then the specific denies again, then the rename rules (nothing
/// allows `file-write-unlink` after them).
public enum CommandSandbox {
    /// What the profile denies besides its fixed rules: built by the app from its settings and `SandboxMemory`, and
    /// read at every spawn (`ConsoleHost(settings:sandboxPolicy:keyboardRequester:)`). Entries are absolute paths (`~/`
    /// is the home folder). An entry that is not absolute, or holds a control character, a `"` or a `\`, is refused and
    /// a label logged; it never changes the fixed rules. Pitbox's own folder and the Application Support tree are not
    /// inputs: they are always denied.
    public struct Policy: Equatable, Sendable {
        /// Private folders of verified dock hosts (`hello.private.folders`, `SandboxMemory.folders`): files and sockets
        /// denied, never re-allowed.
        public var announcedFolders: [String]
        /// Socket folders of verified dock hosts (`hello.private.socketFolders`, `SandboxMemory.socketFolders`): socket
        /// connects denied, never re-allowed.
        public var announcedSocketFolders: [String]
        /// `sandboxDenyFolders` from the settings file: files and sockets denied, never re-allowed.
        public var denyFolders: [String]
        /// `sandboxAllowSocketFolders` from the settings file: socket connects allowed again under these folders. An
        /// entry that is the Application Support folder itself or one of its parents is refused (it would undo the
        /// whole socket rule).
        public var allowSocketFolders: [String]
        /// Pitbox's own folder (`Paths.appSupport`).
        let ownFolder: String
        /// The tree where every Unix-socket connect is denied: `~/Library/Application Support` (tests use a stand-in).
        let socketRoot: String
        /// The home folder `~/` stands for.
        let home: String

        /// A policy over Pitbox's own folder and the user's `~/Library/Application Support`, with the given extra
        /// folders.
        public init(announcedFolders: [String] = [], announcedSocketFolders: [String] = [], denyFolders: [String] = [],
                    allowSocketFolders: [String] = []) {
            self.init(ownFolder: Paths.appSupport.path, socketRoot: CommandSandbox.applicationSupportRoot.path,
                      home: FileManager.default.homeDirectoryForCurrentUser.path, announcedFolders: announcedFolders,
                      announcedSocketFolders: announcedSocketFolders, denyFolders: denyFolders,
                      allowSocketFolders: allowSocketFolders)
        }

        /// Every input given (tests: a stand-in own folder and Application Support tree).
        init(ownFolder: String, socketRoot: String, home: String, announcedFolders: [String] = [],
             announcedSocketFolders: [String] = [], denyFolders: [String] = [], allowSocketFolders: [String] = []) {
            self.ownFolder = ownFolder
            self.socketRoot = socketRoot
            self.home = home
            self.announcedFolders = announcedFolders
            self.announcedSocketFolders = announcedSocketFolders
            self.denyFolders = denyFolders
            self.allowSocketFolders = allowSocketFolders
        }

        /// The fixed rules only: Pitbox's own folder and the Application Support tree. What the console uses until the
        /// app passes its own policy.
        public static var standard: Policy { Policy() }
    }

    /// The user's `~/Library/Application Support` (never `PITBOX_APP_SUPPORT`).
    static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Which list a refused entry came from (log label).
    enum List: String, CommandLogLabel {
        case announced, announcedSockets = "announced-sockets", deny, allowSockets = "allow-sockets", own
        case socketRoot = "socket-root"
        var logLabel: String { rawValue }
    }

    /// Why an entry was refused (log label).
    enum Refusal: String, CommandLogLabel, Error, Equatable {
        case empty, notAbsolute = "not-absolute", controlCharacter = "control-character", quote, tooBroad = "too-broad"
        /// A `..` after the part of the path that exists: it cannot be resolved safely (the existing part may be a
        /// link).
        case dotDot = "dot-dot"
        var logLabel: String { rawValue }
    }

    /// The profile text for `policy`, or nil when Pitbox's own folder or the Application Support tree cannot be written
    /// into a profile safely: then nothing runs (the spawn fails closed).
    static func profile(_ policy: Policy) -> String? {
        guard let own = folder(policy.ownFolder, list: .own, home: policy.home),
              let root = folder(policy.socketRoot, list: .socketRoot, home: policy.home) else { return nil }
        let announced = policy.announcedFolders.compactMap { folder($0, list: .announced, home: policy.home) }
        let announcedSockets = policy.announcedSocketFolders.compactMap { folder($0, list: .announcedSockets, home: policy.home) }
        let denied = policy.denyFolders.compactMap { folder($0, list: .deny, home: policy.home) }
        let allowed = policy.allowSocketFolders.compactMap { folder($0, list: .allowSockets, home: policy.home) }.filter { entry in
            guard isInside(root, folder: entry) else { return true }
            CommandLog.terminal("sandbox entry refused", ["list": .label(List.allowSockets), "reason": .label(Refusal.tooBroad)])
            return false
        }
        let fileFolders = unique([own] + announced + denied)
        let socketFolders = unique(fileFolders + announcedSockets)
        var lines = ["(version 1)", "(allow default)"]
        lines += fileFolders.map { "(deny file-read* file-write* (subpath \(quoted($0))))" }
        lines.append("(deny network-outbound (remote unix-socket (subpath \(quoted(root)))))")
        lines += unique(allowed).map { "(allow network-outbound (remote unix-socket (subpath \(quoted($0)))))" }
        lines += socketFolders.map { "(deny network-outbound (remote unix-socket (subpath \(quoted($0)))))" }
        // No socket or folder under the tree, or under an announced socket folder, can be moved out (or deleted).
        lines += unique([root] + announcedSockets).map {
            "(deny file-write-unlink (require-all (subpath \(quoted($0))) (require-any (vnode-type SOCKET) (vnode-type DIRECTORY))))"
        }
        // No parent of a protected folder can be renamed (the protected folders themselves are covered above).
        let protected = [own] + announced + announcedSockets + denied + [root]
        lines += unique(protected.flatMap(ancestors)).map { "(deny file-write-unlink (literal \(quoted($0))))" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The parent folders of a canonical path, from the top, without `/`: `/a/b/c` gives `/a`, `/a/b`.
    static func ancestors(_ path: String) -> [String] {
        var result: [String] = []
        var current = ""
        for component in path.split(separator: "/").dropLast() {
            current += "/" + component
            result.append(current)
        }
        return result
    }

    /// The canonical form of one entry, or nil (logged) when it is refused.
    private static func folder(_ raw: String, list: List, home: String) -> String? {
        switch canonicalEntry(raw, home: home) {
        case .success(let path): return path
        case .failure(let refusal):
            CommandLog.terminal("sandbox entry refused", ["list": .label(list), "reason": .label(refusal)])
            return nil
        }
    }

    /// Checks one entry and resolves it: absolute after `~/` expansion, no control character, no `"` or `\` before or
    /// after `realpath(3)`.
    static func canonicalEntry(_ raw: String, home: String) -> Result<String, Refusal> {
        guard !raw.isEmpty else { return .failure(.empty) }
        if let refusal = unsafeCharacter(in: raw) { return .failure(refusal) }
        var expanded = raw
        if raw == "~" {
            expanded = home
        } else if raw.hasPrefix("~/") {
            expanded = home + "/" + raw.dropFirst(2)
        }
        guard expanded.hasPrefix("/") else { return .failure(.notAbsolute) }
        if let refusal = unsafeCharacter(in: expanded) { return .failure(refusal) }
        guard let canonical = canonicalPath(expanded) else { return .failure(.dotDot) }
        if let refusal = unsafeCharacter(in: canonical) { return .failure(refusal) }
        return .success(canonical)
    }

    private static func unsafeCharacter(in text: String) -> Refusal? {
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f { return .controlCharacter }
            if scalar == "\"" || scalar == "\\" { return .quote }
        }
        return nil
    }

    /// Whether `folder` is `path` itself or one of its parents (both canonical).
    static func isInside(_ path: String, folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }

    /// `paths`, each once, in order.
    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// `realpath(3)` of the absolute `path`. For a path that does not exist (yet): the longest existing prefix, exactly
    /// as written (`..` and links in it resolved by `realpath`, never lexically), and the rest appended, so the rule
    /// still covers the folder once it is created. Nil when the rest holds a `..`: after a prefix that may be a link,
    /// `..` cannot be resolved without the file system, and a lexical guess could name another folder.
    static func canonicalPath(_ path: String) -> String? {
        if let resolved = realpathString(path) { return resolved }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for count in stride(from: components.count - 1, through: 0, by: -1) {
            guard let resolved = realpathString("/" + components.prefix(count).joined(separator: "/")) else { continue }
            let rest = components.dropFirst(count).filter { $0 != "." }
            if rest.contains("..") { return nil }
            return ([resolved == "/" ? "" : resolved] + rest).joined(separator: "/")
        }
        return nil
    }

    private static func realpathString(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// An SBPL string literal (entries never hold `"` or `\`; escaped anyway).
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
