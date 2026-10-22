import Foundation
import PitboxKit

/// Which transcript form a session was found under: `~/.claude/projects/<cwd folder>/<id>.jsonl` or the SSH
/// mirror `~/.claude/projects/ssh-<id>/<id>.jsonl`.
enum TranscriptForm: Equatable, Sendable { case local, sshMirror }

/// The offers of one reply as the session side keeps them. The store is shaped for up to 3 replies per session (the
/// latest and up to 2 earlier ones whose offers are kept); the parse itself keeps the latest finished reply only.
struct ReplyOffers: Equatable, Sendable {
    /// What the entries were built from: reused while it stays the same, so the classifier runs once per reply.
    struct Key: Equatable, Sendable {
        var replyUUID: String
        var readCompletely: Bool
        var facts: CommandSessionFacts
        var programs: Int
        var source: CommandOffer.Source
        var folder: CommandOffer.Folder
    }

    var key: Key
    var replyUUID: String
    var replyTime: Date
    var entries: [CodeOfferEntry]
    var notShown: Int
    var readCompletely: Bool
    /// What the click-time check needs (registered while the entries are shown).
    var registration: CodeOfferFreshnessChecker.Reply
}

/// Everything the data side keeps about one shown session between reads.
struct SessionRecord {
    static let maxBurnedReplies = 16

    let id: String
    /// The local index (`#3` in logs), stable for this run of the app
    let index: Int
    /// When the app first saw the session (for a stable order: copy, then first seen).
    let firstSeen: Int
    var profile: CodeProfile
    /// From `session-popouts.json`; nil when the session is shown only because the block follows it.
    var popout: ClaudePopouts.Entry?
    /// Within the limit of watched sessions: its transcript is read and watched.
    var fullyRead = false

    var sessionFile: CarefulPath?
    var fileIdentity: FileIdentity?
    var file: ClaudeSessionFile?
    var fileFailure: ClaudeFileFailure?
    var cwdExists = false
    /// The file names no SSH configuration and its `cwd` is on a refused root (an external or network volume): never
    /// looked up, the place is unknown, and none of the session's commands runs or is typed (Copy only).
    var cwdOnRefusedRoot = false

    var transcript: CarefulPath?
    var transcriptForm: TranscriptForm?
    var transcriptFailure: CarefulReadFailure?
    var cursor: TranscriptCursor?
    var tracker = TurnTracker()
    var activity = ActivityBuckets()
    /// Replies whose offers were dropped because the transcript was replaced or cut: never offered again.
    var burnedReplies: [String] = []
    /// Oldest first; the parse holds at most the latest reply.
    var replies: [ReplyOffers] = []

    var loggedOffers: String?
    var loggedFailure: String?

    /// For the derivers: when the transcript last grew and when the session file's `lastActivityAt` last moved,
    /// on this Mac's clock; and a number that changes whenever the digest's inputs (transcript lines, session file)
    /// changed, so derivers can cache by it.
    var lastGrowthAt: Date?
    var lastActivityMovedAt: Date?
    private(set) var digestVersion = 0

    init(id: String, index: Int, firstSeen: Int, profile: CodeProfile, popout: ClaudePopouts.Entry?) {
        self.id = id
        self.index = index
        self.firstSeen = firstSeen
        self.profile = profile
        self.popout = popout
    }

    /// The transcript was read and nothing about it failed.
    var transcriptReadable: Bool { file != nil && cursor != nil && transcriptFailure == nil }

    /// The session's place: local only when the file says so positively (no `sshConfig`, a transcript in the
    /// local form, a `cwd` that exists here); SSH with `sshConfig.sshHost` and an `ssh-` mirror; unknown otherwise.
    var place: CommandSessionFacts.Place {
        guard let file, let form = transcriptForm, transcriptFailure == nil else { return .unknown }
        if file.hasSSHConfig { return file.sshHost != nil && form == .sshMirror ? .ssh : .unknown }
        return form == .local && cwdExists ? .local : .unknown
    }

    // MARK: Reading

