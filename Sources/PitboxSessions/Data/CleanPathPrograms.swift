import Darwin
import Foundation
import PitboxKit

/// The program names on the clean shell's PATH plus usable `extraPath` folders, for reading untagged blocks (offered
/// only when each line starts with a shell word or a known program). A file lookup only: each folder is listed
/// (entries that are executable regular files, links followed as the shell would), nothing is run. A folder is listed
/// again only when its modification time changes.
final class CleanPathPrograms: @unchecked Sendable {
    static let maxNamesPerFolder = 20_000

    private let lock = NSLock()
    private var cache: [String: (modified: TimeInterval, names: Set<String>)] = [:]

    /// The folders of the fixed clean PATH.
    static let folders = CommandExecutionDescriptor.cleanPath.split(separator: ":").map(String.init)

    init() {}

    /// Every program name in the clean PATH's folders and in `extraPath` (already checked by `usableExtraPath`).
    func programs(extraPath: [String]) -> Set<String> {
        var names = Set<String>()
        for folder in Self.folders + extraPath where folder.hasPrefix("/") { names.formUnion(list(folder)) }
        return names
    }

    private func list(_ folder: String) -> Set<String> {
        var info = stat()
        guard stat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return [] }
        let modified = FileIdentity(info).modified
        if let cached = lock.withLock({ cache[folder] }), cached.modified == modified { return cached.names }
        let names = Self.executables(in: folder)
        lock.withLock { cache[folder] = (modified, names) }
        return names
    }

    /// The executable regular files of `folder` (by name).
    static func executables(in folder: String) -> Set<String> {
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        guard let dir = fdopendir(fd) else {
            close(fd)
            return []
        }
        defer { closedir(dir) }
        var names = Set<String>()
        while let entry = readdir(dir), names.count < maxNamesPerFolder {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            guard !name.hasPrefix("."), CarefulFiles.isSafeName(name) else { continue }
            var info = stat()
            guard fstatat(dirfd(dir), name, &info, 0) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  faccessat(dirfd(dir), name, X_OK, 0) == 0 else { continue }
            names.insert(name)
        }
        return names
    }
}
