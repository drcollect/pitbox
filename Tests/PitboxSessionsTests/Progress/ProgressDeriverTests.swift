import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The progress deriver end to end over invented digests and a real store in a temporary folder.
@Suite("Progress deriver", .serialized)
struct ProgressDeriverTests {
    /// 20 October 2026, 20:00 UTC (21:00 in Lisbon).
    let t0 = utcDate(2026, 10, 20, 20, 0)

    init() { CodeLog.enabled = false }

    func deriver() -> ProgressDeriver { ProgressDeriver(localZone: { lisbonZone }) }

    /// The user asks; the session states an ETA, launches two agents and restates it; one notice comes back.
    func lines(secondNotice: Bool = false) -> [String] {
        var lines = [Line.user("Ship the \(secretWord) build", uuid: "u1", at: t0),
                     Line.text("On it. ETA: 22:00", uuid: "a1", stop: "tool_use", at: t0.addingTimeInterval(60))]
        lines += TaskLine.agentLaunch(1, at: t0.addingTimeInterval(70))
        lines += TaskLine.agentLaunch(2, at: t0.addingTimeInterval(80))
        lines += [Line.text("Two agents are running. ETA: 22:30", uuid: "a2", at: t0.addingTimeInterval(120)),
                  SeamLine.noticeTurn(noticeText(taskID: "agent1x"), uuid: "n1", at: t0.addingTimeInterval(600)),
                  Line.text("One agent is back.", uuid: "a3", at: t0.addingTimeInterval(610))]
        if secondNotice {
            lines += [SeamLine.noticeTurn(noticeText(taskID: "agent2x"), uuid: "n2", at: t0.addingTimeInterval(1500)),
                      Line.text("Both are back; done.", uuid: "a4", at: t0.addingTimeInterval(1510))]
        }
        return lines
    }

    @Test func theNewestStatementOfTheWorkWinsAndIsKeptAcrossNoticeTurns() throws {
        let clock = ManualClock(t0.addingTimeInterval(40 * 60))
        let memory = ProgressMemory(clock: clock)
        let deriver = deriver()
        let snapshot = progressSnapshot(state: .done)
        let fields = derived(deriver, deriveInput(snapshot, digest: digestOf(lines()), now: clock.now, memory: memory.store))
        #expect(fields.workStartedAt == t0)
        let progress = try #require(fields.progress)
        #expect(progress.source == .backgroundTasks && progress.done == 1 && progress.total == 2 && progress.pendingBetweenTurns)
        let eta = try #require(fields.eta)
        #expect(eta.kind == .stated && eta.at == utcDate(2026, 10, 20, 21, 30) && !eta.isLate, "22:30 Lisbon, the newer one")
        #expect(eta.statedZone == "Europe/Lisbon" && eta.replyUUID == "a2" && eta.statedAt == t0.addingTimeInterval(120))
        #expect(fields.deadlines.contains(eta.at.addingTimeInterval(0.5)), "it turns late by itself")
        let record: ETARecord = try #require(memory.store.read(.eta, session: sessionA))
        #expect(record == ETARecord(at: eta.at, statedAt: t0.addingTimeInterval(120), reply: "a2"))
        let tasks: [BackgroundTaskRecord] = try #require(memory.store.read(.background, session: sessionA))
        #expect(tasks.count == 2 && tasks.filter { $0.endedAt == nil }.count == 1)

        // Past the ETA while an agent still runs: late. The words come from RunText.
        clock.set(utcDate(2026, 10, 20, 21, 36))
        let late = derived(deriver, deriveInput(snapshot, digest: digestOf(lines()), now: clock.now, memory: memory.store))
        #expect(late.eta?.isLate == true)
        var shown = snapshot
        shown.progress = late.progress
        shown.eta = late.eta
        shown.workStartedAt = late.workStartedAt
        #expect(RunText.large(shown, now: clock.now, clock: clockLisbon) == "Background · 1 of 2 agents done · ETA 22:30 passed 6 min ago")

        // The last notice: the work ends. The store forgets; the field stays (never late) for "ETA was".
        let ended = derived(deriver, deriveInput(snapshot, digest: digestOf(lines(secondNotice: true)), now: clock.now,
                                                 memory: memory.store))
        #expect(ended.eta?.kind == .stated && ended.eta?.isLate == false)
        #expect(ended.progress?.pending == 0)
        #expect((memory.store.read(.eta, session: sessionA) as ETARecord?) == nil)
        #expect((memory.store.read(.background, session: sessionA) as [BackgroundTaskRecord]?) == nil)
        // Two hours after the ETA it is gone.
        clock.set(utcDate(2026, 10, 20, 23, 31))
        let gone = derived(deriver, deriveInput(snapshot, digest: digestOf(lines(secondNotice: true)), now: clock.now,
                                                memory: memory.store))
        #expect(gone.eta == nil)
    }