    /// Reads the session file again when its identity changed. `path` comes from the session index. `folders` and
    /// `pathGuard` are the lookups for the session's `cwd` and the network check they run under (tests pass fakes).
    mutating func refreshFile(path: CarefulPath?, owner: uid_t, folders: LocalPathFileSystem = LiveLocalPathFileSystem(),
                              pathGuard: () -> NetworkPathGuard = { .current() }) {
        if path != sessionFile {
            sessionFile = path
            fileIdentity = nil
        }
        guard let path else {
            if file != nil { digestVersion &+= 1 }
            file = nil
            fileIdentity = nil
            fileFailure = .read(.missing)
            cwdExists = false
            cwdOnRefusedRoot = false
            return
        }
        switch CarefulFiles.readIfChanged(path, owner: owner, maxBytes: ClaudeSessionFile.maxBytes, known: fileIdentity) {
        case .failure(let failure):
            if file != nil { digestVersion &+= 1 }
            file = nil
            fileIdentity = nil
            fileFailure = .read(failure)
        case .success(let (data, identity)):
            fileIdentity = identity
            if let data {
                switch ClaudeSessionFile.parse(data) {
                case .success(let parsed):
                    if parsed.lastActivityAt != file?.lastActivityAt || lastActivityMovedAt == nil {
                        // When it moved: the value itself, never later than the file's own write.
                        lastActivityMovedAt = parsed.lastActivityAt.map { min($0, identity.modifiedDate) }
                    }
                    file = parsed
                    fileFailure = nil
                case .failure(let failure):
                    file = nil
                    fileFailure = failure
                }
                digestVersion &+= 1
            }
        }
        let here = Self.cwdHere(file, folders: folders, pathGuard: pathGuard)
        cwdExists = here == .folder
        cwdOnRefusedRoot = here == .refusedRoot
    }

    /// Where a session's `cwd` is on this Mac, as far as Pitbox may look.
    enum CwdHere: Equatable {
        /// An existing folder here.
        case folder
        /// Not a folder here, not asked (an SSH session), or not an absolute path.
        case notHere
        /// On a refused root (`/Volumes`, `/net`, `/home`, `/Network`, an automount point, a network filesystem), the
        /// path itself or a link on the way: nothing was looked up there.
        case refusedRoot
    }

    /// Where the session's `cwd` is. Never asked for an SSH session (its `cwd` is a path on the server: `/home/…` here is
    /// an automount point); a local session's `cwd` is walked part by part under the network check, so a folder on
    /// `/net`, `/home`, `/Volumes`, `/Network` or an automount point is never looked up: it is `refusedRoot`, and the
    /// session's place is unknown (docs/THREAT_MODEL.md, T33).
    static func cwdHere(_ file: ClaudeSessionFile?, folders: LocalPathFileSystem, pathGuard: () -> NetworkPathGuard) -> CwdHere {
        guard let file, !file.hasSSHConfig, let cwd = file.cwd, cwd.hasPrefix("/"), !cwd.contains("\0") else { return .notHere }
        switch LocalPathWalk.resolve(cwd, followLastLink: true, guard: pathGuard(), fs: folders) {
        case .network: return .refusedRoot
        case .found(_, let info) where info.kind == .directory: return .folder
        default: return .notHere
        }
    }

