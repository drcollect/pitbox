import Darwin
import Foundation
import PitboxKit

public extension CodeDeriverSet {
    /// Ready for you: offers of earlier replies stay runnable behind R22, with the facts of what happened since, and
    /// the click-time check knows them. Register it with the engine beside the other features' sets.
    static var ready: CodeDeriverSet { CodeDeriverSet(perSession: [EarlierOffersDeriver()]) }
}

/// Offers of earlier replies (order 600). The parse offers only the latest finished reply; once a message
/// of the user's, a reply or a background update follows it, those offers move here with `offer.supersession` set, and
/// stay until a third newer reply to a turn of the user's or another session's, 24 hours, an archived session, a replaced
/// or cut transcript, a duplicated uuid, or the session leaving the followed set.
///
/// - Offers are carried over exactly as the parse built them (its facts, classes and numbers), cached in memory only.
///   A reply this run never saw as the latest (the app restarted, a session followed late, a reply answered within one
///   parse) is rebuilt from the digest with the session facts the parse used for this session's (or, for the facts
///   every session shares, any session's) offers; without such facts nothing is rebuilt (fail toward fewer offers; the
///   derive input does not carry those facts).
/// - Copy only: an offer whose turn was not read completely, or whose turn the digest's bounds
///   dropped, gets class Partly read and `replyReadCompletely` false, and no registration (nothing can run).
/// - The click-time check (`CodeOfferFreshnessChecker`) gets one registration per runnable earlier reply, and a marker
///   for the latest reply's, so a move-on answers `superseded` with its facts instead of `stale`.
final class EarlierOffersDeriver: CodeSessionDeriver {
    let label = "earlier-offers"
    let order = CodeDeriveOrder.earlierOffers

    /// Replies kept per session: the latest and the ones with at most `newerRepliesMax` newer replies, plus one spare.
    static let repliesKept = CodeTuning.newerRepliesMax + 2
    /// Burned reply uuids kept at most; past it only the ones the transcript still holds stay (the others cannot return).
    static let burnedMax = 1024

    /// One reply's offers as last built.
    struct Kept: Equatable {
        var replyUUID: String
        var replyTime: Date
        /// Without `supersession` (it is set again at each derive).
        var entries: [CodeOfferEntry]
    }

    /// The session-level facts the parse put into one session's offers: reused for rebuilt offers of that session.
    struct Template: Equatable {
        var facts: CommandSessionFacts
        var programs: Set<String>?
        var folder: CommandOffer.Folder
        var profileLetter: String?
        var profileName: String?
    }

    /// Facts that are the same for every session (one SSH config, one clean PATH, one user), from any session's offers.
    struct SharedFacts: Equatable {
        var homeDirectory: String
        var userName: String
        var knownSSHHosts: [String]
        var programs: Set<String>?
        var multipleProfiles: Bool
        /// `ssh -G` HostNames by alias, as the parse resolved them.
        var hostNames: [String: String] = [:]
    }

    private struct SessionState {
        var kept: [String: Kept] = [:]
        var identity: FileIdentity?
        /// Final replies of the transcript as last read: burned when it is replaced or cut.
        var replies: Set<String> = []
        var burned: Set<String> = []
        var template: Template?
        /// The last log line per reply, so one supersession is logged once.
        var logged: [String: String] = [:]
        /// Offers rebuilt from the digest, reused while what they were built from is unchanged.
        var rebuilt = EarlierOffersRebuilt()
    }

    private var sessions: [String: SessionState] = [:]
    private(set) var shared: SharedFacts?
    /// Tests: the turns, items and first lines the last pass's supersession check looked at, and the offers built from
    /// the digest so far (one per reply rebuilt).
    private(set) var lastSweepWork = 0
    private(set) var rebuildCount = 0

    func sessionLeft(_ sessionID: String) { sessions[sessionID] = nil }

    // MARK: Deriving

