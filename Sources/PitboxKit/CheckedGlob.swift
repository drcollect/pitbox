import Darwin
import Foundation

/// `glob(3)` for an `Include` of the SSH configuration, under the network check every other lookup gets
/// (docs/THREAT_MODEL.md, T33). The pattern as written (after the reader's own `~` and relative-path expansion) is
/// checked first; then every lookup glob itself makes, each folder it lists and each name it checks, is resolved part
/// by part by `LocalPathWalk` under the `NetworkPathGuard` before the real call, which names only the checked real path
/// (`O_NOFOLLOW_ANY`, `AT_SYMLINK_NOFOLLOW_ANY`). A pattern that reaches a refused root anywhere (as written, through a
/// link on the way, or by a name a wildcard matched) is `refused`: nothing was looked up there, and the readers count it
/// as a file they could not read. glob's own matching and order are unchanged.
public enum CheckedGlob {
    public enum Outcome: Equatable, Sendable {
        /// The paths the pattern names, in glob's order (sorted); empty when it names nothing.
        case matches([String])
        /// The pattern reaches a refused root: nothing was looked up there.
        case refused
        /// glob failed for another reason (a relative pattern, no memory, a path too long).
        case failed
    }

    /// The paths an absolute `pattern` names. `fs` makes the walk's lookups (tests pass a recording wrapper of the live
    /// filesystem; the real calls after each walk always use the live one).
    public static func expand(_ pattern: String, guard pathGuard: NetworkPathGuard,
                              fs: LocalPathFileSystem = LiveLocalPathFileSystem()) -> Outcome {
        guard pattern.hasPrefix("/"), !pattern.contains("\0") else { return .failed }
        guard !pathGuard.refuses(pattern) else { return .refused }
        let context = Context(pathGuard: pathGuard, fs: fs)
        let retained = Unmanaged.passRetained(context)
        pthread_setspecific(contextKey, retained.toOpaque())
        defer {
            pthread_setspecific(contextKey, nil)
            retained.release()
        }
        var result = glob_t()
        result.gl_opendir = { path in CheckedGlob.openFolder(path) }
        result.gl_readdir = { folder in folder.flatMap { readdir($0.assumingMemoryBound(to: DIR.self)) } }
        result.gl_closedir = { folder in
            if let folder { _ = closedir(folder.assumingMemoryBound(to: DIR.self)) }
        }
        result.gl_lstat = { path, info in CheckedGlob.look(path, info, followLastLink: false) }
        result.gl_stat = { path, info in CheckedGlob.look(path, info, followLastLink: true) }
        defer { globfree(&result) }
        let status = glob(pattern, GLOB_ALTDIRFUNC, nil, &result)
        if context.refused { return .refused }
        if status == GLOB_NOMATCH { return .matches([]) }
        guard status == 0 else { return .failed }
        var paths: [String] = []
        for index in 0..<Int(result.gl_pathc) {
            if let entry = result.gl_pathv[index] { paths.append(String(cString: entry)) }
        }
        return .matches(paths)
    }

    // MARK: glob's lookups

    /// What one `expand` call's lookups share: glob calls them on the caller's thread, which holds it in `contextKey`.
    private final class Context {
        let pathGuard: NetworkPathGuard
        let fs: LocalPathFileSystem
        /// A lookup glob asked for reached a refused root (and was not made).
        var refused = false

        init(pathGuard: NetworkPathGuard, fs: LocalPathFileSystem) {
            self.pathGuard = pathGuard
            self.fs = fs
        }
    }

    private static let contextKey: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    private static func current() -> Context? {
        guard let raw = pthread_getspecific(contextKey) else { return nil }
        return Unmanaged<Context>.fromOpaque(raw).takeUnretainedValue()
    }

    /// glob's `opendir`: the folder is walked under the guard, then its real path opened without following any link and
    /// required to be the folder the walk found.
    private static func openFolder(_ path: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
        guard let path, let context = current(), let text = String(validatingCString: path) else {
            errno = ENOENT
            return nil
        }
        switch LocalPathWalk.resolve(text, followLastLink: true, guard: context.pathGuard, fs: context.fs) {
        case .network:
            context.refused = true
            errno = EACCES
            return nil
        case .found(let real, let walked) where walked.kind == .directory:
            let fd = open(real, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            var opened = stat()
            guard fstat(fd, &opened) == 0, UInt64(UInt32(bitPattern: opened.st_dev)) == walked.device,
                  UInt64(opened.st_ino) == walked.inode, let folder = fdopendir(fd) else {
                close(fd)
                errno = ENOENT
                return nil
            }
            return UnsafeMutableRawPointer(folder)
        case .found:
            errno = ENOTDIR
            return nil
        case .missing, .link:
            errno = ENOENT
            return nil
        case .failed(let code):
            errno = code
            return nil
        }
    }

    /// glob's `lstat` and `stat`: the name is walked under the guard, then its real path looked at without following
    /// any link on the way.
    private static func look(_ path: UnsafePointer<CChar>?, _ info: UnsafeMutablePointer<stat>?, followLastLink: Bool) -> Int32 {
        guard let path, let info, let context = current(), let text = String(validatingCString: path) else {
            errno = ENOENT
            return -1
        }
        switch LocalPathWalk.resolve(text, followLastLink: followLastLink, guard: context.pathGuard, fs: context.fs) {
        case .network:
            context.refused = true
            errno = EACCES
            return -1
        case .found(let real, _):
            return fstatat(AT_FDCWD, real, info, AT_SYMLINK_NOFOLLOW_ANY)
        case .missing, .link:
            errno = ENOENT
            return -1
        case .failed(let code):
            errno = code
            return -1
        }
    }
}
