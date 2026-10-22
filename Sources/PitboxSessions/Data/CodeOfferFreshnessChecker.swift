import Darwin
import Foundation
import PitboxKit

/// The session side of the click-time check: when Run, Type or Fetch is pressed, the
/// transcript's end and the session file are read once more, off the main thread, within
/// `CommandOfferFreshness.checkTimeout` (slower counts as unknown). This checks what the files show at that moment,
/// nothing more.
///
/// Always stale: the offer is no longer registered (it went stale meanwhile, its session is no longer followed, or
/// the app restarted), it is older than 24 hours, the session file fails its checks, is archived or names another
/// transcript, the transcript was replaced or cut.
///
/// - **Latest reply only** (`phaseOneCheck`, a reply registered without kept offers): only the latest reply can be
///   fresh; stale when the session file has a turn running (`sshReattach.midTurn`) or a new user entry (not a tool
///   result) or a new assistant entry follows the reply; unknown when a line after it cannot be read (or is still being
///   written) or more than 2 MB follow it.
/// - **Kept offers** (`waveTwoCheck`; `Reply.keepsOffersWhenSuperseded`, set by the earlier-offers deriver, which keeps
///   such offers): the tail (up to 2 MB) is read again; stale when the reply's uuid appears more than once, its turn is
///   out of reach or not read completely, the reply is no longer its turn's final reply, or the block at its number
///   differs from the offer's exact text by one byte; unknown when a line after the reply cannot be read or is still
///   being written; otherwise `OfferSupersession`'s answer over the turns since: fresh, `superseded` with the facts
///   found now (an SSH session whose file says `midTurn`, or whose `lastActivityAt` moved more than 10 s past what its
///   mirror shows, counts as working on a newer turn), or stale after a third newer reply.
public final class CodeOfferFreshnessChecker: CommandOfferFreshnessChecking, @unchecked Sendable {
    /// What the check needs about one reply's offers. Registered by the session side while the offers are shown.
    struct Reply: Equatable, Sendable {
        var sessionIndex: Int
        var replyUUID: String
        /// Offer number → the offer's exact text. Compared byte for byte with the block found again at `replyUUID` and
        /// the number; a 16-hex hash is kept only in item keys and run records, never here.
        var texts: [Int: String]
        var sessionFile: CarefulPath
        var transcript: CarefulPath
        var cliSessionID: String
        /// The transcript's identity and size when the offers were made.
        var identity: FileIdentity
        /// The offset just past the reply's last assistant line (`phaseOneCheck` reads from here; 0 when not known).
        var replyEnd: Int64
        var replyTime: Date
        /// The session side keeps this reply's offers when the session moves on (the earlier-offers deriver runs):
        /// a move-on answers `superseded` with its facts instead of `phaseOneCheck`'s `stale`.
        var keepsOffersWhenSuperseded = false
        /// The program names on the clean PATH the offers were found with (untagged blocks); nil: not known,
        /// then every first word of the registered texts counts.
        var programs: Set<String>? = nil
        /// The whole final reply the offers came from (its text blocks joined by a blank line), compared byte for byte.
        var replyText: String? = nil
    }

    /// Replies kept per session: the latest and up to 2 earlier ones.
    static let maxRepliesPerSession = 3

