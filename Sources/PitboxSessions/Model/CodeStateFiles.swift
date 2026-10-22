import Darwin
import Foundation
import PitboxKit

/// The app's own small JSON files in the app-support folder (`settings.json`, `code-memory.json`, `block-state.json` and
/// `code-buckets.json`): read carefully and written atomically. The folder is private to the user (0700); a same-user
/// process can still reach it, so every read is careful.
enum CodeStateFiles {
    /// Why a file could not be used. `label` is safe to log (no path, no content).
    enum ReadFailure: Error, Equatable, Sendable {
        case missing
        /// A link, a FIFO or another non-regular file, another owner, too large, unreadable.
        case refused(CarefulReadFailure)
        /// Bad JSON, a duplicated key, nesting over 64.
        case json(StrictJSONFailure)
        /// Nesting deeper than the file's own limit.
        case tooDeep
        case notObject

        var label: String {
            switch self {
            case .missing: return "missing"
            case .refused(let failure): return failure.label
            case .json(let failure): return failure.label
            case .tooDeep: return "too-deep"
            case .notObject: return "not-object"
            }
        }
    }

    /// The file's top-level object. The file is opened without following a link (`O_NOFOLLOW | O_NONBLOCK`) and checked
    /// through its descriptor: a regular file owned by `owner`, at most `maxBytes`; then read as strict JSON (a key
    /// that appears twice at any depth fails it) nested at most `maxDepth` deep. Strings are kept whole.
    static func readObject(at url: URL, owner: uid_t, maxBytes: Int,
                           maxDepth: Int = CodeTuning.stateFileNestingMax) -> Result<[String: JSONValue], ReadFailure> {
        guard let path = CarefulPath(root: url.deletingLastPathComponent().path, components: [url.lastPathComponent]) else {
            return .failure(.refused(.badPath))
        }
        let data: Data
        switch CarefulFiles.read(path, owner: owner, maxBytes: maxBytes) {
        case .failure(.missing): return .failure(.missing)
        case .failure(let failure): return .failure(.refused(failure))
        case .success(let (bytes, _)): data = bytes
        }
        return parseObject(data, maxDepth: maxDepth)
    }

    /// `data` as a strict JSON object nested at most `maxDepth` deep.
    static func parseObject(_ data: Data, maxDepth: Int = CodeTuning.stateFileNestingMax) -> Result<[String: JSONValue], ReadFailure> {
        let root: JSONValue
        do {
            root = try data.withUnsafeBytes { bytes in
                try StrictJSONReader.read(bytes) { reader in try reader.tree(key: nil, cap: { _ in Int.max }) }
            }
        } catch let failure as StrictJSONFailure {
            return .failure(.json(failure))
        } catch {
            return .failure(.json(.syntax))
        }
        guard depth(of: root) <= maxDepth else { return .failure(.tooDeep) }
        guard case .object(let members) = root else { return .failure(.notObject) }
        return .success(members)
    }

    /// Containers nested in `value` (a scalar is 0, `{}` is 1).
    static func depth(of value: JSONValue) -> Int {
        switch value {
        case .object(let members): return 1 + (members.values.map(depth(of:)).max() ?? 0)
        case .array(let elements): return 1 + (elements.map(depth(of:)).max() ?? 0)
        default: return 0
        }
    }

    /// `object` as JSON text: sorted keys, slashes as written, pretty-printed when asked.
    static func serialize(_ object: [String: JSONValue], pretty: Bool = false) -> Data? {
        let foundation = object.mapValues(\.foundation)
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try? JSONSerialization.data(withJSONObject: foundation, options: options)
    }

    /// Why a write failed. `label` is safe to log.
    enum WriteFailure: Error, Equatable, Sendable {
        case folder, create, write, rename

        var label: String {
            switch self {
            case .folder: return "folder"
            case .create: return "create"
            case .write: return "write"
            case .rename: return "rename"
            }
        }
    }

    /// Writes `data` to `url` atomically: a temporary file next to it, created exclusively with mode 0600 (a link is
    /// never followed), written, `fsync`ed, then renamed over `url` (a link at `url` is replaced, never written
    /// through). The folder is created with mode 0700 when missing.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw WriteFailure.folder
        }
        let random = UInt64.random(in: 0...UInt64.max)
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(String(random, radix: 16)).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteFailure.create }
        let written = fchmod(fd, 0o600) == 0 && writeAll(fd, data) && fsync(fd) == 0
        close(fd)
        guard written else {
            unlink(temporary.path)
            throw WriteFailure.write
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw WriteFailure.rename
        }
        syncFolder(folder)
    }

    /// Creates `url` with `data` only when nothing (not even a link) is there: an exclusive create, mode 0600. False
    /// when something exists or the write failed (a partial file is removed).
    static func createExclusively(_ data: Data, at url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil else { return false }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let written = fchmod(fd, 0o600) == 0 && writeAll(fd, data) && fsync(fd) == 0
        close(fd)
        if !written { unlink(url.path) }
        return written
    }

    /// Renames a broken file (a link, a FIFO, whatever it is) to `<name>.corrupt`, replacing an older one; the entry
    /// itself is renamed, nothing is followed. True when it moved.
    @discardableResult
    static func setAside(_ url: URL) -> Bool {
        rename(url.path, url.path + ".corrupt") == 0
    }

    /// The size of the entry at `url` (`lstat`: a link's own size), for log lines.
    static func entrySize(_ url: URL) -> Int64 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? Int64(info.st_size) : -1
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    private static func syncFolder(_ folder: URL) {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }
}
