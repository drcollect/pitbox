import Darwin
import Foundation
import PitboxKit

/// The results deriver (order 200, after the work of Running and ETA): each followed session's results and the count
/// of other links of its final reply, from the turn digest and, for local files, `lstat` and `readlink` under the
/// session's allowed roots within `CodeTuning.fileCheckBudget`. The output is reused while the digest (transcript lines
/// and session file) and the session's place stay the same; a file that changes later is caught by the click-time
/// re-check. For SSH sessions it tells the result fetches' click-time check where the session's files are.
final class ResultsDeriver: CodeSessionDeriver {
    let label = "results"
    let order = CodeDeriveOrder.results

    private struct Key: Equatable {
        var digestVersion: Int
        var index: Int
        var place: CommandSessionFacts.Place
        var cwd: String?
        var sshHost: String?
    }

    private let extractor: ResultExtractor
    private let fetchChecks: CodeResultFetchChecker?
    private var cache: [String: (key: Key, output: ResultOutput)] = [:]
    private var indexes: [String: Int] = [:]

    init(environment: ResultEnvironment, fetchChecks: CodeResultFetchChecker?) {
        extractor = ResultExtractor(environment: environment)
        self.fetchChecks = fetchChecks
    }

    func derive(_ input: CodeDeriveInput, into fields: inout CodeDerivedFields) {
        let session = input.snapshot
        let key = Key(digestVersion: input.digestVersion, index: session.index, place: session.place, cwd: session.cwd,
                      sshHost: session.sshHost)
        let output: ResultOutput
        if let cached = cache[session.id], cached.key == key {
            output = cached.output
        } else {
            output = extractor.extract(session, digest: input.digest, now: input.now)
            cache[session.id] = (key, output)
        }
        fields.results = output.results
        fields.otherLinkCount = output.otherLinkCount
        if let previous = indexes[session.id], previous != session.index { fetchChecks?.unregister(sessionIndex: previous) }
        indexes[session.id] = session.index
        guard let fetchChecks else { return }
        if session.place == .ssh, let transcript = input.transcript, let sessionFile = input.sessionFile {
            fetchChecks.register(CodeResultFetchChecker.Session(transcript: transcript, sessionFile: sessionFile, owner: input.owner),
                                 sessionIndex: session.index)
        } else {
            fetchChecks.unregister(sessionIndex: session.index)
        }
    }

    func sessionLeft(_ sessionID: String) {
        cache[sessionID] = nil
        if let index = indexes.removeValue(forKey: sessionID) { fetchChecks?.unregister(sessionIndex: index) }
    }
}

public extension CodeDeriverSet {
    /// Results: what each followed session's work produced or handed over: artifacts, files on this Mac
    /// (checked under the allowed roots), files on the server and local previews. `fetchChecks` learns where SSH
    /// sessions' files are, for the click-time check of "⤓ Fetch …"; hand the same object to the block as `freshness`.
    /// `dashboardSites` (built once at start from the settings): links to them are the dashboards' own, never counted
    /// as "other links".
    static func results(fetchChecks: CodeResultFetchChecker?, dashboardSites: CodeDashboardSites = .none) -> CodeDeriverSet {
        CodeDeriverSet(perSession: [ResultsDeriver(environment: .live(dashboardSites: dashboardSites), fetchChecks: fetchChecks)])
    }

    /// Results without the result fetches' click-time check: the engine's own checker answers `unknown` for them (its
    /// default), so a Fetch file sheet opened from a server file result starts nothing.
    static var results: CodeDeriverSet { results(fetchChecks: nil) }
}
