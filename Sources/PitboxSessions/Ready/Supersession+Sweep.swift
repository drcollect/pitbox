import Foundation
import PitboxKit

/// Many replies of one digest judged at once (what came after each reply). Judging each reply on
/// its own reads every turn after it again, and builds the first lines of every newer reply: a fleet session's digest
/// holds up to 200 notice turns whose replies all stay earlier offers (background updates never drop one), so a parse
/// cost the square of that (measured: 10-70 ms a pass in use, over a second for 200 turns). Here the turns are summed
/// once, from the newest back, and each reply takes the sums of the turns after it; only the at most 4 replies the
/// verdict lists get their first lines.
extension OfferSupersession {
    /// One reply to judge: its uuid, when it was written, and the session file's facts.
    struct Query: Hashable, Sendable {
        var replyUUID: String
        var replyTime: Date
        var session: SessionFacts
    }

    /// The verdicts of `queries`, in their order, each exactly what judging it alone gives: one pass over the digest's
    /// turns from the newest back to the oldest reply asked about, every item looked at once. `work` grows by the
    /// turns and items looked at and the first lines built (tests bound it).
    static func evaluate(_ queries: [Query], in digest: CodeTurnDigest, work: inout Int) -> [Verdict] {
        let turns = digest.turns
        var verdicts = [Verdict](repeating: .notFound, count: queries.count)
        guard !queries.isEmpty, !turns.isEmpty else { return verdicts }
        let finished = finishedTurns(in: digest)
        work += turns.count
        var places: [Int: [(position: Int, unfinishedByMidTurn: Bool)]] = [:]
        for (position, query) in queries.enumerated() {
            guard let found = replyTurn(query.replyUUID, in: digest, finished: finished, midTurn: query.session.midTurn)
            else { continue }
            places[found.index, default: []].append((position, found.unfinishedByMidTurn))
        }
        guard let oldest = places.keys.min() else { return verdicts }

        var after = TurnsAfter(digest: digest)
        var index = turns.count - 1
        while true {
            for place in places[index] ?? [] {
                verdicts[place.position] = after.verdict(queries[place.position], at: index,
                                                         unfinishedByMidTurn: place.unfinishedByMidTurn, work: &work)
            }
            guard index > oldest else { break }
            if after.newerReplies > CodeTuning.newerRepliesMax {
                // Every older reply has at least these newer replies: dropped, and nothing more to read.
                for (older, list) in places where older < index {
                    for place in list { verdicts[place.position] = .dropped }
                }
                break
            }
            after.add(index, work: &work)
            index -= 1
        }
        return verdicts
    }

    /// What the turns after some index hold, summed from the newest turn back (`add` the next older turn).
    private struct TurnsAfter {
        let digest: CodeTurnDigest
        /// Finished replies to turns of the user's or another session's (an unknown origin counts as the user's).
        var newerReplies = 0
        /// Finished replies to background-task notices.
        var updates = 0
        /// The turns of those replies, newest first (all of them: past `newerRepliesMax` every older reply drops).
        var answers: [Int] = []
        /// The turns of the 2 newest background replies, newest first.
        var background: [Int] = []
        var latestAt: Date?
        var readWeb = false
        /// Tasks whose ending notice came (`finishedTaskKey`).
        var tasks = Set<String>()
        /// Files edited or written, in the order they were first changed.
        var paths = FirstSeenOrder()
        /// First lines built so far, by turn.
        var heads: [Int: String] = [:]

        init(digest: CodeTurnDigest) { self.digest = digest }

        mutating func add(_ index: Int, work: inout Int) {
            let turn = digest.turns[index]
            consider(turn.startedAt)
            consider(turn.finishedAt)
            if turn.readWeb { readWeb = true }
            var changed: [String] = []
            for item in turn.items {
                switch item {
                case .toolUse(let tool):
                    if OfferSupersession.fileTools.contains(tool.name), let path = tool.filePath, !path.isEmpty {
                        changed.append(path)
                    }
                case .notice(let notice):
                    if let key = OfferSupersession.finishedTaskKey(notice) { tasks.insert(key) }
                case .text, .toolResult:
                    break
                }
            }
            work += turn.items.count + 1
            paths.putFirst(changed)
            guard turn.isFinished else { return }
            if turn.origin == .taskNotification {
                updates += 1
                if background.count < 2 { background.append(index) }
            } else {
                newerReplies += 1
                answers.append(index)
            }
        }

        private mutating func consider(_ date: Date?) {
            guard let date else { return }
            if latestAt.map({ date > $0 }) ?? true { latestAt = date }
        }

