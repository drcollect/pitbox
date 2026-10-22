import Darwin
import Foundation
import PitboxKit

/// The user's buckets and who sits where: `code-buckets.json` in the app-support folder, read once with the careful
/// read below and kept in memory; every change is written atomically (a temporary file created 0600, `fsync`, rename)
/// on a background queue, at most once a second (changes coalesce). Only the app writes it; the folder is private to
/// the user (0700).
///
/// - **Reading** (`CodeStateFiles.readObject`): no link followed, a regular file of the user's, at most 256 KB, nesting
///   at most 16, a duplicated key fails the file; then `CodeBucketFile.decode`'s tolerant rules. A broken file (not
///   JSON, a link, another owner, too large, not a version-1 object) is renamed `code-buckets.json.corrupt` (replacing
///   an older one), logged with its size and reason only, and the block starts with Unsorted alone and the note "Your
///   buckets couldn't be read; a copy was kept." until the user's next change.
/// - **Where new sessions land:** a session seen for the first time goes to Unsorted, with a first-seen time
///   that is always later than every earlier one (whole milliseconds), so its stable place survives restarts.
///   Parking never moves a session; a move is the user's drag (or a drag-to-park drop over a bucket).
/// - **Pruning:** entries not seen for 30 days, or of archived sessions, go; at most 500 entries (the oldest first).
/// - **Limits:** 20 buckets, Unsorted included; names of 1-32 characters.
///
/// Main thread only: the block model owns it. `url` nil keeps everything in memory (tests and previews).
@MainActor
final class CodeBucketStore {
    /// The note under the block header after a broken file.
    static let brokenNote = "Your buckets couldn't be read; a copy was kept."
    /// `lastSeen` is refreshed at most this often (the file is not rewritten for every pass).
    static let lastSeenRefresh: TimeInterval = 3600

    private(set) var state = CodeBucketState()
    /// "Your buckets couldn't be read; a copy was kept." after a broken file, until the user's next change.
    private(set) var note: String?
    private let writer: CodeBucketWriter?
    private var lastFirstSeenMS: Int64 = 0
    private var lastPruned = Date.distantPast

    /// Production: the real file, read now.
    convenience init(url: URL = Paths.appSupport.appendingPathComponent("code-buckets.json")) {
        self.init(url: url, owner: getuid(), now: Date(), writeInterval: CodeTuning.memoryWriteInterval)
    }

    /// Tests: an injected owner (a file of anyone else reads as broken), clock and write interval; `url` nil: memory only.
    init(url: URL?, owner: uid_t, now: Date, writeInterval: TimeInterval) {
        writer = url.map { CodeBucketWriter(url: $0, interval: writeInterval) }
        guard let url else { return }
        switch CodeStateFiles.readObject(at: url, owner: owner, maxBytes: CodeTuning.settingsReadMax) {
        case .failure(.missing):
            break
        case .failure(let failure):
            setAside(url, reason: failure.label)
        case .success(let root):
            guard let decoded = CodeBucketFile.decode(root, now: now) else {
                setAside(url, reason: "shape")
                break
            }
            state = decoded.state
            lastFirstSeenMS = state.sessions.values.map { CodeBucketFile.milliseconds($0.firstSeen) }.max() ?? 0
            lastPruned = now
            if decoded.cleaned { persist() }
        }
    }

    private func setAside(_ url: URL, reason: String) {
        let size = CodeStateFiles.entrySize(url)
        let moved = CodeStateFiles.setAside(url)
        note = Self.brokenNote
        CodeTileLog.warn("buckets file unreadable size=\(size) reason=\(reason) kept=\(moved ? "corrupt" : "no")")
    }

    // MARK: Reading

    /// Unsorted first, then the others in the order they were made.
    var buckets: [CodeBucket] { state.buckets }

    func bucket(_ id: String) -> CodeBucket? { state.buckets.first { $0.id == id } }

    /// The bucket `sessionID` sits in: Unsorted when it was never seen or its bucket is gone.
    func bucketID(of sessionID: String) -> String {
        guard let id = state.sessions[sessionID]?.bucket, bucket(id) != nil else { return CodeBucket.unsortedID }
        return id
    }

    /// When the app first saw the session as a pop-out (its stable place).
    func firstSeen(of sessionID: String) -> Date? { state.sessions[sessionID]?.firstSeen }

    /// "+ New bucket" is on below 20 buckets.
    var canCreate: Bool { state.buckets.count < CodeTuning.maxBuckets }

    // MARK: What the app sees

    /// The sessions the block has monitors or pop-outs for, in the source's order: new ones go to Unsorted with a fresh
    /// first-seen time; known ones refresh `lastSeen` (at most hourly). Old entries are pruned, at most hourly.
    func noteSeen(_ sessionIDs: [String], now: Date) {
        var changed = false
        for id in sessionIDs where CodeIDs.isSessionID(id) {
            if var member = state.sessions[id] {
                guard now.timeIntervalSince(member.lastSeen) >= Self.lastSeenRefresh else { continue }
                member.lastSeen = now
                state.sessions[id] = member
            } else {
                state.sessions[id] = member(in: CodeBucket.unsortedID, now: now)
            }
            changed = true
        }
        let keeping = Set(sessionIDs)
        if state.sessions.count > CodeBucketState.maxSessions || now.timeIntervalSince(lastPruned) >= Self.lastSeenRefresh {
            lastPruned = now
            if state.prune(now: now, keeping: keeping) { changed = true }
        }
        if changed { persist() }
    }

    /// Forgets archived sessions (pruning).
    func forget(_ sessionIDs: Set<String>) {
        let before = state.sessions.count
        for id in sessionIDs { state.sessions[id] = nil }
        if state.sessions.count != before { persist() }
    }

