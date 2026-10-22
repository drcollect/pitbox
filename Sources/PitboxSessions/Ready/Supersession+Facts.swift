import Foundation
import PitboxKit

/// What happened after an offer's reply, read from a turn digest. One
/// definition for the parse (`EarlierOffersDeriver`) and for the click (`CodeOfferFreshnessChecker`), so both find the
/// same facts in the same lines and the sheet's R22 (which compares them) does not re-arm for nothing.
/// Pure. Everything it returns that a session wrote (reply heads, file names) is session text: shown only through the
/// plain-text renderer, never logged.
enum OfferSupersession {
    /// The answer for one reply.
    enum Verdict: Equatable, Sendable {
        /// Nothing that supersedes came after the reply.
        case fresh
        /// A user entry that is not a tool_result, or a final reply, came after it, or the session file says the session
        /// is working on a newer turn the transcript does not show yet: runnable behind R22 with these facts.
        case superseded(CommandOffer.Supersession)
        /// A third newer reply to a turn of the user's or another session's (an unknown origin counts as the user's,
        /// failing toward the drop).
        case dropped
        /// The reply is not the final reply of a turn in the digest: gone, changed, or out of reach.
        case notFound
    }

    /// What the session file says beside the transcript.
    struct SessionFacts: Hashable, Sendable {
        /// `sshReattach.midTurn`: the latest turn is still running though the transcript shows its end. The digest given
        /// to `evaluate` must have it applied too (`CodeTurnDigestBuilder.digest(midTurn:…)`), as the engine's has.
        var midTurn = false
        /// The session file's `lastActivityAt` (never later than the file's own write): the SSH working signal.
        var lastActivityAt: Date?
        /// An SSH session: its transcript is a mirror that arrives in batches, 20-40 s late.
        var isSSH = false

        init(midTurn: Bool = false, lastActivityAt: Date? = nil, isSSH: Bool = false) {
            self.midTurn = midTurn; self.lastActivityAt = lastActivityAt; self.isSSH = isSSH
        }
    }

    /// `<task-notification>` statuses that end a task.
    static let finishedStatuses: Set<String> = ["completed", "failed", "killed", "stopped"]
    /// Tools that change a file (MultiEdit too, unused today).
    static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    /// File names listed at most (the count says how many in all).
    static let filesListed = 8
    /// Lines of a newer reply kept for "▸ Newer replies".
    static let replyHeadLines = 6

    // MARK: Finding the reply

    /// The turn whose final reply is `replyUUID`: the last finished turn with that reply uuid (`finished` is
    /// `finishedTurns(in:)` of `digest`), or (`midTurn` true) the latest turn when the session file alone keeps it
    /// unfinished: nothing was written after the reply's last assistant item.
    static func replyTurn(_ replyUUID: String, in digest: CodeTurnDigest, finished: [String: Int],
                          midTurn: Bool) -> (index: Int, unfinishedByMidTurn: Bool)? {
        if let index = finished[replyUUID] { return (index, false) }
        guard midTurn, let latest = digest.turns.last, !latest.isFinished,
              endsWithAssistantItem(latest, uuid: replyUUID) else { return nil }
        return (digest.turns.count - 1, true)
    }

    /// The finished turns' indices by their reply uuid (the last one when two turns share a uuid).
    static func finishedTurns(in digest: CodeTurnDigest) -> [String: Int] {
        var out: [String: Int] = [:]
        for (index, turn) in digest.turns.enumerated() where turn.isFinished {
            if let reply = turn.replyUUID { out[reply] = index }
        }
        return out
    }

    /// The turn's last item that is not a notice is an assistant item (text or tool call) of the entry `uuid`.
    static func endsWithAssistantItem(_ turn: CodeTurnDigest.Turn, uuid: String) -> Bool {
        for item in turn.items.reversed() {
            switch item {
            case .notice: continue
            case .text(let text): return text.uuid == uuid
            case .toolUse(let tool): return tool.uuid == uuid
            case .toolResult: return false
            }
        }
        return false
    }

    // MARK: The facts

    /// The verdict for the offers of `replyUUID` (whose reply was written at `replyTime`), from `digest` and the session
    /// file's facts. The same as `evaluate(_:in:work:)` for one query (one definition for the parse and the click).
    static func evaluate(_ replyUUID: String, in digest: CodeTurnDigest, replyTime: Date,
                         session: SessionFacts) -> Verdict {
        var work = 0
        return evaluate([Query(replyUUID: replyUUID, replyTime: replyTime, session: session)], in: digest, work: &work)[0]
    }

    /// The first `replyHeadLines` lines of a turn's final reply (session text).
    static func head(of turn: CodeTurnDigest.Turn) -> String {
        let text = turn.finalReply.map(\.text).joined(separator: "\n")
        return CodeText.firstLines(text, count: replyHeadLines, limit: 200) ?? ""
    }

    /// The key of a notice that ends a task (`t:<task id>`, else `u:<tool_use id>`), nil for any other notice.
    static func finishedTaskKey(_ notice: CodeTurnDigest.Notice) -> String? {
        guard let status = notice.status, finishedStatuses.contains(status) else { return nil }
        return notice.taskID.map { "t:" + $0 } ?? notice.toolUseID.map { "u:" + $0 }
    }

    /// Whether `item` is an assistant item (text or tool call) of the entry `uuid`.
    static func isAssistant(_ item: CodeTurnDigest.Item, uuid: String) -> Bool {
        switch item {
        case .text(let text): return text.uuid == uuid
        case .toolUse(let tool): return tool.uuid == uuid
        case .toolResult, .notice: return false
        }
    }
}