    @Test func zonelessClocksFollowWhereTheSessionRuns() throws {
        let clock = ManualClock(t0.addingTimeInterval(120))
        let memory = ProgressMemory(clock: clock)
        let digest = digestOf([Line.user("Go", uuid: "u1", at: t0),
                               Line.text("Working. ETA: 22:30", uuid: "a1", stop: "tool_use", at: t0.addingTimeInterval(60))])
        let local = derived(deriver(), deriveInput(progressSnapshot(), digest: digest, now: clock.now, memory: memory.store))
        #expect(local.eta?.at == utcDate(2026, 10, 20, 21, 30), "this Mac's zone")
        let ssh = progressSnapshot(sessionB, place: .ssh, sshHost: "buildbox")
        let server = derived(deriver(), deriveInput(ssh, digest: digest, now: clock.now, memory: memory.store))
        #expect(server.eta?.at == utcDate(2026, 10, 20, 22, 30) && server.eta?.statedZone == "UTC", "the server's UTC")
        var settings = CodeSettings()
        settings.serverTimeZones = ["buildbox": "America/New_York"]
        let newYork = derived(deriver(), deriveInput(ssh, digest: digest, now: clock.now, memory: memory.store, settings: settings))
        #expect(newYork.eta?.at == utcDate(2026, 10, 21, 2, 30) && newYork.eta?.statedZone == "America/New_York",
                "the zone set for that server")
        let explicit = digestOf([Line.user("Go", uuid: "u1", at: t0),
                                 Line.text("ETA: 20:45 UTC", uuid: "a1", stop: "tool_use", at: t0.addingTimeInterval(60))])
        let utc = derived(deriver(), deriveInput(ssh, digest: explicit, now: clock.now, memory: memory.store, settings: settings))
        #expect(utc.eta?.at == utcDate(2026, 10, 20, 20, 45), "an explicit UTC beats the server's zone")
        let mac = derived(deriver(), deriveInput(progressSnapshot(sessionC), digest: explicit, now: clock.now, memory: memory.store))
        #expect(mac.eta?.at == utcDate(2026, 10, 20, 20, 45), "and this Mac's")
    }

    @Test func withoutAStatementTheEstimateRunsAndNeverReplacesAStatedOne() throws {
        let clock = ManualClock(t0.addingTimeInterval(12 * 60))
        let memory = ProgressMemory(clock: clock)
        var lines = [Line.user("Run seven", uuid: "u1", at: t0)]
        for n in 1...7 { lines += TaskLine.agentLaunch(n, at: t0) }
        lines.append(Line.text("Seven agents.", uuid: "a1", at: t0.addingTimeInterval(5)))
        for n in 1...3 {
            lines += [SeamLine.noticeTurn(noticeText(taskID: "agent\(n)x"), uuid: "n\(n)", at: t0.addingTimeInterval(Double(n) * 60)),
                      Line.text("Back.", uuid: "b\(n)", at: t0.addingTimeInterval(Double(n) * 60 + 5))]
        }
        let fields = derived(deriver(), deriveInput(progressSnapshot(state: .done), digest: digestOf(lines), now: clock.now,
                                                    memory: memory.store))
        let eta = try #require(fields.eta)
        #expect(eta.kind == .estimate && eta.minutesLeft == 16 && eta.at == clock.now.addingTimeInterval(16 * 60))
        #expect(fields.deadlines.contains(clock.now.addingTimeInterval(60)), "recomputed once a minute")

        lines.append(Line.text("ETA: 21:40", uuid: "c1", at: t0.addingTimeInterval(200)))
        let stated = derived(deriver(), deriveInput(progressSnapshot(state: .done), digest: digestOf(lines), now: clock.now,
                                                    memory: memory.store))
        #expect(stated.eta?.kind == .stated && stated.eta?.estimateAt == clock.now.addingTimeInterval(16 * 60))
    }

    @Test func quietTurnsAreNotRunningAndTodosCountOnlyWithoutBackgroundWork() throws {
        let clock = ManualClock(t0.addingTimeInterval(20 * 60))
        let memory = ProgressMemory(clock: clock)
        let todos = CodeSessionTodos(items: [.init(text: "a", status: .completed), .init(text: "b", status: .completed),
                                             .init(text: "c", status: .completed), .init(text: "d", status: .inProgress),
                                             .init(text: "e", status: .pending), .init(text: "f", status: .pending)])
        let digest = digestOf([Line.user("Plan it", uuid: "u1", at: t0),
                               Line.toolUse(StepWords.updatePlan, id: "toolu_p1", uuid: "p1", at: t0.addingTimeInterval(60),
                                            input: ["items": [["content": "a", "status": "in_progress"]]])])
        let working = derived(deriver(), deriveInput(progressSnapshot(state: .working, todos: todos), digest: digest,
                                                     now: clock.now, memory: memory.store))
        let progress = try #require(working.progress)
        #expect(progress.source == .todos && progress.done == 3 && progress.total == 6 && progress.since == t0.addingTimeInterval(60))
        #expect(working.eta?.kind == .estimate, "3 of 6 after 19 min")
        let quiet = derived(deriver(), deriveInput(progressSnapshot(state: .quietUnfinished, todos: todos), digest: digest,
                                                   now: clock.now, memory: memory.store))
        #expect(quiet.eta == nil, "quiet is not running: no estimate")
        var shown = progressSnapshot(state: .quietUnfinished)
        shown.progress = quiet.progress
        #expect(!RunText.isRunning(shown))
        let finished = derived(deriver(), deriveInput(progressSnapshot(state: .done, todos: todos), digest: digest,
                                                      now: clock.now, memory: memory.store))
        #expect(finished.progress == nil, "todos only while the turn runs")
    }

    @Test func pendingTasksAndTheETASurviveARestart() throws {
        let clock = ManualClock(t0.addingTimeInterval(40 * 60))
        let memory = ProgressMemory(clock: clock)
        _ = derived(deriver(), deriveInput(progressSnapshot(state: .done), digest: digestOf(lines()), now: clock.now,
                                           memory: memory.store))
        // After a restart the tail holds only a later notice turn: the store keeps the pending agent and the ETA.
        let store = memory.restarted()
        let tail = digestOf([SeamLine.noticeTurn(noticeText(taskID: "agent9x"), uuid: "n9", at: t0.addingTimeInterval(1800)),
                             Line.text("An unrelated task.", uuid: "a9", at: t0.addingTimeInterval(1810))])
        let after = derived(deriver(), deriveInput(progressSnapshot(state: .done), digest: tail, now: clock.now, memory: store))
        #expect(after.progress?.pending == 1, "agent 2 still runs")
        #expect(after.eta?.kind == .stated && after.eta?.at == utcDate(2026, 10, 20, 21, 30))
    }

    @Test func logLinesHoldLabelsAndNumbersOnly() throws {
        let lines = Shared<[String]>([])
        let token = CodeLog.observe { line in lines.value.append(line) }
        defer { CodeLog.stopObserving(token) }
        let clock = ManualClock(t0.addingTimeInterval(40 * 60))
        let memory = ProgressMemory(clock: clock)
        _ = derived(deriver(), deriveInput(progressSnapshot(headline: "\(secretWord) headline"), digest: digestOf(self.lines()),
                                           now: clock.now, memory: memory.store))
        #expect(lines.value.contains { $0.contains("eta stated session=#3 minutes=") && $0.contains("zone=local") })
        for line in lines.value {
            #expect(!line.contains(secretWord) && !line.contains("22:30") && !line.contains("a2"), "\(line)")
        }
    }
}
