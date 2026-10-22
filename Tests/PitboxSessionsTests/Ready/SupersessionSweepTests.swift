import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The supersession facts of many replies in one pass (`OfferSupersession.evaluate(_:in:work:)`) give exactly
/// what judging each reply alone gave (the reference below is the per-reply code as it was), and the work grows with
/// the digest, not with its square; the earlier-offers deriver judges its replies together and builds each reply's
/// offers once while their inputs stay the same.
@Suite("Supersession in one pass")
struct SupersessionSweepTests {
    let start = readyNow.addingTimeInterval(-4 * 3600)
    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    // MARK: Fixtures

    /// Human, notice and peer turns; edits of more than 8 files, repeated ones; web reads; finished and running notices,
    /// one queued after a reply in its own turn; a running turn of the user's at the end.
    var mixed: [String] {
        var lines = [Line.user("Fix the checkout", uuid: "u0", at: at(0)),
                     Line.text("Here:\n\n```bash\nmake\n```", uuid: "a0", at: at(1))]
        lines += [Line.user("And now?", uuid: "u1", at: at(5))]
        lines.append(SeamLine.edit("/Users/alex/my project/src/ten.swift", id: "toolu_e10", uuid: "e10", at: at(6), tool: "Write"))
        lines.append(SeamLine.result("toolu_e10", uuid: "er10", at: at(6), content: "ok"))
        lines.append(SeamLine.edit("/Users/alex/my project/src/one.swift", id: "toolu_e11", uuid: "e11", at: at(6)))
        lines.append(SeamLine.result("toolu_e11", uuid: "er11", at: at(6), content: "ok"))
        lines.append(Line.text("Done:\n\n```bash\nmake test\n```", uuid: "r1", at: at(7)))
        lines += [SeamLine.noticeTurn(noticeText(taskID: "t1"), uuid: "n2", at: at(10))]
        for (k, name) in ["one", "two", "three", "four"].enumerated() {
            lines.append(SeamLine.edit("/Users/alex/my project/src/\(name).swift", id: "toolu_e2\(k)", uuid: "e2\(k)", at: at(11)))
            lines.append(SeamLine.result("toolu_e2\(k)", uuid: "er2\(k)", at: at(11), content: "ok"))
        }
        lines.append(Line.text("Agent one reported.\n\n```bash\necho one\n```", uuid: "r2", at: at(12)))
        lines += [SeamLine.noticeTurn(noticeText(taskID: "t2", status: "failed"), uuid: "n3", at: at(20))]
        for (k, name) in ["three", "five", "six", "seven", "eight", "nine"].enumerated() {
            lines.append(SeamLine.edit("/Users/alex/my project/src/\(name).swift", id: "toolu_e3\(k)", uuid: "e3\(k)", at: at(21)))
            lines.append(SeamLine.result("toolu_e3\(k)", uuid: "er3\(k)", at: at(21), content: "ok"))
        }
        lines.append(Line.toolUse("WebFetch", id: "toolu_w3", uuid: "w3", at: at(22), input: ["url": "https://example.com/a"]))
        lines.append(SeamLine.result("toolu_w3", uuid: "wr3", at: at(22), content: "page"))
        lines.append(Line.text("Agent two reported.", uuid: "r3", at: at(23)))
        lines.append(SeamLine.queuedCommand(noticeText(taskID: "t3"), uuid: "q3", at: at(24)))
        lines += [SeamLine.noticeTurn(noticeText(taskID: "t3"), uuid: "n4", at: at(40)),
                  Line.text("Agent three reported.", uuid: "r4", at: at(41))]
        lines += [Line.user("A peer asks", uuid: "u5", at: at(50), origin: "peer"),
                  Line.text("Answered the peer.", uuid: "r5", at: at(51))]
        lines += [SeamLine.noticeTurn(noticeText(toolUseID: "toolu_x", status: "killed"), uuid: "n6", at: at(60)),
                  Line.text("A notice reply.", uuid: "r6", at: at(61))]
        lines += [Line.user("One more", uuid: "u7", at: at(70)),
                  Line.text("Sure.", uuid: "r7", at: at(71))]
        lines += [SeamLine.noticeTurn(noticeText(taskID: "t9"), uuid: "n8", at: at(80)),
                  Line.text("Last notice reply.", uuid: "r8", at: at(81))]
        lines += [Line.user("Keep going", uuid: "u9", at: at(90)),
                  SeamLine.bash("make", description: "Build", id: "toolu_b9", uuid: "b9", at: at(91))]
        return lines
    }