        /// The verdict for `query`, whose reply is the turn at `index` (every turn after it added, none before).
        mutating func verdict(_ query: Query, at index: Int, unfinishedByMidTurn: Bool, work: inout Int) -> Verdict {
            if newerReplies > CodeTuning.newerRepliesMax { return .dropped }
            let turns = digest.turns
            let turn = turns[index]
            // Notices that arrived in the reply's own turn after its last assistant item (a queued notice, then its turn).
            var finishedTasks = tasks.count
            if let last = turn.items.lastIndex(where: { OfferSupersession.isAssistant($0, uuid: query.replyUUID) }) {
                var own = Set<String>()
                for case .notice(let notice) in turn.items[(last + 1)...] {
                    if let key = OfferSupersession.finishedTaskKey(notice), !tasks.contains(key), own.insert(key).inserted {
                        finishedTasks += 1
                    }
                }
            }
            work += turn.items.count
            let hasNewer = index < turns.count - 1
            let latest = turns.last
            let newerRunning = hasNewer && latest?.isFinished == false
            // An SSH mirror lags: a session file whose lastActivityAt moved more than the slack past everything the mirror
            // shows says the session works on a turn whose lines have not arrived.
            let visibleUntil = [latestAt, query.replyTime].compactMap { $0 }.max() ?? query.replyTime
            let slackWorking = query.session.isSSH && (query.session.lastActivityAt.map {
                $0.timeIntervalSince(visibleUntil) > CodeTuning.sshMidTurnSlack
            } ?? false)
            let working = newerRunning || unfinishedByMidTurn || slackWorking
            guard hasNewer || working else { return .fresh }

            var latestAt = self.latestAt
            if unfinishedByMidTurn || slackWorking, let activity = query.session.lastActivityAt,
               latestAt.map({ activity > $0 }) ?? true {
                latestAt = activity
            }
            var unanswered: String?
            if let latest, newerRunning, latest.origin == .human { unanswered = latest.askedHead }
            let listed = answers.reversed().map { reply($0, replyTime: query.replyTime, work: &work) }
                + background.reversed().map { reply($0, replyTime: query.replyTime, work: &work) }
            let replies = listed.sorted { $0.at < $1.at }.prefix(CodeTuning.newerRepliesShown)
            let names = paths.first(OfferSupersession.filesListed).map { ($0 as NSString).lastPathComponent }
            return .superseded(CommandOffer.Supersession(
                newerReplies: newerReplies, newerBackgroundUpdates: updates, latestAt: latestAt ?? query.replyTime,
                replies: Array(replies), unansweredMessageHead: unanswered, sessionIsWorking: working,
                readWebSince: readWeb, filesChangedSince: names, filesChangedCount: paths.count,
                backgroundTasksFinishedSince: finishedTasks))
        }

        /// The newer reply of the turn at `index`, its first lines built once.
        private mutating func reply(_ index: Int, replyTime: Date, work: inout Int) -> CommandOffer.Supersession.NewerReply {
            let turn = digest.turns[index]
            let head: String
            if let known = heads[index] {
                head = known
            } else {
                head = OfferSupersession.head(of: turn)
                heads[index] = head
                work += 1
            }
            return .init(at: turn.finishedAt ?? turn.lastEntryAt ?? replyTime, origin: turn.origin, head: head)
        }
    }
}

/// Distinct strings in the order they first occur, built from the back: `putFirst` puts the next older turn's strings
/// in front (moving any seen later), at a constant cost per string.
struct FirstSeenOrder {
    private var ids: [String: Int] = [:]
    private var names: [String] = []
    private var next: [Int] = []
    private var previous: [Int] = []
    private var head = -1

    /// How many distinct strings.
    var count: Int { names.count }

    /// Puts `items` (one turn's, in its order) before everything: each at its first occurrence among them.
    mutating func putFirst(_ items: [String]) {
        guard !items.isEmpty else { return }
        var seen = Set<String>()
        let distinct = items.filter { seen.insert($0).inserted }
        for item in distinct.reversed() { moveToFront(item) }
    }

    /// The first `limit` strings.
    func first(_ limit: Int) -> [String] {
        var out: [String] = []
        var id = head
        while id >= 0, out.count < limit {
            out.append(names[id])
            id = next[id]
        }
        return out
    }

    private mutating func moveToFront(_ item: String) {
        let id: Int
        if let known = ids[item] {
            guard known != head else { return }
            id = known
            let before = previous[id], after = next[id]
            if before >= 0 { next[before] = after }
            if after >= 0 { previous[after] = before }
        } else {
            id = names.count
            ids[item] = id
            names.append(item)
            next.append(-1)
            previous.append(-1)
        }
        next[id] = head
        previous[id] = -1
        if head >= 0 { previous[head] = id }
        head = id
    }
}
