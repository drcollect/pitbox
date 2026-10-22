import Foundation
import PitboxKit

/// One of the user's buckets: a named, coloured group of monitors. Unsorted
/// (`unsorted`) always exists and comes first; the others follow in the order they were made.
struct CodeBucket: Equatable, Sendable, Identifiable {
    /// Unsorted's id: "moves to Unsorted" always means the same place.
    static let unsortedID = "unsorted"
    /// Unsorted as it starts: grey, open.
    static let unsorted = CodeBucket(id: unsortedID, name: CodeBucketName.unsorted, color: .grey, folded: false)

    /// `unsorted`, or `b-` and 6 characters of `[a-z0-9]`.
    let id: String
    /// The user's words (`CodeBucketName`); always "Unsorted" for Unsorted.
    var name: String
    var color: CodeBucketColor
    /// Folded to its header (the badges stay).
    var folded: Bool

    var isUnsorted: Bool { id == Self.unsortedID }

    /// `^(unsorted|b-[a-z0-9]{6})$`.
    static func isValidID(_ id: String) -> Bool {
        if id == unsortedID { return true }
        let bytes = Array(id.utf8)
        guard bytes.count == 8, bytes[0] == 0x62, bytes[1] == 0x2D else { return false }
        return bytes[2...].allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }
    }
}

/// Which bucket a session sits in, and when the app first and last saw it as a pop-out. `firstSeen` is the
/// session's stable place in its bucket; `lastSeen` keeps the entry from being pruned.
struct CodeBucketMember: Equatable, Sendable {
    var bucket: String
    var firstSeen: Date
    var lastSeen: Date
}

/// What `code-buckets.json` holds: the buckets (Unsorted first) and the members by session id. Session ids and times
/// are the only session facts stored: no titles, no headlines.
struct CodeBucketState: Equatable, Sendable {
    var buckets: [CodeBucket] = [.unsorted]
    var sessions: [String: CodeBucketMember] = [:]

    /// Entries not seen for this long go (`CodeTuning.bucketsPruneDays`).
    static let pruneAge = TimeInterval(CodeTuning.bucketsPruneDays) * 86_400
    /// Entries kept at most (the oldest `lastSeen` go first).
    static let maxSessions = 500

    /// Removes entries not seen for 30 days, then the oldest beyond 500 (never one in `keeping`). True when something
    /// went.
    @discardableResult
    mutating func prune(now: Date, keeping: Set<String> = []) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.pruneAge)
        let before = sessions.count
        sessions = sessions.filter { $0.value.lastSeen >= cutoff || keeping.contains($0.key) }
        let over = sessions.count - Self.maxSessions
        if over > 0 {
            let oldest = sessions.filter { !keeping.contains($0.key) }.sorted {
                $0.value.lastSeen != $1.value.lastSeen ? $0.value.lastSeen < $1.value.lastSeen : $0.key < $1.key
            }.prefix(over)
            for (id, _) in oldest { sessions[id] = nil }
        }
        return sessions.count != before
    }
}

/// Reading and writing `code-buckets.json`. Pure: the store does the file work.
///
/// ```json
/// { "version": 1,
///   "buckets": [ { "id": "unsorted", "name": "Unsorted", "color": "grey", "folded": false },
///                { "id": "b-k3x9q2", "name": "Toy Cube", "color": "amber", "folded": false } ],
///   "sessions": { "local_8f3a…": { "bucket": "b-k3x9q2", "firstSeen": "2026-10-19T21:10:04.000Z",
///                                  "lastSeen": "2026-10-20T08:00:00.000Z" } } }
/// ```
/// Tolerant: unknown keys are ignored; a bad bucket or session entry is dropped alone; a missing Unsorted is added back
/// (first); a session pointing at an unknown bucket goes to Unsorted; past 20 buckets the first 20 stay. A bucket entry
/// is bad when its id fails `^(unsorted|b-[a-z0-9]{6})$` (or repeats), its name fails `CodeBucketName.validated`, or
/// its colour is not one of the 8 names: the rules of typing hold on reading too. A file that is
/// not a version-1 object is broken.
enum CodeBucketFile {
    static let version = 1
    /// How far ahead of the clock a stored time may be before it counts as wrong.
    static let futureSlack: TimeInterval = 86_400

    /// A parsed file: the state, and whether anything was dropped or fixed (the store writes the clean form back).
    struct Decoded: Equatable {
        var state: CodeBucketState
        var cleaned: Bool
    }

