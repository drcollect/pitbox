import Darwin
import Foundation
import Testing
import PitboxKit

/// A filesystem of invented entries that records every call, for "no lookup reached the network". Parents of every
/// entry are folders.
final class RecordingPathFileSystem: LocalPathFileSystem, @unchecked Sendable {
    enum Entry: Equatable { case folder, file, link(String) }

    private let lock = NSLock()
    private var entries: [String: Entry] = ["/": .folder]
    private var recorded: [String] = []

    init(_ list: [String: Entry] = [:]) {
        for (path, entry) in list { add(path, entry) }
    }

    func add(_ path: String, _ entry: Entry) {
        lock.withLock {
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/", !parent.isEmpty, entries[parent] == nil {
                entries[parent] = .folder
                parent = (parent as NSString).deletingLastPathComponent
            }
            entries[path] = entry
        }
    }

    /// Every path asked about, in order.
    var calls: [String] { lock.withLock { recorded } }

    func lstat(_ path: String) -> LocalPathLookup {
        lock.withLock {
            recorded.append(path)
            switch entries[path] {
            case .folder?: return .found(LocalPathStat(kind: .directory, device: 1, inode: UInt64(path.utf8.count)))
            case .file?: return .found(LocalPathStat(kind: .regular, device: 1, inode: UInt64(path.utf8.count)))
            case .link?: return .found(LocalPathStat(kind: .link, device: 1, inode: UInt64(path.utf8.count)))
            case nil: return .missing
            }
        }
    }

    func readlink(_ path: String) -> String? {
        lock.withLock {
            recorded.append(path)
            if case .link(let target)? = entries[path] { return target }
            return nil
        }
    }
}

/// The paths a reply or session file can name that reach the network, and the check every lookup runs under.
struct NetworkPathsTests {
    static let networkPaths = ["/net/host/f", "/Volumes/x", "/Volumes/x/project/f", "/Network/Servers/box/f", "/home/u",
                               "/home/u/project", "/private/var/automount/x", "/var/automount/x",
                               "/System/Volumes/Data/home/u", "/System/Volumes/Data/net/host"]

