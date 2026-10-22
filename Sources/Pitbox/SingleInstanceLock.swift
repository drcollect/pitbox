import Darwin
import Foundation
import PitboxKit

/// One Pitbox per user (docs/DOCK_PROTOCOL.md §2.1): an exclusive `flock` on `<appSupport>/pitbox.lock`, taken first
/// thing at launch and held for the life of the process (the descriptor stays open; the kernel drops the lock when the
/// process ends, a crash included, so a stale file never blocks the next launch). A second Pitbox finds it taken and
/// quits. The dock socket binds right after the lock (`DockWiring.bind`), so only the instance holding it ever touches
/// `dock.sock`.
final class SingleInstanceLock {
    /// The lock file's name in the app-support folder.
    static let fileName = "pitbox.lock"

    /// Why the lock was not taken. `label` is safe to log.
    enum Failure: Error, Equatable {
        /// Another process holds it: another Pitbox runs.
        case taken
        /// The file could not be opened (a link, not a regular file, another owner, or an error number).
        case unusable(String)

        var label: String {
            switch self {
            case .taken: return "taken"
            case .unusable(let why): return "unusable (\(why))"
            }
        }
    }

    /// The lock file.
    let url: URL
    private var fd: Int32

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit { release() }

    /// Opens (or creates, 0600) the lock file in `folder` without following a link and takes the lock without waiting.
    static func acquire(in folder: URL = Paths.appSupport) -> Result<SingleInstanceLock, Failure> {
        let url = folder.appendingPathComponent(fileName)
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failure(.unusable(errno == ELOOP ? "link" : "errno \(errno)")) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else {
            close(fd)
            return .failure(.unusable("not a file of this user"))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(fd)
            return .failure(error == EWOULDBLOCK ? .taken : .unusable("errno \(error)"))
        }
        return .success(SingleInstanceLock(url: url, fd: fd))
    }

    /// Lets go of the lock (tests; the app keeps it until it exits).
    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// True while this object holds the lock.
    var isHeld: Bool { fd >= 0 }
}
