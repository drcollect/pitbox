import Darwin
import Foundation
import PitboxKit

/// Finds the command helper (`pitbox-command-helper`) the app bundle carries next to its main executable, and checks
/// it before every spawn: a regular file (not a link), owned by this user or root, executable, not writable by group
/// or others, in a folder that is not writable by group or others either. Never looked up anywhere else (the repo,
/// PATH, the working directory): a missing or doubtful helper means command tabs fail closed.
enum CommandHelperLocator {
    static let name = "pitbox-command-helper"

    enum Problem: Error, Equatable {
        case missing
        case doubtful(String)

        var words: String {
            switch self {
            case .missing: return "\(AppIdentity.displayName) can't start commands as their own app: its command helper is missing"
            case .doubtful: return "\(AppIdentity.displayName) can't start commands as their own app: its command helper failed its check"
            }
        }
    }

    /// The helper beside `mainExecutable` (normally `Bundle.main.executableURL`), checked.
    static func bundled(mainExecutable: URL? = Bundle.main.executableURL) -> Result<URL, Problem> {
        guard let mainExecutable else { return .failure(.missing) }
        return check(mainExecutable.deletingLastPathComponent().appendingPathComponent(name))
    }

    /// Checks one candidate path (tests pass the copy SwiftPM built).
    static func check(_ url: URL, uid: uid_t = getuid()) -> Result<URL, Problem> {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .failure(.missing) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.doubtful("not a regular file")) }
        guard info.st_uid == uid || info.st_uid == 0 else { return .failure(.doubtful("owned by another user")) }
        guard info.st_mode & 0o022 == 0 else { return .failure(.doubtful("writable by group or others")) }
        guard info.st_mode & 0o100 != 0 else { return .failure(.doubtful("not executable")) }
        var folder = stat()
        guard stat(url.deletingLastPathComponent().path, &folder) == 0,
              folder.st_uid == uid || folder.st_uid == 0, folder.st_mode & 0o022 == 0 else {
            return .failure(.doubtful("its folder is writable by others"))
        }
        return .success(url)
    }
}
