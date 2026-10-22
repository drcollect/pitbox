import Foundation
import PitboxKit

/// The work whose results show: the latest work (from the latest turn of the user's or another session's, with the
/// notice turns since; the current turn when that start is over 12 hours old or missing) once its last turn finished;
/// while a newer work runs, the one before it, because a newer *finished* work replaces the results. Its final reply is
/// the final reply of its last turn.
struct ResultWork: Equatable {
    var turns: [CodeTurnDigest.Turn]
    var reply: [CodeTurnDigest.Text]
    var startedAt: Date?
    /// When the next work started (results of an earlier work while a newer one runs); nil for the latest work.
    var endedAt: Date?

    var replyText: String { reply.map(\.text).joined(separator: "\n\n") }
    var replyAt: Date? { reply.last?.at ?? turns.last?.finishedAt }

    static func locate(_ digest: CodeTurnDigest, now: Date) -> ResultWork? {
        let turns = digest.turns
        guard let last = turns.indices.last else { return nil }
        let start = workStart(turns, through: last, now: now)
        if turns[last].isFinished { return make(turns, start...last, endedAt: nil) }
        guard start > 0, turns[start - 1].isFinished else { return nil }
        let previous = workStart(turns, through: start - 1, now: now)
        return make(turns, previous...(start - 1), endedAt: turns[start].startedAt)
    }

    /// The latest turn of the user's or another session's at or before `end`, unless it is over `CodeTuning.workMaxAge`
    /// old; else `end` itself.
    private static func workStart(_ turns: [CodeTurnDigest.Turn], through end: Int, now: Date) -> Int {
        guard let index = turns[...end].lastIndex(where: { $0.origin == .human || $0.origin == .peer }) else { return end }
        if let at = turns[index].startedAt, now.timeIntervalSince(at) > CodeTuning.workMaxAge { return end }
        return index
    }

    private static func make(_ turns: [CodeTurnDigest.Turn], _ range: ClosedRange<Int>, endedAt: Date?) -> ResultWork {
        let slice = Array(turns[range])
        let started = slice.first?.startedAt ?? slice.first?.lastEntryAt
        return ResultWork(turns: slice, reply: slice.last?.finalReply ?? [], startedAt: started, endedAt: endedAt)
    }

    /// `date` lies inside the work.
    func contains(_ date: Date?) -> Bool {
        guard let date, let startedAt else { return false }
        return date >= startedAt && (endedAt.map { date < $0 } ?? true)
    }

    /// Every item of the work's turns, in order.
    var items: [CodeTurnDigest.Item] { turns.flatMap(\.items) }
}

/// What the results deriver writes into the snapshot: `results` and `otherLinkCount`.
struct ResultOutput: Equatable, Sendable {
    var results: [CodeResult] = []
    var otherLinkCount = 0
    /// The session has server files: the click-time check needs its paths.
    var hasServerFiles: Bool { results.contains { $0.kind == .serverFile } }
}

/// Finds a session's results in its turn digest, in this order: artifacts (the session file's
/// `publishedArtifacts` updated inside the work, then the work's `Artifact` tool results), files handed over
/// (`SendUserFile`), files the work wrote that the final reply names, then links of the final reply (local previews and
/// artifacts not found yet). At most `CodeTuning.maxResults` buttons; the same address or path counts once. The peek
/// also gets up to 5 earlier artifacts and up to 4 other path-like words of the reply (never buttons). Only the file
/// checks touch the filesystem (`LocalReportCheck`, under the roots and the budget).
struct ResultExtractor {
    let environment: ResultEnvironment

    static let earlierArtifactsMax = 5
    static let mentionedPathsMax = 4

