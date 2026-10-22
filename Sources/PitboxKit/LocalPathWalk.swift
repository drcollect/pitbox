import Darwin
import Foundation

/// What `lstat` said about one path (a link is reported as a link, never followed).
public struct LocalPathStat: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case regular, directory, link, other }

    public var kind: Kind
    /// `st_dev` as the run path records it (`UInt32` bit pattern).
    public var device: UInt64
    public var inode: UInt64
    /// `st_uid`.
    public var owner: UInt32
    /// Group or others may write it (`S_IWGRP | S_IWOTH`).
    public var othersCanWrite: Bool

    public init(kind: Kind, device: UInt64, inode: UInt64, owner: UInt32 = 0, othersCanWrite: Bool = false) {
        self.kind = kind
        self.device = device
        self.inode = inode
        self.owner = owner
        self.othersCanWrite = othersCanWrite
    }

    public init(_ info: stat) {
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .link
        default: kind = .other
        }
        device = UInt64(UInt32(bitPattern: info.st_dev))
        inode = UInt64(info.st_ino)
        owner = info.st_uid
        othersCanWrite = info.st_mode & (S_IWGRP | S_IWOTH) != 0
    }
}

/// The answer of one `lstat`.
public enum LocalPathLookup: Equatable, Sendable {
    case found(LocalPathStat)
    /// `ENOENT` or `ENOTDIR`.
    case missing
    /// Any other `errno` (no permission, a name too long, a link on the way that appeared since, …).
    case failed(Int32)
}

/// The two calls a walk makes. The app uses `LiveLocalPathFileSystem`; tests pass a recording fake.
public protocol LocalPathFileSystem: Sendable {
    /// `lstat(2)` of an absolute path whose folders are all real folders.
    func lstat(_ path: String) -> LocalPathLookup
    /// The text of the link at `path`; nil when it is no link or cannot be read.
    func readlink(_ path: String) -> String?
}

/// This Mac's filesystem. The kernel itself refuses a link on the way (`AT_SYMLINK_NOFOLLOW_ANY`, `O_NOFOLLOW_ANY`):
/// the walk only asks about paths whose folders it resolved as real folders, so a folder swapped for a link since then
/// (by another process) fails the lookup instead of being followed.
public struct LiveLocalPathFileSystem: LocalPathFileSystem {
    public init() {}

    public func lstat(_ path: String) -> LocalPathLookup {
        var info = stat()
        guard fstatat(AT_FDCWD, path, &info, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
            let code = errno
            return code == ENOENT || code == ENOTDIR ? .missing : .failed(code)
        }
        return .found(LocalPathStat(info))
    }