    func derive(_ input: CodeDeriveInput, into fields: inout CodeDerivedFields) {
        let snapshot = input.snapshot
        var state = sessions[input.sessionID] ?? SessionState()
        defer { sessions[input.sessionID] = state }
        guard !snapshot.isArchived, let transcript = input.transcript, let sessionFile = input.sessionFile,
              let cli = Self.cliSessionID(of: transcript) else {
            state.kept = [:]
            state.rebuilt = EarlierOffersRebuilt()
            return
        }
        let digest = input.digest
        let latestOffers = snapshot.offers
        let latestReply = latestOffers.first?.offer.id.replyUUID

        // A replaced or cut transcript drops every reply read from it, for good.
        var identity: FileIdentity?
        if case .success(let now) = CarefulFiles.identity(transcript, owner: input.owner) {
            if let before = state.identity, !now.isSameFile(as: before) || now.size < before.size {
                state.burned.formUnion(state.replies)
                state.burned.formUnion(state.kept.keys)
                state.kept = [:]
                CodeLog.info("offers burned session=#\(snapshot.index) reason=transcript")
            }
            state.identity = now
            identity = now
        }
        state.replies = Set(digest.turns.compactMap(\.replyUUID)).union(state.kept.keys)
        if state.burned.count > Self.burnedMax { state.burned.formIntersection(state.replies) }

        if let latestReply, let first = latestOffers.first, !state.burned.contains(latestReply) {
            state.kept[latestReply] = Kept(replyUUID: latestReply, replyTime: first.offer.source.replyTime,
                                           entries: latestOffers.map(Self.withoutSupersession))
            learn(from: first, into: &state)
        }

        var out: [(reply: String, time: Date, entries: [CodeOfferEntry], runnable: Bool)] = []
        var handled = Set<String>()
        if let latestReply { handled.insert(latestReply) }
        let midTurnReply = inferredMidTurnReply(digest, kept: state.kept, latest: latestReply)

        // Replies in the digest: every finished turn but the latest offered one, and a latest turn kept open by midTurn;
        // a reply that cannot hold a code block is passed over before any other work (a fleet digest has 200 turns).
        var candidates: [(index: Int, reply: String)] = []
        for (index, turn) in digest.turns.enumerated() {
            guard turn.isFinished, let reply = turn.replyUUID, reply != latestReply else { continue }
            guard state.kept[reply] != nil || Self.mayHoldCode(turn) else { continue }
            candidates.append((index, reply))
        }
        if let midTurnReply { candidates.append((digest.turns.count - 1, midTurnReply)) }

        // The supersession facts of every candidate that gets that far, judged together in one pass over the digest (one
        // pass per reply read the newer turns again for each: quadratic in a fleet session's 200 notice turns).
        func sessionFacts(_ reply: String) -> OfferSupersession.SessionFacts {
            OfferSupersession.SessionFacts(midTurn: reply == midTurnReply, lastActivityAt: digest.lastActivityMovedAt,
                                           isSSH: snapshot.place == .ssh)
        }
        func timeOfReply(_ reply: String, _ turn: CodeTurnDigest.Turn) -> Date {
            state.kept[reply]?.replyTime ?? turn.finishedAt ?? turn.lastEntryAt ?? input.now
        }
        var queries: [OfferSupersession.Query] = []
        for (index, reply) in candidates where !state.burned.contains(reply) && !digest.duplicateUUIDs.contains(reply) {
            let time = timeOfReply(reply, digest.turns[index])
            guard input.now.timeIntervalSince(time) < CommandOffer.maxAge else { continue }
            queries.append(OfferSupersession.Query(replyUUID: reply, replyTime: time, session: sessionFacts(reply)))
        }
        var work = 0
        let judged = OfferSupersession.evaluate(queries, in: digest, work: &work)
        let verdicts = Dictionary(zip(queries, judged), uniquingKeysWith: { first, _ in first })
        lastSweepWork = work
        let rebuildTemplate = template(for: snapshot, own: state.template, settings: input.settings)
        // The session works on a refused root now: every earlier offer carries it, kept ones too (made before, when the
        // folder may have been an ordinary one). Added from the current snapshot on every pass; a mark an offer was made
        // with is never removed (the sheet decides again when it opens and at the click).
        let refusedCwd = snapshot.place != .ssh && snapshot.cwdOnRefusedRoot ? snapshot.cwd : nil
        state.rebuilt.begin(template: rebuildTemplate)
        defer { state.rebuilt.end() }

        for (index, reply) in candidates {
            handled.insert(reply)
            if state.burned.contains(reply) {
                forget(reply, reason: "burned", in: &state, index: snapshot.index)
                continue
            }
            if digest.duplicateUUIDs.contains(reply) {
                forget(reply, reason: "duplicate", in: &state, index: snapshot.index)
                continue
            }
            let turn = digest.turns[index]
            let replyTime = timeOfReply(reply, turn)
            guard input.now.timeIntervalSince(replyTime) < CommandOffer.maxAge else {
                forget(reply, reason: "age", in: &state, index: snapshot.index)
                continue
            }
            let query = OfferSupersession.Query(replyUUID: reply, replyTime: replyTime, session: sessionFacts(reply))
            let supersession: CommandOffer.Supersession
            let verdict = verdicts[query]
                ?? OfferSupersession.evaluate(reply, in: digest, replyTime: replyTime, session: query.session)
            switch verdict {
            case .superseded(let found): supersession = found
            case .dropped:
                forget(reply, reason: "newer-replies", in: &state, index: snapshot.index)
                continue
            case .fresh, .notFound:
                continue
            }
            let entries: [CodeOfferEntry]
            if let kept = state.kept[reply] {
                entries = kept.entries
            } else {
                guard let rebuildTemplate else { continue }
                let source = EarlierOffersRebuilt.Source(turn, replyTime: replyTime, snapshot: snapshot)
                let rebuilt: [CodeOfferEntry]
                if let known = state.rebuilt.entries(for: reply, source: source) {
                    rebuilt = known
                } else {
                    rebuilt = rebuild(turn, reply: reply, replyTime: replyTime, snapshot: snapshot,
                                      template: rebuildTemplate)
                    rebuildCount += 1
                    state.rebuilt.store(rebuilt, for: reply, source: source)
                }
                guard !rebuilt.isEmpty else { continue }
                entries = rebuilt
                state.kept[reply] = Kept(replyUUID: reply, replyTime: replyTime, entries: rebuilt)
            }
            let complete = turn.readCompletely && entries.allSatisfy(\.offer.replyReadCompletely)
            out.append((reply, replyTime, Self.applying(supersession, complete: complete, refusedCwd: refusedCwd, to: entries),
                        complete))
            logSupersession(supersession, reply: reply, index: snapshot.index, state: &state)
        }

        // Kept replies whose turn left the digest: Copy only when its bounds dropped them, else gone (pruned by
        // three newer replies: the digest keeps every turn that could still run).
        for (reply, kept) in state.kept where !handled.contains(reply) {
            let replies = digest.turns.filter { $0.origin != .taskNotification && $0.isFinished }.count
            guard digest.truncated, replies <= CodeTuning.newerRepliesMax,
                  input.now.timeIntervalSince(kept.replyTime) < CommandOffer.maxAge else {
                forget(reply, reason: "out-of-reach", in: &state, index: snapshot.index)
                continue
            }
            let latestAt = digest.turns.compactMap(\.lastEntryAt).max() ?? kept.replyTime
            let unknown = CommandOffer.Supersession(newerReplies: 0, latestAt: latestAt,
                                                    sessionIsWorking: digest.latestTurn?.isFinished == false)
            out.append((reply, kept.replyTime, Self.applying(unknown, complete: false, refusedCwd: refusedCwd, to: kept.entries),
                        false))
        }

        // Oldest reply first; at most the replies the checker keeps beside the latest.
        out.sort { $0.time != $1.time ? $0.time < $1.time : $0.reply < $1.reply }
        while state.kept.count > Self.repliesKept, let oldest = state.kept.values.min(by: { $0.replyTime < $1.replyTime }) {
            state.kept[oldest.replyUUID] = nil
        }
        fields.earlierOffers = out.flatMap(\.entries)
        fields.deadlines.append(contentsOf: out.map { $0.time.addingTimeInterval(CommandOffer.maxAge) })

        guard let identity else { return }
        var registrations: [CodeOfferFreshnessChecker.Reply] = out.filter(\.runnable).map { item in
            Self.registration(for: item.entries, reply: item.reply, replyTime: item.time, index: snapshot.index,
                              sessionFile: sessionFile, transcript: transcript, cli: cli, identity: identity)
        }
        if let latestReply, let first = latestOffers.first, !state.burned.contains(latestReply) {
            registrations.append(Self.registration(for: latestOffers, reply: latestReply, replyTime: first.offer.source.replyTime,
                                                   index: snapshot.index, sessionFile: sessionFile, transcript: transcript,
                                                   cli: cli, identity: identity))
        }
        fields.earlierRegistrations = Array(registrations.suffix(CodeOfferFreshnessChecker.maxRepliesPerSession))
    }