    @Test func networkRootsAreRefusedInEveryWayTheVolumeSpellsThem() {
        for path in Self.networkPaths { #expect(NetworkPaths.isNetwork(path), "\(path)") }
        // The volume ignores case (with Unicode folding: a long s is an s, the Kelvin sign a k) and these reach the
        // same folders: refused as well.
        for path in ["/NET/host", "/volumes/x", "/Volume\u{017F}/x", "/Networ\u{212A}/Servers/x", "/\u{FF4E}et/host",
                     "/./net/host", "//net/host", "/tmp/../net/host", "/net/host/../../Users/x", "/net"] {
            #expect(NetworkPaths.isNetwork(path), "\(path)")
        }
        // Paths that address files by other means than their path are never looked up.
        for path in ["/.nofollow/net/host", "/.resolve/1/net/host", "/.vol/16777220/2", "/.file"] {
            #expect(NetworkPaths.isNetwork(path), "\(path)")
        }
        #expect(NetworkPaths.isNetwork("relative/path"), "not absolute: never looked up")
        for path in ["/Users/alex/net/x", "/networks/x", "/homes/x", "/tmp/x", "/private/tmp/x", "/Users/alex/.ssh/config", "/"] {
            #expect(!NetworkPaths.isNetwork(path), "\(path)")
        }
    }

    @Test func theMountTableAddsAutomountAndNetworkMounts() {
        let pathGuard = NetworkPathGuard(mountRoots: ["/Users/alex/nfs", "/mnt/share/", "/"])
        #expect(pathGuard.refuses("/Users/alex/nfs") && pathGuard.refuses("/Users/alex/nfs/a/b") && pathGuard.refuses("/mnt/share/x"))
        #expect(!pathGuard.refuses("/Users/alex/nfsx") && !pathGuard.refuses("/Users/alex/project"), "by whole parts; / is never one")
        // This Mac's table: absolute mount points other than /; with auto_home active, its trigger is among them.
        let mounted = NetworkPaths.mountedNetworkRoots()
        #expect(mounted.allSatisfy { $0.hasPrefix("/") && $0 != "/" })
    }

    @Test func aWalkNeverLooksUpANetworkPath() {
        let fs = RecordingPathFileSystem()
        let pathGuard = NetworkPathGuard(mountRoots: ["/Users/alex/automounted"])
        for path in Self.networkPaths + ["/Users/alex/automounted/x"] {
            #expect(LocalPathWalk.resolve(path, followLastLink: false, guard: pathGuard, fs: fs) == .network, "\(path)")
        }
        #expect(fs.calls.isEmpty, "not one lookup: \(fs.calls)")
    }

    @Test func linksOnTheWayAreCheckedBeforeTheyAreFollowed() {
        let fs = RecordingPathFileSystem(["/Users/alex/to-net": .link("/net/host"),
                                          "/Users/alex/to-volume": .link("../../Volumes/x"),
                                          "/Users/alex/to-mount": .link("automounted/deep"),
                                          "/Users/alex/project/notes.txt": .file])
        let pathGuard = NetworkPathGuard(mountRoots: ["/Users/alex/automounted"])
        for path in ["/Users/alex/to-net/f", "/Users/alex/to-volume/f", "/Users/alex/to-mount/f", "/Users/alex/to-net"] {
            #expect(LocalPathWalk.resolve(path, followLastLink: true, guard: pathGuard, fs: fs) == .network, "\(path)")
        }
        let reached = fs.calls.filter { pathGuard.refuses($0) }
        #expect(reached.isEmpty, "a lookup reached a refused root: \(reached)")
        #expect(fs.calls.contains("/Users/alex/to-net"), "the link itself is read, then its target is checked")
        // A link as the last part is reported, not followed, when asked so (a write target's own link).
        #expect(LocalPathWalk.resolve("/Users/alex/to-net", followLastLink: false, guard: pathGuard, fs: fs)
                == .found(realPath: "/Users/alex/to-net", stat: LocalPathStat(kind: .link, device: 1, inode: 18)))
        // Local paths still get their facts.
        if case .found(let real, let info) = LocalPathWalk.resolve("/Users/alex/project/notes.txt", followLastLink: true,
                                                                     guard: pathGuard, fs: fs) {
            #expect(real == "/Users/alex/project/notes.txt" && info.kind == .regular)
        } else {
            Issue.record("a local file was not found")
        }
        #expect(LocalPathWalk.resolve("/Users/alex/project/gone", followLastLink: true, guard: pathGuard, fs: fs) == .missing)
        #expect(LocalPathWalk.resolve("/Users/alex/project/notes.txt/x", followLastLink: true, guard: pathGuard, fs: fs) == .missing,
                "a file in the middle is ENOTDIR")
    }

    @Test func localPathsResolveAsTheKernelResolvesThem() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pitbox-walk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a/b/file.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link-b").path, withDestinationPath: "a/b")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("a/b/up").path, withDestinationPath: "..")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("loop").path, withDestinationPath: "loop")
        let fs = LiveLocalPathFileSystem()
        let pathGuard = NetworkPathGuard.current()
        func real(_ path: String) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            guard Darwin.realpath(path, &buffer) != nil else { return nil }
            return String(cString: buffer)
        }
        for relative in ["a/b/file.txt", "link-b/file.txt", "link-b/up/b/file.txt", "link-b/../b/file.txt", "a/b/up"] {
            let path = root.path + "/" + relative
            guard case .found(let resolved, _) = LocalPathWalk.resolve(path, followLastLink: true, guard: pathGuard, fs: fs) else {
                Issue.record("\(relative) was not found")
                continue
            }
            #expect(resolved == real(path), "\(relative)")
        }
        #expect(LocalPathWalk.resolve(root.path + "/loop", followLastLink: true, guard: pathGuard, fs: fs) == .failed(ELOOP))
        #expect(LocalPathWalk.resolve(root.path + "/nothing", followLastLink: true, guard: pathGuard, fs: fs) == .missing)
        #expect(LocalPathWalk.isFolder(root.path + "/link-b", guard: pathGuard, fs: fs))
        #expect(!LocalPathWalk.isFolder(root.path + "/a/b/file.txt", guard: pathGuard, fs: fs))
    }
}

