import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The away recap with a fake idle clock: 30 s polls while present and 2 s once away; 14:59 idle is not away and 15:00
/// is; a return with nothing new makes no card; sections of 8 lines and "and N more"; nothing while the block is
/// hidden; Got it; 30 minutes; a sleep longer than the threshold counts as an absence.
@MainActor
@Suite("While you were away", .serialized)
struct AwayRecapTests {
    init() { CodeTileLog.enabled = false }

    func id(_ n: Int) -> String { "local_0aaaaaaa-1111-4111-8111-\(String(format: "%012d", n))" }

    struct Rig {
        let recap: CodeAwayRecap
        let presence: ReadyPresence
        let scheduler: ReadyScheduler
        let box: ContentsBox
    }

    final class ContentsBox {
        var contents = CodeAwayRecapContents(sessions: [], items: [], hideText: false)
        var recaps: [CodeAwayRecap.Recap] = []
    }

    func rig(_ settings: CodeSettings = CodeSettings()) -> Rig {
        let presence = ReadyPresence(), scheduler = ReadyScheduler(), box = ContentsBox()
        let recap = CodeAwayRecap(environment: presence.environment(scheduler), settings: settings)
        recap.clockWords = utcClock
        recap.contents = { box.contents }
        recap.onRecap = { box.recaps.append($0) }
        return Rig(recap: recap, presence: presence, scheduler: scheduler, box: box)
    }

    /// Advances the fake clock and runs the next poll.
    func tick(_ r: Rig, by seconds: TimeInterval, idle: TimeInterval?) {
        r.presence.now = r.presence.now.addingTimeInterval(seconds)
        r.presence.idle = idle
        r.scheduler.runAll()
    }

    func finishedSession(_ n: Int, at: Date) -> CodeSessionSnapshot {
        readySession(id(n), "Session \(n)", index: n, tldr: "Report written.",
                     finished: CodeFinishedMark(replyUUID: "f\(n)", at: at, ranSeconds: 600))
    }

    @Test func pollsEvery30sWhilePresentAndEvery2sOnceAway() {
        let r = rig()
        r.presence.idle = 1
        r.recap.setStripVisible(true)
        #expect(r.scheduler.delays == [CodeTuning.recapPollPresent])
        tick(r, by: 30, idle: 15 * 60 - 1)
        #expect(r.recap.phase == .present && r.scheduler.delays.last == CodeTuning.recapPollPresent, "14:59 is not away")
        tick(r, by: 30, idle: 15 * 60)
        #expect(r.recap.phase == .away(since: r.presence.now.addingTimeInterval(-900)), "15:00 is")
        #expect(r.scheduler.delays.last == CodeTuning.recapPollAway)
        // Back with nothing new: no card.
        tick(r, by: 2, idle: 0.5)
        #expect(r.recap.phase == .present && r.recap.recap == nil && r.box.recaps.isEmpty)
    }

    @Test func aReturnWithFinishedAndWaitingWorkShowsTheSections() throws {
        let r = rig()
        r.presence.idle = 1
        r.recap.setStripVisible(true)
        tick(r, by: 30, idle: 20 * 60)
        guard case .away(let since) = r.recap.phase else { Issue.record("not away"); return }
        let during = since.addingTimeInterval(60)
        var sessions = (1...11).map { (finishedSession($0, at: during), CodeFollowedSet.Kind.parked) }
        let waiting = readySession(id(20), "Waiting one", index: 20, state: .needsYou)
        let running = readySession(id(21), "Running one", index: 21, state: .working,
                                   eta: CodeETA(kind: .stated, at: readyNow.addingTimeInterval(3600)))
        sessions += [(waiting, .parked), (running, .desk)]
        let offerItem = CodeReadyItem(id: "cmd:\(id(20)):r:1:0000000000000000", kind: .command, sessionID: id(20), sessionIndex: 20,
                                      follow: .parked, headline: "“Waiting one”", whereText: "parked", time: during,
                                      title: "▶ Command ready", detail: "", buttons: [])
        r.box.contents = CodeAwayRecapContents(sessions: sessions, items: [offerItem], hideText: false)
        tick(r, by: 2, idle: 1)
        let recap = try #require(r.recap.recap)
        #expect(recap.from == since && recap.until == r.presence.now && r.box.recaps.count == 1)
        let finished = try #require(recap.sections.first { $0.kind == .finished })
        #expect(finished.count == 11 && finished.lines.count == 8 && finished.more == 3 && finished.title == "Finished · 11")
        #expect(finished.lines.first == CodeAwayRecap.Line(headline: "“Session 1”", detail: "at \(utcClock.time(during)) · Report written."))
        #expect(recap.sections.first { $0.kind == .waiting }?.lines == [CodeAwayRecap.Line(headline: "“Waiting one”", detail: "command ready")])
        #expect(recap.sections.first { $0.kind == .running }?.lines.first?.detail == "ETA \(utcClock.time(readyNow.addingTimeInterval(3600)))")
        // Got it removes it.
        r.recap.gotIt()
        #expect(r.recap.recap == nil)
    }

