import Foundation
import PitboxKit

/// Where the console keeps its files. Everything lives under `Paths.appSupport` (private, 0700), where commands run from
/// the console cannot read or write (`CommandSandbox`).
struct TerminalPaths: Equatable {
    var directory: URL

    /// The tab list, written by the console itself in the terminal's mode: `console-state.json`. Tabs from a command
    /// sheet are never in it, and Pitbox's console (no plain shells) never writes it.
    var stateFile: URL { directory.appendingPathComponent("console-state.json") }

    static var live: TerminalPaths { TerminalPaths(directory: Paths.appSupport) }
}

/// Small helpers for the console's own files. They are private to the user; a file that is a symlink, belongs to someone
/// else, or is writable by group or others is not trusted and is never read as input (the tab list decides which
/// presets start again).
enum SecureFile {
    enum Trust: Equatable {
        case trusted
        case missing
        case untrusted(String)
    }

    /// Checks `url` with `lstat` (symlinks are not followed) and its parent folder.
    static func trust(of url: URL, uid: uid_t = getuid()) -> Trust {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            return errno == ENOENT ? .missing : .untrusted("cannot stat: \(String(cString: strerror(errno)))")
        }
        if (info.st_mode & S_IFMT) != S_IFREG { return .untrusted("not a regular file") }
        if info.st_uid != uid { return .untrusted("owned by another user") }
        if info.st_mode & 0o022 != 0 { return .untrusted("writable by group or others") }
        var dir = stat()
        if stat(url.deletingLastPathComponent().path, &dir) == 0 {
            if dir.st_uid != uid { return .untrusted("folder owned by another user") }
            if dir.st_mode & 0o022 != 0 { return .untrusted("folder writable by group or others") }
        }
        return .trusted
    }

    /// Reads a trusted file, or nil (with `Trust` explaining why in `reason`).
    static func read(_ url: URL, uid: uid_t = getuid()) -> (data: Data?, trust: Trust) {
        let trust = trust(of: url, uid: uid)
        guard trust == .trusted else { return (nil, trust) }
        guard let data = try? Data(contentsOf: url, options: [.uncached]) else { return (nil, .untrusted("unreadable")) }
        return (data, .trusted)
    }

    /// Writes `data` atomically with mode 0600: temp file created 0600, fsync, rename. Creates the folder (0700) if needed.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        var ok = true
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard let base = raw.baseAddress else { break }
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; ok = false; break }
                offset += n
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        if ok, rename(temp.path, url.path) == 0 { return true }
        unlink(temp.path)
        return false
    }
}
