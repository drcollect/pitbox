import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// Items from snapshots, their order, the visible cards and the cap, Later, Dismiss, OK and Undo, keys and states
/// across a restart, items leaving by themselves, result rows. Invented sessions only.
@MainActor
@Suite("Ready list", .serialized)
struct ReadyListTests {
    let folder = SeamFolder("ready-list")
    let clock = ManualClock(readyNow)

    init() { CodeTileLog.enabled = false }

    func id(_ n: Int) -> String { "local_0aaaaaaa-1111-4111-8111-\(String(format: "%012d", n))" }

    func list(_ store: CodeMemoryStore? = nil) -> (CodeReadyList, ReadyScheduler) {
        let list = CodeReadyList(memory: store ?? readyStore(folder, clock: clock))
        let scheduler = ReadyScheduler()
        list.schedule = scheduler.schedule
        list.clock = utcClock
        list.now = { readyNow }
        return (list, scheduler)
    }

    func followed(_ sessions: [CodeSessionSnapshot], parked: Set<String> = [], recent: [CodeRecentSession] = []) -> CodeFollowedSet {
        CodeFollowedSet(monitors: sessions.filter { $0.popout != nil }, statuses: statuses(sessions, parked: parked),
                        parked: parked, recent: recent, recentHours: 6, now: readyNow)
    }

    func statuses(_ sessions: [CodeSessionSnapshot], parked: Set<String>) -> [String: CodeWindowStatus] {
        var out: [String: CodeWindowStatus] = [:]
        for session in sessions where session.popout != nil {
            out[session.id] = CodeWindowStatus(place: parked.contains(session.id) ? .parked(since: readyNow) : .onDesk)
        }
        return out
    }

    func input(_ sessions: [CodeSessionSnapshot], parked: Set<String> = [], recent: [CodeRecentSession] = [],
               hideText: Bool = false, tall: Bool = false, now: Date = readyNow) -> CodeReadyInput {
        CodeReadyInput(sessions: sessions, followed: followed(sessions, parked: parked, recent: recent),
                       statuses: statuses(sessions, parked: parked), bucketName: { _ in "Toy Cube" }, hideText: hideText,
                       tallTile: tall, now: now)
    }

    func command(_ n: Int, minutesAgo: Double, number: Int = 1, session: String? = nil) -> CodeOfferEntry {
        readyOffer("echo \(n)", session: session ?? id(n), index: n, reply: "r\(n)", number: number,
                   replyTime: readyNow.addingTimeInterval(-minutesAgo * 60))
    }

    func finished(_ reply: String, minutesAgo: Double, ran: Double = 1260) -> CodeFinishedMark {
        CodeFinishedMark(replyUUID: reply, at: readyNow.addingTimeInterval(-minutesAgo * 60), ranSeconds: ran)
    }

    var titles: (CodeReadyList) -> [String] { { list in list.snapshot.entries.map(\.item.title) } }

    @Test func itemsComeInTheirOrder() throws {
        let (list, _) = list()
        let warned = readySession(id(1), index: 1, warnings: [CodeWarning(kind: .failedInARow, since: readyNow.addingTimeInterval(-60),
                                                                            failures: 4, lastExitCode: 1)])
        let two = readySession(id(2), index: 2, offers: [command(2, minutesAgo: 3, number: 1),
                                                         readyOffer("echo second", session: id(2), index: 2, reply: "r2", number: 2,
                                                                    total: 2, replyTime: readyNow.addingTimeInterval(-180))])
        let three = readySession(id(3), index: 3, offers: [command(3, minutesAgo: 10)])
        let done = readySession(id(4), index: 4, finished: finished("f4", minutesAgo: 1))
        list.update(input([warned, two, three, done], parked: [id(3)]))
        let entries = list.snapshot.entries
        #expect(entries.map(\.item.kind) == [.warning, .command, .command])
        #expect(entries[1].item.offerID?.number == 1 && entries[2].item.offerID?.number == 2, "one reply's offers in order")
        #expect(list.snapshot.more == 2 && list.snapshot.header?.count == 5)
        list.press(.showMore)
        #expect(list.snapshot.entries.map(\.item.kind) == [.warning, .command, .command, .command, .finished])
        #expect(list.snapshot.entries[3].item.detail == "from “Toy Cube · checkout” · in the pit (Toy Cube)")
        #expect(list.snapshot.counts == CodeReadySnapshot.Counts(commands: 3, files: 0, finished: 1, warnings: 1))
        // A tall block shows 6 cards.
        let (tall, _) = self.list()
        tall.update(input([warned, two, three, done], tall: true))
        #expect(tall.snapshot.entries.count == 5 && tall.snapshot.more == 0)
    }