    /// A fleet session: one question, then `turns` notice turns, each editing a few of 12 files and replying with a block.
    static func fleet(turns: Int, start: Date) -> [String] {
        var lines = [Line.user("Run the fleet", uuid: "u0", at: start)]
        for k in 0..<turns {
            let t = start.addingTimeInterval(Double(k + 1) * 60)
            lines.append(SeamLine.noticeTurn(noticeText(taskID: "agent\(k % 10)"), uuid: "n\(k)", at: t))
            for j in 0..<3 {
                let file = (k * 5 + j * 7) % 12
                lines.append(SeamLine.edit("/Users/alex/my project/src/file\(file).swift", id: "toolu_e\(k)_\(j)",
                                           uuid: "e\(k)_\(j)", at: t.addingTimeInterval(5)))
                lines.append(SeamLine.result("toolu_e\(k)_\(j)", uuid: "er\(k)_\(j)", at: t.addingTimeInterval(6), content: "ok"))
            }
            lines.append(Line.text("Agent \(k) reported.\n\n```bash\necho \(k)\n```", uuid: "r\(k)", at: t.addingTimeInterval(10)))
        }
        return lines
    }

    /// Every finished reply, a missing one, under several session facts.
    func queries(_ digest: CodeTurnDigest, extra: [String] = []) -> [OfferSupersession.Query] {
        let replies = digest.turns.compactMap(\.replyUUID) + ["nope"] + extra
        let facts = [OfferSupersession.SessionFacts(),
                     OfferSupersession.SessionFacts(lastActivityAt: at(400), isSSH: true),
                     OfferSupersession.SessionFacts(midTurn: true, lastActivityAt: at(5))]
        return replies.flatMap { reply in
            facts.map { OfferSupersession.Query(replyUUID: reply, replyTime: at(1), session: $0) }
        }
    }