    @Test func stillRunningUsesW3sWordsWhenTheTileWiresThem() throws {
        let from = readyNow.addingTimeInterval(-1800)
        let running = readySession(id(21), "Running one", index: 21, state: .working)
        var contents = CodeAwayRecapContents(sessions: [(finishedSession(1, at: from.addingTimeInterval(60)), .parked),
                                                        (running, .desk)], items: [], hideText: false)
        #expect(try #require(CodeAwayRecapBuilder.build(from: from, until: readyNow, contents: contents, clock: utcClock, now: readyNow))
            .sections.first { $0.kind == .running }?.lines.first?.detail == "working", "the recap's own words without the running texts")
        contents.runWords = { session, _ in session.state == .working ? "ETA 23:24 · 4/6 agents" : nil }
        let recap = try #require(CodeAwayRecapBuilder.build(from: from, until: readyNow, contents: contents, clock: utcClock, now: readyNow))
        #expect(recap.sections.first { $0.kind == .running }?.lines
                == [CodeAwayRecap.Line(headline: "“Running one”", detail: "ETA 23:24 · 4/6 agents")])
        #expect(recap.count(.running) == 1, "a finished session is not running")
    }

    @Test func hideTextLeavesHeadlinesAndHostWords() throws {
        let r = rig()
        r.recap.setStripVisible(true)
        tick(r, by: 30, idle: 30 * 60)
        guard case .away(let since) = r.recap.phase else { Issue.record("not away"); return }
        r.box.contents = CodeAwayRecapContents(sessions: [(finishedSession(1, at: since.addingTimeInterval(5)), .parked)], items: [],
                                               hideText: true)
        tick(r, by: 2, idle: 0)
        #expect(r.recap.recap?.sections.first?.lines.first?.detail == "at \(utcClock.time(since.addingTimeInterval(5)))")
    }

    @Test func nothingPollsWhileTheStripIsHiddenAndAnAbsenceThenMakesNoCard() {
        let r = rig()
        r.recap.setStripVisible(true)
        tick(r, by: 30, idle: 20 * 60)
        #expect(r.recap.phase != .present)
        r.recap.setStripVisible(false)
        let before = r.scheduler.delays.count
        r.box.contents = CodeAwayRecapContents(sessions: [(finishedSession(1, at: r.presence.now), .parked)], items: [], hideText: false)
        tick(r, by: 2, idle: 0)
        #expect(r.scheduler.delays.count == before, "a hidden block does not poll")
        r.recap.setStripVisible(true)
        #expect(r.recap.recap == nil && r.recap.phase == .present)
    }

    @Test func theCardLeavesAfterThirtyMinutesOrTheNextAbsence() throws {
        let r = rig()
        r.recap.setStripVisible(true)
        tick(r, by: 30, idle: 20 * 60)
        guard case .away(let since) = r.recap.phase else { Issue.record("not away"); return }
        r.box.contents = CodeAwayRecapContents(sessions: [(finishedSession(1, at: since.addingTimeInterval(1)), .parked)], items: [],
                                               hideText: false)
        tick(r, by: 2, idle: 0)
        #expect(r.recap.recap != nil)
        tick(r, by: CodeTuning.recapLife, idle: 1)
        #expect(r.recap.recap == nil, "30 minutes shown")
    }

    @Test func aSleepLongerThanTheThresholdIsAnAbsence() throws {
        let r = rig()
        r.recap.setStripVisible(true)
        let start = r.presence.now
        r.box.contents = CodeAwayRecapContents(sessions: [(finishedSession(1, at: start.addingTimeInterval(600)), .parked)], items: [],
                                               hideText: false)
        // The Mac slept 20 minutes: the next poll comes late, with fresh input.
        tick(r, by: 20 * 60, idle: 1)
        let recap = try #require(r.recap.recap)
        #expect(recap.from == start && recap.count(.finished) == 1)
    }

    @Test func theRecapCanBeSwitchedOff() {
        var settings = CodeSettings()
        settings.awayRecap = false
        let r = rig(settings)
        r.recap.setStripVisible(true)
        #expect(r.scheduler.delays.isEmpty)
    }
}
