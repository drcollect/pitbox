import Darwin
import Foundation
import Testing
@testable import Pitbox

/// One Pitbox per user: the lock file in the app-support folder (docs/DOCK_PROTOCOL.md §2.1). Scratch folders only.
@Suite("Single-instance lock")
struct SingleInstanceLockTests {
    /// A fresh folder, resolved (so `/var` and `/private/var` cannot differ); removed by the caller.
    static func folder(_ name: String) -> URL {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pitbox-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return raw.resolvingSymlinksInPath()
    }

    @Test func aSecondInstanceFindsTheLockTaken() throws {
        let folder = Self.folder("lock")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try SingleInstanceLock.acquire(in: folder).get()
        #expect(first.isHeld && first.url.lastPathComponent == "pitbox.lock")
        // flock belongs to the open file: a second open, even in this process, is a second Pitbox.
        guard case .failure(let failure) = SingleInstanceLock.acquire(in: folder) else {
            Issue.record("the second acquire must fail")
            return
        }
        #expect(failure == .taken && failure.label == "taken")
        first.release()
        #expect(!first.isHeld)
        let again = try SingleInstanceLock.acquire(in: folder).get()
        #expect(again.isHeld, "free again once the holder lets go (or exits)")
        var st = stat()
        #expect(lstat(again.url.path, &st) == 0 && (st.st_mode & 0o777) == 0o600)
    }

    @Test func aLinkOrAFolderIsNeverUsedAsTheLock() throws {
        let folder = Self.folder("lock-link")
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("elsewhere")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("pitbox.lock"), withDestinationURL: target)
        guard case .failure(.unusable(let why)) = SingleInstanceLock.acquire(in: folder) else {
            Issue.record("a link must be refused")
            return
        }
        #expect(why == "link")

        let other = Self.folder("lock-dir")
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createDirectory(at: other.appendingPathComponent("pitbox.lock"), withIntermediateDirectories: false)
        guard case .failure(.unusable) = SingleInstanceLock.acquire(in: other) else {
            Issue.record("a folder must be refused")
            return
        }
    }

    @Test func aLeftoverFileFromACrashDoesNotBlock() throws {
        let folder = Self.folder("lock-stale")
        defer { try? FileManager.default.removeItem(at: folder) }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("pitbox.lock").path, contents: Data("x".utf8),
                                       attributes: [.posixPermissions: 0o600])
        let lock = try SingleInstanceLock.acquire(in: folder).get()
        #expect(lock.isHeld)
    }
}