    @Test func cardWords() throws {
        let (list, _) = list()
        let fetch = readyOffer("scp 'someone@buildbox:/home/someone/draft.md' ~/Downloads/", session: id(1), index: 1, reply: "r1",
                               commandClass: .fetchFile,
                               fetch: FetchFileRequest(alias: "buildbox", replyUser: nil, remotePath: "/home/someone/draft.md",
                                                       destinationName: nil))
        var earlier = readyOffer("rm -rf build", session: id(2), index: 2, reply: "r2", replyTime: readyNow.addingTimeInterval(-3600),
                                 commandClass: .risky)
        earlier.offer.supersession = CommandOffer.Supersession(newerReplies: 1, latestAt: readyNow, sessionIsWorking: false)
        let done = readySession(id(3), index: 3, tldr: "Draft letter written.\nChecked.",
                                finished: CodeFinishedMark(replyUUID: "f3", at: readyNow.addingTimeInterval(-60), ranSeconds: 1260,
                                                           etaWas: readyNow.addingTimeInterval(-120)),
                                results: [CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"),
                                                     label: "localhost:5173")],
                                dashboard: CodeDashboard(handle: "polar-shore", site: .test, firstSeen: readyNow))
        list.update(input([readySession(id(1), index: 1, offers: [fetch]), readySession(id(2), index: 2, earlierOffers: [earlier]), done],
                          tall: true))
        let entries = list.snapshot.entries.map(\.item)
        let file = try #require(entries.first { $0.kind == .file })
        #expect(file.title == "⤓ File ready" && file.line == "draft.md on buildbox" && file.buttons.first?.title == "⤓ Fetch…")
        let command = try #require(entries.first { $0.kind == .command })
        #expect(command.title == "▶ Command ready" && command.titleNote == "from an earlier reply (13:37)")
        #expect(command.chip == "Risky" && command.line == "rm -rf build" && command.lineIsCommand)
        #expect(command.buttons.map(\.title) == ["Review…", "Show window", "Later", "Dismiss"], "Run is off by default")
        let finishedItem = try #require(entries.first { $0.kind == .finished })
        #expect(finishedItem.title == "✓ Finished 14:36" && finishedItem.line == "Draft letter written.")
        #expect(finishedItem.detail == "“Toy Cube · checkout” · ran 21 min · window on track · ETA was 14:35")
        #expect(finishedItem.buttons.map(\.title) == ["Back on track", "↗ Open preview · localhost:5173", "▦ Dashboard", "OK"])
        #expect(finishedItem.buttons.map(\.opensSomething) == [false, true, true, false])
        // Hide text keeps kind, headline and where.
        list.update(input([readySession(id(1), index: 1, offers: [fetch]), readySession(id(2), index: 2, earlierOffers: [earlier]), done],
                          hideText: true, tall: true))
        #expect(list.snapshot.entries.allSatisfy { $0.item.line == "hidden" && $0.item.chip == nil })
    }

    @Test func recentSessionsAndOwnActivityOnes() throws {
        let (list, _) = list()
        let used = readySession(id(1), index: 1, offers: [command(1, minutesAgo: 5)], popout: false,
                                finished: finished("f1", minutesAgo: 2))
        let own = readySession(id(2), index: 2, offers: [command(2, minutesAgo: 5)], popout: false,
                               finished: finished("f2", minutesAgo: 2), dashboard: CodeDashboard(handle: "quiet-fjord", site: .test, firstSeen: readyNow))
        let recent = [CodeRecentSession(id: id(1), profile: .a, lastFocusedAt: readyNow.addingTimeInterval(-5 * 3600)),
                      CodeRecentSession(id: id(2), profile: .a, ownLastActivity: readyNow.addingTimeInterval(-600))]
        list.update(input([used, own], recent: recent, tall: true))
        let items = list.snapshot.entries.map(\.item)
        #expect(!items.contains { $0.sessionID == id(2) && $0.kind == .command }, "no command from a session the user has not used")
        let ownFinished = try #require(items.first { $0.sessionID == id(2) })
        #expect(ownFinished.buttons.map(\.title) == ["OK", "Open in Claude"], "an own finished card: OK and Open in Claude")
        let usedCommand = try #require(items.first { $0.sessionID == id(1) && $0.kind == .command })
        #expect(usedCommand.whereText == "in Claude · you opened it 5 h ago")
        #expect(usedCommand.buttons[1] == CodeReadyButton(.openInClaude(sessionID: id(1)), "Open in Claude"))
        var actions: [CodeReadyAction] = []
        list.onAction = { action, _ in actions.append(action) }
        list.press(.openInClaude(sessionID: id(1)))
        #expect(actions == [.openInClaude(sessionID: id(1))])
    }

    @Test func laterDismissUndoAndOK() throws {
        let store = readyStore(folder, clock: clock)
        let (list, scheduler) = list(store)
        let session = readySession(id(1), index: 1, offers: [command(1, minutesAgo: 5)],
                                   finished: finished("f1", minutesAgo: 1),
                                   warnings: [CodeWarning(kind: .silence, since: readyNow.addingTimeInterval(-1900))])
        list.update(input([session], tall: true))
        let key = try #require(list.snapshot.entries.first { $0.item.kind == .command }?.item.id)
        #expect(key.hasPrefix("cmd:\(id(1)):r1:1:") && key.count == "cmd:\(id(1)):r1:1:".count + 16)

        list.press(.later(key))
        #expect(list.snapshot.later.map(\.item.id) == [key] && !list.snapshot.entries.contains { $0.item.id == key })
        #expect(list.snapshot.later.first?.item.buttons.map(\.title) == ["Unfold", "Review…"])
        #expect(list.snapshot.counts.commands == 1, "Later ones count")
        list.press(.unfold(key))
        #expect(list.snapshot.entries.contains { $0.item.id == key })

        list.press(.dismiss(key))
        #expect(!list.snapshot.entries.contains { $0.item.id == key } && list.snapshot.header?.undoShown == true)
        let entry = session.offers[0]
        #expect(list.dismissedAt(entry.id, in: session) == readyNow)
        list.press(.undoDismiss)
        #expect(list.snapshot.entries.contains { $0.item.id == key } && list.snapshot.header?.undoShown == false)
        list.press(.dismiss(key))
        #expect(scheduler.delays.last == CodeTuning.dismissUndo)
        scheduler.runAll()
        #expect(list.snapshot.header?.undoShown == false && !list.snapshot.entries.contains { $0.item.id == key })

        // OK on the warning and the Finished card.
        var warnedOK: [CodeWarning.Kind] = []
        list.onWarningOK = { _, warning in warnedOK.append(warning.kind) }
        list.press(.ok("warn:\(id(1)):silence"))
        #expect(warnedOK == [.silence] && !list.snapshot.entries.contains { $0.item.kind == .warning })
        list.press(.ok("fin:\(id(1)):f1"))
        #expect(!list.snapshot.entries.contains { $0.item.kind == .finished })
        let record: [CodeFinishedRecord]? = store.read(.finished, session: id(1))
        _ = record
        let seen: CodeSeenRecord? = store.read(.seen, session: id(1))
        #expect(seen?.at == readyNow, "OK clears the unread dot")
        // A new warning (a later start) shows again.
        list.update(input([readySession(id(1), index: 1, warnings: [CodeWarning(kind: .silence, since: readyNow.addingTimeInterval(60))])],
                          now: readyNow.addingTimeInterval(120)))
        #expect(list.snapshot.entries.contains { $0.item.kind == .warning })
    }

    @Test func statesSurviveARestartAndASessionComingBack() throws {
        let store = readyStore(folder, clock: clock)
        let session = readySession(id(1), index: 1, offers: [command(1, minutesAgo: 5), command(1, minutesAgo: 5, number: 2)])
        let (first, _) = list(store)
        first.update(input([session]))
        let keys = first.snapshot.entries.map(\.item.id)
        first.press(.later(keys[0]))
        first.press(.dismiss(keys[1]))
        store.flush()
        // A new store on the same file, a new list: the same keys come back with their states.
        let (second, _) = list(readyStore(folder, clock: clock))
        second.update(input([session]))
        #expect(second.snapshot.later.map(\.item.id) == [keys[0]] && second.snapshot.entries.isEmpty)
        // The session leaves the followed set and returns.
        second.update(input([]))
        #expect(second.snapshot.isEmpty)
        second.update(input([session]))
        #expect(second.snapshot.later.map(\.item.id) == [keys[0]])
    }

    @Test func itemsLeaveOnRunTypeFetchStaleNewWorkAndUnfollowing() throws {
        let (list, _) = list()
        let one = command(1, minutesAgo: 5)
        let session = readySession(id(1), index: 1, offers: [one], finished: finished("f1", minutesAgo: 1))
        list.update(input([session]))
        let runID = UUID()
        list.record(.started(runID: runID), offer: one.offer, sessionID: id(1), now: readyNow)
        let row = try #require(list.snapshot.entries.first { if case .result = $0.style { return true } else { return false } })
        #expect(row.item.id.hasPrefix("cmd:") && !list.snapshot.entries.contains { $0.item.kind == .command && $0.style == .card })
        list.record(.finished(runID: runID, exitStatus: 0, seconds: 3), offer: one.offer, sessionID: id(1), now: readyNow)
        if case .result(let result) = list.snapshot.entries.first(where: { $0.item.id == row.item.id })?.style {
            #expect(result.state == .finished(exitStatus: 0, seconds: 3) && result.runID == runID)
            #expect(CodeReadyListView.resultWords(result.state).0 == "✓ exit 0 · 3 s")
        } else {
            Issue.record("no result row")
        }
        // 10 minutes later the row is gone, and the offer does not come back as an item.
        list.update(input([session], now: readyNow.addingTimeInterval(CodeTuning.resultRowLife + 1)))
        #expect(!list.snapshot.entries.contains { $0.item.id == row.item.id })
        // A finished item leaves when its record closes (new work), and everything when the session is not followed.
        list.update(input([readySession(id(1), index: 1)]))
        #expect(list.snapshot.isEmpty)
        // A failed fetch shows its row, and the item returns after OK.
        let fetch = readyOffer("scp 'someone@buildbox:/x/a.md' ~/Downloads/", session: id(2), index: 2, reply: "r2",
                               commandClass: .fetchFile)
        let other = readySession(id(2), index: 2, offers: [fetch])
        list.update(input([other]))
        list.record(.fetched(.failed(reason: "no such file on buildbox")), offer: fetch.offer, sessionID: id(2), now: readyNow)
        let failed = try #require(list.snapshot.entries.first)
        list.press(.ok(failed.item.id))
        #expect(list.snapshot.entries.first?.style == .card)
        list.record(.fetched(.saved(fileName: "a.md", bytes: 42_000)), offer: fetch.offer, sessionID: id(2), now: readyNow)
        if case .result(let saved)? = list.snapshot.entries.first?.style {
            #expect(CodeReadyListView.resultWords(saved.state).0.hasPrefix("Fetched a.md · 42"))
        } else {
            Issue.record("no fetch row")
        }
    }

    /// 8 offers of one reply of session `n` (the most one reply offers).
    func eight(_ n: Int, minutesAgo: Double) -> [CodeOfferEntry] {
        (1...8).map { number in
            readyOffer("echo \(n).\(number)", session: id(n), index: n, reply: "r\(n)", number: number, total: 8,
                       replyTime: readyNow.addingTimeInterval(-minutesAgo * 60))
        }
    }

    @Test func theCapDropsFinishedThenLaterThenHidesRecentSessionsItemsNeverWarnings() throws {
        let (list, _) = list()
        var sessions: [CodeSessionSnapshot] = []
        // 5 desk sessions with a warning and a finished item each; 3 desk sessions with 8 commands each; 2 recent sessions
        // The user used with 8 commands each: 10 + 24 + 16 = 50 items.
        for n in 1...5 {
            sessions.append(readySession(id(n), index: n, finished: finished("f\(n)", minutesAgo: Double(n)),
                                         warnings: [CodeWarning(kind: .silence, since: readyNow.addingTimeInterval(-Double(n)))]))
        }
        for n in 6...8 { sessions.append(readySession(id(n), index: n, offers: eight(n, minutesAgo: Double(n)))) }
        for n in 9...10 { sessions.append(readySession(id(n), index: n, offers: eight(n, minutesAgo: Double(n)), popout: false)) }
        let recent = (9...10).map { CodeRecentSession(id: id($0), profile: .a, lastFocusedAt: readyNow.addingTimeInterval(-Double($0) * 60)) }
        list.update(input(sessions, recent: recent))
        list.press(.showMore)
        let shown = list.snapshot.entries.map(\.item)
        // The 5 finished go first, then 5 commands of the session the user used least recently wait behind the line.
        #expect(shown.count == 40 && !shown.contains { $0.kind == .finished })
        #expect(shown.filter { $0.kind == .warning }.count == 5, "no warning is ever dropped")
        #expect((6...8).allSatisfy { n in shown.filter { $0.sessionID == id(n) }.count == 8 }, "desk items are never hidden")
        #expect(shown.filter { $0.sessionID == id(10) }.count == 3 && shown.filter { $0.sessionID == id(9) }.count == 8)
        #expect(list.snapshot.hiddenRecent == 5)
        list.press(.showHidden)
        #expect(list.snapshot.hiddenRecent == 0 && list.snapshot.entries.count == 45)
    }

    @Test func threeCardsFitTheHeightBudgetWithAndWithoutTheMoreLine() {
        for count in [3, 4] {
            let (list, _) = list()
            list.update(input((1...count).map { readySession(id($0), index: $0, offers: [command($0, minutesAgo: Double($0))]) }))
            let ready = CodeReadyListView.height(of: list.snapshot, width: 992)
            // Header 24 + summary 20 + the list + a bucket header 28 + one medium page 474 fit the 798 pt budget.
            #expect(24 + 20 + ready + 28 + 474 <= 798, "\(count) items: \(ready) pt")
        }
        #expect(CodeReadyListView.height(of: CodeReadySnapshot(), width: 992) == 0)
    }

    @Test func deskTagsLearnWhatTheListNoLongerShows() throws {
        let (list, _) = list()
        let one = command(1, minutesAgo: 5), two = command(1, minutesAgo: 5, number: 2), three = command(1, minutesAgo: 5, number: 3)
        let warning = CodeWarning(kind: .sameFile, since: readyNow.addingTimeInterval(-60), otherSessionID: id(2), otherHeadline: "Other",
                                  path: "src/a.swift")
        let session = readySession(id(1), index: 1, offers: [one, two, three], warnings: [warning])
        list.update(input([session], tall: true))
        let keys = list.snapshot.entries.compactMap { entry in entry.item.offerID.map { ($0, entry.item.id) } }
        let key = { (offer: CodeOfferEntry) in keys.first { $0.0 == offer.id }?.1 ?? "" }
        list.press(.later(key(one)))
        list.press(.dismiss(key(two)))
        list.record(.typed, offer: three.offer, sessionID: id(1), now: readyNow)
        list.press(.ok("warn:\(id(1)):same_file"))
        #expect(list.snapshot.suppressedOffers == [two.id, three.id], "Later keeps its tag")
        #expect(list.snapshot.okWarnings == [id(1): [warning.id]])
    }

    @Test func openSheetsLearnStaleAndSupersededAcrossBothLists() {
        let one = command(1, minutesAgo: 5)
        var moved = one
        let s = CommandOffer.Supersession(newerReplies: 0, latestAt: readyNow, unansweredMessageHead: "wait", sessionIsWorking: true)
        moved.offer.supersession = s
        let sessions = [readySession(id(1), index: 1, earlierOffers: [moved])]
        let changes = CodeReadyOffers.changes(presented: [one.id: nil, command(9, minutesAgo: 1).id: nil], sessions: sessions)
        #expect(changes.stale == [command(9, minutesAgo: 1).id])
        #expect(changes.superseded.map(\.0) == [one.id] && changes.superseded.first?.1 == s)
        #expect(CodeReadyOffers.changes(presented: [one.id: s], sessions: sessions).superseded.isEmpty, "told already")
        #expect(CodeReadyOffers.entry(one.id, in: sessions)?.sessionID == id(1))
    }
}
