import Foundation

/// The sessions the app follows: it reads their transcript ends and makes Ready items for them.
/// In this order, at most `CodeTuning.followMax` (24, the bound on watched transcripts):
/// 1. every pop-out on the desk (in the monitors' fixed order);
/// 2. every parked pop-out, and every parked session whose window closed (their monitors stay);
/// 3. recent sessions of readable copies, from their session files alone: first the ones **the user used**
///    (`lastFocusedAt` or `latestUserFrameAt` within `readyRecentHours`), by the user's last activity, newest first;
///    then the ones **active only on their own** (`lastActivityAt` within the hours, no input from the user), by their
///    own activity. The session's own writing never moves a session the user used out of the 24.
/// Past 24 the least recent wait, and the list header says "24 of 27 followed". Pure.
struct CodeFollowedSet: Equatable, Sendable {
    /// How a session is followed, which decides its items and its "<where>" words.
    enum Kind: Equatable, Sendable {
        /// A pop-out on the desk (another Space, hidden and not matched included).
        case desk
        /// A parked pop-out, or a parked session whose window closed.
        case parked
        /// A main-window session the user used: every kind of item. `at` is the user's last activity there.
        case recentUsed(at: Date)
        /// A main-window session active only on its own: finished items, warnings and ETA, never a command or file
        /// item, so a session cannot put a command in front of the user by writing (docs/THREAT_MODEL.md); its cards
        /// carry OK and Open in Claude only. `at` is its own last activity.
        case recentOwn(at: Date)

        /// Command and file items may come from it.
        var getsOffers: Bool {
            if case .recentOwn = self { return false }
            return true
        }

        /// A main-window session: no monitor, no window to show; Open in Claude instead.
        var isRecent: Bool {
            switch self {
            case .desk, .parked: return false
            case .recentUsed, .recentOwn: return true
            }
        }
    }

    /// One followed session.
    struct Entry: Equatable, Sendable {
        var id: String
        var kind: Kind
    }

    /// Which of the user's fields count as their own input: a field the session's own writing
    /// also moves is not used; with neither, every recent session counts as active on its own only.
    struct Policy: Equatable, Sendable {
        var usesFocusedAt = true
        var usesUserFrameAt = true

        init(usesFocusedAt: Bool = true, usesUserFrameAt: Bool = true) {
            self.usesFocusedAt = usesFocusedAt; self.usesUserFrameAt = usesUserFrameAt
        }

        /// The user's last activity in a session under this policy.
        func usersActivity(_ session: CodeRecentSession) -> Date? {
            [usesFocusedAt ? session.lastFocusedAt : nil, usesUserFrameAt ? session.latestUserFrameAt : nil]
                .compactMap { $0 }.max()
        }
    }

    /// The followed sessions, in order.
    private(set) var entries: [Entry] = []
    /// Sessions that would be followed beyond the bound.
    private(set) var waiting = 0

    /// No session followed.
    static let empty = CodeFollowedSet()

    /// The followed set from the monitors' sessions (pop-outs and parked ones, in the block's fixed order), the window
    /// statuses, the parked ids and the recent sessions (`CodeSessionsSource.recentSessions(within:)`).
    init(monitors: [CodeSessionSnapshot], statuses: [String: CodeWindowStatus], parked: Set<String>,
         recent: [CodeRecentSession], recentHours: Double, now: Date, policy: Policy = Policy(),
         limit: Int = CodeTuning.followMax) {
        var desk: [Entry] = []
        var parkedEntries: [Entry] = []
        var seen = Set<String>()
        for session in monitors where seen.insert(session.id).inserted {
            if parked.contains(session.id) || statuses[session.id].map(Self.isParked) == true {
                parkedEntries.append(Entry(id: session.id, kind: .parked))
            } else if session.popout != nil {
                desk.append(Entry(id: session.id, kind: .desk))
            } else {
                seen.remove(session.id)
            }
        }
        for id in parked.sorted() where seen.insert(id).inserted { parkedEntries.append(Entry(id: id, kind: .parked)) }

        var used: [Entry] = []
        var own: [Entry] = []
        if recentHours > 0, recentHours.isFinite {
            let start = now.addingTimeInterval(-min(recentHours, CodeTuning.readyRecentHoursMax) * 3600)
            for session in recent where session.profile.isReadable && !seen.contains(session.id) {
                if let at = policy.usersActivity(session), at >= start {
                    used.append(Entry(id: session.id, kind: .recentUsed(at: at)))
                } else if let at = session.ownLastActivity, at >= start {
                    own.append(Entry(id: session.id, kind: .recentOwn(at: at)))
                } else {
                    continue
                }
                seen.insert(session.id)
            }
        }
        used.sort { Self.time($0.kind) != Self.time($1.kind) ? Self.time($0.kind) > Self.time($1.kind) : $0.id < $1.id }
        own.sort { Self.time($0.kind) != Self.time($1.kind) ? Self.time($0.kind) > Self.time($1.kind) : $0.id < $1.id }
        let all = desk + parkedEntries + used + own
        entries = Array(all.prefix(max(0, limit)))
        waiting = all.count - entries.count
    }

    private init() {}

    /// The ids to hand to `CodeSessionsSource.setWatched`.
    var ids: Set<String> { Set(entries.map(\.id)) }

    /// The sessions active only on their own (`recentOwn`): no command or file items, and no Open on their rows in the
    /// dashboards list.
    var ownActivityOnly: Set<String> {
        Set(entries.compactMap { entry -> String? in
            if case .recentOwn = entry.kind { return entry.id }
            return nil
        })
    }

    /// How `id` is followed, nil when it is not.
    func kind(of id: String) -> Kind? { entries.first { $0.id == id }?.kind }

    /// "24 of 27 followed" while some wait, else nil.
    var headerNote: String? {
        waiting > 0 ? "\(entries.count) of \(entries.count + waiting) followed" : nil
    }

    private static func isParked(_ status: CodeWindowStatus) -> Bool {
        if status.isParked { return true }
        if case .closed = status.place { return true }
        return false
    }

    private static func time(_ kind: Kind) -> Date {
        switch kind {
        case .recentUsed(let at), .recentOwn(let at): return at
        case .desk, .parked: return .distantPast
        }
    }
}
