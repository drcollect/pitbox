import Darwin
import Foundation
@testable import PitboxSessions
import PitboxKit

// Made-up folders and files only (created in a fresh temporary folder, then resolved), never the user's.

/// This Mac's filesystem, recording every path it is asked about; optionally slow (each call sleeps).
final class RecordingFileSystem: ResultFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let delay: TimeInterval
    private let live = LiveResultFileSystem()

    /// The network check the walks run under; nil: this Mac's (`NetworkPathGuard.recent()`).
    let guardOverride: NetworkPathGuard?

    init(delay: TimeInterval = 0, guard pathGuard: NetworkPathGuard? = nil) {
        self.delay = delay
        guardOverride = pathGuard
    }

    var networkGuard: NetworkPathGuard { guardOverride ?? .recent() }

    func lstat(_ path: String) -> ResultFileStat? {
        note(path)
        return live.lstat(path)
    }

    func readlink(_ path: String) -> String? {
        note(path)
        return live.readlink(path)
    }

    private func note(_ path: String) {
        lock.withLock { recorded.append(path) }
        if delay > 0 { usleep(useconds_t(delay * 1_000_000)) }
    }

    var calls: [String] { lock.withLock { recorded } }

    /// Some call named `path` or a path below it (ASCII case ignored, as the volume does).
    func touched(_ path: String) -> Bool {
        let wanted = path.lowercased()
        return calls.contains { $0.lowercased() == wanted || $0.lowercased().hasPrefix(wanted + "/") }
    }

    func reset() { lock.withLock { recorded = [] } }
}

/// A made-up home folder (with a repository and `~/.ssh`) and a made-up temporary folder below a fresh temporary
/// folder that is created first and then resolved.
final class ResultTree: @unchecked Sendable {
    let root: URL
    let home: URL
    let tmp: URL
    let repo: URL

    init(_ name: String = "results") {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = raw.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        tmp = root.appendingPathComponent("tmp", isDirectory: true)
        repo = home.appendingPathComponent("code/toy-cube", isDirectory: true)
        for folder in [home, tmp, repo, repo.appendingPathComponent(".git"), home.appendingPathComponent(".ssh"),
                       home.appendingPathComponent("Library")] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ text: String, _ path: String) -> URL {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        return url
    }

    func environment(_ fs: ResultFileSystem = RecordingFileSystem(), webPreview: Bool = true,
                     budget: TimeInterval = CodeTuning.fileCheckBudget) -> ResultEnvironment {
        ResultEnvironment(home: home.path, temporaryDirectory: tmp.path, owner: getuid(), fileSystem: fs, webPreview: webPreview,
                          budgetSeconds: budget, dashboardSites: .test)
    }
}

extension Result {
    /// The failure, nil on success (for results whose success value is not Equatable).
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

/// `realpath(3)` of a fixture (the form results carry: `/private/var/…` for `/var/…`).
func realPath(_ url: URL) -> String {
    guard let resolved = Darwin.realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// "Now" for result and warning fixtures: 2026-10-20 14:00:00 UTC.
let resultNow = Date(timeIntervalSince1970: 1_792_504_800)

/// A session snapshot for the results and warnings rules.
func resultSession(_ id: String = "local_r1", index: Int = 1, place: CommandSessionFacts.Place = .local, cwd: String? = nil,
                   sshHost: String? = nil, state: CodeSessionState = .reviewReady, headline: String = "Toy Cube · checkout \(secretWord)",
                   results: [CodeResult] = [], progress: CodeProgress? = nil, lastActivity: Date? = nil) -> CodeSessionSnapshot {
    CodeSessionSnapshot(id: id, index: index, profile: .a, headline: headline, title: headline, place: place, sshHost: sshHost,
                        cwd: cwd, state: state, lastActivity: lastActivity, progress: progress, results: results)
}

/// The digest of `lines` with the session-file facts the engine adds.
func resultDigest(_ lines: [String], published: [CodeTurnDigest.PublishedArtifact] = [], midTurn: Bool = false,
                  copied: Set<String> = [], lastGrowthAt: Date? = nil, lastActivityMovedAt: Date? = nil) -> CodeTurnDigest {
    digestTracker(lines, now: resultNow).digest.digest(midTurn: midTurn, lastGrowthAt: lastGrowthAt,
                                                       lastActivityMovedAt: lastActivityMovedAt, publishedArtifacts: published,
                                                       copied: copied)
}

/// Waits on the main actor (suspending, never parking a thread) until `condition` holds or `seconds` pass.
@MainActor
func onMain(_ seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = MonotonicClock.now() + seconds
    while !condition() {
        if MonotonicClock.now() > deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

/// `minutes` before `resultNow`.
func ago(_ minutes: Double) -> Date { resultNow.addingTimeInterval(-minutes * 60) }

/// A finished work: the user's message 20 minutes ago, `middle` lines, then a final reply `reply` 1 minute ago.
func finishedWork(_ middle: [String], reply: String, start: Double = 20) -> [String] {
    [Line.user("Make the \(secretWord) report", uuid: "u-work", at: ago(start))] + middle
        + [Line.text(reply, uuid: "a-final", at: ago(1))]
}

/// An `Artifact` tool_use and its result with `toolUseResult.url`.
func artifactCall(_ url: String, id: String, at: Date) -> [String] {
    [Line.toolUse("Artifact", id: id, uuid: "a-\(id)", at: at, input: ["file_path": "/x/\(secretWord).html"]),
     SeamLine.result(id, uuid: "r-\(id)", at: at, content: "published", toolUseResult: ["url": url, "status": "ok"])]
}

/// A Write tool_use of `path` and its result.
func writeCall(_ path: String, id: String, at: Date) -> [String] {
    [SeamLine.edit(path, id: id, uuid: "a-\(id)", at: at, tool: "Write"),
     SeamLine.result(id, uuid: "r-\(id)", at: at, content: "written")]
}

/// A `SendUserFile` tool_use of `files` and its result.
func sendCall(_ files: [String], id: String, at: Date) -> [String] {
    [SeamLine.sendUserFile(files, id: id, uuid: "a-\(id)", at: at), SeamLine.result(id, uuid: "r-\(id)", at: at, content: "sent")]
}
