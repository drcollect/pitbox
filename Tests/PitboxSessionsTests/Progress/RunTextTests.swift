import Foundation
import Testing
@testable import PitboxSessions

/// The running words and the summary line.
@Suite("Running words")
struct RunTextTests {
    /// 23:10 UTC on 20 October 2026; the work started 34 minutes before.
    let now = utcDate(2026, 10, 20, 23, 10)
    var started: Date { now.addingTimeInterval(-34 * 60) }

    func session(_ state: CodeSessionState = .working, progress: CodeProgress? = nil, eta: CodeETA? = nil,
                 id: String = sessionA) -> CodeSessionSnapshot {
        var s = progressSnapshot(id, state: state)
        s.workStartedAt = started
        s.progress = progress
        s.eta = eta
        return s
    }

    let agents = CodeProgress(source: .backgroundTasks, unit: .agents, done: 4, total: 6)
    var stated: CodeETA { CodeETA(kind: .stated, at: utcDate(2026, 10, 20, 23, 24), statedZone: "UTC") }
    var estimate: CodeETA { CodeETA(kind: .estimate, at: now.addingTimeInterval(9 * 60), minutesLeft: 9) }

    @Test func largeMonitorsSayTheRunningTimeTheETAAndTheProgress() {
        #expect(RunText.large(session(progress: agents, eta: stated), now: now, clock: clockUTC)
            == "Running 34 min · ETA 23:24 · 4 of 6 agents done")
        var between = agents
        between.pendingBetweenTurns = true
        #expect(RunText.large(session(.done, progress: between, eta: stated), now: now, clock: clockUTC)
            == "Background · 4 of 6 agents done · ETA 23:24")
        #expect(RunText.large(session(), now: now, clock: clockUTC) == "Running 34 min")
        let late = utcDate(2026, 10, 20, 23, 30, 30)
        #expect(RunText.large(session(progress: agents, eta: stated), now: late, clock: clockUTC)
            == "Running 54 min · ETA 23:24 passed 6 min ago · 4 of 6 agents done")
        #expect(RunText.large(session(progress: agents, eta: estimate), now: now, clock: clockUTC)
            == "Running 34 min · ≈ 9 min left · 4 of 6 agents done")
    }

    @Test func shortFormsForMediumSmallRowsAndTags() {
        #expect(RunText.medium(session(progress: agents, eta: stated), now: now, clock: clockUTC) == "ETA 23:24 · 4/6 agents")
        #expect(RunText.medium(session(progress: agents, eta: estimate), now: now, clock: clockUTC) == "≈ 9 min left")
        #expect(RunText.medium(session(progress: agents), now: now, clock: clockUTC) == "4/6 agents")
        #expect(RunText.small(session(progress: agents, eta: estimate), now: now, clock: clockUTC) == "≈ 9 min")
        #expect(RunText.small(session(progress: agents), now: now, clock: clockUTC) == nil, "the state word then")
        #expect(RunText.tag(session(eta: stated), now: now, clock: clockUTC) == "ETA 23:24")
        #expect(RunText.tag(session(eta: stated), now: utcDate(2026, 10, 20, 23, 40), clock: clockUTC) == "ETA 23:24 passed")
        #expect(RunText.tag(session(eta: estimate), now: now, clock: clockUTC) == "≈ 9 min left")
        #expect(RunText.tag(session(progress: agents), now: now, clock: clockUTC) == "4 of 6 agents done")
        #expect(RunText.tag(session(), now: now.addingTimeInterval(-22 * 60), clock: clockUTC) == "Running 12 min")
        let twelve = CodeClockFormat(timeZone: utcZone, uses24Hour: false)
        #expect(RunText.tag(session(eta: stated), now: now, clock: twelve) == "ETA 11:24 PM")
    }

    @Test func thePeekNamesTheSourceAndTheZone() {
        let late = utcDate(2026, 10, 20, 23, 30)
        #expect(RunText.peek(session(progress: agents, eta: stated), now: late, clock: clockUTC) == [
            "Started 22:36 · running 54 min · ETA 23:24, as stated in its reply (passed 6 min ago)", "4 of 6 agents done"])
        #expect(RunText.peek(session(progress: agents, eta: estimate), now: now, clock: clockUTC).first
            == "Started 22:36 · running 34 min · ≈ 9 min left (estimate from 4 of 6 agents done)")
        var both = stated
        both.estimateAt = utcDate(2026, 10, 20, 23, 31)
        #expect(RunText.peek(session(progress: agents, eta: both), now: now, clock: clockUTC).first
            == "Started 22:36 · running 34 min · ETA 23:24 as stated · estimate ≈ 23:31")
        #expect(RunText.peek(session(progress: agents, eta: stated), now: now, clock: clockLisbon).first
            == "Started 23:36 · running 34 min · ETA 00:24, as stated in its reply (stated as 23:24 UTC)")
        let workflow = CodeProgress(source: .backgroundTasks, unit: .workflows, done: 1, total: 2, workflowAgentsDone: 7,
                                    workflowAgentCount: 8)
        #expect(RunText.peek(session(progress: workflow), now: now, clock: clockUTC).last
            == "1 of 2 workflows done · workflow agents 7 of 8")
    }

    @Test func onlyRunningSessionsHaveRunWords() throws {
        let quiet = session(.quietUnfinished, progress: CodeProgress(source: .todos, unit: .todos, done: 2, total: 5), eta: stated)
        #expect(!RunText.isRunning(quiet) && RunText.large(quiet, now: now, clock: clockUTC) == nil)
        #expect(!RunText.isLate(quiet, now: utcDate(2026, 10, 21, 0, 0)), "late only while it still runs")
        #expect(RunText.peek(quiet, now: now, clock: clockUTC).isEmpty && RunText.fraction(quiet) == nil)
        #expect(RunText.isRunning(session(.maybeNeedsYou)))
        #expect(RunText.fraction(session(progress: agents)) == 4.0 / 6.0)
        let line = CodeRunLine.make(session(progress: agents, eta: stated), now: utcDate(2026, 10, 20, 23, 30), clock: clockUTC)
        #expect(line?.isLate == true && line?.fraction == 4.0 / 6.0)
        #expect(line?.text(for: .large) == "Running 54 min · ETA 23:24 passed 6 min ago · 4 of 6 agents done")
        #expect(line?.text(for: .medium) == "ETA 23:24 passed · 4/6 agents" && line?.text(for: .row) == line?.medium)
        #expect(CodeRunLine.make(session(.done), now: now, clock: clockUTC) == nil)
        let bar = CodeRunLine.make(session(progress: agents), now: now, clock: clockUTC)
        #expect(bar?.small == nil && bar?.fraction == 4.0 / 6.0, "a small monitor's bar alone")
        #expect(CodeRunLine.make(session(progress: agents, eta: estimate), now: now, clock: clockUTC)?.small == "≈ 9 min")
        // Without an ETA or a progress source a medium monitor keeps its "Now:" line; large monitors and rows say how
        // long it runs.
        let plain = try #require(CodeRunLine.make(session(), now: now, clock: clockUTC))
        #expect(plain.medium == nil && plain.large == "Running 34 min" && plain.row == "Running 34 min" && plain.fraction == nil)
    }

    @Test func sshSessionsSayHowOldTheirNowIs() {
        var s = progressSnapshot(state: .working, place: .ssh, sshHost: "buildbox")
        s.steps = [CodeSessionStep(words: "running: npm test", at: now.addingTimeInterval(-90))]
        #expect(RunText.nowAsOf(s, now: now, clock: clockUTC) == "as of 23:08")
        s.steps = [CodeSessionStep(words: "running: npm test", at: now.addingTimeInterval(-20))]
        #expect(RunText.nowAsOf(s, now: now, clock: clockUTC) == nil)
        #expect(RunText.nowAsOf(progressSnapshot(state: .working), now: now, clock: clockUTC) == nil, "local: never")
    }

    // MARK: Summary line

    @Test func theSummaryLineCountsAndLeavesOutZeros() {
        var finished = session(.reviewReady, id: "local_s4")
        finished.finished = CodeFinishedMark(replyUUID: "r1", at: now, ranSeconds: 1260)
        var warned = session(.working, id: "local_s5")
        warned.warnings = [CodeWarning(kind: .failedInARow, since: now)]
        warned.dashboard = CodeDashboard(handle: "polar-shore", site: .test, firstSeen: now)
        var lateOne = session(.working, eta: stated, id: "local_s6")
        lateOne.dashboard = CodeDashboard(handle: "quiet-fjord", site: .test, firstSeen: now)
        let sessions = [
            session(.working, eta: CodeETA(kind: .stated, at: utcDate(2026, 10, 20, 23, 50)), id: "local_s1"),
            session(.done, progress: CodeProgress(source: .backgroundTasks, unit: .agents, done: 1, total: 3), eta: estimate,
                    id: "local_s2"),
            session(.quietUnfinished, eta: CodeETA(kind: .estimate, at: now.addingTimeInterval(60), minutesLeft: 1), id: "local_s3"),
            finished, warned, lateOne,
        ]
        let line = CodeSummaryLine.make(sessions: sessions, readyItems: 4, now: utcDate(2026, 10, 20, 23, 30), clock: clockUTC)
        #expect(line.text == "4 running · next done ≈ 23:50 · 1 past ETA · 1 just finished · 4 ready for you · 1 warning · ▦ 2 dashboards")
        let early = CodeSummaryLine.make(sessions: sessions, readyItems: 0, justFinished: 2, now: now, clock: clockUTC)
        #expect(early.text == "4 running · next done ≈ 23:19 · 2 just finished · 1 warning · ▦ 2 dashboards",
                "the estimate (23:19) is next; quiet sessions do not count")
        #expect(CodeSummaryLine.make(sessions: [session(.done)], readyItems: 0, now: now, clock: clockUTC).isEmpty)
        let one = CodeSummaryLine.make(sessions: [warned], readyItems: 1, now: now, clock: clockUTC)
        #expect(one.text == "1 running · 1 ready for you · 1 warning · ▦ 1 dashboard")
        #expect(one.parts.last?.kind == .dashboards && one.dashboards == 1)
    }
}
