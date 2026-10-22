import Darwin
import Foundation
import PitboxKit

/// The device and inode a folder descriptor was bound to (Downloads is bound once).
struct FolderIdentity: Equatable, Sendable {
    var device: Int32
    var inode: UInt64
}

/// The `com.apple.quarantine` value Fetch file writes: flags, the time in hex, the agent, a UUID.
enum FetchQuarantine {
    static let attributeName = "com.apple.quarantine"
    static let agentName = AppIdentity.displayName
    /// "Downloaded file" plus the bit browsers set; a value measured to write and read back through a descriptor.
    static let flags = "0081"

    static func value(at date: Date, id: UUID) -> String {
        let seconds = UInt32(clamping: Int(date.timeIntervalSince1970.rounded(.down)))
        return "\(flags);\(String(format: "%08x", seconds));\(agentName);\(id.uuidString)"
    }

    /// Writes `value` through `fd` and reads it back; true only when the stored bytes are exactly `value`.
    static func apply(_ value: String, to fd: Int32, io: FetchQuarantineIO) -> Bool {
        let bytes = Array(value.utf8)
        guard io.set(fd, bytes) == 0, let stored = io.get(fd) else { return false }
        return stored == bytes
    }
}

/// Descriptor-based file work for Fetch file. Downloads and the staging folder are opened once and every later step
/// works relative to those descriptors, never by path; no step follows a link.
enum FetchFolders {
    /// Prefix of the private staging folders inside `Paths.cachesDir/fetch`.
    static let stagingPrefix = "fetch-"

    /// Opens a folder for descriptor-relative work with `O_DIRECTORY | O_NOFOLLOW`, so a link in its place is refused.
    /// -1 when it is missing, not a folder or a link.
    static func openFolder(_ path: String) -> Int32 {
        open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    static func identity(of fd: Int32) -> FolderIdentity? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return FolderIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// What `path` leads to now, without following a link in its last part.
    static func identity(atPath path: String) -> (identity: FolderIdentity, isFolder: Bool)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (FolderIdentity(device: info.st_dev, inode: info.st_ino), (info.st_mode & S_IFMT) == S_IFDIR)
    }

    /// Free bytes for an unprivileged writer on the descriptor's volume.
    @Sendable static func freeBytes(_ fd: Int32) -> Int64? {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return nil }
        let (bytes, overflow) = Int64(clamping: info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize))
        return overflow ? Int64.max : bytes
    }

    /// Opens the staging parent (`Paths.cachesDir/fetch`), creating it (0700) when missing. It must be a real folder of this user;
    /// its mode is set to 0700. -1 on failure.
    static func openStagingParent(_ path: String) -> Int32 {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = openFolder(path)
        guard fd >= 0 else { return -1 }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            return -1
        }
        if info.st_mode & 0o777 != 0o700, fchmod(fd, 0o700) != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    /// A new private staging folder (0700, random name) inside the parent, opened. Nil on failure.
    static func makeStagingFolder(in parent: Int32) -> (name: String, fd: Int32)? {
        for _ in 0..<4 {
            var generator = SystemRandomNumberGenerator()
            let name = stagingPrefix + (0..<4).map { _ in String(format: "%08x", UInt32.random(in: 0...UInt32.max, using: &generator)) }.joined()
            if mkdirat(parent, name, 0o700) != 0 {
                if errno == EEXIST { continue }
                return nil
            }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { removeTree(named: name, in: parent); return nil }
            _ = fchmod(fd, 0o700)
            return (name, fd)
        }
        return nil
    }

    /// Removes `name` inside `parent` without following links: a file or link is unlinked, a folder is emptied
    /// (at most 8 levels deep) and removed.
    static func removeTree(named name: String, in parent: Int32, depth: Int = 0) {
        if unlinkat(parent, name, 0) == 0 || errno == ENOENT { return }
        guard depth < 8 else { return }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fchmod(fd, 0o700)   // a folder made read-only could not be emptied otherwise
        for entry in entries(of: fd) { removeTree(named: entry, in: fd, depth: depth + 1) }
        close(fd)
        _ = unlinkat(parent, name, AT_REMOVEDIR)
    }

    /// Removes staging folders older than `age` (left behind when Pitbox quit or crashed mid-fetch). A running
    /// fetch's folder is younger than its 10-minute limit, so it is never touched.
    static func sweepStale(in parent: Int32, olderThan age: TimeInterval, now: Date) {
        for name in entries(of: parent).prefix(256) where name.hasPrefix(stagingPrefix) && name.count == stagingPrefix.count + 32 {
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) > age { removeTree(named: name, in: parent) }
        }
    }

    /// The names in a folder (not `.` and `..`), read through a duplicate of its descriptor.
    static func entries(of folder: Int32) -> [String] {
        let copy = dup(folder)
        guard copy >= 0 else { return [] }
        guard let directory = fdopendir(copy) else { close(copy); return [] }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// The size of what scp has staged so far, nil while there is nothing (the connection or the login is not done).
    static func stagedSize(in folder: Int32, name: String) -> Int64? {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return info.st_size
    }

    /// The first candidate that is free in the folder right now (nothing of that name, not even a link): the preview
    /// the sheet shows. The exclusive rename decides at the end.
    static func firstFreeName(in folder: Int32, candidates: [String]) -> String? {
        for candidate in candidates {
            var info = stat()
            if fstatat(folder, candidate, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return candidate }
        }
        return nil
    }

    /// Opens the staged file with `O_NOFOLLOW` (and without blocking, should it be a FIFO). It must be a regular file of
    /// this user with a single link: not a folder, a link, a FIFO or a bundle.
    static func openStagedFile(in folder: Int32, name: String) -> Result<(fd: Int32, size: Int64), FetchFailure> {
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ENOENT ? .noSuchFile : .notPlainFile) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else {
            close(fd)
            return .failure(.notPlainFile)
        }
        return .success((fd, info.st_size))
    }

    /// Moves the staged file into Downloads with `renameatx_np(…, RENAME_EXCL)` between the two descriptors, which
    /// never replaces anything; a taken name moves on to the next candidate (`name 2.ext` … `name 99.ext`).
    static func moveExclusive(name: String, from staging: Int32, to downloads: Int32,
                              candidates: [String]) -> Result<String, FetchFailure> {
        for candidate in candidates {
            if renameatx_np(staging, name, downloads, candidate, UInt32(RENAME_EXCL)) == 0 { return .success(candidate) }
            if errno == EEXIST { continue }
            return .failure(.moveFailed)
        }
        return .failure(.noFreeName)
    }
}