    /// A new entry: a first-seen time later than every one handed out or read (whole milliseconds, so a burst runs a few
    /// milliseconds ahead of the clock), and a last-seen time never before it.
    private func member(in bucket: String, now: Date) -> CodeBucketMember {
        let next = max(Int64((now.timeIntervalSince1970 * 1000).rounded(.down)), lastFirstSeenMS + 1)
        lastFirstSeenMS = next
        let firstSeen = Date(timeIntervalSince1970: TimeInterval(next) / 1000)
        return CodeBucketMember(bucket: bucket, firstSeen: firstSeen, lastSeen: max(now, firstSeen))
    }

    // MARK: The user's changes (each clears the broken-file note)

    /// "+ New bucket": "New bucket" at the end, in the first palette colour no bucket uses. Nil at 20 buckets.
    @discardableResult
    func create() -> CodeBucket? {
        guard canCreate else { return nil }
        let bucket = CodeBucket(id: newID(), name: CodeBucketName.newBucket, color: .forNewBucket(existing: state.buckets),
                                folded: false)
        state.buckets.append(bucket)
        changedByUser()
        return bucket
    }

    /// A new name (typed, then trimmed); false for Unsorted, an unknown bucket or a name empty after trimming.
    @discardableResult
    func rename(_ id: String, to text: String) -> Bool {
        guard let index = index(of: id), !state.buckets[index].isUnsorted, let name = CodeBucketName.committed(text) else {
            return false
        }
        guard state.buckets[index].name != name else { return true }
        state.buckets[index].name = name
        changedByUser()
        return true
    }

    func setColor(_ id: String, _ color: CodeBucketColor) {
        guard let index = index(of: id), state.buckets[index].color != color else { return }
        state.buckets[index].color = color
        changedByUser()
    }

    func setFolded(_ id: String, _ folded: Bool) {
        guard let index = index(of: id), state.buckets[index].folded != folded else { return }
        state.buckets[index].folded = folded
        changedByUser()
    }

    /// Deletes a bucket (never Unsorted): its sessions move to Unsorted, where their first-seen times give their
    /// places. No window, session or file is touched. Returns how many sessions moved, nil when nothing was deleted.
    @discardableResult
    func delete(_ id: String) -> Int? {
        guard let index = index(of: id), !state.buckets[index].isUnsorted else { return nil }
        state.buckets.remove(at: index)
        var moved = 0
        for (session, member) in state.sessions where member.bucket == id {
            state.sessions[session]?.bucket = CodeBucket.unsortedID
            moved += 1
        }
        changedByUser()
        return moved
    }

    /// Moves a session to another bucket (a drop). False when the bucket is unknown or it already sits there.
    @discardableResult
    func move(_ sessionID: String, to bucketID: String, now: Date) -> Bool {
        guard CodeIDs.isSessionID(sessionID), bucket(bucketID) != nil, self.bucketID(of: sessionID) != bucketID else { return false }
        if state.sessions[sessionID] == nil {
            state.sessions[sessionID] = member(in: bucketID, now: now)
        } else {
            state.sessions[sessionID]?.bucket = bucketID
        }
        changedByUser()
        return true
    }

    // MARK: Writing

    /// Writes pending changes now, on the caller's thread (tests, and app quit).
    func flush() { writer?.flush() }

    /// Tests: how many times the file was written.
    var writeCount: Int { writer?.writes ?? 0 }

    private func changedByUser() {
        note = nil
        persist()
    }

    private func persist() {
        guard let writer else { return }
        guard let data = CodeBucketFile.encode(state) else {
            CodeTileLog.warn("buckets write failed reason=encoding")
            return
        }
        writer.submit(data)
    }

    private func index(of id: String) -> Int? { state.buckets.firstIndex { $0.id == id } }

    /// `b-` and 6 random characters of `[a-z0-9]`, unused.
    private func newID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        while true {
            let id = "b-" + String((0..<6).map { _ in alphabet.randomElement() ?? "a" })
            if index(of: id) == nil { return id }
        }
    }
}

/// The background writer of `code-buckets.json`: the first change of a burst opens a window of `interval`, then the
/// latest bytes are written once (a temporary file 0600, `fsync`, rename). A file the reader would refuse (over 256 KB)
/// is never written. Thread-safe.
final class CodeBucketWriter: @unchecked Sendable {
    private let url: URL
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "pitbox.code.buckets", qos: .utility)
    private let lock = NSLock()
    private var pending: Data?
    private var scheduled = false
    private var count = 0

    init(url: URL, interval: TimeInterval) {
        self.url = url
        self.interval = interval
    }

    /// How many times the file was written.
    var writes: Int { lock.withLock { count } }

    func submit(_ data: Data) {
        let schedule = lock.withLock { () -> Bool in
            pending = data
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + interval) { [self] in writeNow() }
    }

    /// Writes what is pending, on the caller's thread.
    func flush() { queue.sync { writeNow() } }

    /// On `queue`.
    private func writeNow() {
        let data = lock.withLock { () -> Data? in
            scheduled = false
            defer { pending = nil }
            return pending
        }
        guard let data else { return }
        guard data.count <= CodeTuning.settingsReadMax else {
            CodeTileLog.warn("buckets write refused size=\(data.count)")
            return
        }
        do {
            try CodeStateFiles.writeAtomically(data, to: url)
            lock.withLock { count += 1 }
        } catch {
            // Kept for the next change (unless a newer one is waiting already).
            lock.withLock { if pending == nil { pending = data } }
            CodeTileLog.warn("buckets write failed reason=\((error as? CodeStateFiles.WriteFailure)?.label ?? "error")")
        }
    }
}
