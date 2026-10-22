import Foundation
import PitboxKit

/// The string rules for paths a session handed over or wrote (docs/THREAT_MODEL.md). Everything here works on strings
/// only: no filesystem call is made for a path before it passed these rules, so no candidate can make the app touch a
/// network mount. Paths are session
/// text: never logged.
enum ResultPaths {
    /// Longer paths (UTF-8 bytes) are refused (`PATH_MAX`).
    static let maxBytes = 1024

    /// Folders that reach the network through the automounter or belong to another volume: never allowed, not even
    /// when a session works in one of them. The one list the whole app uses (`NetworkPaths.roots`, PitboxKit).
    static let networkRoots = NetworkPaths.roots

    /// Why a path string was refused before any filesystem call.
    enum Refusal: Error, Equatable, Sendable {
        case empty, tooLong
        /// A NUL, control or other hidden character (B1).
        case hiddenCharacter
        /// Any character outside ASCII (B2 in a path: a homoglyph such as Cyrillic `р` cannot pass).
        case notASCII
        /// `~name/…`: another user's home folder.
        case otherUsersHome
        /// A relative path with no folder to take it from.
        case relative
    }

    /// `raw` as one absolute path without `.` or `..` parts and without repeated or trailing `/`, by string work only:
    /// `~` and `~/…` become `home`, a relative path is taken from `folder` (nil: refused). Refused: empty, longer than
    /// `maxBytes`, any character that is not printable ASCII (a NUL, a control character, B1 or B2), `~name`.
    static func normalize(_ raw: String, home: String, folder: String?) -> Result<String, Refusal> {
        guard !raw.isEmpty else { return .failure(.empty) }
        guard raw.utf8.count <= maxBytes else { return .failure(.tooLong) }
        if let refusal = characterRefusal(raw) { return .failure(refusal) }
        var absolute: String
        if raw == "~" {
            absolute = home
        } else if raw.hasPrefix("~/") {
            absolute = home + "/" + raw.dropFirst(2)
        } else if raw.hasPrefix("~") {
            return .failure(.otherUsersHome)
        } else if raw.hasPrefix("/") {
            absolute = raw
        } else if let folder, folder.hasPrefix("/") {
            absolute = folder + "/" + raw
        } else {
            return .failure(.relative)
        }
        absolute = lexical(absolute)
        guard absolute.utf8.count <= maxBytes else { return .failure(.tooLong) }
        if let refusal = characterRefusal(absolute) { return .failure(refusal) }
        return .success(absolute)
    }

    /// The first character rule `text` breaks: only printable ASCII (U+0020-U+007E) passes.
    static func characterRefusal(_ text: String) -> Refusal? {
        for scalar in text.unicodeScalars {
            guard scalar.isASCII else { return .notASCII }
            if scalar.value < 0x20 || scalar.value == 0x7F { return .hiddenCharacter }
        }
        return nil
    }

    /// An absolute path with `.` and `..` resolved and empty parts dropped (`/a/./b/../c//` is `/a/c`); `..` at the top
    /// stays at `/`. String work only.
    static func lexical(_ absolute: String) -> String {
        var parts: [Substring] = []
        for part in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The parts of an absolute path, top first (`/a/b` is `["a", "b"]`).
    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// The last part (the file name), nil for `/`.
    static func lastComponent(_ path: String) -> String? {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
    }

    /// `path` is `root` or lies below it (by whole parts: `/tmpx` is not inside `/tmp`). Both are lexical paths.
    static func isInside(_ path: String, _ root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }

    /// `path` is one of `networkRoots` or below one, or below a network or automount point of the mount table,
    /// compared as the Mac's volume compares names (`NetworkPathGuard.recent()`).
    static func isNetwork(_ path: String) -> Bool { NetworkPathGuard.recent().refuses(path) }

    /// The parts of `path` below `root` (empty when they are equal), nil when it is not inside.
    static func remainder(_ path: String, below root: String) -> [String]? {
        guard isInside(path, root) else { return nil }
        if root == "/" { return components(path) }
        return components(String(path.dropFirst(root.count)))
    }
}

/// The folders a session's files may lie in, each as written and as its real path: the session's `cwd` and its
/// git toplevel, the home folder, `$TMPDIR`, `/tmp` and `/private/tmp`. Built once per session by
/// `ResultPathRoots.make`, which calls the filesystem only for these folders, never for a candidate.
struct ResultPathRoots: Equatable, Sendable {
    /// One allowed folder.
    struct Root: Equatable, Sendable {
        /// As written, made lexical.
        var lexical: String
        /// Its real path (links resolved), nil when it could not be resolved.
        var real: String?

