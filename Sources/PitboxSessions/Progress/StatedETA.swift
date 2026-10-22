import Foundation
import PitboxKit

/// The ETA a session stated for its work: the newest statement in the work's
/// assistant texts that can be placed on the timeline.
struct StatedETA: Equatable, Sendable {
    /// Where the zone of a zone-less clock came from (for the log line, `zone=utc|server|local`).
    enum ZoneSource: String, Sendable { case utc, server, local }

    /// The moment, absolute.
    var at: Date
    /// The statement's entry timestamp.
    var statedAt: Date
    /// The zone the clock was read in.
    var zone: TimeZone
    var source: ZoneSource
    /// The text entry that stated it, when its uuid passes the grammar.
    var replyUUID: String?
}

/// What `code-memory.json` keeps of a stated ETA (key `eta`): until a newer statement, the end of the work,
/// or 2 hours after `at`.
struct ETARecord: Codable, Equatable, Sendable {
    var at: Date
    var statedAt: Date?
    var reply: String?
}

/// Parsed statements of one session's texts, so a text is parsed once (texts never change once written).
struct ETATextCache: Sendable {
    struct Key: Hashable, Sendable {
        var uuid: String?
        var at: TimeInterval?
        var length: Int
    }

    private(set) var context = ETAParser.Context()
    private var entries: [Key: ETAParser.Statement?] = [:]

    /// The statement of `text`, parsed now or taken from the cache; `seen` collects the keys used in this pass.
    mutating func statement(of text: CodeTurnDigest.Text, context: ETAParser.Context,
                            seen: inout Set<Key>) -> ETAParser.Statement? {
        if context != self.context {
            self.context = context
            entries = [:]
        }
        let key = Key(uuid: text.uuid, at: text.at?.timeIntervalSince1970, length: text.text.utf8.count)
        seen.insert(key)
        if let cached = entries[key] { return cached }
        let parsed = ETAParser.statement(in: text.text, context: context)
        entries.updateValue(parsed, forKey: key)
        return parsed
    }

    /// Drops the texts no longer in the work.
    mutating func keep(only keys: Set<Key>) {
        entries = entries.filter { keys.contains($0.key) }
    }

    var count: Int { entries.count }
}

enum StatedETAFinder {
    /// The newest placeable statement in the work's texts. A clock without a zone is read in `defaultZone` (this Mac's
    /// for local sessions, `serverTimeZones[alias]` for SSH ones, `source` says which); an explicit UTC wins.
    static func newest(in digest: CodeTurnDigest, work: CodeWork, context: ETAParser.Context, defaultZone: TimeZone,
                       defaultSource: StatedETA.ZoneSource, cache: inout ETATextCache) -> StatedETA? {
        var seen = Set<ETATextCache.Key>()
        var newest: StatedETA?
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        for index in work.firstTurn..<digest.turns.count {
            for item in digest.turns[index].items {
                guard case .text(let text) = item,
                      let statement = cache.statement(of: text, context: context, seen: &seen),
                      let statedAt = text.at else { continue }
                let zone = statement.value.utc ? utc : defaultZone
                guard let at = ETAClock.place(hour: statement.value.hour, minute: statement.value.minute, in: zone,
                                              statedAt: statedAt) else { continue }
                newest = StatedETA(at: at, statedAt: statedAt, zone: zone,
                                   source: statement.value.utc ? .utc : defaultSource, replyUUID: text.uuid)
            }
        }
        cache.keep(only: seen)
        return newest
    }
}
