import Darwin
import Foundation
import PitboxKit

/// What `lstat` says about one path: a link is reported as a link, never followed.
struct ResultFileStat: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case regular, directory, link, other }
    var kind: Kind
    var device: UInt64
    var inode: UInt64
    /// Hard links (`st_nlink`).
    var links: UInt64
    var owner: uid_t

    init(kind: Kind, device: UInt64, inode: UInt64, links: UInt64, owner: uid_t) {
        self.kind = kind; self.device = device; self.inode = inode; self.links = links; self.owner = owner
    }

    init(_ info: stat) {
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .link
        default: kind = .other
        }
        device = UInt64(UInt32(bitPattern: info.st_dev))
        inode = UInt64(info.st_ino)
        links = UInt64(info.st_nlink)
        owner = info.st_uid
    }
}

/// The filesystem as the result checks see it: `lstat` and `readlink` only, so nothing is opened,
/// read or followed, and a FIFO is never waited on. Every call happens only for a path that passed the string rules
/// (`ResultPaths`, `ResultPathRules`). Tests pass a recording fake.
protocol ResultFileSystem: Sendable {
    /// `lstat(2)` of an absolute path; nil when it fails (missing, no permission).
    func lstat(_ path: String) -> ResultFileStat?
    /// The target of the link at `path` as written in it; nil when it is no link or cannot be read.
    func readlink(_ path: String) -> String?
    /// The network check every walk runs before a lookup: the fixed roots and the mount table's network and automount
    /// points (`NetworkPathGuard.recent()`, read at most once a second). Tests give their own.
    var networkGuard: NetworkPathGuard { get }
}

extension ResultFileSystem {
    var networkGuard: NetworkPathGuard { .recent() }
}

/// This Mac's filesystem.
struct LiveResultFileSystem: ResultFileSystem {
    func lstat(_ path: String) -> ResultFileStat? {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { return nil }
        return ResultFileStat(info)
    }

    func readlink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = Darwin.readlink(path, &buffer, Int(PATH_MAX))
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// How long one session's file checks may take in one pass (`CodeTuning.fileCheckBudget`, 50 ms): checked before each
/// filesystem call; once spent, the remaining candidates are given up (no button). Used on one queue at a time.
final class ResultCheckBudget {
    private let deadline: TimeInterval
    private let clock: () -> TimeInterval
    /// Filesystem calls made under this budget (tests).
    private(set) var calls = 0

    init(seconds: TimeInterval = CodeTuning.fileCheckBudget, clock: @escaping () -> TimeInterval = MonotonicClock.now) {
        self.clock = clock
        self.deadline = clock() + seconds
    }

    /// No limit (the click-time check of one file).
    static func unlimited() -> ResultCheckBudget { ResultCheckBudget(seconds: .infinity) }

    /// Whether another call may be made now; counts it when it may.
    func take() -> Bool {
        guard clock() < deadline else { return false }
        calls += 1
        return true
    }

    var isSpent: Bool { clock() >= deadline }
}

/// `realpath(3)` done one part at a time with `lstat`, so that no link is ever followed into a place the string rules
/// would refuse: each link's target is checked as a string (printable ASCII, not a network path) before
/// resolution goes on through it, and at most 32 links are followed. An `lstat` is made only of a path whose folders
/// are all real folders already resolved, so the kernel follows no link on the way either.
enum ResultRealPath {
    enum Failure: Error, Equatable, Sendable {
        case missing, network, refused, loop, notFolder, budget
    }

    static let maxLinks = 32

    /// The real path of the lexical absolute `path` and the `lstat` of what it names.
    static func resolve(_ path: String, fs: ResultFileSystem, budget: ResultCheckBudget) -> Result<(path: String, stat: ResultFileStat), Failure> {
        let pathGuard = fs.networkGuard
        var pending = ResultPaths.components(path)
        var resolved = ""
        var links = 0
        var last: ResultFileStat?
        guard !pending.isEmpty else { return .failure(.notFolder) }
        while !pending.isEmpty {
            let name = pending.removeFirst()
            let candidate = resolved + "/" + name
            guard !pathGuard.refuses(candidate) else { return .failure(.network) }
            guard budget.take() else { return .failure(.budget) }
            guard let info = fs.lstat(candidate) else { return .failure(.missing) }
            switch info.kind {
            case .link:
                links += 1
                guard links <= maxLinks else { return .failure(.loop) }
                guard budget.take() else { return .failure(.budget) }
                guard let target = fs.readlink(candidate), !target.isEmpty, target.utf8.count <= ResultPaths.maxBytes,
                      ResultPaths.characterRefusal(target) == nil else { return .failure(.refused) }
                let base = target.hasPrefix("/") ? target : (resolved.isEmpty ? "/" : resolved) + "/" + target
                let next = ResultPaths.lexical(pending.isEmpty ? base : base + "/" + pending.joined(separator: "/"))
                guard !pathGuard.refuses(next), next.utf8.count <= ResultPaths.maxBytes else { return .failure(.network) }
                pending = ResultPaths.components(next)
                resolved = ""
                last = nil
                if pending.isEmpty { return .failure(.notFolder) }
            case .directory:
                resolved = candidate
                last = info
            case .regular, .other:
                guard pending.isEmpty else { return .failure(.notFolder) }
                resolved = candidate
                last = info
            }
        }
        guard let last else { return .failure(.missing) }
        return .success((resolved, last))
    }
}
