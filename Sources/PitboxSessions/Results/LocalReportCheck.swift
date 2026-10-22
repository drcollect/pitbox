import Darwin
import Foundation
import PitboxKit

/// What the result checks take from the outside world, so tests run on made-up folders with a
/// recording fake filesystem and clock.
struct ResultEnvironment: Sendable {
    /// The user's home folder and `$TMPDIR` (allowed roots).
    var home: String
    var temporaryDirectory: String
    /// Files must belong to this user.
    var owner: uid_t
    var fileSystem: ResultFileSystem
    /// The preview was verified script-free on this macOS: web documents get it. False: Show in Finder only.
    var webPreview: Bool
    /// The file checks' time per session and pass (`CodeTuning.fileCheckBudget`) and the clock that measures it.
    var budgetSeconds: TimeInterval
    var clock: @Sendable () -> TimeInterval
    /// The configured dashboard sites: their links are the dashboards' own, never counted as "other links".
    var dashboardSites: CodeDashboardSites

    init(home: String, temporaryDirectory: String, owner: uid_t, fileSystem: ResultFileSystem, webPreview: Bool,
         budgetSeconds: TimeInterval = CodeTuning.fileCheckBudget, clock: @escaping @Sendable () -> TimeInterval = { MonotonicClock.now() },
         dashboardSites: CodeDashboardSites = .none) {
        self.home = home; self.temporaryDirectory = temporaryDirectory; self.owner = owner; self.fileSystem = fileSystem
        self.webPreview = webPreview; self.budgetSeconds = budgetSeconds; self.clock = clock
        self.dashboardSites = dashboardSites
    }

    /// This Mac: the real home and temporary folders, this user, `lstat` and `readlink`.
    static func live(webPreview: Bool = CodeWebPreview.isScriptFree, dashboardSites: CodeDashboardSites = .none) -> ResultEnvironment {
        ResultEnvironment(home: NSHomeDirectory(), temporaryDirectory: NSTemporaryDirectory(), owner: getuid(),
                          fileSystem: LiveResultFileSystem(), webPreview: webPreview, dashboardSites: dashboardSites)
    }

    var rootsMaker: ResultRootsMaker {
        ResultRootsMaker(home: ResultPaths.lexical(home), temporaryDirectory: ResultPaths.lexical(temporaryDirectory), fs: fileSystem)
    }

    func budget() -> ResultCheckBudget { ResultCheckBudget(seconds: budgetSeconds, clock: clock) }
}

/// A path a work handed over (`SendUserFile`) or wrote (Write, Edit) that the final reply names, before any check.
/// Session text: never logged.
struct ResultFileCandidate: Equatable, Sendable {
    var path: String
    /// `.handedOver` or `.written`.
    var origin: CodeResult.Origin
    var toolUseID: String?
    var at: Date?
}

/// Why a file result cannot be opened at the click: "the file changed after you looked".
enum ResultRecheckFailure: Error, Equatable, Sendable {
    case changed
    var words: String { "the file changed after you looked" }
}

/// The checks for files on this Mac, in this order: the string rules (no filesystem call before them: `~`
/// expanded, `.` and `..` resolved, printable ASCII only, an allowed root, never a network path); then on disk, within
/// `CodeTuning.fileCheckBudget` and for at most `CodeTuning.fileCandidatesMax` candidates: the real path (no link
/// followed into a refused place), the same roots again on it, a regular file with one link of the user's, and the type
/// and name rules on the resolved name. Device and inode are kept for the click.
struct LocalReportCheck {
    let environment: ResultEnvironment

    /// Host words.
    static let networkNote = "not checked: network path"

