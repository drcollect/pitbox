import Darwin
import Foundation

/// A file's identity as `fstat` reported it through the open descriptor.
struct FileIdentity: Equatable, Hashable, Sendable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    /// Modification time, seconds since 1970.
    var modified: TimeInterval

    init(device: UInt64, inode: UInt64, size: Int64, modified: TimeInterval) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
    }

    init(_ info: stat) {
        device = UInt64(UInt32(bitPattern: info.st_dev))
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
    }

    /// The same file (device and inode), whatever its size now.
    func isSameFile(as other: FileIdentity) -> Bool { device == other.device && inode == other.inode }

    var modifiedDate: Date { Date(timeIntervalSince1970: modified) }
}

/// Why a careful read refused or failed. `label` is safe to log (no path).
enum CarefulReadFailure: Error, Equatable, Sendable {
    case missing, badPath, link, notRegular, notDirectory, notOwned, tooLarge, unreadable

    var label: String {
        switch self {
        case .missing: return "missing"
        case .badPath: return "bad-path"
        case .link: return "link"
        case .notRegular: return "not-regular"
        case .notDirectory: return "not-directory"
        case .notOwned: return "other-owner"
        case .tooLarge: return "too-large"
        case .unreadable: return "unreadable"
        }
    }
}

/// A path below a configured root, built only from checked names.
/// The root is configuration (it may itself be reached through a link, such as `/var` → `/private/var`); every name
/// below it is a single checked component that is never followed when it is a link.
struct CarefulPath: Equatable, Hashable, Sendable {
    let root: String
    let components: [String]

    /// Nil when the root is not absolute or a component is not a plain name.
    init?(root: String, components: [String] = []) {
        guard root.hasPrefix("/"), !root.contains("\0"), components.allSatisfy(CarefulFiles.isSafeName) else { return nil }
        self.root = root
        self.components = components
    }

    /// The path one name further down, or nil when `name` is not a plain name.
    func appending(_ name: String) -> CarefulPath? { CarefulPath(root: root, components: components + [name]) }

    /// The folder holding this path; nil for the root itself.
    var parent: CarefulPath? {
        guard !components.isEmpty else { return nil }
        return CarefulPath(root: root, components: Array(components.dropLast()))
    }

    var name: String? { components.last }

    /// The path as one string, for FSEvents only. Never logged.
    var absolutePath: String {
        components.isEmpty ? root : (root.hasSuffix("/") ? root : root + "/") + components.joined(separator: "/")
    }
}

/// One entry of a folder listing.
struct DirectoryEntry: Equatable, Sendable {
    enum Kind: Sendable { case directory, file, link, other }
    var name: String
    var kind: Kind
}

