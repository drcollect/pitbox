import Foundation
import PitboxKit

/// The git toplevel of a folder: the nearest folder at or above it that holds a `.git` folder
/// or file (a worktree's `.git` is a file), found by walking up from that folder only, one `lstat` of `<folder>/.git` a
/// level, at most `CodeTuning.repoSearchDepth` levels. It never goes above the home folder, never above the top of a
/// temporary folder the start lies in, never to `/`, and never into a network path. Separate worktrees have separate
/// toplevels, so their files never count as one.
enum ResultRepoRoot {
    /// The toplevel of `folder`, a real path (no link in it, so `lstat` follows none on the way), or nil.
    /// - Parameters:
    ///   - home: the home folder's real path; it and its parents above are never passed.
    ///   - tops: real paths of the temporary folders: the walk ends at the one holding `folder`.
    static func find(from folder: String, home: String, tops: [String], fs: ResultFileSystem,
                     budget: ResultCheckBudget) -> String? {
        var current = folder
        let pathGuard = fs.networkGuard
        for _ in 0..<CodeTuning.repoSearchDepth {
            guard current != "/", !pathGuard.refuses(current), !pathGuard.refuses(current + "/.git") else { return nil }
            // Above the home folder: `/Users` and `/` are never looked at.
            if current != home, ResultPaths.isInside(home, current) { return nil }
            guard budget.take() else { return nil }
            if let info = fs.lstat(current + "/.git"), info.kind == .directory || info.kind == .regular { return current }
            if current == home || tops.contains(current) { return nil }
            current = parent(of: current)
        }
        return nil
    }

    /// `/a/b` → `/a`; `/a` → `/`.
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}

/// The allowed roots of one session, resolved on disk once: the home folder, the temporary folders and, for a
/// local session, its `cwd` (when it passes the string rules and is no network path) and the `cwd`'s git toplevel.
/// Only these folders are looked at here, never a candidate.
struct ResultRootsMaker {
    let home: String
    let temporaryDirectory: String
    let fs: ResultFileSystem

    /// The roots for a session working in `cwd` (nil: SSH, unknown place, or no folder).
    func make(cwd: String?, budget: ResultCheckBudget) -> ResultPathRoots {
        let homeRoot = root(home, budget: budget)
        let temporary = [temporaryDirectory, "/tmp", "/private/tmp"].map { root($0, budget: budget) }
        var roots = ResultPathRoots(home: homeRoot, temporary: temporary, cwd: nil, toplevel: nil, cwdIsNetwork: false)
        guard let cwd else { return roots }
        guard case .success(let folder) = ResultPaths.normalize(cwd, home: home, folder: nil),
              !fs.networkGuard.refuses(folder) else {
            roots.cwdIsNetwork = true
            return roots
        }
        let cwdRoot = root(folder, budget: budget)
        roots.cwd = cwdRoot
        if let real = cwdRoot.real, let top = ResultRepoRoot.find(from: real, home: homeRoot.real ?? homeRoot.lexical,
                                                                    tops: temporary.compactMap(\.real), fs: fs, budget: budget) {
            roots.toplevel = ResultPathRoots.Root(lexical: top, real: top)
        }
        return roots
    }

    /// One folder as written (made lexical) and as its real path when it resolves to a folder.
    private func root(_ path: String, budget: ResultCheckBudget) -> ResultPathRoots.Root {
        let lexical = ResultPaths.lexical(path)
        guard ResultPaths.characterRefusal(lexical) == nil, !fs.networkGuard.refuses(lexical),
              case .success(let resolved) = ResultRealPath.resolve(lexical, fs: fs, budget: budget),
              resolved.stat.kind == .directory else {
            return ResultPathRoots.Root(lexical: lexical, real: nil)
        }
        return ResultPathRoots.Root(lexical: lexical, real: resolved.path)
    }
}