    // MARK: Pieces

    /// The latest turn's kept reply when the transcript shows nothing after it but the turn is unfinished: the session
    /// file's `midTurn` (the digest applies it; the parse then offers nothing).
    private func inferredMidTurnReply(_ digest: CodeTurnDigest, kept: [String: Kept], latest: String?) -> String? {
        guard let turn = digest.latestTurn, !turn.isFinished else { return nil }
        for reply in kept.keys where reply != latest && OfferSupersession.endsWithAssistantItem(turn, uuid: reply) {
            return reply
        }
        return nil
    }

    private func forget(_ reply: String, reason: String, in state: inout SessionState, index: Int) {
        guard state.kept.removeValue(forKey: reply) != nil else { return }
        state.logged[reply] = nil
        CodeLog.info("offer dropped session=#\(index) reason=\(reason)")
    }

    private func logSupersession(_ s: CommandOffer.Supersession, reply: String, index: Int, state: inout SessionState) {
        let line = "offer superseded session=#\(index) replies=\(s.newerReplies) updates=\(s.newerBackgroundUpdates)"
            + " working=\(s.sessionIsWorking ? "yes" : "no")"
        guard state.logged[reply] != line else { return }
        state.logged[reply] = line
        CodeLog.info(line)
    }

    /// Remembers the facts the parse used for this session, and the ones every session shares.
    private func learn(from entry: CodeOfferEntry, into state: inout SessionState) {
        let offer = entry.offer
        let facts = offer.context.facts
        state.template = Template(facts: facts, programs: offer.context.programsOnCleanPath, folder: offer.folder,
                                  profileLetter: offer.source.profileLetter, profileName: offer.source.profileName)
        var next = SharedFacts(homeDirectory: facts.homeDirectory, userName: facts.userName,
                               knownSSHHosts: facts.knownSSHHosts, programs: offer.context.programsOnCleanPath,
                               multipleProfiles: offer.source.profileLetter != nil, hostNames: shared?.hostNames ?? [:])
        if let alias = facts.sshAlias, let host = facts.resolvedHostName { next.hostNames[alias] = host }
        shared = next
    }

