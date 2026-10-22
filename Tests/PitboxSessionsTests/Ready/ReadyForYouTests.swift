import AppKit
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The coordinator the block talks to: one list view per block view in its Ready slot, heights reported, the recap card
/// first and its Got it, badge counts, Open in Claude through the session's own copy, and log lines without session
/// text.
@MainActor
@Suite("Ready for you, in the block", .serialized)
struct ReadyForYouTests {
    let folder = SeamFolder("ready-for-you")
    let clock = ManualClock(readyNow)

    init() {
        CodeTileLog.enabled = false
        CodeLog.enabled = false
    }

    func id(_ n: Int) -> String { "local_0aaaaaaa-1111-4111-8111-\(String(format: "%012d", n))" }

    func make() -> (CodeReadyForYou, ReadyPresence, ReadyScheduler) {
        let presence = ReadyPresence(), scheduler = ReadyScheduler()
        let ready = CodeReadyForYou(memory: readyStore(folder, clock: clock), settings: CodeSettings(),
                                    environment: presence.environment(scheduler))
        ready.list.clock = utcClock
        ready.recap.clockWords = utcClock
        return (ready, presence, scheduler)
    }

    func input(_ ready: CodeReadyForYou, _ sessions: [CodeSessionSnapshot]) -> CodeReadyInput {
        var statuses: [String: CodeWindowStatus] = [:]
        for session in sessions { statuses[session.id] = CodeWindowStatus(place: .parked(since: readyNow)) }
        let followed = ready.follow(monitors: sessions, statuses: statuses, parked: Set(sessions.map(\.id)), recent: [])
        return CodeReadyInput(sessions: sessions, followed: followed, statuses: statuses, now: readyNow)
    }

    @Test func eachTileViewGetsItsOwnListViewAndHeightChangesAreReported() {
        let (ready, _, _) = make()
        let first = ready.makeView(), second = ready.makeView()
        #expect(first !== second && ready.listViews.count == 2)
        var reported = 0
        first.onHeightChange = { reported += 1 }
        first.frame = CGRect(x: 0, y: 0, width: 992, height: 300)
        #expect(first.accessoryHeight(forWidth: 992) == 0, "no items, no band")
        ready.update(input(ready, [readySession(id(1), index: 1, offers: [readyOffer("echo 1", session: id(1), index: 1, reply: "r1")])]))
        #expect(first.accessoryHeight(forWidth: 992) > 0 && second.accessoryHeight(forWidth: 992) == first.accessoryHeight(forWidth: 992))
        #expect(reported == 1)
        ready.update(input(ready, [readySession(id(1), index: 1, offers: [readyOffer("echo 1", session: id(1), index: 1, reply: "r1")])]))
        #expect(reported == 1, "the same height reports nothing")
        #expect(ready.counts(for: id(1)) == (commands: 1, files: 0) && ready.counts(for: id(2)) == (commands: 0, files: 0))
    }

    @Test func theRecapCardComesFirstAndGotItRemovesIt() throws {
        let (ready, presence, scheduler) = make()
        let view = ready.makeView()
        view.frame = CGRect(x: 0, y: 0, width: 992, height: 500)
        let session = readySession(id(1), index: 1,
                                   finished: CodeFinishedMark(replyUUID: "f1", at: readyNow.addingTimeInterval(-300), ranSeconds: 900))
        ready.update(input(ready, [session]))
        presence.idle = 1
        ready.setStripVisible(true)
        presence.now = readyNow.addingTimeInterval(30)
        presence.idle = 20 * 60
        scheduler.runAll()
        presence.now = readyNow.addingTimeInterval(32)
        presence.idle = 0
        scheduler.runAll()
        let recap = try #require(ready.list.snapshot.recap)
        #expect(recap.count(.finished) == 1 && ready.list.snapshot.header != nil)
        guard case .recap? = CodeReadyLayout(ready.list.snapshot, width: 992).blocks.dropFirst().first else {
            Issue.record("the recap is not first")
            return
        }
        ready.list.press(.gotIt)
        #expect(ready.list.snapshot.recap == nil && ready.recap.recap == nil)
    }

    @Test func w3sSummaryHooksCountTheListsFinishedItemsAndOwnActivitySessions() {
        let (ready, _, _) = make()
        let one = readySession(id(1), index: 1,
                               finished: CodeFinishedMark(replyUUID: "f1", at: readyNow.addingTimeInterval(-300), ranSeconds: 900))
        let two = readySession(id(2), index: 2,
                               finished: CodeFinishedMark(replyUUID: "f2", at: readyNow, ranSeconds: 60, hasItem: false))
        ready.update(input(ready, [one, two]))
        #expect(ready.justFinished(in: [one, two, one]) == 1, "items only, each session once")
        ready.list.press(.ok("fin:\(id(1)):f1"))
        #expect(ready.justFinished(in: [one, two]) == 0, "OK takes it off at once, before the next parse")

        // Followed for its own activity only (no input of the user's): the dashboards list gives it no Open.
        let own = CodeRecentSession(id: id(3), profile: .a, lastFocusedAt: nil, latestUserFrameAt: nil,
                                    ownLastActivity: readyNow.addingTimeInterval(-600))
        let used = CodeRecentSession(id: id(4), profile: .a, lastFocusedAt: readyNow.addingTimeInterval(-900),
                                     latestUserFrameAt: nil, ownLastActivity: readyNow.addingTimeInterval(-60))
        ready.follow(monitors: [one], statuses: [:], parked: [id(1)], recent: [own, used])
        #expect(ready.ownActivityOnly == [id(3)])
    }

