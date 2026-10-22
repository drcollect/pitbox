import Darwin
import Foundation

/// Which private folders announced by a host (`hello.private`) the guest accepts (docs/DOCK_PROTOCOL.md §5.3): only a
/// specific app-private folder. Its canonical path (`realpath(3)` of the part that exists, links and `..`
/// resolved there; a `..` after it is refused) must lie at least 3 components below the user's home folder
/// (`~/Library/Application Support/<App>`), or at least 1 below `/private/tmp` (`/private/tmp/<app>-runner-<uid>`). Never
/// `/`, the home folder or one of its ancestors, the system's top folders, `~/Library` or
/// `~/Library/Application Support`, also when a link or `..` leads there. A refused entry is dropped and counted; the
/// console's sandbox memory checks the same rule again.
struct DockFolderRule: Sendable {
    /// The canonical home folder.
    let home: String

    /// Folders never accepted, before canonicalisation (each is also refused in its canonical spelling).
    static let systemFolders = ["/", "/Users", "/System", "/Library", "/Applications", "/private", "/var", "/tmp",
                                "/private/tmp", "/private/var", "/Volumes", "/opt", "/usr", "/bin", "/sbin", "/etc",
                                "/private/etc", "/dev", "/cores", "/Network", "/System/Volumes", "/System/Volumes/Data"]

    /// The rule for `home` (default: this user's home folder).
    init(home: String = NSHomeDirectory()) {
        self.home = Self.canonicalPath(home) ?? home
    }

    enum Verdict: Equatable {
        /// Accepted, in canonical form (the guest passes this spelling on).
        case accepted(String)
        /// Refused; the label goes to the log (never the entry).
        case refused(String)
    }

    func check(_ raw: String) -> Verdict {
        guard raw.hasPrefix("/") else { return .refused("not absolute") }
        guard let canonical = Self.canonicalPath(raw) else { return .refused("dot-dot") }
        if broad.contains(canonical) || Self.isInside(home, folder: canonical) { return .refused("too broad") }
        if Self.isInside(canonical, folder: home), Self.depth(of: canonical, below: home) >= 3 { return .accepted(canonical) }
        if Self.isInside(canonical, folder: "/private/tmp"), Self.depth(of: canonical, below: "/private/tmp") >= 1 {
            return .accepted(canonical)
        }
        return .refused("too broad")
    }

    /// The accepted entries of `entries` (canonical, each once) and how many were refused.
    func filter(_ entries: [String]) -> (kept: [String], refused: Int) {
        var kept: [String] = []
        var refused = 0
        for entry in entries {
            switch check(entry) {
            case .accepted(let canonical): if !kept.contains(canonical) { kept.append(canonical) }
            case .refused: refused += 1
            }
        }
        return (kept, refused)
    }

    private var broad: Set<String> {
        var set = Set(Self.systemFolders)
        for folder in Self.systemFolders + [home + "/Library", home + "/Library/Application Support"] {
            set.insert(folder)
            if let canonical = Self.canonicalPath(folder) { set.insert(canonical) }
        }
        return set
    }

    /// Components of `path` below `folder` (`path` inside `folder`).
    static func depth(of path: String, below folder: String) -> Int {
        let base = folder == "/" ? 0 : folder.split(separator: "/").count
        return path.split(separator: "/").count - base
    }

    /// Whether `folder` is `path` itself or one of its parents (both canonical).
    static func isInside(_ path: String, folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }

    /// `realpath(3)` of `path`, or for a path that does not exist (yet) the longest existing prefix resolved and the rest
    /// appended (`.` dropped); nil when the rest holds `..` (after a prefix that may be a link it cannot be resolved
    /// without the file system). The same rule as the console's sandbox.
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
}
