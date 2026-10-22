import Foundation
import Testing
@testable import PitboxSessions

/// Progress from background tasks.
@Suite("Background tasks", .serialized)
struct BackgroundTaskTests {
    let t0 = fixtureNow.addingTimeInterval(-3600)

    /// The user asks; the session launches six agents (and a background dev server) and ends its turn; four notices
    /// come back through the three carriers, one of them naming only the tool_use id.
    func fleetLines() -> [String] {
        var lines = [Line.user("Build the \(secretWord) fleet", uuid: "u1", at: t0)]
        for n in 1...6 { lines += TaskLine.agentLaunch(n, at: t0.addingTimeInterval(Double(n) * 10)) }
        lines += TaskLine.bashLaunch(1, at: t0.addingTimeInterval(70))
        lines += [
            Line.text("Six agents are running.", uuid: "a1", at: t0.addingTimeInterval(80)),
            SeamLine.noticeTurn(noticeText(taskID: "agent1x", status: "completed"), uuid: "n1", at: t0.addingTimeInterval(600)),
            Line.text("Agent 1 is back.", uuid: "a2", stop: "tool_use", at: t0.addingTimeInterval(610)),
            SeamLine.queuedCommand(noticeText(taskID: "agent2x", status: "failed"), uuid: "q1", at: t0.addingTimeInterval(620)),
            Line.text("Agent 2 failed; going on.", uuid: "a3", at: t0.addingTimeInterval(630)),
            SeamLine.queueOperation(noticeText(taskID: "agent3x", status: "completed"), at: t0.addingTimeInterval(700)),
            SeamLine.noticeTurn(noticeText(taskID: "agent3x", status: "completed"), uuid: "n3", at: t0.addingTimeInterval(701)),
            Line.text("Agent 3 is back.", uuid: "a4", at: t0.addingTimeInterval(710)),
            SeamLine.noticeTurn(noticeText(toolUseID: "toolu_ag4", status: "completed"), uuid: "n4",
                                at: t0.addingTimeInterval(800), origin: nil),
            Line.text("Agent 4 is back.", uuid: "a5", at: t0.addingTimeInterval(810)),
            SeamLine.noticeTurn(noticeText(taskID: "bash1", status: "completed"), uuid: "n5", at: t0.addingTimeInterval(820)),
            Line.text("The dev server stopped.", uuid: "a6", at: t0.addingTimeInterval(830)),
        ]
        return lines
    }

    func tally(_ lines: [String], records: [BackgroundTaskRecord] = [], now: Date = fixtureNow) throws -> BackgroundTally {
        let digest = digestOf(lines)
        let work = try #require(WorkClock.work(in: digest, now: now))
        let tasks = BackgroundTasks.merge(BackgroundTasks.fromDigest(digest), records: records, digest: digest)
        return BackgroundTasks.tally(tasks, work: work, now: now)
    }

    @Test func launchesAgainstNoticesFromEveryCarrier() throws {
        let result = try tally(fleetLines())
        #expect(result.total == 6 && result.done == 4 && result.pending == 2, "background Bash is never a task")
        #expect(result.unit == .agents && result.since == t0.addingTimeInterval(10))
        #expect(RunText.progressWords(CodeProgress(source: .backgroundTasks, unit: result.unit, done: result.done,
                                                   total: result.total)) == "4 of 6 agents done")
        #expect(result.counted.allSatisfy { CodeMemorySchema.isHash16($0.task) }, "ids are kept as hashes only")
    }

    @Test func workflowsCountOneEachAndMixesSayTasks() throws {
        var lines = [Line.user("Run the workflows", uuid: "u1", at: t0)]
        lines += TaskLine.workflowLaunch(1, at: t0.addingTimeInterval(10))
        lines += TaskLine.workflowLaunch(2, at: t0.addingTimeInterval(20))
        lines += [Line.text("Two workflows started.", uuid: "a1", at: t0.addingTimeInterval(30)),
                  SeamLine.noticeTurn(noticeText(taskID: "wf1task", status: "completed", agentCount: 8, agentsDone: 7),
                                      uuid: "n1", at: t0.addingTimeInterval(2400)),
                  Line.text("One is done.", uuid: "a2", at: t0.addingTimeInterval(2410))]
        let workflows = try tally(lines)
        #expect(workflows.unit == .workflows && workflows.done == 1 && workflows.total == 2)
        #expect(workflows.workflowAgentsDone == 7 && workflows.workflowAgentCount == 8)
        lines += TaskLine.agentLaunch(9, at: t0.addingTimeInterval(2420))
        #expect(try tally(lines).unit == .tasks)
    }

    @Test func aTaskWithoutItsNoticeIsDroppedAfterSixHours() throws {
        var lines = [Line.user("Long job", uuid: "u1", at: t0)]
        lines += TaskLine.agentLaunch(1, at: t0)
        lines += [Line.text("Started.", uuid: "a1", at: t0.addingTimeInterval(5))]
        let within = try tally(lines, now: t0.addingTimeInterval(6 * 3600 - 60))
        #expect(within.pending == 1 && within.nextExpiry == t0.addingTimeInterval(6 * 3600))
        let past = try tally(lines, now: t0.addingTimeInterval(6 * 3600 + 60))
        #expect(past.total == 0 && past.expired == 1, "it never reported back")
    }

    @Test func tasksStillRunningWhenANewWorkBeginsKeepCounting() throws {
        var lines = fleetLines()
        lines += [Line.user("How is it going?", uuid: "u2", at: t0.addingTimeInterval(900)),
                  Line.text("Two agents still run.", uuid: "a7", at: t0.addingTimeInterval(905)),
                  SeamLine.noticeTurn(noticeText(taskID: "agent5x", status: "completed"), uuid: "n6", at: t0.addingTimeInterval(1000)),
                  Line.text("Agent 5 is back.", uuid: "a8", at: t0.addingTimeInterval(1010))]
        let result = try tally(lines)
        // Agents 1-4 ended before the question: not this work's. 5 ended after it, 6 still runs.
        #expect(result.total == 2 && result.done == 1 && result.pending == 1)
    }

    @Test func recordsCarryPendingTasksBeyondTheTail() throws {
        let full = try tally(fleetLines())
        let records = BackgroundTasks.records(full.counted)
        #expect(records.count == 6 && records.filter { $0.endedAt == nil }.count == 2)
        // Later the tail holds only the last notice turn (a restart's fresh tail, or a cut): agent 5 reports back.
        let tail = [SeamLine.noticeTurn(noticeText(taskID: "agent5x", status: "completed"), uuid: "n9",
                                        at: t0.addingTimeInterval(2000)),
                    Line.text("Agent 5 is back.", uuid: "a9", at: t0.addingTimeInterval(2010))]
        let later = try tally(tail, records: records)
        #expect(later.done == 1 && later.pending == 1, "5 matched by its stored hash, 6 still pending")
        #expect(later.since == t0.addingTimeInterval(50), "the stored launch times stay")
    }
}

/// Small helpers for building lines with a chosen stop reason.
extension Line {
    static func text(_ text: String, uuid: String, stop: String?, at date: Date) -> String {
        Line.text(text, uuid: uuid, at: date, stop: stop)
    }
}