    @Test func openInClaudeUsesTheSessionsOwnCopy() {
        var opened: [(URL, URL)] = []
        let processes = [ClaudeProcessInfo(pid: 42, profile: .a, bundlePath: "/Applications/Claude.app")]
        #expect(CodeReadyOpener.openInClaude(id(1), profile: .a, processes: processes) { opened.append(($0, $1)) })
        #expect(opened.first?.0.absoluteString == "claude://code/continue?session=\(id(1))")
        #expect(opened.first?.1.path == "/Applications/Claude.app")
        #expect(!CodeReadyOpener.openInClaude(id(1), profile: .b, processes: processes) { opened.append(($0, $1)) }, "B is not running")
        #expect(!CodeReadyOpener.openInClaude("not-a-session", profile: .a, processes: processes) { opened.append(($0, $1)) })
        #expect(opened.count == 1)
    }

    @Test func everyFlowLogsLabelsAndNumbersOnly() async throws {
        CodeTileLog.startRecording()
        let lines = Shared<[String]>([])
        let token = CodeLog.observe { lines.value.append($0) }
        defer { CodeLog.stopObserving(token) }
        // The data side: earlier offers and finishes.
        let files = ReadyFiles("ready-logs")
        let memory = readyStore(folder, clock: clock)
        let deriver = EarlierOffersDeriver(), finisher = FinishedDeriver()
        let start = readyNow.addingTimeInterval(-3600)
        let turn = [Line.user("\(secretWord) ask", uuid: "u1", at: start),
                    Line.text("```bash\necho \(secretWord)\n```", uuid: "a1", at: start.addingTimeInterval(900))]
        let entry = readyOffer("echo \(secretWord)", reply: "a1", replyTime: start.addingTimeInterval(900))
        var fields = CodeDerivedFields()
        deriver.derive(deriveInput(readySession(sessionA, "\(secretWord) headline", offers: [entry], replyUUID: "a1"),
                                   digest: digestOf(turn), memory: memory, files: files), into: &fields)
        fields = CodeDerivedFields()
        deriver.derive(deriveInput(readySession(sessionA, "\(secretWord) headline", state: .working),
                                   digest: digestOf(turn + [Line.user("\(secretWord) wait", uuid: "u2", at: readyNow)]),
                                   memory: memory, files: files), into: &fields)
        fields = CodeDerivedFields()
        finisher.derive(deriveInput(readySession(sessionA, state: .working), digest: digestOf([turn[0]]), memory: memory, files: nil),
                        into: &fields)
        finisher.derive(deriveInput(readySession(sessionA, "\(secretWord) headline", replyUUID: "a1"), digest: digestOf(turn),
                                    memory: memory, files: nil), into: &fields)
        // The block side: items, Later, Dismiss, OK, a run, alerts.
        let (ready, presence, scheduler) = make()
        var settings = CodeSettings()
        settings.chime = true
        ready.update(settings: settings)
        let session = readySession(sessionA, "\(secretWord) headline", tldr: "\(secretWord) tldr", offers: [entry],
                                   finished: CodeFinishedMark(replyUUID: "a1", at: readyNow, ranSeconds: 900),
                                   warnings: [CodeWarning(kind: .sameFile, since: readyNow, otherHeadline: secretWord, path: "/x/\(secretWord).md")])
        ready.update(input(ready, [session]))
        let key = try #require(ready.list.snapshot.entries.first { $0.item.kind == .command }?.item.id)
        ready.list.press(.later(key))
        ready.list.press(.unfold(key))
        ready.list.press(.dismiss(key))
        ready.list.press(.undoDismiss)
        ready.record(.started(runID: UUID()), offer: entry.offer, sessionID: sessionA)
        ready.list.press(.ok("fin:\(sessionA):a1"))
        scheduler.runAll()
        presence.now = readyNow.addingTimeInterval(1)
        await settle()
        let all = lines.value + CodeTileLog.recorded
        #expect(all.contains { $0.contains("offer superseded session=#3") } && all.contains { $0.contains("ready item later") })
        for line in all {
            #expect(!line.contains(secretWord) && !line.contains(sessionA) && !line.contains("a1 ") && !line.contains(files.cli), "\(line)")
        }
    }
}
