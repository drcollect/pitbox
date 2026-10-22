import Darwin
import Foundation
import PitboxKit

/// Why a folder cannot be used for a run, in Pitbox's words.
enum FolderBindingProblem: Error, Equatable {
    /// Not an absolute path, or one with a NUL.
    case notUsable
    /// Nothing is there, or it is not a folder.
    case missing
    /// It is there but cannot be opened (`errno`).
    case cannotOpen(Int32)
    /// The path no longer leads to the folder the sheet showed (replaced, moved, a link retargeted, removed).
    case changed
    /// It is (or leads) under `/net`, `/home`, `/Volumes`, `/Network` or an automount point: never looked up
    /// (docs/THREAT_MODEL.md, T33), so nothing runs there.
    case network

    var words: String {
        switch self {
        case .notUsable: return "the folder can't be used"
        case .missing: return "the folder isn't there"
        case .cannotOpen: return "the folder can't be opened"
        case .changed: return "the folder changed after you looked; review again"
        case .network: return "the folder is on a network or another volume; \(AppIdentity.displayName) runs nothing there"
        }
    }
}

/// The folder a run starts in, bound by descriptor when the sheet opens: the folder the user saw.
///
/// The sheet opens the folder (`O_DIRECTORY`) and keeps the descriptor with its device and inode. At Run the path must
/// still lead to the same folder and the descriptor must still be that folder; the child then enters it through the
/// descriptor (`fchdir` in the command helper), never by path. There is no fallback after approval: any mismatch
/// starts nothing. The descriptor is closed when the binding goes away or is consumed by a spawn.
///
/// The path comes from a session file, so it is walked part by part under `NetworkPathGuard` before anything is opened
/// (`LocalPathWalk`, links on the way checked too), and the resolved real folder is opened with `O_NOFOLLOW_ANY`: a folder
/// on a network or automount root is refused (`.network`) without any lookup, at the bind and again at `verify()`.
final class FolderBinding {
    /// The folder as the sheet showed it (absolute, standardized).
    let path: String
    let device: UInt64
    let inode: UInt64
    /// The open descriptor, or -1 once closed.
    private(set) var descriptor: Int32
    /// The lookups `verify()` makes, and the network check they run under (the mount table then).
    private let fileSystem: LocalPathFileSystem
    private let pathGuard: () -> NetworkPathGuard

    private init(path: String, device: UInt64, inode: UInt64, descriptor: Int32, fileSystem: LocalPathFileSystem,
                 pathGuard: @escaping () -> NetworkPathGuard) {
        self.path = path
        self.device = device
        self.inode = inode
        self.descriptor = descriptor
        self.fileSystem = fileSystem
        self.pathGuard = pathGuard
    }

    deinit { close() }

    /// Opens `path` (absolute; `~` is not expanded here) as a folder and records its identity. `fs` and `pathGuard` are
    /// for tests.
    static func bind(_ path: String, fs: LocalPathFileSystem = LiveLocalPathFileSystem(),
                     guard pathGuard: @escaping () -> NetworkPathGuard = { .current() }) -> Result<FolderBinding, FolderBindingProblem> {
        guard path.hasPrefix("/"), !path.contains("\0") else { return .failure(.notUsable) }
        let standardized = lexicallyNormalized(path)
        let real: String
        let walked: LocalPathStat
        switch LocalPathWalk.resolve(standardized, followLastLink: true, guard: pathGuard(), fs: fs) {
        case .network: return .failure(.network)
        case .missing: return .failure(.missing)
        case .link: return .failure(.cannotOpen(ELOOP))
        case .failed(let code): return .failure(.cannotOpen(code))
        case .found(let resolved, let info):
            guard info.kind == .directory else { return .failure(.missing) }
            real = resolved
            walked = info
        }
        // The real folder, every part already checked: `O_NOFOLLOW_ANY` makes the kernel refuse any link on the way
        // (one swapped in since the walk is never followed), and the folder must be the one the walk found.
        let fd = open(real, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            return .failure(code == ENOENT || code == ENOTDIR ? .missing : code == ELOOP ? .changed : .cannotOpen(code))
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(fd)
            return .failure(.missing)
        }
        guard UInt64(UInt32(bitPattern: info.st_dev)) == walked.device, UInt64(info.st_ino) == walked.inode else {
            Darwin.close(fd)
            return .failure(.changed)
        }
        return .success(FolderBinding(path: standardized, device: UInt64(UInt32(bitPattern: info.st_dev)),
                                      inode: UInt64(info.st_ino), descriptor: fd, fileSystem: fs, pathGuard: pathGuard))
    }

    /// Nil when the path still leads to the bound folder and the descriptor is still that folder, else why not.
    func verify() -> FolderBindingProblem? {
        guard descriptor >= 0 else { return .changed }
        var held = stat()
        guard fstat(descriptor, &held) == 0, (held.st_mode & S_IFMT) == S_IFDIR, held.st_nlink > 0,
              UInt64(UInt32(bitPattern: held.st_dev)) == device, UInt64(held.st_ino) == inode else { return .changed }
        switch LocalPathWalk.resolve(path, followLastLink: true, guard: pathGuard(), fs: fileSystem) {
        case .network:
            return .network
        case .found(_, let current) where current.kind == .directory && current.device == device && current.inode == inode:
            return nil
        default:
            return .changed
        }
    }

    /// The folder for "How it runs" and the bar: `~/my project` for a folder under `home`, else the full path.
    func shortPath(home: String) -> String { Self.shortPath(path, home: home) }

    static func shortPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if !home.isEmpty, path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Removes empty and `.` components and applies `..` by text, nothing else: unlike `standardizingPath` it never
    /// drops `/private` or resolves links (no filesystem call), so the path shown is the path given.
    static func lexicallyNormalized(_ path: String) -> String { FolderText.lexical(path) }

    /// Closes the descriptor (idempotent).
    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}
