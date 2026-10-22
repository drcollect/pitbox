import CoreGraphics
import Foundation

/// What a bucket header counts, over every page of the bucket: "4 · 2 running"
/// and the badges "2 need you", "▶ 3", "⤓ 1", "✓ 2 new", "⚠ 1", each only above 0.
struct CodeBucketCounts: Equatable, Sendable {
    /// Monitors shown in the bucket.
    var monitors = 0
    /// Working or maybe needing you, or with background tasks pending between turns; "quiet · turn not
    /// finished" is not running.
    var running = 0
    /// Monitors in Needs you.
    var needYou = 0
    /// Command and file items of the bucket's monitors in Ready (Later ones included).
    var commands = 0
    var files = 0
    /// Monitors with an unread finished turn.
    var finishedNew = 0
    /// Monitors with an active warning.
    var warnings = 0
}

/// What one session adds to its bucket's "▶ n" and "⤓ n" (the Ready list's items replace the default through
/// `CodeMonitorsModel.readyCounts`).
struct CodeReadyCounts: Equatable, Sendable {
    var commands: Int
    var files: Int

    /// Until the Ready list counts its items: the offers of the latest and the earlier replies (Fetch file ones are
    /// files) and the server-file results.
    static func fromSnapshot(_ session: CodeSessionSnapshot) -> CodeReadyCounts {
        let offers = session.offers + session.earlierOffers
        let fetches = offers.filter { $0.assessment.commandClass == .fetchFile }.count
        let serverFiles = session.results.filter { $0.kind == .serverFile }.count
        return CodeReadyCounts(commands: offers.count - fetches, files: fetches + serverFiles)
    }
}

/// The pure rules behind buckets in the block: which sessions get a monitor, their fixed order, the buckets
/// they fall into, the header counts, and where headers and bodies go. Unit-tested without views.
enum CodeBucketLayout {
    // MARK: Which sessions get a monitor

    /// A member (a pop-out, or a session the app parked) gets a monitor unless its window is on the desk while desk
    /// tags stand in for desk windows (the default). Parked, minimized and closed-while-parked windows always do, and
    /// so do windows elsewhere (another Space, hidden, not matched), whose chip says why. Without a window status yet a
    /// desk-tag member gets none, so a pop-out never flashes up before the first window pass.
    static func hasMonitor(_ session: CodeSessionSnapshot, status: CodeWindowStatus?, parked: Set<String>,
                           deskMonitors: Bool) -> Bool {
        if deskMonitors || parked.contains(session.id) { return true }
        guard let status else { return false }
        return status.place != .onDesk
    }

    /// Parked for the header's words: the app's record of parking it (also a window closed while parked), minimized,
    /// or parked before a restart and not found again yet.
    static func isParked(_ session: CodeSessionSnapshot, status: CodeWindowStatus?, parked: Set<String>) -> Bool {
        parked.contains(session.id) || status?.isParked == true || status?.place == .closed
    }

    // MARK: Order

    /// Always by copy letter (A, B, C, then unknown), then by first-seen time (stored, so restarts keep it), then by
    /// session id. A state, an offer, a result or a warning never moves a monitor; with one copy the letter plays no
    /// part, and a second copy starting moves nothing of the first.
    static func ordered(_ sessions: [CodeSessionSnapshot], firstSeen: (String) -> Date?) -> [CodeSessionSnapshot] {
        let keyed = sessions.map { (session: $0, rank: CodeMonitorBuilder.profileRank($0.profile), seen: firstSeen($0.id)) }
        return keyed.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            switch (a.seen, b.seen) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.session.id < b.session.id
            }
        }.map(\.session)
    }

    /// The monitors of each bucket, in the buckets' order (Unsorted first) and each in the order given.
    static func group(_ sessions: [CodeSessionSnapshot], buckets: [CodeBucket],
                      bucketOf: (String) -> String) -> [(bucket: CodeBucket, sessions: [CodeSessionSnapshot])] {
        var byBucket: [String: [CodeSessionSnapshot]] = [:]
        for session in sessions { byBucket[bucketOf(session.id), default: []].append(session) }
        return buckets.map { ($0, byBucket[$0.id] ?? []) }
    }

    // MARK: Counts

    static func isRunning(_ session: CodeSessionSnapshot) -> Bool {
        session.state == .working || session.state == .maybeNeedsYou || session.progress?.pendingBetweenTurns == true
    }

    /// The header counts of one bucket's monitors.
    static func counts(_ sessions: [CodeSessionSnapshot], ready: (CodeSessionSnapshot) -> CodeReadyCounts) -> CodeBucketCounts {
        var counts = CodeBucketCounts()
        for session in sessions {
            counts.monitors += 1
            if isRunning(session) { counts.running += 1 }
            if session.state == .needsYou { counts.needYou += 1 }
            let items = ready(session)
            counts.commands += max(0, items.commands)
            counts.files += max(0, items.files)
            if session.unread, let finished = session.finished, finished.hasItem, finished.isOpen { counts.finishedNew += 1 }
            if !session.warnings.isEmpty { counts.warnings += 1 }
        }
        return counts
    }

    // MARK: The stack (headers and bodies, in the block's scrolling area)

    /// A bucket header's height, its colour line included.
    static let headerHeight: CGFloat = 28
    /// From a header to its body, and between one bucket's end and the next header.
    static let headerToBody: CGFloat = 6
    static let betweenBuckets: CGFloat = 14
    /// After the last bucket, before the Ready list.
    static let aboveReady: CGFloat = 10
    /// An empty bucket's drop zone: "Drop windows or monitors here", 48 pt tall.
    static let emptyHeight: CGFloat = 48

    /// Where one bucket's parts go, in the scrolling area's coordinates (before scrolling).
    struct Placed: Equatable {
        var id: String
        /// Nil with Unsorted alone (the flat look).
        var header: CGRect?
        /// Nil when folded.
        var body: CGRect?
        /// The bucket's whole area: a drop target, and where the drop outline goes.
        var area: CGRect
    }

    /// The stack's frames: each bucket's header and body (`bodyHeight`, folded ones none), then the Ready list of
    /// `readyHeight` (0: none) at `readyY`. Buckets come first, then the Ready list. With `flat` (Unsorted alone) the
    /// one body has no header and the list follows it directly.
    static func stack(width: CGFloat, readyHeight: CGFloat, flat: Bool,
                      buckets: [(id: String, folded: Bool, bodyHeight: CGFloat)])
        -> (placed: [Placed], readyY: CGFloat, height: CGFloat) {
        var y: CGFloat = 0
        var out: [Placed] = []
        if flat, let only = buckets.first {
            let body = CGRect(x: 0, y: 0, width: width, height: only.bodyHeight)
            out.append(Placed(id: only.id, header: nil, body: body, area: body))
            y = body.maxY
        } else {
            for (index, bucket) in buckets.enumerated() {
                if index > 0 { y += betweenBuckets }
                let header = CGRect(x: 0, y: y, width: width, height: headerHeight)
                y = header.maxY
                var body: CGRect?
                if !bucket.folded {
                    y += headerToBody
                    body = CGRect(x: 0, y: y, width: width, height: bucket.bodyHeight)
                    y += bucket.bodyHeight
                }
                out.append(Placed(id: bucket.id, header: header, body: body, area: header.union(body ?? header)))
            }
            if readyHeight > 0, !buckets.isEmpty { y += aboveReady }
        }
        return (out, y, y + readyHeight)
    }
}