    private let lock = NSLock()
    private var replies: [Int: [Reply]] = [:]
    private let owner: uid_t
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "pitbox.code.freshness", qos: .userInitiated)
    private let timerQueue = DispatchQueue(label: "pitbox.code.freshness.timer", qos: .userInitiated)
    private let timeoutLock = NSLock()
    private var timeoutValue = CommandOfferFreshness.checkTimeout

    init(owner: uid_t, clock: @escaping @Sendable () -> Date) {
        self.owner = owner
        self.clock = clock
    }

    /// How long a check may take before it counts as unknown (tests shorten it).
    var timeout: TimeInterval {
        get { timeoutLock.withLock { timeoutValue } }
        set { timeoutLock.withLock { timeoutValue = newValue } }
    }

    /// Sets the replies whose offers a session shows now, oldest first (at most `maxRepliesPerSession`, the newest
    /// kept); an empty list removes the session. Two registrations of one reply (the parse's and the earlier-offers
    /// deriver's marker for it) become one: the later one's identity and offsets, with the kept-offer facts of either.
    func register(_ list: [Reply], sessionIndex: Int) {
        var merged: [Reply] = []
        for reply in list where reply.sessionIndex == sessionIndex {
            if let index = merged.firstIndex(where: { $0.replyUUID == reply.replyUUID }) {
                let earlier = merged.remove(at: index)
                var joined = reply
                joined.keepsOffersWhenSuperseded = reply.keepsOffersWhenSuperseded || earlier.keepsOffersWhenSuperseded
                joined.programs = reply.programs ?? earlier.programs
                joined.replyText = reply.replyText ?? earlier.replyText
                merged.append(joined)
            } else {
                merged.append(reply)
            }
        }
        let kept = Array(merged.suffix(Self.maxRepliesPerSession))
        lock.withLock { replies[sessionIndex] = kept.isEmpty ? nil : kept }
    }

    func unregister(sessionIndex: Int) {
        _ = lock.withLock { replies.removeValue(forKey: sessionIndex) }
    }

    func unregisterAll() {
        lock.withLock { replies.removeAll() }
    }

    /// Tests: the registered replies of a session, oldest first.
    func registered(sessionIndex: Int) -> [Reply] {
        lock.withLock { replies[sessionIndex] ?? [] }
    }

    /// Reads the session file and the transcript's end again on the checker's own queue; `unknown` when that takes
    /// longer than `CommandOfferFreshness.checkTimeout` (0.3 s).
    public func freshness(of offer: CommandOffer.ID) async -> CommandOfferFreshness {
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            queue.async { [self] in once.resume(check(offer)) }
            timerQueue.asyncAfter(deadline: .now() + timeout) { once.resume(.unknown) }
        }
    }

    /// Tests: hold back the reading queue (a check then runs into its timeout) and let it go again.
    func suspendChecks() { queue.suspend() }
    func resumeChecks() { queue.resume() }

    /// The check itself, synchronous (on the checker's queue in `freshness(of:)`).
    func check(_ offer: CommandOffer.ID) -> CommandOfferFreshness {
        let list = lock.withLock { replies[offer.sessionIndex] ?? [] }
        guard let reply = list.last(where: { $0.replyUUID == offer.replyUUID }), let text = reply.texts[offer.number] else {
            return .stale
        }
        guard clock().timeIntervalSince(reply.replyTime) <= CommandOffer.maxAge else { return .stale }
        guard reply.keepsOffersWhenSuperseded else {
            // Only the session's latest reply can be fresh; anything after it makes it stale.
            guard list.last == reply else { return .stale }
            return phaseOneCheck(reply)
        }
        return waveTwoCheck(reply, number: offer.number, text: text)
    }

    // MARK: Latest reply only

    private func phaseOneCheck(_ reply: Reply) -> CommandOfferFreshness {
        switch CarefulFiles.read(reply.sessionFile, owner: owner, maxBytes: ClaudeSessionFile.maxBytes) {
        case .failure:
            return .stale
        case .success(let (data, _)):
            guard case .success(let file) = ClaudeSessionFile.parse(data), !file.isArchived, !file.midTurn,
                  file.cliSessionID == reply.cliSessionID else { return .stale }
        }
        let outcome = CarefulFiles.withFile(reply.transcript, owner: owner) { fd, identity -> CommandOfferFreshness in
            guard identity.isSameFile(as: reply.identity), identity.size >= reply.identity.size else { return .stale }
            let after = identity.size - reply.replyEnd
            guard after > 0 else { return .fresh }
            let count = Int(min(after, Int64(TranscriptReader.tailLimit)))
            guard let bytes = CarefulFiles.readRange(fd: fd, from: reply.replyEnd, count: count) else { return .unknown }
            return Self.verdict(after: bytes, complete: after <= Int64(TranscriptReader.tailLimit))
        }
        switch outcome {
        case .failure: return .stale
        case .success(let verdict): return verdict
        }
    }

    /// The lines written after the reply: a new user entry that is not a tool result, or a new assistant entry, means
    /// the session moved on (`phaseOneCheck`).
    static func verdict(after bytes: [UInt8], complete: Bool) -> CommandOfferFreshness {
        bytes.withUnsafeBytes { raw -> CommandOfferFreshness in
            guard let base = raw.baseAddress else { return .fresh }
            var start = 0
            while start < raw.count {
                guard let found = memchr(base + start, 0x0A, raw.count - start) else {
                    // A line still being written (or cut by the 2 MB limit): it may be a new entry.
                    let rest = UnsafeRawBufferPointer(start: base + start, count: raw.count - start)
                    return rest.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D } && complete ? .fresh : .unknown
                }
                let end = base.distance(to: found)
                let line = UnsafeRawBufferPointer(start: base + start, count: end - start)
                if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                    guard let entry = TranscriptEntry.parse(line) else { return .unknown }
                    if !entry.isSidechain {
                        if entry.kind == .assistant { return .stale }
                        if entry.kind == .user && !entry.isToolResult { return .stale }
                    }
                }
                start = end + 1
            }
            return complete ? .fresh : .unknown
        }
    }

    // MARK: Kept offers

    private func waveTwoCheck(_ reply: Reply, number: Int, text: String) -> CommandOfferFreshness {
        let session: OfferSupersession.SessionFacts
        switch CarefulFiles.read(reply.sessionFile, owner: owner, maxBytes: ClaudeSessionFile.maxBytes) {
        case .failure:
            return .stale
        case .success(let (data, identity)):
            guard case .success(let file) = ClaudeSessionFile.parse(data), !file.isArchived,
                  file.cliSessionID == reply.cliSessionID else { return .stale }
            let mirror = reply.transcript.parent?.name == "ssh-" + reply.cliSessionID
            session = OfferSupersession.SessionFacts(
                midTurn: file.midTurn, lastActivityAt: file.lastActivityAt.map { min($0, identity.modifiedDate) },
                isSSH: file.hasSSHConfig && file.sshHost != nil && mirror)
        }
        // The whole tail (up to 2 MB): a duplicated uuid anywhere in it makes the offer stale.
        switch TranscriptReader.read(reply.transcript, owner: owner, cursor: nil, digestFacts: true, reaches: { _ in false }) {
        case .failure:
            return .stale
        case .success(let read):
            let identity = read.cursor.identity
            guard identity.isSameFile(as: reply.identity), identity.size >= reply.identity.size else { return .stale }
            let unfinishedTail = read.cursor.nextOffset < identity.size || read.cursor.dropUntilNewline
            return Self.verdict(lines: read.lines, unfinishedTail: unfinishedTail, reply: reply, number: number, text: text,
                                session: session, now: clock())
        }
    }

    /// The kept-offers answer from the tail's lines (oldest first) and the session file's facts.
    static func verdict(lines: [TranscriptLine], unfinishedTail: Bool, reply: Reply, number: Int, text: String,
                        session: OfferSupersession.SessionFacts, now: Date) -> CommandOfferFreshness {
        let uuid = reply.replyUUID
        var tracker = TurnTracker()
        var turnAtReply: TranscriptTurn?
        var occurrences = 0
        var sawReply = false
        var newTurnSince = false
        var assistantInTurnSince = false
        var unreadableSince = false
        for line in lines {
            tracker.feed(line, fallbackTime: now)
            guard let entry = line.entry else {
                if sawReply { unreadableSince = true }
                continue
            }
            if entry.uuid == uuid { occurrences += 1 }
            guard !entry.isSidechain else { continue }
            if !sawReply {
                if entry.kind == .assistant, entry.uuid == uuid {
                    sawReply = true
                    turnAtReply = tracker.turn
                }
                continue
            }
            if TranscriptReader.startsTurn(entry) {
                newTurnSince = true
            } else if entry.kind == .assistant, !newTurnSince {
                assistantInTurnSince = true
            }
        }
        // The reply must still be its turn's final reply, read completely, its start inside the tail, its uuid unique.
        guard let turn = turnAtReply, occurrences == 1, turn.startHeld, turn.endedByTranscript, turn.isReadCompletely,
              !assistantInTurnSince else { return .stale }
        if unreadableSince || unfinishedTail { return .unknown }
        if let replyText = reply.replyText, !turn.run.joined(separator: "\n\n").utf8.elementsEqual(replyText.utf8) {
            return .stale
        }
        let blocks = OfferExtraction.extract(from: turn.run, programs: reply.programs ?? firstWords(of: reply.texts)).blocks
        guard blocks.indices.contains(number - 1), blocks[number - 1].text.utf8.elementsEqual(text.utf8) else { return .stale }
        let digest = tracker.digest.digest(midTurn: session.midTurn, lastGrowthAt: nil,
                                           lastActivityMovedAt: session.lastActivityAt, publishedArtifacts: [])
        switch OfferSupersession.evaluate(uuid, in: digest, replyTime: reply.replyTime, session: session) {
        case .fresh: return .fresh
        case .superseded(let supersession): return .superseded(supersession)
        case .dropped, .notFound: return .stale
        }
    }

    /// The first word of every line of the registered texts: with them, the untagged blocks that were offered are read
    /// as commands again (an extra block read that way shifts the numbers: stale, the safe side).
    static func firstWords(of texts: [Int: String]) -> Set<String> {
        var words = Set<String>()
        for text in texts.values {
            for line in text.split(separator: "\n") {
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                let word = trimmed.prefix { !$0.isWhitespace && $0 != ";" && $0 != "|" && $0 != "&" && $0 != "(" && $0 != ")" }
                if !word.isEmpty { words.insert(String(word)) }
            }
        }
        return words
    }
}

/// Resumes a continuation once: whichever of the check and the timeout comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandOfferFreshness, Never>?

    init(_ continuation: CheckedContinuation<CommandOfferFreshness, Never>) { self.continuation = continuation }

    func resume(_ value: CommandOfferFreshness) {
        let pending = lock.withLock { () -> CheckedContinuation<CommandOfferFreshness, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