    func extract(_ snapshot: CodeSessionSnapshot, digest: CodeTurnDigest, now: Date) -> ResultOutput {
        var buttons = ResultList(limit: CodeTuning.maxResults)
        var earlier = ResultList(limit: Self.earlierArtifactsMax)
        var mentioned = ResultList(limit: Self.mentionedPathsMax)
        let work = ResultWork.locate(digest, now: now)

        // 1. Artifacts (the session file lists them newest first). Earlier ones are those published before the work.
        for artifact in digest.publishedArtifacts {
            guard let url = ResultLinks.artifactURL(artifact.url) else { continue }
            if let work, work.contains(artifact.updatedAt) {
                buttons.add(CodeResult(kind: .artifact, origin: .publishedArtifact, url: url, label: "artifact", at: artifact.updatedAt))
            } else if Self.isEarlier(artifact.updatedAt, than: work) {
                earlier.add(CodeResult(kind: .earlierArtifact, origin: .publishedArtifact, url: url, label: "artifact",
                                       at: artifact.updatedAt))
            }
        }
        guard let work else {
            return ResultOutput(results: buttons.items + earlier.items, otherLinkCount: 0)
        }
        for case .toolResult(let result) in work.items {
            guard let raw = result.artifactURL, let url = ResultLinks.artifactURL(raw) else { continue }
            buttons.add(CodeResult(kind: .artifact, origin: .artifactTool, url: url, label: "artifact", toolUseID: result.toolUseID,
                                   at: result.at))
        }

        // 2-3. Files handed over, then files written that the reply names.
        let reply = work.replyText
        var candidates: [ResultFileCandidate] = []
        for case .toolUse(let tool) in work.items where tool.name == "SendUserFile" {
            for file in tool.files { candidates.append(ResultFileCandidate(path: file, origin: .handedOver, toolUseID: tool.id, at: tool.at)) }
        }
        for case .toolUse(let tool) in work.items {
            guard let path = tool.filePath, ResultReplyNames.names(path, in: reply, cwd: snapshot.cwd),
                  !candidates.contains(where: { $0.path == path }) else { continue }
            candidates.append(ResultFileCandidate(path: path, origin: .written, toolUseID: tool.id, at: tool.at))
        }
        switch snapshot.place {
        case .local:
            let checked = LocalReportCheck(environment: environment)
                .results(for: candidates, cwd: snapshot.cwd, budget: environment.budget())
            for result in checked {
                if result.kind == .mentionedPath { mentioned.add(result) } else { buttons.add(result) }
            }
        case .ssh:
            for result in ResultServerFiles.results(for: candidates, alias: snapshot.sshHost) { buttons.add(result) }
        case .unknown:
            break
        }

        // 4. Links of the final reply.
        var others = Set<String>()
        for raw in ResultLinks.find(in: reply) {
            switch ResultLinks.classify(raw, dashboardSites: environment.dashboardSites) {
            case .preview(let url, let label):
                switch snapshot.place {
                case .local: buttons.add(CodeResult(kind: .preview, origin: .replyLink, url: url, label: label, at: work.replyAt))
                case .ssh: buttons.add(CodeResult(kind: .serverPreview, origin: .replyLink, url: url, label: label, at: work.replyAt))
                case .unknown: others.insert(raw)
                }
            case .artifact(let url):
                buttons.add(CodeResult(kind: .artifact, origin: .replyLink, url: url, label: "artifact", at: work.replyAt))
            case .dashboard:
                continue
            case .other:
                others.insert(raw)
            }
        }

        // Peek text: other path-like words of the reply.
        let known = Set((buttons.items + mentioned.items).compactMap(\.path))
        for word in ResultReplyNames.mentionedPaths(in: reply, limit: Self.mentionedPathsMax * 2) {
            let normalized = (try? ResultPaths.normalize(word, home: environment.home, folder: nil).get()) ?? word
            guard !known.contains(normalized), !known.contains(word) else { continue }
            mentioned.add(CodeResult(kind: .mentionedPath, origin: .replyText, path: word, label: word, at: work.replyAt))
        }
        earlier.removeAll { item in buttons.items.contains { $0.url == item.url } }
        return ResultOutput(results: buttons.items + earlier.items + mentioned.items, otherLinkCount: others.count)
    }

    /// Published before the work started (or with no time, or with no work at all).
    private static func isEarlier(_ date: Date?, than work: ResultWork?) -> Bool {
        guard let work, let start = work.startedAt, let date else { return true }
        return date < start
    }
}

/// Results in order, each address or path once, at most `limit`.
struct ResultList {
    let limit: Int
    private(set) var items: [CodeResult] = []
    private var seen = Set<String>()

    init(limit: Int) { self.limit = limit }

    mutating func add(_ result: CodeResult) {
        guard items.count < limit, seen.insert(Self.key(result)).inserted else { return }
        items.append(result)
    }

    mutating func removeAll(where shouldRemove: (CodeResult) -> Bool) { items.removeAll(where: shouldRemove) }

    /// The same address or path counts once, whatever it was found as.
    private static func key(_ result: CodeResult) -> String {
        if let url = result.url { return "u:" + url.absoluteString }
        if let path = result.path { return "p:" + path }
        return "l:" + result.label
    }
}
