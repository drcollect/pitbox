import Darwin
import Foundation

/// Paths whose lookup can reach the network or another volume (docs/THREAT_MODEL.md, T33). A path that came from a
/// reply, a session file or a program's output is checked here before ANY filesystem call (`stat`, `lstat`,
/// `readlink`, `open`, `realpath`, `fileExists`): a lookup under `/net` or an automount point makes the automounter
/// contact a host the text chose, before anyone clicked anything. Paths are never logged.
public enum NetworkPaths {
    /// Folders that reach the network through the automounter or belong to another volume. Besides `/net`, `/home`,
    /// `/Volumes`, `/Network` and `/private/var/automount`, the list holds the forms the data volume's firmlinks and the
    /// `/var` link give (`/System/Volumes/Data/home` is where `/home` points, an autofs mount; `/Network/Servers` is
    /// `auto_master`'s `-fstab` map).
    public static let roots = ["/net", "/home", "/Volumes", "/Network", "/private/var/automount", "/var/automount",
                               "/System/Volumes/Data/net", "/System/Volumes/Data/home", "/System/Volumes/Data/Volumes",
                               "/System/Volumes/Data/Network", "/System/Volumes/Data/private/var/automount"]

    /// String work only, for an absolute path as written. True when the path, or any folder on the way to it (read part
    /// by part, `.` skipped, `..` taken back by text), is one of `roots` or below one; when its first part starts with
    /// a dot (`/.vol/…`, `/.nofollow/…`, `/.resolve/…` reach files by other means than their path); or when it is not
    /// absolute. Names are compared the way the Mac's volume compares them: case and width folded, so `/NET`, `/Ｎet`
    /// and `/Volumeſ` (a long s) are refused too.
    public static func isNetwork(_ path: String) -> Bool {
        NetworkPathGuard.fixed.refuses(path)
    }

    /// Mount points of filesystems that are not local, that the automounter made, or that are automount triggers
    /// (`autofs`: `/System/Volumes/Data/home`, `/net`, the entries of a direct map), from the kernel's mount table.
    /// `getfsstat` with `MNT_NOWAIT` asks no filesystem and looks up no path. Empty when the table cannot be read (the
    /// fixed `roots` still apply).
    public static func mountedNetworkRoots() -> [String] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let capacity = Int(count) + 4
        // The kernel fills the entries it reports (plain C structs); only those are kept.
        let table = Array<statfs>(unsafeUninitializedCapacity: capacity) { buffer, initialized in
            let read = getfsstat(buffer.baseAddress, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
            initialized = max(0, min(capacity, Int(read)))
        }
        var found: [String] = []
        for var entry in table {
            let flags = entry.f_flags
            let type = withUnsafeBytes(of: &entry.f_fstypename) { cString($0) }
            let local = flags & UInt32(MNT_LOCAL) != 0
            let automounted = flags & UInt32(MNT_AUTOMOUNTED) != 0
            guard !local || automounted || type == "autofs" else { continue }
            let point = withUnsafeBytes(of: &entry.f_mntonname) { cString($0) }
            if point.hasPrefix("/"), point != "/" { found.append(point) }
        }
        return found
    }

    private static func cString(_ bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// The check one lookup uses: `NetworkPaths.roots` plus the mount table's network and automount points, read once
/// when the guard is made (`current()`). Tests make one with their own mount points.
public struct NetworkPathGuard: Sendable, Equatable {
    /// The fixed roots only (string work; no mount table).
    public static let fixed = NetworkPathGuard(mountRoots: [])

    /// Folded forms of every refused root.
    private let foldedRoots: Set<String>

    /// The fixed roots plus `mountRoots` (absolute mount points; `/` itself is never one).
    public init(mountRoots: [String]) {
        var roots = Set(NetworkPaths.roots.map(Self.fold))
        for root in mountRoots where root.hasPrefix("/") && root != "/" {
            roots.insert(Self.fold(FolderText.lexical(root)))
        }
        foldedRoots = roots
    }

    /// The fixed roots and this Mac's mount table now.
    public static func current() -> NetworkPathGuard {
        NetworkPathGuard(mountRoots: NetworkPaths.mountedNetworkRoots())
    }

    /// `current()`, read again at most once a second: for checks made many times a pass (the result checks' walks).
    public static func recent() -> NetworkPathGuard {
        RecentGuard.shared.value()
    }

    /// `NetworkPaths.isNetwork`'s rule against this guard's roots.
    public func refuses(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return true }
        var parts: [String] = []
        for (index, raw) in path.split(separator: "/", omittingEmptySubsequences: true).enumerated() {
            if index == 0, raw.hasPrefix(".") { return true }
            if raw == "." { continue }
            if raw == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(Self.fold(String(raw)))
            if foldedRoots.contains("/" + parts.joined(separator: "/")) { return true }
        }
        return false
    }

    /// How the Mac's (case-insensitive) volume compares a name, made stricter with width folding.
    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}

/// Path text helpers that never touch the disk.
public enum FolderText {
    /// An absolute path with empty and `.` parts dropped and `..` applied by text (`/a/./b/../c//` is `/a/c`).
    public static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// The cache behind `NetworkPathGuard.recent()`, safe from any thread.
private final class RecentGuard: @unchecked Sendable {
    static let shared = RecentGuard()
    static let lifetime: TimeInterval = 1

    private let lock = NSLock()
    private var cached: (value: NetworkPathGuard, at: TimeInterval)?

    func value() -> NetworkPathGuard {
        let now = MonotonicClock.now()
        if let cached = lock.withLock({ cached }), now - cached.at < Self.lifetime { return cached.value }
        let fresh = NetworkPathGuard.current()
        lock.withLock { cached = (fresh, now) }
        return fresh
    }
}