    /// Finds and reads the transcript: appended lines only, or a fresh tail when it is new, replaced, cut or far
    /// ahead. Returns why a fresh read happened when that drops offers (replaced or cut), for the log.
    mutating func refreshTranscript(projects: CarefulPath?, owner: uid_t, now: Date) -> TranscriptRead.FreshReason? {
        guard fullyRead, let file else {
            clearTranscript()
            return nil
        }
        guard let cli = file.cliSessionID else {
            clearTranscript()
            transcriptFailure = file.cliSessionIDRejected ? .badPath : .missing
            return nil
        }
        var chosen: (path: CarefulPath, form: TranscriptForm)?
        var failure: CarefulReadFailure = .missing
        search: for candidate in Self.transcriptCandidates(projects: projects, cli: cli, file: file) {
            switch CarefulFiles.identity(candidate.path, owner: owner) {
            case .success:
                chosen = candidate
                break search
            case .failure(.missing):
                continue search
            case .failure(let refused):
                // A link, a FIFO, another owner: refused, and no other form is tried instead.
                failure = refused
                break search
            }
        }
        guard let chosen else {
            clearTranscript()
            transcriptFailure = failure
            return nil
        }
        if chosen.path != transcript {
            resetTranscriptState()
            transcript = chosen.path
        }
        transcriptForm = chosen.form
        let previousReply = tracker.turn?.lastAssistantUUID
        let previousSize = cursor?.identity.size
        var dropped: TranscriptRead.FreshReason?
        switch TranscriptReader.read(chosen.path, owner: owner, cursor: cursor, digestFacts: true,
                                     reaches: CodeTurnDigestBuilder.windowHoldsNeededTurns) {
        case .failure(let refused):
            transcriptFailure = refused
            cursor = nil
            digestVersion &+= 1
        case .success(let read):
            transcriptFailure = nil
            let identity = read.cursor.identity
            switch read.kind {
            case .fresh(let reason):
                if reason == .replaced || reason == .cut {
                    if let previousReply { burn(previousReply) }
                    dropped = reason
                }
                var fresh = TurnTracker()
                activity.reset()
                for line in read.lines {
                    fresh.feed(line, fallbackTime: now)
                    if let at = line.entry?.timestamp { activity.add(line.length + 1, at: at, now: now) }
                }
                tracker = fresh
                lastGrowthAt = identity.size > 0 ? min(identity.modifiedDate, now) : nil
                digestVersion &+= 1
            case .appended:
                for line in read.lines { tracker.feed(line, fallbackTime: now) }
                if let previousSize { activity.add(Int(identity.size - previousSize), at: now, now: now) }
                if identity.size > (previousSize ?? 0) { lastGrowthAt = min(identity.modifiedDate, now) }
                digestVersion &+= 1
            case .unchanged:
                break
            }
            cursor = read.cursor
        }
        activity.prune(now: now)
        return dropped
    }

    /// The turn digest as of the last read; nil while the transcript is not readable. `copied` holds the
    /// tool_use ids also found in another followed session's digest (marked `isCopied`).
    func digest(copied: Set<String> = []) -> CodeTurnDigest? {
        guard transcriptReadable, let file else { return nil }
        return tracker.digest.digest(midTurn: file.midTurn, lastGrowthAt: lastGrowthAt,
                                     lastActivityMovedAt: lastActivityMovedAt,
                                     publishedArtifacts: file.publishedArtifacts, copied: copied)
    }

    /// Forgets the transcript (beyond the watch limit, or no usable session file).
    mutating func clearTranscript() {
        resetTranscriptState()
        transcript = nil
        transcriptForm = nil
        transcriptFailure = nil
    }

    /// Drops the offers of `uuid` for good.
    mutating func burn(_ uuid: String) {
        guard !burnedReplies.contains(uuid) else { return }
        burnedReplies.append(uuid)
        if burnedReplies.count > Self.maxBurnedReplies { burnedReplies.removeFirst(burnedReplies.count - Self.maxBurnedReplies) }
        replies.removeAll { $0.replyUUID == uuid }
    }

    private mutating func resetTranscriptState() {
        cursor = nil
        tracker = TurnTracker()
        activity.reset()
        lastGrowthAt = nil
        digestVersion &+= 1
    }

    // MARK: Paths

    /// The transcript paths to try, in order: the form the session file implies first, the other one second (finding
    /// only the other one makes the place unknown).
    static func transcriptCandidates(projects: CarefulPath?, cli: String, file: ClaudeSessionFile)
        -> [(path: CarefulPath, form: TranscriptForm)] {
        guard let projects else { return [] }
        let name = "\(cli).jsonl"
        let mirror = projects.appending("ssh-\(cli)")?.appending(name).map { (path: $0, form: TranscriptForm.sshMirror) }
        let local = file.cwd.flatMap(projectFolderName).flatMap { projects.appending($0)?.appending(name) }
            .map { (path: $0, form: TranscriptForm.local) }
        return (file.hasSSHConfig ? [mirror, local] : [local, mirror]).compactMap { $0 }
    }

    /// Claude Code's folder name for a working folder: every UTF-16 unit outside `[A-Za-z0-9-]` becomes `-` (dots too,
    /// not only `/` and spaces). Nil for a relative path or a name over 255 bytes.
    static func projectFolderName(_ cwd: String) -> String? {
        guard cwd.hasPrefix("/") else { return nil }
        var name = ""
        name.reserveCapacity(cwd.utf16.count)
        for unit in cwd.utf16 {
            let allowed = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
                || unit == 0x2D
            name.unicodeScalars.append(allowed ? Unicode.Scalar(UInt8(unit)) : "-")
        }
        return CarefulFiles.isSafeName(name) ? name : nil
    }
}