    public func readlink(_ path: String) -> String? {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        let fd = open(folder.isEmpty ? "/" : folder, O_SEARCH | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(fd, name, &buffer, Int(PATH_MAX))
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// An absolute path resolved one part at a time with `lstat`, so that no lookup ever names a path the guard refuses
/// (docs/THREAT_MODEL.md, T33): the whole path is checked as written first, then every prefix before its `lstat`, and a
/// link's target is spliced in and checked part by part before the walk goes on through it. Each `lstat` is of a path
/// whose folders are real folders already resolved, so the kernel follows no link on the way either (and with the live
/// filesystem refuses one that appeared since). At most 32 links, paths up to `PATH_MAX`.
public enum LocalPathWalk {
    public static let maxLinks = 32

    /// Which links the walk goes through.
    public enum Links: Sendable {
        /// Every link (its target checked first).
        case follow
        /// Only a link root made in a folder only root can change (root owns both, group and others cannot write the
        /// folder: `/etc`, `/var`, `/tmp`, macOS's `/etc/ssh/crypto.conf`); any other link on the way ends the walk.
        case rootsOnly
    }

    public enum Outcome: Equatable, Sendable {
        /// The path names this, at this real path. With `followLastLink: false` a last part that is a link is reported
        /// as the link itself.
        case found(realPath: String, stat: LocalPathStat)
        /// Nothing there, or a part on the way is not a folder.
        case missing
        /// The path (or where its links lead) reaches a refused root: nothing was looked up there.
        case network
        /// A link the rule (`Links.rootsOnly`) does not follow.
        case link
        /// A lookup failed (`errno`), a link could not be read, too many links, or the path is too long or not absolute.
        case failed(Int32)
    }

    /// - Parameter pathGuard: the network check; nil checks nothing (a file of the user's own configuration).
    public static func resolve(_ path: String, followLastLink: Bool, guard pathGuard: NetworkPathGuard?,
                               fs: LocalPathFileSystem, links: Links = .follow) -> Outcome {
        guard path.hasPrefix("/"), !path.contains("\0") else { return .failed(EINVAL) }
        func refused(_ candidate: String) -> Bool { pathGuard?.refuses(candidate) ?? false }
        guard !refused(path) else { return .network }
        guard path.utf8.count <= Int(PATH_MAX) else { return .failed(ENAMETOOLONG) }
        var pending = parts(path)
        // The resolved real folders, top down, with what `lstat` said of each (the root's is asked for when needed).
        var folders: [(name: String, stat: LocalPathStat)] = []
        var rootStat: LocalPathStat?
        var last: LocalPathStat?
        var linkCount = 0
        func resolvedPath() -> String { "/" + folders.map(\.name).joined(separator: "/") }
        func holderStat() -> LocalPathStat? {
            if let top = folders.last { return top.stat }
            if rootStat == nil, case .found(let info) = fs.lstat("/") { rootStat = info }
            return rootStat
        }
        while !pending.isEmpty {
            let name = pending.removeFirst()
            if name == "." { continue }
            if name == ".." {
                // The folders are real, so the parent by text is the parent on disk.
                if !folders.isEmpty { folders.removeLast() }
                last = nil
                continue
            }
            let candidate = (folders.isEmpty ? "" : resolvedPath()) + "/" + name
            guard !refused(candidate) else { return .network }
            guard candidate.utf8.count <= Int(PATH_MAX) else { return .failed(ENAMETOOLONG) }
            switch fs.lstat(candidate) {
            case .missing:
                return .missing
            case .failed(let code):
                return .failed(code)
            case .found(let info):
                if info.kind == .link, followLastLink || !pending.isEmpty {
                    if links == .rootsOnly {
                        guard info.owner == 0, let holder = holderStat(), holder.owner == 0, !holder.othersCanWrite else {
                            return .link
                        }
                    }
                    linkCount += 1
                    guard linkCount <= maxLinks else { return .failed(ELOOP) }
                    guard let target = fs.readlink(candidate), !target.isEmpty, !target.contains("\0") else {
                        return .failed(EINVAL)
                    }
                    if target.hasPrefix("/") { folders.removeAll() }
                    pending = parts(target) + pending
                    last = nil
                    guard !refused((folders.isEmpty ? "" : resolvedPath()) + "/" + pending.joined(separator: "/")) else {
                        return .network
                    }
                    continue
                }
                if info.kind != .directory, !pending.isEmpty { return .missing }   // ENOTDIR
                folders.append((name, info))
                last = info
            }
        }
        let real = resolvedPath()
        if let last { return .found(realPath: real, stat: last) }
        // The walk ended on `..` or on a link to a folder already resolved: look at that folder itself.
        guard !refused(real) else { return .network }
        switch fs.lstat(real) {
        case .found(let info): return .found(realPath: real, stat: info)
        case .missing: return .missing
        case .failed(let code): return .failed(code)
        }
    }

    /// Whether `path` is an existing folder (links followed, checked), without any lookup the guard refuses.
    public static func isFolder(_ path: String, guard pathGuard: NetworkPathGuard, fs: LocalPathFileSystem) -> Bool {
        if case .found(_, let info) = resolve(path, followLastLink: true, guard: pathGuard, fs: fs), info.kind == .directory {
            return true
        }
        return false
    }

    private static func parts(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
