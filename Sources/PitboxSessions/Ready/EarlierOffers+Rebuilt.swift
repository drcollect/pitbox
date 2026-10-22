import Foundation
import PitboxKit

/// The offers `EarlierOffersDeriver` rebuilt from the digest for one session, by reply, with what they were built from.
/// Rebuilding is pure in that (the turn's final reply and facts, the reply time, the session's id, index, headline and
/// nickname, and the template), so a reply whose inputs did not change gets the same offers without extracting and
/// classifying its blocks again. A fleet session's notice replies all stay earlier offers for 24 hours while the deriver
/// keeps only the newest few as `Kept`: the others would be rebuilt at every parse. Only the replies looked up
/// in the latest pass stay; a new template forgets everything.
struct EarlierOffersRebuilt {
    /// What one reply's offers were built from, besides the template.
    struct Source: Equatable {
        var texts: [String]
        var origin: CommandTurnOrigin
        var readWeb: Bool
        var askedHead: String?
        var readCompletely: Bool
        var replyTime: Date
        var sessionID: String
        var index: Int
        var headline: String
        var nickname: String?

        init(_ turn: CodeTurnDigest.Turn, replyTime: Date, snapshot: CodeSessionSnapshot) {
            texts = turn.finalReply.map(\.text)
            origin = turn.origin
            readWeb = turn.readWeb
            askedHead = turn.askedHead
            readCompletely = turn.readCompletely
            self.replyTime = replyTime
            sessionID = snapshot.id
            index = snapshot.index
            headline = snapshot.headline
            nickname = snapshot.nickname
        }
    }

    private var template: EarlierOffersDeriver.Template?
    private var built: [String: (source: Source, entries: [CodeOfferEntry])] = [:]
    private var used = Set<String>()

    /// Starts a pass whose rebuilds use `template`.
    mutating func begin(template: EarlierOffersDeriver.Template?) {
        if template != self.template {
            self.template = template
            built = [:]
        }
        used = []
    }

    /// The offers built for `reply` from `source` (with this pass's template), or nil.
    mutating func entries(for reply: String, source: Source) -> [CodeOfferEntry]? {
        used.insert(reply)
        guard let known = built[reply], known.source == source else { return nil }
        return known.entries
    }

    mutating func store(_ entries: [CodeOfferEntry], for reply: String, source: Source) {
        used.insert(reply)
        built[reply] = (source, entries)
    }

    /// Ends a pass: the replies it did not look up go.
    mutating func end() {
        guard built.keys.contains(where: { !used.contains($0) }) else { return }
        built = built.filter { used.contains($0.key) }
    }

    /// Tests: how many replies are held.
    var count: Int { built.count }
}