/// Configuration files Pitbox acts on: no links, your files or root's, nobody else may write them, bounded.
struct TrustedConfigFileTests {
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pitbox-trusted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func onlyAPrivateRegularFileWithinTheLimitIsRead() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config")
        try Data("Host a\n".utf8).write(to: file)
        chmod(file.path, 0o600)
        let me = getuid()
        #expect((try? TrustedConfigFile.read(file.path, owner: me, maxBytes: 1024).get())?.data == Data("Host a\n".utf8))
        // A link is refused, never followed (whatever it points to).
        let link = dir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)
        #expect(TrustedConfigFile.read(link.path, owner: me, maxBytes: 1024) == .failure(.link))
        // Someone else's file (the owner asked for is not the file's, and it is not root's).
        #expect(TrustedConfigFile.read(file.path, owner: me &+ 1, maxBytes: 1024) == .failure(.owner))
        chmod(file.path, 0o620)
        #expect(TrustedConfigFile.read(file.path, owner: me, maxBytes: 1024) == .failure(.writableByOthers))
        chmod(file.path, 0o602)
        #expect(TrustedConfigFile.read(file.path, owner: me, maxBytes: 1024) == .failure(.writableByOthers))
        chmod(file.path, 0o600)
        #expect(TrustedConfigFile.read(file.path, owner: me, maxBytes: 3) == .failure(.tooLarge))
        #expect(mkfifo(dir.appendingPathComponent("fifo").path, 0o600) == 0)
        #expect(TrustedConfigFile.read(dir.appendingPathComponent("fifo").path, owner: me, maxBytes: 1024) == .failure(.notAFile),
                "a FIFO is never waited on")
        #expect(TrustedConfigFile.read(dir.appendingPathComponent("none").path, owner: me, maxBytes: 1024) == .failure(.missing))
    }

    /// L4 of the security review: no link on any part of the path, a linked folder on the way included.
    @Test func aLinkedFolderOnThePathIsRefusedToo() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dotfiles/ssh")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("config")
        try Data("Host a\n".utf8).write(to: file)
        chmod(file.path, 0o600)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent(".ssh").path, withDestinationPath: real.path)
        #expect(TrustedConfigFile.read(dir.appendingPathComponent(".ssh/config").path, owner: getuid(), maxBytes: 1024) == .failure(.link))
        #expect((try? TrustedConfigFile.read(file.path, owner: getuid(), maxBytes: 1024).get()) != nil, "the real path reads")
        // Root's own links (`/var` here, the temporary folder's parent) are the exception, never yours.
        #expect(LocalPathWalk.resolve(dir.appendingPathComponent(".ssh/config").path, followLastLink: true, guard: nil,
                                      fs: LiveLocalPathFileSystem(), links: .rootsOnly) == .link)
    }

    /// L2 of the security review: the live lookups let the kernel refuse a link on the way (one swapped in after the
    /// walk resolved that folder), instead of following it.
    @Test func theLiveLookupsNeverFollowALinkOnTheWay() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: real.appendingPathComponent("f"))
        try FileManager.default.createSymbolicLink(atPath: real.appendingPathComponent("l").path, withDestinationPath: "f")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("via").path, withDestinationPath: real.path)
        let fs = LiveLocalPathFileSystem()
        let base = realpathOf(dir.path)
        if case .found(let info) = fs.lstat(base + "/real/f") { #expect(info.kind == .regular) } else { Issue.record("not found") }
        #expect(fs.lstat(base + "/via/f") == .failed(ELOOP), "a link on the way is an error, not followed")
        #expect(fs.readlink(base + "/real/l") == "f")
        #expect(fs.readlink(base + "/via/l") == nil)
        // A path named through a link still resolves by the walk (which reads the link and checks its target).
        if case .found(let resolved, _) = LocalPathWalk.resolve(dir.path + "/via/f", followLastLink: true, guard: .current(), fs: fs) {
            #expect(resolved == base + "/real/f")
        } else {
            Issue.record("the walk did not resolve the link")
        }
    }

    private func realpathOf(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard Darwin.realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    /// macOS's own `/etc/ssh/crypto.conf` is a link root made in a folder only root can change: followed, by the same
    /// rules for its target. A link of yours to the same file is still refused.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/etc/ssh/crypto.conf")))
    func rootsOwnLinkInARootOnlyFolderIsFollowed() throws {
        #expect((try? TrustedConfigFile.read("/etc/ssh/crypto.conf", owner: getuid(), maxBytes: 1 << 20).get()) != nil)
        #expect((try? TrustedConfigFile.read("/etc/ssh/ssh_config", owner: getuid(), maxBytes: 1 << 20).get()) != nil,
                "through `/etc`, root's link in `/`")
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = dir.appendingPathComponent("crypto.conf")
        try FileManager.default.createSymbolicLink(atPath: mine.path, withDestinationPath: "/etc/ssh/crypto.conf")
        #expect(TrustedConfigFile.read(mine.path, owner: getuid(), maxBytes: 1 << 20) == .failure(.link))
    }
}
