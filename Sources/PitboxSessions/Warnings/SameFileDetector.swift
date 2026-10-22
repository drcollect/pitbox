import Foundation
import PitboxKit

/// "Same file": two working sessions editing one file of one repository. From the Edit, Write,
/// MultiEdit and NotebookEdit tool_uses of all followed sessions; a tool_use a fork copied from its parent never counts
/// (the engine marks ids found in two digests). Two sessions collide on a file when both are running or in
/// Needs you, their latest edits of it lie within `CodeTuning.sameFileWindow` (30 min) of each other, and one of them
/// is within the last 30 minutes; it clears when either stops running or neither has edited the file for 30 minutes.
/// Both get "⚠ Also edited by “<headline>”: src/checkout.tsx". OK silences that pair and file for 2 hours.
///
/// **The key** of a file: for a local session the path checked as a string under the result checks' allowed roots
/// (`ResultPathRoots`) first (no filesystem call outside them, none for a network path), then real-pathed when it
/// exists, its git toplevel giving the shown path (relative to it, at most its last 2 parts); for an SSH session the
/// alias and the path as written, made lexical, with no filesystem call at all. The same path on two machines is never
/// the same file, and separate worktrees have separate real paths.
struct SameFileDetector {
    /// One session's edits of one file, as far as the collision needs them.
    struct Held: Equatable {
        var key: String
        var shown: String
        var earliest: Date
        var latest: Date
    }

    let environment: ResultEnvironment
    /// How long a resolved key is reused before the file is looked at again (a file written later may appear).
    static let keyLife: TimeInterval = 60

    private var keys: [String: (key: String, shown: String, at: Date)] = [:]

    init(environment: ResultEnvironment) { self.environment = environment }

    /// The files `session` edited since `now` minus twice the window, by key.
    mutating func held(by session: CodeCrossSessionInput, now: Date, budget: ResultCheckBudget) -> [String: Held] {
        let snapshot = session.snapshot
        let from = now.addingTimeInterval(-2 * CodeTuning.sameFileWindow)
        var out: [String: Held] = [:]
        var roots: ResultPathRoots?
        for case .toolUse(let tool) in session.digest.allItems {
            guard !tool.isCopied, let path = tool.filePath, path.hasPrefix("/"), let at = tool.at, at >= from, at <= now else { continue }
            guard let (key, shown) = fileKey(path, snapshot: snapshot, roots: &roots, now: now, budget: budget) else { continue }
            var held = out[key] ?? Held(key: key, shown: shown, earliest: at, latest: at)
            held.earliest = min(held.earliest, at)
            held.latest = max(held.latest, at)
            out[key] = held
        }
        return out
    }

    /// The key and the shown path of `path` edited by a session, or nil when it gives none (relative, network, outside
    /// the roots, another place, a link into a refused place, or the budget spent).
    private mutating func fileKey(_ path: String, snapshot: CodeSessionSnapshot, roots: inout ResultPathRoots?, now: Date,
                                  budget: ResultCheckBudget) -> (String, String)? {
        let home = ResultPaths.lexical(environment.home)
        switch snapshot.place {
        case .ssh:
            guard let alias = snapshot.sshHost, ResultServerFiles.isValidAlias(alias), ResultPaths.characterRefusal(path) == nil else {
                return nil
            }
            let lexical = ResultPaths.lexical(path)
            return ("ssh:\(alias):\(lexical)", Self.lastParts(ResultPaths.components(lexical)))
        case .unknown:
            return nil
        case .local:
            guard case .success(let lexical) = ResultPaths.normalize(path, home: home, folder: nil),
                  !ResultPaths.isNetwork(lexical) else { return nil }
            let cacheKey = (snapshot.cwd ?? "") + "\n" + lexical
            if let cached = keys[cacheKey], now.timeIntervalSince(cached.at) < Self.keyLife { return (cached.key, cached.shown) }
            if let cwd = snapshot.cwd, case .success(let folder) = ResultPaths.normalize(cwd, home: home, folder: nil),
               ResultPaths.isNetwork(folder) { return nil }
            let sessionRoots = roots ?? environment.rootsMaker.make(cwd: snapshot.cwd.flatMap {
                try? ResultPaths.normalize($0, home: home, folder: nil).get()
            }, budget: budget)
            roots = sessionRoots
            guard sessionRoots.handedRoots.contains(where: { $0.containsLexically(lexical) }), !budget.isSpent else { return nil }
            let real: String
            switch ResultRealPath.resolve(lexical, fs: environment.fileSystem, budget: budget) {
            case .success(let resolved):
                guard resolved.stat.kind == .regular else { return nil }
                real = resolved.path
            case .failure(.missing):
                // Not there (yet, or any more): its folder's real path and the name, when the folder resolves.
                guard let name = ResultPaths.lastComponent(lexical),
                      case .success(let parent) = ResultRealPath.resolve(ResultRepoRoot.parent(of: lexical), fs: environment.fileSystem,
                                                                         budget: budget),
                      parent.stat.kind == .directory else { return nil }
                real = (parent.path == "/" ? "" : parent.path) + "/" + name
            case .failure:
                return nil
            }
            guard sessionRoots.handedRoots.contains(where: { $0.containsResolved(real) }) else { return nil }
            let folder = ResultRepoRoot.parent(of: real)
            let top = ResultRepoRoot.find(from: folder, home: sessionRoots.home.real ?? home,
                                          tops: sessionRoots.temporary.compactMap(\.real), fs: environment.fileSystem, budget: budget)
            let below = top.flatMap { ResultPaths.remainder(real, below: $0) } ?? ResultPaths.components(real)
            let result = ("local:" + real, Self.lastParts(below))
            keys[cacheKey] = (result.0, result.1, now)
            return result
        }
    }

