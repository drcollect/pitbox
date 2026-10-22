import CoreServices
import Darwin
import Foundation

/// File events below several folders (FSEvents, recursive, per file), delivered on `queue` as the changed paths, with
/// `mustRescan` set when FSEvents lost track (dropped events, a changed root): then only a full re-read is reliable.
/// FSEvents coalesces bursts (`latency`); nothing runs while nothing changes. Create, use and stop it on `queue`. (The
/// pattern of a usage reader's folder watcher, copied.)
final class CodeFolderWatcher {
    private var stream: FSEventStreamRef?

    /// The object FSEvents hands back to the callback; it lives as long as the stream (released by the stream).
    private final class Box {
        let handler: ([String], Bool) -> Void
        init(handler: @escaping ([String], Bool) -> Void) { self.handler = handler }
    }

    /// Nil when no folder exists or the stream could not be created.
    init?(folders: [String], latency: TimeInterval, queue: DispatchQueue,
          handler: @escaping (_ paths: [String], _ mustRescan: Bool) -> Void) {
        let existing = folders.filter { CarefulFiles.isExistingFolder($0) }
        guard !existing.isEmpty else { return nil }
        let info = Unmanaged.passRetained(Box(handler: handler)).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil,
                                           release: { info in
                                               if let info { Unmanaged<Box>.fromOpaque(info).release() }
                                           }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            let list = Array(((array as? [String]) ?? []).prefix(count))
            let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            var mustRescan = false
            for index in 0..<count where flags[index] & rescanFlags != 0 { mustRescan = true }
            box.handler(list, mustRescan)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, existing as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            Unmanaged<Box>.fromOpaque(info).release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Kernel events for one file and its folder: the file written, extended, replaced, renamed or deleted, or the folder's
/// entries changing (a file saved by renaming, or created). For `session-popouts.json`, which lives in the busy profile
/// folder, where a recursive FSEvents stream would wake on every cache write. Nothing runs while nothing happens. Create,
/// use and stop it on `queue`.
final class CodeFileWatcher {
    private let file: String
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var stopped = false

    init(file: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.file = file
        self.queue = queue
        self.onChange = onChange
        let folder = (file as NSString).deletingLastPathComponent
        folderSource = Self.watch(folder, mask: [.write, .rename, .delete], queue: queue) { [weak self] in self?.changed() }
        rewatchFile()
    }

    deinit { cancelSources() }

    func stop() {
        stopped = true
        cancelSources()
    }

    private func cancelSources() {
        folderSource?.cancel()
        folderSource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    private func changed() {
        guard !stopped else { return }
        rewatchFile()
        onChange()
    }

    /// A replaced file has a new inode, and a missing file may appear: the file source is renewed after every event.
    private func rewatchFile() {
        fileSource?.cancel()
        fileSource = Self.watch(file, mask: [.write, .extend, .delete, .rename, .attrib], queue: queue) { [weak self] in
            self?.changed()
        }
    }

    private static func watch(_ path: String, mask: DispatchSource.FileSystemEvent, queue: DispatchQueue,
                              handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
