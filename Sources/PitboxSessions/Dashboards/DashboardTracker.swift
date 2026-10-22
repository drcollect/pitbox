import Foundation

/// One dashboard link seen in a session's own writing.
struct DashboardSighting: Equatable, Sendable {
    var handle: String
    /// The site's key (`CodeDashboardSite.key`).
    var site: String
    /// The entry's timestamp.
    var at: Date?

    /// The same link: handle and site.
    func isSameLink(handle other: String, site otherSite: String?) -> Bool { handle == other && site == otherSite }
}

/// What the digest says about dashboards (every tail read): the links in order, and the latest
/// `dashboard-builder` call.
struct DigestDashboards: Equatable, Sendable {
    var links: [DashboardSighting] = []
    var lastBuilderCallAt: Date?
}

/// The session's dashboard as `code-memory.json` keeps it (key `dashboard`), so the ▦ button survives
/// restarts; kept while the session exists and is not archived (the store's pruning).
struct DashboardRecord: Codable, Equatable, Sendable {
    var handle: String
    /// The site's key ("dash.example.com/dash/"); nil in a record from before sites were named: the first site.
    var site: String? = nil
    var firstSeen: Date
    var lastBuilderCallAt: Date?
}

/// The one-time scan's mark (key `dashboardScan`): it ran, how far, and what it found (the handle and times
/// only), so it never repeats and its finding survives a restart. Only the scan writes it; only the deriver writes
/// `dashboard`, so the two never overwrite each other.
struct DashboardScanRecord: Codable, Equatable, Sendable {
    var at: Date
    var found: Bool
    var bytes: Int?
    var handle: String?
    /// The found link's site key.
    var site: String? = nil
    var linkAt: Date?
    var builderAt: Date?
}

/// Texts already searched (texts and tool inputs never change once written).
struct DashboardTextCache: Sendable {
    struct Key: Hashable, Sendable {
        var id: String?
        var at: TimeInterval?
        var length: Int
    }

    private var entries: [Key: [DashboardLinkHit]] = [:]

    mutating func links(_ key: Key, text: String, sites: CodeDashboardSites, seen: inout Set<Key>) -> [DashboardLinkHit] {
        seen.insert(key)
        if let cached = entries[key] { return cached }
        let found = DashboardLink.links(in: text, sites: sites)
        entries[key] = found
        return found
    }

    mutating func keep(only keys: Set<Key>) { entries = entries.filter { keys.contains($0.key) } }
}

/// Tracks a session's dashboard. Pure.
enum DashboardTracker {
    static let builderType = "dashboard-builder"

    /// The links in the digest's assistant texts and in its `dashboard-builder` prompts (written by the session
    /// itself), and the latest such call. Never tool results, notices, user text or thinking (the digest holds none of
    /// those as text). A fork's copied history counts: it shows its parent's dashboard until it posts its own.
    static func sightings(in digest: CodeTurnDigest, sites: CodeDashboardSites,
                          cache: inout DashboardTextCache) -> DigestDashboards {
        var out = DigestDashboards()
        var seen = Set<DashboardTextCache.Key>()
        for turn in digest.turns {
            for item in turn.items {
                sight(item, sites: sites, into: &out, cache: &cache, seen: &seen)
            }
        }
        cache.keep(only: seen)
        return out
    }

    /// One item: an assistant text's links, or a builder call's time and its prompt's links.
    private static func sight(_ item: CodeTurnDigest.Item, sites: CodeDashboardSites, into out: inout DigestDashboards,
                              cache: inout DashboardTextCache, seen: inout Set<DashboardTextCache.Key>) {
        switch item {
        case .text(let text):
            let key = DashboardTextCache.Key(id: text.uuid, at: text.at?.timeIntervalSince1970, length: text.text.utf8.count)
            for link in cache.links(key, text: text.text, sites: sites, seen: &seen) {
                out.links.append(DashboardSighting(handle: link.handle, site: link.site.key, at: text.at))
            }
        case .toolUse(let tool):
            guard isBuilderCall(name: tool.name, subagentType: tool.subagentType) else { return }
            if let at = tool.at { out.lastBuilderCallAt = max(out.lastBuilderCallAt ?? at, at) }
            guard let prompt = tool.promptHead else { return }
            let key = DashboardTextCache.Key(id: tool.id.map { "tool:" + $0 }, at: tool.at?.timeIntervalSince1970,
                                             length: prompt.utf8.count)
            for link in cache.links(key, text: prompt, sites: sites, seen: &seen) {
                out.links.append(DashboardSighting(handle: link.handle, site: link.site.key, at: tool.at))
            }
        case .toolResult, .notice:
            return
        }
    }

    /// An Agent (or Task) call with `subagent_type: "dashboard-builder"`.
    static func isBuilderCall(name: String, subagentType: String?) -> Bool {
        (name == "Agent" || name == "Task") && subagentType == builderType
    }

    /// The dashboard to keep: the newest link wins (the digest always holds the transcript's end, so its last link is
    /// the newest one); else the stored one; else the scan's. `firstSeen` is the earliest sighting of the shown link
    /// since another link was last posted (kept from the store while the link stays); `lastBuilderCallAt` the latest
    /// builder call known from the store, the scan and the digest, never earlier than `firstSeen`. A link counts only
    /// while its site is in `sites` and its handle passes that site's check (an old record without a site belongs to the
    /// first site).
    static func merge(stored: DashboardRecord?, scan: DashboardScanRecord?, digest: DigestDashboards, sites: CodeDashboardSites,
                      now: Date) -> DashboardRecord? {
        var handle: String?
        var siteKey: String?
        var firstSeen: Date?
        if let newest = digest.links.last {
            handle = newest.handle
            siteKey = newest.site
            var earliest = newest.at
            for sighting in digest.links.reversed() {
                guard sighting.isSameLink(handle: newest.handle, site: newest.site) else { break }
                if let at = sighting.at { earliest = min(earliest ?? at, at) }
            }
            if let stored, newest.isSameLink(handle: stored.handle, site: sites.site(key: stored.site)?.key) {
                firstSeen = min(stored.firstSeen, earliest ?? stored.firstSeen)
            } else {
                firstSeen = earliest ?? now
            }
        } else if let stored {
            handle = stored.handle
            siteKey = sites.site(key: stored.site)?.key
            firstSeen = stored.firstSeen
        } else if let scan, scan.found, let found = scan.handle {
            handle = found
            siteKey = sites.site(key: scan.site)?.key
            firstSeen = scan.linkAt ?? scan.at
        }
        guard let handle, let site = sites.site(key: siteKey), siteKey != nil, site.isValidHandle(handle), let firstSeen
        else { return nil }
        let builder = [stored?.lastBuilderCallAt, scan?.builderAt, digest.lastBuilderCallAt].compactMap { $0 }.max()
        return DashboardRecord(handle: handle, site: site.key, firstSeen: firstSeen,
                               lastBuilderCallAt: builder.map { max($0, firstSeen) })
    }
}