    /// At most the last 2 parts: "src/checkout.tsx".
    static func lastParts(_ parts: [String]) -> String { parts.suffix(2).joined(separator: "/") }

    /// Forgets resolved keys of a session's folder (it left the followed set).
    mutating func forget(cwd: String?) {
        let prefix = (cwd ?? "") + "\n"
        keys = keys.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Bounds the cache.
    mutating func prune(now: Date) {
        keys = keys.filter { now.timeIntervalSince($0.value.at) < Self.keyLife }
    }
}

/// The warnings' cross-session deriver (order 100): Same file over every followed session whose digest was read, after
/// the per-session derivers (it appends to their `warnings`). Logs `warning session=#3 kind=same_file` when one
/// appears.
final class SameFileDeriver: CodeCrossSessionDeriver {
    let label = "same-file"
    let order = CodeDeriveOrder.sameFile
    private var detector: SameFileDetector
    private var shown: [String: Set<String>] = [:]
    private var cwds: [String: String?] = [:]

    init(environment: ResultEnvironment) { detector = SameFileDetector(environment: environment) }

    func derive(_ sessions: [CodeCrossSessionInput], context: CodeCrossDeriveContext, into fields: inout [String: CodeDerivedFields]) {
        let now = context.now
        var found: [String: [CodeWarning]] = [:]
        if context.settings.warnings.sameFile {
            let budget = detector.environment.budget()
            let active = sessions.filter { Self.isActive($0.snapshot) }
            var held: [String: [String: SameFileDetector.Held]] = [:]
            for session in active {
                cwds[session.sessionID] = session.snapshot.cwd
                held[session.sessionID] = detector.held(by: session, now: now, budget: budget)
            }
            var deadlines: [String: Date] = [:]
            for (index, a) in active.enumerated() {
                for b in active[(index + 1)...] where a.sessionID != b.sessionID {
                    guard let collision = Self.collision(held[a.sessionID] ?? [:], held[b.sessionID] ?? [:], now: now) else { continue }
                    let rule = CodeWarningSilencer.sameFileRule(sessionIDs: [a.sessionID, b.sessionID], path: collision.shown)
                    let silencedA: [WarningSilenceRecord] = context.memory.read(.silenced, session: a.sessionID) ?? []
                    let silencedB: [WarningSilenceRecord] = context.memory.read(.silenced, session: b.sessionID) ?? []
                    guard !WarningSilenceRecord.covers(silencedA + silencedB, rule: rule, workStartedAt: nil, now: now) else { continue }
                    found[a.sessionID, default: []].append(CodeWarning(kind: .sameFile, since: collision.since, otherSessionID: b.sessionID,
                                                                       otherHeadline: b.snapshot.headline, path: collision.shown))
                    found[b.sessionID, default: []].append(CodeWarning(kind: .sameFile, since: collision.since, otherSessionID: a.sessionID,
                                                                       otherHeadline: a.snapshot.headline, path: collision.shown))
                    for id in [a.sessionID, b.sessionID] { deadlines[id] = min(deadlines[id] ?? .distantFuture, collision.endsAt) }
                }
            }
            for (id, deadline) in deadlines { fields[id, default: CodeDerivedFields()].deadlines.append(deadline) }
            detector.prune(now: now)
        }
        for session in sessions {
            let warnings = found[session.sessionID] ?? []
            if !warnings.isEmpty { fields[session.sessionID, default: CodeDerivedFields()].warnings.append(contentsOf: warnings) }
            let ids = Set(warnings.map(\.id))
            if !ids.subtracting(shown[session.sessionID] ?? []).isEmpty {
                CodeLog.info("warning session=#\(session.snapshot.index) kind=\(CodeWarning.Kind.sameFile.rawValue)")
            }
            shown[session.sessionID] = ids
        }
    }

    func sessionLeft(_ sessionID: String) {
        shown[sessionID] = nil
        if let cwd = cwds.removeValue(forKey: sessionID) { detector.forget(cwd: cwd) }
    }

    /// Running (working, maybe needs you, background tasks pending) or in Needs you.
    static func isActive(_ snapshot: CodeSessionSnapshot) -> Bool {
        [.working, .maybeNeedsYou, .needsYou].contains(snapshot.state) || snapshot.progress?.pendingBetweenTurns == true
    }

    /// The pair's shared file with the newest edit, when its two latest edits lie within the window of each other and
    /// the newer one within the window of `now`: what is shown, since when, and when it ends by itself.
    static func collision(_ a: [String: SameFileDetector.Held], _ b: [String: SameFileDetector.Held],
                          now: Date) -> (shown: String, since: Date, endsAt: Date)? {
        let window = CodeTuning.sameFileWindow
        var best: (shown: String, since: Date, endsAt: Date)?
        for (key, left) in a {
            guard let right = b[key] else { continue }
            let newest = max(left.latest, right.latest)
            guard now.timeIntervalSince(newest) < window, abs(left.latest.timeIntervalSince(right.latest)) <= window else { continue }
            let candidate = (shown: left.shown, since: max(left.earliest, right.earliest), endsAt: newest.addingTimeInterval(window))
            if best.map({ candidate.endsAt > $0.endsAt }) ?? true { best = candidate }
        }
        return best
    }
}