/// Careful reading of Claude's files: folders and files are opened one checked name at a time with
/// `openat` and `O_NOFOLLOW`, so no link below a root is ever followed; files are opened with `O_NONBLOCK` (a FIFO is never
/// waited on) and checked through the descriptor (`fstat`): a regular file owned by the expected user, within its size
/// limit, before a byte is parsed.
enum CarefulFiles {
    /// A single path component: not empty, at most 255 bytes, no `/` or NUL, not `.` or `..`.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255 else { return false }
        return !name.utf8.contains(0x2F) && !name.utf8.contains(0)
    }

    /// Opens the folder `path` names: the root as configured, each component below it without following a link and
    /// owned by `owner`. The caller closes the descriptor.
    static func openDirectory(_ path: CarefulPath, owner: uid_t) -> Result<Int32, CarefulReadFailure> {
        var fd = open(path.root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(failure(errno)) }
        for name in path.components {
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else { return .failure(failure(code)) }
            var info = stat()
            guard fstat(next, &info) == 0 else {
                close(next)
                return .failure(.unreadable)
            }
            guard info.st_uid == owner else {
                close(next)
                return .failure(.notOwned)
            }
            fd = next
        }
        return .success(fd)
    }

    /// Opens the regular file `path` names and calls `body` with its descriptor and identity. Refused: a link (never
    /// followed), anything but a regular file (a FIFO is opened without waiting and refused), a file of another owner.
    static func withFile<T>(_ path: CarefulPath, owner: uid_t, _ body: (Int32, FileIdentity) -> T) -> Result<T, CarefulReadFailure> {
        guard let name = path.name, let folder = path.parent else { return .failure(.badPath) }
        let dirfd: Int32
        switch openDirectory(folder, owner: owner) {
        case .failure(let failure): return .failure(failure)
        case .success(let fd): dirfd = fd
        }
        let fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let code = errno
        close(dirfd)
        guard fd >= 0 else { return .failure(failure(code)) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegular) }
        guard info.st_uid == owner else { return .failure(.notOwned) }
        return .success(body(fd, FileIdentity(info)))
    }

    /// The whole file, refused before reading when it is larger than `maxBytes` (and when it grew past it meanwhile).
    static func read(_ path: CarefulPath, owner: uid_t, maxBytes: Int) -> Result<(Data, FileIdentity), CarefulReadFailure> {
        let outcome = withFile(path, owner: owner) { fd, identity -> Result<(Data, FileIdentity), CarefulReadFailure> in
            guard identity.size <= Int64(maxBytes) else { return .failure(.tooLarge) }
            guard let bytes = readToEnd(fd: fd, limit: maxBytes) else { return .failure(.unreadable) }
            guard bytes.count <= maxBytes else { return .failure(.tooLarge) }
            return .success((Data(bytes), identity))
        }
        switch outcome {
        case .failure(let failure): return .failure(failure)
        case .success(let inner): return inner
        }
    }

    /// Like `read`, but returns no data (only the identity) when the file still has the identity `known` (same device,
    /// inode, size and modification time), so an unchanged file is not read or parsed again.
    static func readIfChanged(_ path: CarefulPath, owner: uid_t, maxBytes: Int,
                              known: FileIdentity?) -> Result<(Data?, FileIdentity), CarefulReadFailure> {
        let outcome = withFile(path, owner: owner) { fd, identity -> Result<(Data?, FileIdentity), CarefulReadFailure> in
            if let known, known == identity { return .success((nil, identity)) }
            guard identity.size <= Int64(maxBytes) else { return .failure(.tooLarge) }
            guard let bytes = readToEnd(fd: fd, limit: maxBytes) else { return .failure(.unreadable) }
            guard bytes.count <= maxBytes else { return .failure(.tooLarge) }
            return .success((Data(bytes), identity))
        }
        switch outcome {
        case .failure(let failure): return .failure(failure)
        case .success(let inner): return inner
        }
    }

    /// The identity of the regular file `path` names, without reading it.
    static func identity(_ path: CarefulPath, owner: uid_t) -> Result<FileIdentity, CarefulReadFailure> {
        withFile(path, owner: owner) { _, identity in identity }
    }

    /// The entries of the folder `path` names (at most `limit`), without following links ("." and ".." left out).
    static func list(_ path: CarefulPath, owner: uid_t, limit: Int) -> Result<[DirectoryEntry], CarefulReadFailure> {
        let fd: Int32
        switch openDirectory(path, owner: owner) {
        case .failure(let failure): return .failure(failure)
        case .success(let opened): fd = opened
        }
        guard let dir = fdopendir(fd) else {
            close(fd)
            return .failure(.unreadable)
        }
        defer { closedir(dir) }
        var entries: [DirectoryEntry] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(length), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var kind: DirectoryEntry.Kind
            switch Int32(entry.pointee.d_type) {
            case DT_DIR: kind = .directory
            case DT_REG: kind = .file
            case DT_LNK: kind = .link
            default: kind = .other
            }
            if Int32(entry.pointee.d_type) == DT_UNKNOWN {
                var info = stat()
                if fstatat(dirfd(dir), name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    switch info.st_mode & S_IFMT {
                    case S_IFDIR: kind = .directory
                    case S_IFREG: kind = .file
                    case S_IFLNK: kind = .link
                    default: kind = .other
                    }
                }
            }
            entries.append(DirectoryEntry(name: name, kind: kind))
            if entries.count >= limit { break }
        }
        return .success(entries)
    }

    /// `count` bytes from `offset` (fewer at the end of the file); nil on a read error.
    static func readRange(fd: Int32, from offset: Int64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var total = 0
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while total < count {
                let n = pread(fd, base + total, count - total, off_t(offset) + off_t(total))
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { break }
                total += n
            }
            return true
        }
        guard ok else { return nil }
        if total < count { buffer.removeLast(count - total) }
        return buffer
    }

    /// Whether `path` is an existing folder on this Mac (links followed: a working folder reached through a link is
    /// still a folder here). Absolute paths only.
    static func isExistingFolder(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: Internals

    /// Reads from the start to the end of the file, at most `limit + 1` bytes (so growth past the limit is seen).
    private static func readToEnd(fd: Int32, limit: Int) -> [UInt8]? {
        var out: [UInt8] = []
        let chunk = 64 * 1024
        var offset: Int64 = 0
        while out.count <= limit {
            guard let bytes = readRange(fd: fd, from: offset, count: min(chunk, limit + 1 - out.count)) else { return nil }
            if bytes.isEmpty { break }
            out.append(contentsOf: bytes)
            offset += Int64(bytes.count)
        }
        return out
    }

    private static func failure(_ code: Int32) -> CarefulReadFailure {
        switch code {
        case ENOENT: return .missing
        case ELOOP, EMLINK: return .link
        case ENOTDIR: return .notDirectory
        case ENAMETOOLONG: return .badPath
        default: return .unreadable
        }
    }
}
