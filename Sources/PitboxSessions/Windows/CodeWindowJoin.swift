import CoreGraphics
import Foundation

/// What the join knows about one session (built from `CodeSessionSnapshot`, plus the saved frame of a parked record).
struct CodeWindowSessionInput: Equatable, Sendable {
    var id: String
    /// The session's local index in this run (`#3` in logs).
    var index: Int
    var profile: CodeProfile
    /// The full session title: a pop-out's `AXTitle` equals it exactly.
    var title: String
    var previousTitles: [String]
    /// The bounds `session-popouts.json` holds (may be stale) or, for a parked record, the frame saved when parking.
    var hint: CGRect?
    /// Claude lists the session in `session-popouts.json` (the file is gone when no pop-out is open). A held window that
    /// is off screen and not minimized while its record is gone is a closed pop-out Claude kept alive.
    var hasPopout: Bool = true
}

/// One Accessibility window of one Claude process, read for the join.
struct CodeJoinWindow: Equatable, Sendable {
    var element: CodeAXElement
    var title: String?
    var frame: CGRect?
    var minimized: Bool
    /// The window-server number, resolved (`_AXUIElementGetWindow`, else unique equal bounds); nil: not resolvable.
    var number: CGWindowID?
}

/// The pure half of the window join: no system calls, so every rule is unit-tested.
/// There is no match by position: a Claude copy was seen keeping a hidden 912 × 622 layer-0 window that the file's
/// bounds could match, so only windows on screen or minimized, with a real title, are joined.
enum CodeWindowJoin {
    /// Layer-0 windows of at least this size count as pop-outs.
    static let minimumSize = CGSize(width: 160, height: 100)
    /// The main window's AX title: it never gets a monitor.
    static let mainWindowTitle = "Claude"
    /// Bounds within this many points count as equal (Electron rounds to whole points).
    static let boundsTolerance: CGFloat = 1

    /// Window levels a pop-out can have: normal (0), and floating (3) for an `alwaysOnTop` pop-out (Electron's
    /// `setAlwaysOnTop` uses the floating level; a layer-0-only filter would drop it).
    static let popoutLayers: Set<Int> = [0, 3]

    /// Whether a window-server window can be a pop-out (layer 0 or the floating level).
    static func isEligible(_ window: CodeServerWindow) -> Bool {
        popoutLayers.contains(window.layer) && window.bounds.width >= minimumSize.width
            && window.bounds.height >= minimumSize.height
    }

    static func sameBounds(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= boundsTolerance && abs(a.minY - b.minY) <= boundsTolerance
            && abs(a.width - b.width) <= boundsTolerance && abs(a.height - b.height) <= boundsTolerance
    }

    /// The window number of an AX window: `_AXUIElementGetWindow`'s answer when it names one of the pid's server windows,
    /// else the one server window of that pid whose bounds equal the AX frame now. Two windows with equal bounds (Zones
    /// places windows at identical rects) give nil: "window not matched".
    static func resolveNumber(reported: CGWindowID?, frame: CGRect?, serverWindows: [CodeServerWindow]) -> CGWindowID? {
        if let reported, serverWindows.contains(where: { $0.number == reported }) { return reported }
        guard let frame else { return nil }
        let equal = serverWindows.filter { sameBounds($0.bounds, frame) }
        return equal.count == 1 ? equal[0].number : nil
    }

    /// Matches sessions of one Claude process to its AX windows: by title exactly, then by
    /// `previousTitles`. Two windows (or sessions) with the same title are told apart by the hint bounds; still
    /// ambiguous means "not matched" for all of them, and they are not tried again by an older title. The main window
    /// ("Claude") and windows without a title never match. Returns session id → index into `windows`.
    static func matchTitles(sessions: [CodeWindowSessionInput], windows: [CodeJoinWindow]) -> [String: Int] {
        var result: [String: Int] = [:]
        var usedWindows = Set<Int>()
        var settled = Set<String>()   // matched, or ambiguous on its current title
        let candidates = windows.indices.filter { index in
            guard let title = windows[index].title, !title.isEmpty else { return false }
            return title != mainWindowTitle
        }

        // Phase 1: the current title.
        let byTitle = Dictionary(grouping: sessions, by: \.title)
        for (title, group) in byTitle {
            let matching = candidates.filter { windows[$0].title == title }
            guard !matching.isEmpty else { continue }
            let pairs = pair(group, matching, windows: windows)
            for (id, index) in pairs { result[id] = index; usedWindows.insert(index) }
            // Everyone in an ambiguous group is settled as "not matched".
            for session in group { settled.insert(session.id) }
            if pairs.isEmpty || pairs.count < min(group.count, matching.count) {
                // The windows that could not be told apart are not handed to an older title either.
                for index in matching where !pairs.values.contains(index) { usedWindows.insert(index) }
            }
        }

        // Phase 2: the previous titles, for sessions that found no window by their current title.
        let open = sessions.filter { !settled.contains($0.id) && !$0.previousTitles.isEmpty }
        let free = candidates.filter { !usedWindows.contains($0) }
        var sessionToWindows: [String: [Int]] = [:]
        var windowToSessions: [Int: [String]] = [:]
        for session in open {
            let titles = Set(session.previousTitles)
            for index in free where titles.contains(windows[index].title ?? "") {
                sessionToWindows[session.id, default: []].append(index)
                windowToSessions[index, default: []].append(session.id)
            }
        }
        let sessionsByID = Dictionary(uniqueKeysWithValues: open.map { ($0.id, $0) })
        for (id, indexes) in sessionToWindows {
            if indexes.count == 1, windowToSessions[indexes[0]]?.count == 1 {
                result[id] = indexes[0]
                continue
            }
            // Several candidates: the hint bounds decide, uniquely in both directions.
            guard let hint = sessionsByID[id]?.hint else { continue }
            let equal = indexes.filter { windows[$0].frame.map { sameBounds($0, hint) } == true }
            guard equal.count == 1 else { continue }
            let rivals = (windowToSessions[equal[0]] ?? []).filter { other in
                guard other != id, let otherHint = sessionsByID[other]?.hint, let frame = windows[equal[0]].frame else { return false }
                return sameBounds(otherHint, frame)
            }
            if rivals.isEmpty, !result.values.contains(equal[0]) { result[id] = equal[0] }
        }
        return result
    }

    /// Pairs a group of sessions sharing one title with the windows of that title: one and one match; otherwise each
    /// session whose hint equals exactly one window's frame, and that window equals no other session's hint.
    private static func pair(_ group: [CodeWindowSessionInput], _ matching: [Int], windows: [CodeJoinWindow]) -> [String: Int] {
        if group.count == 1, matching.count == 1 { return [group[0].id: matching[0]] }
        var pairs: [String: Int] = [:]
        for session in group {
            guard let hint = session.hint else { continue }
            let equal = matching.filter { windows[$0].frame.map { sameBounds($0, hint) } == true }
            guard equal.count == 1 else { continue }
            let frame = windows[equal[0]].frame ?? .null
            let others = group.filter { $0.id != session.id && $0.hint.map { sameBounds($0, frame) } == true }
            if others.isEmpty { pairs[session.id] = equal[0] }
        }
        return pairs
    }
}
