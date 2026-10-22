import Foundation
import PitboxKit

/// When the user last looked at a session (`code-memory.json` key `seen`).
struct CodeSeenRecord: Codable, Equatable, Sendable {
    var at: Date
}

/// The unread dot (cross-session order 200): something new arrived since the user last looked: a finished
/// turn of any length, a new offer, a new result or a new warning (Same file included, which is why it runs after every
/// other deriver). Each event's time is compared with the stored `seenAt`; on the first sight of a session
/// `seenAt` becomes now, so nothing is unread (no burst of dots after an update). The block draws the dot on parked
/// monitors only; opening the peek, restoring the window, or OK and Open window on its Finished card clear it
/// (`CodeUnreadMarks.markSeen`). SSH sessions' entry times carry the server's clock: an event within `sshClockSlack`
/// after `seenAt` does not count there.
final class UnreadDeriver: CodeCrossSessionDeriver {
    let label = "unread"
    let order = CodeDeriveOrder.unread

    /// An SSH session's events this close after `seenAt` were seen (the user was looking then): a server clock a few
    /// seconds ahead raises no dot for what they saw.
    static let sshClockSlack: TimeInterval = 5

    func derive(_ sessions: [CodeCrossSessionInput], context: CodeCrossDeriveContext,
                into fields: inout [String: CodeDerivedFields]) {
        for session in sessions {
            let id = session.sessionID
            guard let seen: CodeSeenRecord = context.memory.read(.seen, session: id) else {
                context.memory.write(.seen, session: id, value: CodeSeenRecord(at: context.now))
                fields[id, default: CodeDerivedFields()].unread = false
                continue
            }
            let latest = Self.latestEvent(session)
            let ssh = session.snapshot.place == .ssh || session.snapshot.sshHost != nil
            let after = seen.at.addingTimeInterval(ssh ? Self.sshClockSlack : 0)
            fields[id, default: CodeDerivedFields()].unread = latest.map { $0 > after } ?? false
        }
    }

    /// The newest of the events that make a session unread.
    static func latestEvent(_ session: CodeCrossSessionInput) -> Date? {
        let snapshot = session.snapshot
        var times: [Date] = session.digest.turns.compactMap(\.finishedAt)
        times += snapshot.offers.map(\.offer.source.replyTime)
        times += snapshot.earlierOffers.map(\.offer.source.replyTime)
        times += snapshot.results.compactMap(\.at)
        times += snapshot.warnings.map(\.since)
        if let finished = snapshot.finished { times.append(finished.at) }
        return times.max()
    }
}

/// The main thread's side of the unread dot.
public enum CodeUnreadMarks {
    /// The dot's colour inside its ring (the monitor's corner-dot slot draws the ring in the block's dark).
    static let dotFill: UInt32 = 0xF3F4F6
    /// VoiceOver's words for the dot: the app's own words, no session text.
    static let dotLabel = "Something new since you last looked"

    /// The user looked at the session now (its peek opened, its window restored, OK or Open window on its Finished card):
    /// the dot goes once the engine derives again (the store's change brings it back at once).
    public static func markSeen(_ sessionID: String, memory: CodeMemoryStore, now: Date) {
        memory.write(.seen, session: sessionID, value: CodeSeenRecord(at: now))
    }

    /// Whether the session's monitor shows the dot: something unread, on a parked monitor (parked by
    /// the app, minimized, parked before a restart, or closed while parked), every size and slim rows.
    static func showsDot(_ session: CodeSessionSnapshot, status: CodeWindowStatus?, parked: Set<String>) -> Bool {
        guard session.unread else { return false }
        if parked.contains(session.id) || status?.isParked == true { return true }
        if case .closed? = status?.place { return true }
        return false
    }
}