        /// `path` (lexical) is inside either form.
        func containsLexically(_ path: String) -> Bool {
            ResultPaths.isInside(path, lexical) || real.map { ResultPaths.isInside(path, $0) } == true
        }

        /// `path` (a real path) is inside the real form.
        func containsResolved(_ path: String) -> Bool { real.map { ResultPaths.isInside(path, $0) } == true }

        /// The parts below this root, by the form `resolved` asks for (the deeper match when both forms hold).
        func remainder(_ path: String, resolved: Bool) -> [String]? {
            let forms = resolved ? [real].compactMap { $0 } : [lexical, real].compactMap { $0 }
            return forms.compactMap { ResultPaths.remainder(path, below: $0) }.min { $0.count < $1.count }
        }
    }

    var home: Root
    /// `$TMPDIR`, `/tmp` and `/private/tmp`.
    var temporary: [Root]
    /// Local sessions only; nil for SSH and unknown places or a missing `cwd`.
    var cwd: Root?
    var toplevel: Root?
    /// The session works under a network path (or its `cwd` failed the string rules): nothing of it is checked on disk,
    /// and its files read "not checked: network path".
    var cwdIsNetwork: Bool

    /// Every root a file the session wrote may lie in: its folder and its repository.
    var writtenRoots: [Root] { [cwd, toplevel].compactMap { $0 } }

    /// Every root a file the session handed over may lie in: the home and temporary folders, and its own folders.
    var handedRoots: [Root] { [home] + temporary + writtenRoots }
}

/// The per-origin rules over the roots: a file the session handed over (`SendUserFile`) may lie anywhere in
/// the home or temporary folders (or its own folders), never in `~/Library` or below a folder whose name starts with
/// `.`; a file it wrote (Write, Edit) only inside its `cwd` or its git toplevel.
enum ResultPathRules {
    /// The lexical check, before any filesystem call: `path` is normalized (`ResultPaths.normalize`).
    static func allowsLexically(_ path: String, origin: CodeResult.Origin, roots: ResultPathRoots) -> Bool {
        allows(path, origin: origin, roots: roots, resolved: false)
    }

    /// The same rules on a real path, against the roots' real forms.
    static func allowsResolved(_ path: String, origin: CodeResult.Origin, roots: ResultPathRoots) -> Bool {
        allows(path, origin: origin, roots: roots, resolved: true)
    }

    private static func allows(_ path: String, origin: CodeResult.Origin, roots: ResultPathRoots, resolved: Bool) -> Bool {
        guard !roots.cwdIsNetwork, !ResultPaths.isNetwork(path), ResultPaths.characterRefusal(path) == nil else { return false }
        func inside(_ root: ResultPathRoots.Root) -> Bool {
            resolved ? root.containsResolved(path) : root.containsLexically(path)
        }
        switch origin {
        case .written:
            return roots.writtenRoots.contains(where: inside)
        case .handedOver:
            let matching = roots.handedRoots.filter(inside)
            guard !matching.isEmpty else { return false }
            // Never in ~/Library, by either form of the home folder, in any spelling: the volume ignores case, so
            // `~/LIBRARY` is the same folder.
            if inside(roots.home), let below = roots.home.remainder(path, resolved: resolved),
               let first = below.first, first.compare("Library", options: [.caseInsensitive]) == .orderedSame {
                return false
            }
            // Never below a dot-folder, counted from the deepest allowed root that holds the path.
            let below = matching.compactMap { $0.remainder(path, resolved: resolved) }.min { $0.count < $1.count } ?? []
            return !below.dropLast().contains { $0.hasPrefix(".") }
        default:
            return false
        }
    }
}
