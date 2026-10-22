import Darwin
import Foundation
import PitboxKit

/// The recent sessions (other unarchived sessions with recent activity, followed beside the pop-outs), from session
/// files alone (no transcript of an unfollowed session is read): the indexed sessions of the running readable copies,
/// their files read with `CarefulFiles`' care. A file whose identity did not change is not read again; one last
/// modified before `CodeTuning.readyRecentHoursMax` is not read past its `fstat` (whatever it holds was written before
/// then). A full scan looks at every indexed file; an update only at the files that file events named.
struct RecentSessionScanner {
    /// What one session file says about activity (the first two are the user's own input).
    struct Facts: Equatable, Sendable {
        var archived: Bool
        var lastFocusedAt: Date?
        var latestUserFrameAt: Date?
        var lastActivityAt: Date?
    }

    private struct Entry {
        var profile: CodeProfile
        var identity: FileIdentity
        /// Nil: the file is older than the window, or failed its checks.
        var facts: Facts?
    }

    /// At most this many session files are looked at per full scan (the index allows far more; about 150 exist).
    static let maxFiles = 2000

    private var entries: [String: Entry] = [:]

    /// Sessions whose file says they are archived (for pruning `code-memory.json`).
    var archivedIDs: Set<String> { Set(entries.filter { $0.value.facts?.archived == true }.keys) }

    /// Looks at every indexed session of `profiles` again.
    mutating func scanAll(profiles: [CodeProfile], indices: [String: SessionIndex], applicationSupport: String,
                          owner: uid_t, now: Date) {
        var next: [String: Entry] = [:]
        var looked = 0
        for profile in profiles where profile.isReadable {
            guard let index = indices[profile.folderName],
                  let folder = CarefulPath(root: applicationSupport, components: [profile.folderName]) else { continue }
            for id in index.locations.keys.sorted() where looked < Self.maxFiles {
                looked += 1
                if let entry = look(id, profile: profile, index: index, folder: folder, owner: owner, now: now) { next[id] = entry }
            }
        }
        entries = next
    }

    /// Looks again at the files of `ids` only (file events named them).
    mutating func update(_ ids: Set<String>, profiles: [CodeProfile], indices: [String: SessionIndex],
                         applicationSupport: String, owner: uid_t, now: Date) {
        for id in ids {
            entries[id] = nil
            for profile in profiles where profile.isReadable {
                guard let index = indices[profile.folderName], index.locations[id] != nil,
                      let folder = CarefulPath(root: applicationSupport, components: [profile.folderName]) else { continue }
                if let entry = look(id, profile: profile, index: index, folder: folder, owner: owner, now: now) {
                    entries[id] = entry
                }
                break
            }
        }
    }

    /// The unarchived sessions whose user-side or own activity lies within the window (by id).
    func recent(now: Date) -> [CodeRecentSession] {
        let windowStart = now.addingTimeInterval(-CodeTuning.readyRecentHoursMax * 3600)
        return entries.compactMap { id, entry -> CodeRecentSession? in
            guard let facts = entry.facts, !facts.archived else { return nil }
            let session = CodeRecentSession(id: id, profile: entry.profile, lastFocusedAt: facts.lastFocusedAt,
                                            latestUserFrameAt: facts.latestUserFrameAt, ownLastActivity: facts.lastActivityAt)
            guard let latest = [session.usersLastActivity, session.ownLastActivity].compactMap({ $0 }).max(),
                  latest >= windowStart else { return nil }
            return session
        }.sorted { $0.id < $1.id }
    }

    /// Forgets everything (the engine stopped).
    mutating func reset() { entries = [:] }

    private func look(_ id: String, profile: CodeProfile, index: SessionIndex, folder: CarefulPath, owner: uid_t,
                      now: Date) -> Entry? {
        guard let path = index.path(of: id, profileFolder: folder),
              case .success(let identity) = CarefulFiles.identity(path, owner: owner) else { return nil }
        if let known = entries[id], known.identity == identity, known.profile == profile { return known }
        let windowStart = now.addingTimeInterval(-CodeTuning.readyRecentHoursMax * 3600)
        guard identity.modifiedDate >= windowStart else { return Entry(profile: profile, identity: identity, facts: nil) }
        return Entry(profile: profile, identity: identity, facts: Self.read(path, owner: owner))
    }

    private static func read(_ path: CarefulPath, owner: uid_t) -> Facts? {
        guard case .success(let (data, _)) = CarefulFiles.read(path, owner: owner, maxBytes: ClaudeSessionFile.maxBytes),
              case .success(let file) = ClaudeSessionFile.parse(data) else { return nil }
        return Facts(archived: file.isArchived, lastFocusedAt: file.lastFocusedAt, latestUserFrameAt: file.latestUserFrameAt,
                     lastActivityAt: file.lastActivityAt)
    }

    /// `sessions` within the last `hours` of `now` (at most `CodeTuning.readyRecentHoursMax`; by the user's activity or
    /// the session's own), the user's most recent first, then the session's own, then by id.
    static func filter(_ sessions: [CodeRecentSession], within hours: Double, now: Date) -> [CodeRecentSession] {
        guard hours.isFinite, hours > 0 else { return [] }
        let start = now.addingTimeInterval(-min(hours, CodeTuning.readyRecentHoursMax) * 3600)
        func within(_ date: Date?) -> Date? { date.flatMap { $0 >= start ? $0 : nil } }
        return sessions.filter { within($0.usersLastActivity) != nil || within($0.ownLastActivity) != nil }.sorted { a, b in
            let pa = within(a.usersLastActivity)
            let pb = within(b.usersLastActivity)
            if pa != pb {
                guard let pa else { return false }
                guard let pb else { return true }
                return pa > pb
            }
            let oa = a.ownLastActivity ?? .distantPast
            let ob = b.ownLastActivity ?? .distantPast
            return oa != ob ? oa > ob : a.id < b.id
        }
    }
}