    /// The template for `snapshot`: its own, else one made from the shared facts and what the snapshot says (place,
    /// alias, folder). Nil when no offer of any session was seen yet.
    func template(for snapshot: CodeSessionSnapshot, own: Template?, settings: CodeSettings) -> Template? {
        if let own { return own }
        guard let shared else { return nil }
        let place = snapshot.place
        let alias = place == .ssh ? snapshot.sshHost.flatMap { shared.knownSSHHosts.contains($0) ? $0 : nil } : nil
        let facts = CommandSessionFacts(
            place: place, sshAlias: alias, resolvedHostName: alias.flatMap { shared.hostNames[$0] },
            serverNames: alias.flatMap { settings.serverNames[$0] } ?? [], knownSSHHosts: shared.knownSSHHosts,
            remoteCwd: place == .ssh ? snapshot.cwd : nil, localCwd: place == .local ? snapshot.cwd : nil,
            refusedLocalCwd: place != .ssh && snapshot.cwdOnRefusedRoot ? snapshot.cwd : nil,
            // The snapshot cannot tell an unknown place's folder from a server path: only a local or refused one.
            localWorkFolder: place == .local || (place != .ssh && snapshot.cwdOnRefusedRoot) ? snapshot.cwd : nil,
            homeDirectory: shared.homeDirectory, userName: shared.userName)
        let folder: CommandOffer.Folder
        switch place {
        case .local: folder = CommandOffer.Folder(path: snapshot.cwd ?? shared.homeDirectory, isHomeFallback: snapshot.cwd == nil)
        case .ssh: folder = CommandOffer.Folder(path: shared.homeDirectory, isHomeFallback: false)
        case .unknown: folder = CommandOffer.Folder(path: shared.homeDirectory, isHomeFallback: true)
        }
        let letter = shared.multipleProfiles ? snapshot.profile.letter : nil
        let name = shared.multipleProfiles ? snapshot.profile.name.replacingOccurrences(of: TitleRules.separator, with: " ") : nil
        return Template(facts: facts, programs: shared.programs, folder: folder, profileLetter: letter, profileName: name)
    }