    func expectSameAsAlone(_ digest: CodeTurnDigest, _ queries: [OfferSupersession.Query]) {
        var work = 0
        let together = OfferSupersession.evaluate(queries, in: digest, work: &work)
        for (query, verdict) in zip(queries, together) {
            let alone = Self.reference(query.replyUUID, in: digest, replyTime: query.replyTime, session: query.session)
            #expect(verdict == alone, "\(query.replyUUID) \(query.session)")
            #expect(OfferSupersession.evaluate(query.replyUUID, in: digest, replyTime: query.replyTime,
                                               session: query.session) == alone)
        }
    }

    // MARK: Tests

    @Test func manyRepliesTogetherGiveWhatEachGaveAlone() {
        let digest = digestOf(mixed)
        expectSameAsAlone(digest, queries(digest))
        // The verdicts cover every case: dropped, superseded with files, web, tasks and replies, and fresh.
        var work = 0
        let verdicts = OfferSupersession.evaluate(queries(digest), in: digest, work: &work)
        #expect(verdicts.contains(.notFound))
        let facts = verdicts.compactMap { verdict -> CommandOffer.Supersession? in
            if case .superseded(let s) = verdict { return s } else { return nil }
        }
        #expect(facts.contains { $0.filesChangedCount > 8 && $0.filesChangedSince.count == 8 })
        #expect(facts.contains { $0.readWebSince && $0.backgroundTasksFinishedSince > 0 && $0.replies.count == 4 })
        #expect(facts.contains { $0.unansweredMessageHead == "Keep going" && $0.sessionIsWorking })
        // A finished latest turn: its reply is fresh; with the session file's midTurn it is working.
        let ended = digestOf(mixed.dropLast() + [Line.text("Built.", uuid: "r9", at: at(92))])
        expectSameAsAlone(ended, queries(ended))
        #expect(OfferSupersession.evaluate("r9", in: ended, replyTime: at(92), session: .init()) == .fresh)
        let midTurn = digestOf(mixed.dropLast() + [Line.text("Built.", uuid: "r9", at: at(92))], midTurn: true)
        expectSameAsAlone(midTurn, queries(midTurn, extra: ["r9"]))
        // Three newer replies of the user's (notices between them): the first reply is dropped, the later ones are not.
        var asks = [Line.user("Start", uuid: "s0", at: at(0)), Line.text("Run:\n\n```bash\nmake\n```", uuid: "a0", at: at(1))]
        for k in 1...3 {
            asks += [SeamLine.noticeTurn(noticeText(taskID: "d\(k)"), uuid: "dn\(k)", at: at(Double(k * 10))),
                     Line.text("Notice \(k).", uuid: "dr\(k)", at: at(Double(k * 10 + 1))),
                     Line.user("Ask \(k)", uuid: "s\(k)", at: at(Double(k * 10 + 5))),
                     Line.text("Answer \(k).", uuid: "a\(k)", at: at(Double(k * 10 + 6)))]
        }
        let dropping = digestOf(asks)
        expectSameAsAlone(dropping, queries(dropping))
        #expect(OfferSupersession.evaluate("a0", in: dropping, replyTime: at(1), session: .init()) == .dropped)
        var droppingWork = 0
        let all = OfferSupersession.evaluate(queries(dropping), in: dropping, work: &droppingWork)
        #expect(all.contains(.dropped) && all.contains { if case .superseded = $0 { return true } else { return false } })
    }

    @Test func aFleetDigestGivesTheSameAndTheWorkGrowsWithItsSize() {
        let digest = digestOf(Self.fleet(turns: 150, start: start))
        let replies = digest.turns.compactMap(\.replyUUID)
        let queries = replies.map { OfferSupersession.Query(replyUUID: $0, replyTime: at(1), session: .init()) }
        expectSameAsAlone(digest, queries)
        var work = 0
        _ = OfferSupersession.evaluate(queries, in: digest, work: &work)
        let items = digest.turns.reduce(0) { $0 + $1.items.count }
        // Every item at most twice (summed once, its own turn once), plus the first lines of a few replies.
        #expect(work <= 2 * items + 2 * digest.turns.count + 8, "work \(work) for \(items) items")
        // One by one it was about half of items × replies: here over 20 times as much.
        #expect(items * replies.count / 2 > 20 * work)
    }

    @Test func untimedTurnsUnknownOriginsAndDuplicateUUIDsGiveWhatEachGaveAlone() {
        var lines = [Line.user("Fix the checkout", uuid: "u0", at: at(0)),
                     Line.text("Here:\n\n```bash\nmake\n```", uuid: "a0", at: at(1))]
        // A turn whose entries carry no timestamps: a newer reply's time falls back to the query's reply time.
        lines += [Self.untimed(Line.user("Untimed ask", uuid: "u1", at: at(5))),
                  Self.untimed(SeamLine.edit("/Users/alex/my project/src/one.swift", id: "toolu_e1", uuid: "e1", at: at(5))),
                  Self.untimed(SeamLine.result("toolu_e1", uuid: "er1", at: at(5), content: "ok")),
                  Self.untimed(Line.text("Untimed answer.\n\n```bash\nmake test\n```", uuid: "r1", at: at(6)))]
        // A turn the transcript did not say who started (no `turnOrigin`): counted as the user's.
        lines += [Line.user("Who sent this?", uuid: "u2", at: at(10), origin: nil),
                  Line.text("Answered.", uuid: "r2", at: at(11))]
        // An untimed notice turn.
        lines += [Self.untimed(SeamLine.noticeTurn(noticeText(taskID: "t3"), uuid: "n3", at: at(20))),
                  Self.untimed(Line.text("Notice answer.", uuid: "r3", at: at(21)))]
        // A reply uuid seen twice (a copied history): the later turn holds it as well.
        lines += [Line.user("Again", uuid: "u4", at: at(30)), Line.text("Same uuid.", uuid: "r1", at: at(31))]
        lines += [Line.user("Last", uuid: "u5", at: at(40), origin: nil), Line.text("Done.", uuid: "r5", at: at(41))]
        let digest = digestOf(lines)
        // The fixture has the shapes this test is about.
        #expect(digest.duplicateUUIDs.contains("r1"))
        #expect(digest.turns.contains { $0.isFinished && $0.finishedAt == nil && $0.lastEntryAt == nil })
        #expect(digest.turns.filter { $0.origin == .unknown }.count == 2)
        // Every reply under every session fact, and each reply again at two other reply times in the same batch.
        var all = queries(digest)
        for reply in digest.turns.compactMap(\.replyUUID) {
            all.append(OfferSupersession.Query(replyUUID: reply, replyTime: at(200), session: .init()))
            all.append(OfferSupersession.Query(replyUUID: reply, replyTime: at(-30),
                                               session: .init(lastActivityAt: at(400), isSSH: true)))
        }
        expectSameAsAlone(digest, all)
        // The same digest with its last turn still running.
        let running = digestOf(lines + [Line.user("Keep going", uuid: "u6", at: at(50)),
                                        SeamLine.bash("make", description: "Build", id: "toolu_b6", uuid: "b6", at: at(51))])
        expectSameAsAlone(running, queries(running) + all)
    }

    @Test func randomDigestsGiveWhatEachGaveAlone() {
        var generator = SplitMix(seed: 20261021)
        for round in 0..<60 {
            let lines = Self.randomLines(&generator, start: start)
            let digest = digestOf(lines, midTurn: round % 3 == 0)
            var all = queries(digest)
            for reply in digest.turns.compactMap(\.replyUUID) {
                all.append(OfferSupersession.Query(replyUUID: reply, replyTime: at(Double(round)), session: .init()))
            }
            expectSameAsAlone(digest, all)
        }
    }

    /// A random history: turns of the user, of a peer, of unknown origin and of notices, some without timestamps,
    /// with edits, web reads and finished notices, replies that sometimes reuse an earlier reply's uuid, and now and
    /// then a last turn still running.
    static func randomLines(_ generator: inout SplitMix, start: Date) -> [String] {
        func at(_ minutes: Int) -> Date { start.addingTimeInterval(Double(minutes) * 60) }
        var lines: [String] = []
        var replies: [String] = []
        let turns = Int.random(in: 1...12, using: &generator)
        for k in 0..<turns {
            let t = k * 10
            let timed = Int.random(in: 0..<4, using: &generator) > 0
            var turn: [String] = []
            switch Int.random(in: 0..<4, using: &generator) {
            case 0: turn.append(Line.user("Ask \(k)", uuid: "u\(k)", at: at(t)))
            case 1: turn.append(Line.user("Peer \(k)", uuid: "u\(k)", at: at(t), origin: "peer"))
            case 2: turn.append(Line.user("Unknown \(k)", uuid: "u\(k)", at: at(t), origin: nil))
            default: turn.append(SeamLine.noticeTurn(noticeText(taskID: "t\(k % 3)"), uuid: "u\(k)", at: at(t)))
            }
            for j in 0..<Int.random(in: 0...3, using: &generator) {
                let file = Int.random(in: 0..<6, using: &generator)
                turn.append(SeamLine.edit("/Users/alex/my project/src/f\(file).swift", id: "toolu_e\(k)_\(j)",
                                          uuid: "e\(k)_\(j)", at: at(t + 1)))
                turn.append(SeamLine.result("toolu_e\(k)_\(j)", uuid: "er\(k)_\(j)", at: at(t + 1), content: "ok"))
            }
            if Int.random(in: 0..<4, using: &generator) == 0 {
                turn.append(Line.toolUse("WebFetch", id: "toolu_w\(k)", uuid: "w\(k)", at: at(t + 2),
                                         input: ["url": "https://example.com/\(k)"]))
                turn.append(SeamLine.result("toolu_w\(k)", uuid: "wr\(k)", at: at(t + 2), content: "page"))
            }
            if Int.random(in: 0..<4, using: &generator) == 0 {
                turn.append(SeamLine.queuedCommand(noticeText(taskID: "q\(k)"), uuid: "q\(k)", at: at(t + 3)))
            }
            let last = k == turns - 1
            if last, Int.random(in: 0..<3, using: &generator) == 0 {
                turn.append(SeamLine.bash("make", description: "Build", id: "toolu_b\(k)", uuid: "b\(k)", at: at(t + 4)))
            } else {
                let reuse = !replies.isEmpty && Int.random(in: 0..<6, using: &generator) == 0
                let uuid = reuse ? replies[Int.random(in: 0..<replies.count, using: &generator)] : "r\(k)"
                replies.append(uuid)
                turn.append(Line.text("Reply \(k).\n\n```bash\necho \(k)\n```", uuid: uuid, at: at(t + 5)))
            }
            lines += timed ? turn : turn.map(Self.untimed)
        }
        return lines
    }

    @Test func firstSeenOrderMatchesTheForwardOrder() {
        var generator = SplitMix(seed: 20261021)
        for _ in 0..<50 {
            let turns = (0..<Int.random(in: 1...30, using: &generator)).map { _ in
                (0..<Int.random(in: 0...6, using: &generator)).map { _ in "f\(Int.random(in: 0..<15, using: &generator))" }
            }
            var order = FirstSeenOrder()
            for (index, turn) in turns.enumerated().reversed() {
                order.putFirst(turn)
                // The forward order of the turns from `index` on, the first occurrence of each.
                var seen = Set<String>()
                let forward = turns[index...].flatMap { $0 }.filter { seen.insert($0).inserted }
                #expect(order.first(8) == Array(forward.prefix(8)))
                #expect(order.count == forward.count)
            }
        }
    }

    @Test func theDeriverJudgesTogetherAndBuildsEachReplysOffersOnce() throws {
        let files = ReadyFiles("sweep")
        let folder = SeamFolder("sweep-memory")
        let memory = readyStore(folder, clock: ManualClock(readyNow))
        let digest = digestOf(Self.fleet(turns: 150, start: readyNow.addingTimeInterval(-3 * 3600)))
        let latest = try #require(digest.turns.last?.replyUUID)
        let entry = readyOffer("echo 149", reply: latest, replyTime: readyNow.addingTimeInterval(-60))
        let snapshot = readySession(sessionA, index: 3, offers: [entry], replyUUID: latest)
        func pass(_ deriver: EarlierOffersDeriver, now: Date = readyNow) -> CodeDerivedFields {
            var fields = CodeDerivedFields()
            deriver.derive(deriveInput(snapshot, digest: digest, now: now, memory: memory, files: files), into: &fields)
            return fields
        }
        let deriver = EarlierOffersDeriver()
        let first = pass(deriver)
        #expect(first.earlierOffers.count == 149, "every notice reply's offer stays (background updates never drop one)")
        let built = deriver.rebuildCount
        #expect(built == 149, "every earlier reply's offers built once (the latest reply's come from the parse)")
        let items = digest.turns.reduce(0) { $0 + $1.items.count }
        #expect(deriver.lastSweepWork <= 2 * items + 2 * digest.turns.count + 8)
        // The next passes build nothing again, and give what a fresh deriver gives.
        let again = pass(deriver, now: readyNow.addingTimeInterval(30))
        #expect(deriver.rebuildCount == built)
        let fresh = pass(EarlierOffersDeriver(), now: readyNow.addingTimeInterval(30))
        #expect(again.earlierOffers == fresh.earlierOffers && again.earlierRegistrations == fresh.earlierRegistrations)
        // Another headline is another input: built again.
        var renamed = snapshot
        renamed.headline = "Toy Cube · renamed"
        var fields = CodeDerivedFields()
        deriver.derive(deriveInput(renamed, digest: digest, memory: memory, files: files), into: &fields)
        #expect(deriver.rebuildCount > built)
        withExtendedLifetime(folder) {}
    }

    /// `line` without its `timestamp`: an entry the transcript did not date.
    static func untimed(_ line: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return line }
        object["timestamp"] = nil
        return jsonLine(object)
    }

    /// A seeded generator, so a failure repeats.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: The reference: one reply alone, as it was judged before the one-pass sweep

    static func reference(_ replyUUID: String, in digest: CodeTurnDigest, replyTime: Date,
                          session: OfferSupersession.SessionFacts) -> OfferSupersession.Verdict {
        let found: (index: Int, unfinishedByMidTurn: Bool)
        if let index = digest.turns.lastIndex(where: { $0.isFinished && $0.replyUUID == replyUUID }) {
            found = (index, false)
        } else if session.midTurn, let latest = digest.turns.last, !latest.isFinished,
                  OfferSupersession.endsWithAssistantItem(latest, uuid: replyUUID) {
            found = (digest.turns.count - 1, true)
        } else {
            return .notFound
        }
        let turn = digest.turns[found.index]
        let newer = Array(digest.turns[(found.index + 1)...])
        var newerReplies = 0
        var updates = 0
        var answers: [CommandOffer.Supersession.NewerReply] = []
        var background: [CommandOffer.Supersession.NewerReply] = []
        var latestAt: Date?
        var readWeb = false
        var paths: [String] = []
        var seenPaths = Set<String>()
        var tasks = Set<String>()
        func consider(_ date: Date?) {
            guard let date else { return }
            if latestAt.map({ date > $0 }) ?? true { latestAt = date }
        }
        func note(_ item: CodeTurnDigest.Item) {
            switch item {
            case .toolUse(let tool):
                if OfferSupersession.fileTools.contains(tool.name), let path = tool.filePath, !path.isEmpty,
                   seenPaths.insert(path).inserted {
                    paths.append(path)
                }
            case .notice(let notice):
                if let status = notice.status, OfferSupersession.finishedStatuses.contains(status),
                   let key = notice.taskID.map({ "t:" + $0 }) ?? notice.toolUseID.map({ "u:" + $0 }) {
                    tasks.insert(key)
                }
            case .text, .toolResult:
                break
            }
        }
        if let last = turn.items.lastIndex(where: { OfferSupersession.isAssistant($0, uuid: replyUUID) }) {
            for item in turn.items[(last + 1)...] { if case .notice = item { note(item) } }
        }
        for next in newer {
            consider(next.startedAt)
            consider(next.finishedAt)
            if next.readWeb { readWeb = true }
            for item in next.items { note(item) }
            guard next.isFinished else { continue }
            let reply = CommandOffer.Supersession.NewerReply(
                at: next.finishedAt ?? next.lastEntryAt ?? replyTime, origin: next.origin, head: OfferSupersession.head(of: next))
            if next.origin == .taskNotification {
                updates += 1
                background.append(reply)
            } else {
                newerReplies += 1
                answers.append(reply)
            }
        }
        if newerReplies > CodeTuning.newerRepliesMax { return .dropped }
        let latest = digest.turns.last
        let newerRunning = !newer.isEmpty && latest?.isFinished == false
        let visibleUntil = [latestAt, replyTime].compactMap { $0 }.max() ?? replyTime
        let slackWorking = session.isSSH && (session.lastActivityAt.map {
            $0.timeIntervalSince(visibleUntil) > CodeTuning.sshMidTurnSlack
        } ?? false)
        let working = newerRunning || found.unfinishedByMidTurn || slackWorking
        guard !newer.isEmpty || working else { return .fresh }
        if found.unfinishedByMidTurn || slackWorking, let activity = session.lastActivityAt { consider(activity) }
        var unanswered: String?
        if let latest, newerRunning, latest.origin == .human { unanswered = latest.askedHead }
        let replies = (answers + background.suffix(2)).sorted { $0.at < $1.at }.prefix(CodeTuning.newerRepliesShown)
        let names = paths.prefix(OfferSupersession.filesListed).map { ($0 as NSString).lastPathComponent }
        return .superseded(CommandOffer.Supersession(
            newerReplies: newerReplies, newerBackgroundUpdates: updates, latestAt: latestAt ?? replyTime,
            replies: Array(replies), unansweredMessageHead: unanswered, sessionIsWorking: working,
            readWebSince: readWeb, filesChangedSince: names, filesChangedCount: paths.count,
            backgroundTasksFinishedSince: tasks.count))
    }
}