    /// The state in a file's top-level object, or nil when it is not a version-1 buckets file.
    static func decode(_ root: [String: JSONValue], now: Date) -> Decoded? {
        guard root["version"]?.intValue == version else { return nil }
        var cleaned = false
        var buckets: [CodeBucket] = []
        var seen: Set<String> = []
        for entry in root["buckets"]?.arrayValue ?? [] {
            guard let bucket = decodeBucket(entry), !seen.contains(bucket.id) else {
                cleaned = true
                continue
            }
            seen.insert(bucket.id)
            buckets.append(bucket)
        }
        if root["buckets"] != nil, root["buckets"]?.arrayValue == nil { cleaned = true }
        // Unsorted first, added back when missing; then the others in their order, the first 20 buckets in all.
        let unsorted = buckets.first(where: \.isUnsorted) ?? CodeBucket.unsorted
        if buckets.first?.isUnsorted != true { cleaned = true }
        var ordered = [unsorted] + buckets.filter { !$0.isUnsorted }
        if ordered.count > CodeTuning.maxBuckets {
            ordered = Array(ordered.prefix(CodeTuning.maxBuckets))
            cleaned = true
        }
        let ids = Set(ordered.map(\.id))
        var sessions: [String: CodeBucketMember] = [:]
        if let all = root["sessions"]?.objectValue {
            for (id, value) in all {
                guard CodeIDs.isSessionID(id), var member = decodeMember(value, now: now) else {
                    cleaned = true
                    continue
                }
                if member.0.bucket.isEmpty || !ids.contains(member.0.bucket) {
                    member.0.bucket = CodeBucket.unsortedID
                    member.1 = true
                }
                if member.1 { cleaned = true }
                sessions[id] = member.0
            }
        } else if root["sessions"] != nil {
            cleaned = true
        }
        var state = CodeBucketState(buckets: ordered, sessions: sessions)
        if state.prune(now: now) { cleaned = true }
        return Decoded(state: state, cleaned: cleaned)
    }

    private static func decodeBucket(_ value: JSONValue) -> CodeBucket? {
        guard let fields = value.objectValue, let id = fields["id"]?.stringValue, CodeBucket.isValidID(id),
              let raw = fields["color"]?.stringValue, let color = CodeBucketColor(rawValue: raw) else { return nil }
        let folded = fields["folded"]?.boolValue ?? false
        if id == CodeBucket.unsortedID {
            // Unsorted cannot be renamed: its name in the file plays no part.
            return CodeBucket(id: id, name: CodeBucketName.unsorted, color: color, folded: folded)
        }
        guard let text = fields["name"]?.stringValue, let name = CodeBucketName.validated(text) else { return nil }
        return CodeBucket(id: id, name: name, color: color, folded: folded)
    }

    /// The member and whether it needed fixing (a missing time taken from the other one, a time in the future).
    private static func decodeMember(_ value: JSONValue, now: Date) -> (CodeBucketMember, Bool)? {
        guard let fields = value.objectValue, let bucket = fields["bucket"]?.stringValue else { return nil }
        let first = fields["firstSeen"]?.stringValue.flatMap(CodeDates.parse)
        let last = fields["lastSeen"]?.stringValue.flatMap(CodeDates.parse)
        guard let anyTime = first ?? last else { return nil }
        var fixed = first == nil || last == nil
        var firstSeen = first ?? anyTime
        var lastSeen = last ?? anyTime
        // A time over a day ahead (a wrong clock, a hand edit) counts as now; first never after last. (First-seen times
        // handed out in one burst run a few milliseconds ahead of the clock: they keep their order.)
        let latest = now.addingTimeInterval(futureSlack)
        if firstSeen > latest { firstSeen = now; fixed = true }
        if lastSeen > latest { lastSeen = now; fixed = true }
        if lastSeen < firstSeen { lastSeen = firstSeen; fixed = true }
        return (CodeBucketMember(bucket: CodeBucket.isValidID(bucket) ? bucket : "", firstSeen: firstSeen, lastSeen: lastSeen),
                fixed)
    }

    /// The file's bytes: pretty-printed with sorted keys, buckets in their order, times as ISO 8601 with milliseconds.
    static func encode(_ state: CodeBucketState) -> Data? {
        let buckets: [JSONValue] = state.buckets.map { bucket in
            .object(["id": .string(bucket.id), "name": .string(bucket.name), "color": .string(bucket.color.rawValue),
                     "folded": .bool(bucket.folded)])
        }
        var sessions: [String: JSONValue] = [:]
        for (id, member) in state.sessions {
            sessions[id] = .object(["bucket": .string(member.bucket), "firstSeen": .string(isoMilliseconds(member.firstSeen)),
                                    "lastSeen": .string(isoMilliseconds(member.lastSeen))])
        }
        return CodeStateFiles.serialize(["version": .number(Double(version)), "buckets": .array(buckets),
                                         "sessions": .object(sessions)], pretty: true)
    }

    /// `2026-10-19T21:10:04.123Z`: UTC, the nearest millisecond (so the order of first-seen times survives a reload).
    static func isoMilliseconds(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let whole = Date(timeIntervalSince1970: TimeInterval(milliseconds.quotientAndRemainder(dividingBy: 1000).quotient))
        let base = Date.ISO8601FormatStyle(timeZone: .gmt).format(whole)
        let fraction = Int(milliseconds.quotientAndRemainder(dividingBy: 1000).remainder)
        guard base.hasSuffix("Z") else { return base }
        return String(base.dropLast()) + String(format: ".%03dZ", fraction)
    }

    /// Whole milliseconds since 1970 (the unit first-seen times are handed out in).
    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