    /// The results for `candidates` of a session working in `cwd`, in order: buttons for files that pass, peek-only
    /// lines for the ones that do not (with "not checked: network path" for network paths). Candidates beyond the
    /// budget or `fileCandidatesMax` are given up.
    func results(for candidates: [ResultFileCandidate], cwd: String?, budget: ResultCheckBudget) -> [CodeResult] {
        let home = ResultPaths.lexical(environment.home)
        var folder: String?
        var cwdIsNetwork = false
        if let cwd {
            switch ResultPaths.normalize(cwd, home: home, folder: nil) {
            case .success(let path): folder = path; cwdIsNetwork = ResultPaths.isNetwork(path)
            case .failure: cwdIsNetwork = true
            }
        }
        var roots: ResultPathRoots?
        var out: [CodeResult] = []
        for candidate in candidates.prefix(CodeTuning.fileCandidatesMax) {
            // 1. Strings only.
            guard case .success(let path) = ResultPaths.normalize(candidate.path, home: home, folder: folder) else { continue }
            if cwdIsNetwork || ResultPaths.isNetwork(path) {
                out.append(peek(candidate, path: path, note: Self.networkNote))
                continue
            }
            // 2. The session's roots (the filesystem sees only these folders), once.
            let sessionRoots = roots ?? environment.rootsMaker.make(cwd: folder, budget: budget)
            roots = sessionRoots
            guard ResultPathRules.allowsLexically(path, origin: candidate.origin, roots: sessionRoots) else {
                out.append(peek(candidate, path: path, note: nil))
                continue
            }
            // 3. On disk.
            switch ResultRealPath.resolve(path, fs: environment.fileSystem, budget: budget) {
            case .failure(.budget):
                return out
            case .failure:
                out.append(peek(candidate, path: path, note: nil))
            case .success(let resolved):
                guard let result = fileResult(candidate, resolved: resolved, roots: sessionRoots) else {
                    out.append(peek(candidate, path: path, note: nil))
                    continue
                }
                out.append(result)
            }
            if budget.isSpent { return out }
        }
        return out
    }

    /// The click-time re-check: every rule again on the resolved path, which must still resolve
    /// to itself and be the file (device and inode) seen when the result was made, of the same kind. The URL opens only
    /// that path.
    func recheck(_ result: CodeResult, cwd: String?) -> Result<URL, ResultRecheckFailure> {
        guard let path = result.path, let device = result.device, let inode = result.inode,
              result.kind == .document || result.kind == .webDocument || result.kind == .otherFile,
              result.origin == .handedOver || result.origin == .written else { return .failure(.changed) }
        let home = ResultPaths.lexical(environment.home)
        guard case .success(let lexical) = ResultPaths.normalize(path, home: home, folder: nil), lexical == path,
              !ResultPaths.isNetwork(path) else { return .failure(.changed) }
        var folder: String?
        if let cwd {
            guard case .success(let normalized) = ResultPaths.normalize(cwd, home: home, folder: nil),
                  !ResultPaths.isNetwork(normalized) else { return .failure(.changed) }
            folder = normalized
        }
        let budget = ResultCheckBudget(seconds: 0.5, clock: environment.clock)
        let roots = environment.rootsMaker.make(cwd: folder, budget: budget)
        let candidate = ResultFileCandidate(path: path, origin: result.origin, toolUseID: result.toolUseID, at: result.at)
        guard ResultPathRules.allowsLexically(path, origin: result.origin, roots: roots),
              case .success(let resolved) = ResultRealPath.resolve(path, fs: environment.fileSystem, budget: budget),
              resolved.path == path, let again = fileResult(candidate, resolved: resolved, roots: roots),
              again.kind == result.kind, again.device == device, again.inode == inode else { return .failure(.changed) }
        return .success(URL(fileURLWithPath: path))
    }

    /// A button for a resolved candidate, or nil when the real path or the file fails a rule.
    private func fileResult(_ candidate: ResultFileCandidate, resolved: (path: String, stat: ResultFileStat),
                            roots: ResultPathRoots) -> CodeResult? {
        let stat = resolved.stat
        guard ResultPathRules.allowsResolved(resolved.path, origin: candidate.origin, roots: roots), stat.kind == .regular,
              stat.links == 1, stat.owner == environment.owner, let name = ResultPaths.lastComponent(resolved.path) else {
            return nil
        }
        let kind: CodeResult.Kind
        switch ResultFileTypes.kind(ofFileName: name, webPreview: environment.webPreview) {
        case .document: kind = .document
        case .webDocument: kind = .webDocument
        case .other: kind = .otherFile
        }
        return CodeResult(kind: kind, origin: candidate.origin, path: resolved.path, label: name, device: stat.device,
                          inode: stat.inode, toolUseID: candidate.toolUseID, at: candidate.at)
    }

    /// Peek text only: the path as made lexical, never a button.
    private func peek(_ candidate: ResultFileCandidate, path: String, note: String?) -> CodeResult {
        CodeResult(kind: .mentionedPath, origin: candidate.origin, path: path, label: path, toolUseID: candidate.toolUseID,
                   at: candidate.at, note: note)
    }
}
