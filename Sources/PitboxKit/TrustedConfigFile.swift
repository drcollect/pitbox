import Darwin
import Foundation

/// How Pitbox reads a configuration file it acts on (the SSH configuration and its `Include`s; docs/THREAT_MODEL.md,
/// "What Pitbox reads"). No link anywhere on the path is followed: the path is resolved part by part
/// (`LocalPathWalk`, `Links.rootsOnly`), where the only links gone through are those root made in a folder only root
/// can change (`/etc`, `/var`, `/tmp`, macOS's own `/etc/ssh/crypto.conf`); any other link, the file itself or a
/// folder on the way (a `~/.ssh` linked into a dotfiles folder), is refused. The real path is then opened with
/// `O_NOFOLLOW_ANY | O_NONBLOCK` (a link that appeared since fails, a FIFO is never waited on), must be the file the walk
/// found, and is checked through the descriptor: a regular file, owned by you or root, not writable by group or others,
/// within the reader's size limit. Every refusal is a problem for the caller: it says "couldn't read your SSH config",
/// never a guess.
public enum TrustedConfigFile {
    /// Why a file was not read.
    public enum Refusal: String, Error, Equatable, Sendable {
        /// Nothing there (not a problem for an `Include`'s pattern; the reader decides).
        case missing
        /// A link, the file itself or a folder on its path (other than root's own in a root-only folder).
        case link
        case notAFile
        /// Owned by someone other than you or root.
        case owner
        case writableByOthers
        case tooLarge
        case unreadable
    }

    /// One file read.
    public struct Contents: Equatable, Sendable {
        public var data: Data
        public var device: UInt64
        public var inode: UInt64
        public var modifiedSeconds: Int
        public var modifiedNanoseconds: Int
    }

    /// - Parameter pathGuard: the network check for a file an `Include` named (`CheckedGlob`): a path on a refused root,
    ///   as written or through root's link, is `unreadable` and never looked up. Nil for the configuration file itself.
    public static func read(_ path: String, owner: uid_t, maxBytes: Int,
                            guard pathGuard: NetworkPathGuard? = nil) -> Result<Contents, Refusal> {
        guard path.hasPrefix("/"), !path.contains("\0") else { return .failure(.unreadable) }
        let real: String
        let walked: LocalPathStat
        switch LocalPathWalk.resolve(path, followLastLink: true, guard: pathGuard, fs: LiveLocalPathFileSystem(), links: .rootsOnly) {
        case .missing: return .failure(.missing)
        case .link: return .failure(.link)
        case .network, .failed: return .failure(.unreadable)
        case .found(let resolved, let info):
            real = resolved
            walked = info
        }
        let fd = open(real, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .failure(.missing)
            case ELOOP: return .failure(.link)
            default: return .failure(.unreadable)
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable) }
        // The file the walk looked at, not one swapped in since.
        guard UInt64(UInt32(bitPattern: info.st_dev)) == walked.device, UInt64(info.st_ino) == walked.inode else {
            return .failure(.unreadable)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.notAFile) }
        guard info.st_uid == owner || info.st_uid == 0 else { return .failure(.owner) }
        guard (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return .failure(.writableByOthers) }
        guard info.st_size <= Int64(maxBytes) else { return .failure(.tooLarge) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                data.append(contentsOf: buffer[0..<n])
                if data.count > maxBytes { return .failure(.tooLarge) }
            } else if n == 0 {
                break
            } else if errno != EINTR {
                return .failure(.unreadable)
            }
        }
        return .success(Contents(data: data, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                                 modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec))
    }
}