    /// The offers of an earlier reply this run never saw as the latest, built as the parse builds them with
    /// `template` (`template(for:own:settings:)`). Pure in its inputs (`EarlierOffersRebuilt.Source` and the template).
    private func rebuild(_ turn: CodeTurnDigest.Turn, reply: String, replyTime: Date, snapshot: CodeSessionSnapshot,
                         template: Template) -> [CodeOfferEntry] {
        let texts = turn.finalReply.map(\.text)
        guard !texts.isEmpty else { return [] }
        let extraction = OfferExtraction.extract(from: texts, programs: template.programs)
        guard !extraction.blocks.isEmpty else { return [] }
        var facts = template.facts
        facts.turnOrigin = turn.origin
        facts.turnReadWeb = turn.readWeb
        let source = CommandOffer.Source(profileLetter: template.profileLetter, profileName: template.profileName,
                                         sessionID: snapshot.id, headline: snapshot.headline, nickname: snapshot.nickname,
                                         youAsked: turn.askedHead, replyTime: replyTime)
        let complete = turn.readCompletely
        let replyText = texts.joined(separator: "\n\n")
        return extraction.blocks.enumerated().map { position, block in
            let context = CommandContext(facts: facts, caption: block.caption, programsOnCleanPath: template.programs,
                                         runFolder: template.folder.path)
            let offer = CommandOffer(id: CommandOffer.ID(sessionIndex: snapshot.index, replyUUID: reply, number: position + 1),
                                     text: block.text, total: extraction.blocks.count, blockKind: block.kind,
                                     displayLines: block.displayLines, caption: block.caption, source: source,
                                     replyReadCompletely: complete, folder: template.folder, context: context,
                                     replyText: replyText)
            var assessment = CommandClassifier.assess(text: block.text, context: context)
            if !complete, assessment.commandClass != .blocked { assessment.commandClass = .partlyRead }
            return CodeOfferEntry(offer: offer, assessment: assessment)
        }
    }

    // MARK: Helpers

    /// Whether a turn's final reply could hold a code block at all (a fence, or an indented line): a cheap first look.
    static func mayHoldCode(_ turn: CodeTurnDigest.Turn) -> Bool {
        turn.finalReply.contains { text in
            let body = text.text
            return body.contains("```") || body.contains("~~~") || body.contains("\n    ") || body.contains("\n\t")
                || body.hasPrefix("    ") || body.hasPrefix("\t")
        }
    }

    static func withoutSupersession(_ entry: CodeOfferEntry) -> CodeOfferEntry {
        var copy = entry
        copy.offer.supersession = nil
        return copy
    }

    /// The entries with `supersession` set; Copy only (Partly read, not read completely) when `complete` is false. With
    /// `refusedCwd` (the session works on a refused root now) every entry that is not an SSH session's and lacks the mark
    /// gets `refusedLocalCwd`, so the sheet runs and types none of them.
    static func applying(_ supersession: CommandOffer.Supersession, complete: Bool, refusedCwd: String? = nil,
                         to entries: [CodeOfferEntry]) -> [CodeOfferEntry] {
        entries.map { entry in
            var copy = entry
            copy.offer.supersession = supersession
            if let refusedCwd, copy.offer.context.facts.place != .ssh, copy.offer.context.facts.refusedLocalCwd == nil {
                copy.offer.context.facts.refusedLocalCwd = refusedCwd
            }
            if !complete {
                copy.offer.replyReadCompletely = false
                if copy.assessment.commandClass != .blocked { copy.assessment.commandClass = .partlyRead }
            }
            return copy
        }
    }

    /// What the click-time check needs for one reply's offers.
    static func registration(for entries: [CodeOfferEntry], reply: String, replyTime: Date, index: Int,
                             sessionFile: CarefulPath, transcript: CarefulPath, cli: String,
                             identity: FileIdentity) -> CodeOfferFreshnessChecker.Reply {
        var texts: [Int: String] = [:]
        for entry in entries { texts[entry.offer.id.number] = entry.offer.text }
        return CodeOfferFreshnessChecker.Reply(
            sessionIndex: index, replyUUID: reply, texts: texts, sessionFile: sessionFile, transcript: transcript,
            cliSessionID: cli, identity: identity, replyEnd: 0, replyTime: replyTime, keepsOffersWhenSuperseded: true,
            programs: entries.first?.offer.context.programsOnCleanPath, replyText: entries.first?.offer.replyText)
    }

    /// The transcript's file is `<cliSessionId>.jsonl`, so its name gives the id the session file must name.
    static func cliSessionID(of transcript: CarefulPath) -> String? {
        guard let name = transcript.name, name.hasSuffix(".jsonl") else { return nil }
        let id = String(name.dropLast(".jsonl".count))
        return CodeIDs.isCLISessionID(id) ? id : nil
    }
}
