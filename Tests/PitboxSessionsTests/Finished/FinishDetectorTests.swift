import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// Finished once per piece of work, the 3-minute rule, the states, a fleet session finishing once after
/// its last notice turn, expiry, work seen first at start, and the item closing on the user's new message.
@Suite("Finish detection", .serialized)
struct FinishDetectorTests {
    let folder = SeamFolder("finish")
    let clock = ManualClock(readyNow)
    let start = readyNow.addingTimeInterval(-3600)
    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    init() { CodeLog.enabled = false }

    func work(minutes: Double) -> [String] {
        [Line.user("Make the checkout work", uuid: "u1", at: at(0)), Line.text("Done: checkout works.", uuid: "a1", at: at(minutes))]
    }

    func derive(_ deriver: FinishedDeriver, _ snapshot: CodeSessionSnapshot, _ lines: [String], now: Date? = nil,
                memory: CodeMemoryStore, prepare: (inout CodeDerivedFields) -> Void = { _ in }) -> CodeDerivedFields {
        var fields = CodeDerivedFields()
        prepare(&fields)
        deriver.derive(deriveInput(snapshot, digest: digestOf(lines), now: now ?? clock.now, memory: memory, files: nil), into: &fields)
        return fields
    }

    func running() -> CodeSessionSnapshot { readySession(sessionA, state: .working) }
    func done(_ reply: String = "a1", state: CodeSessionState = .reviewReady) -> CodeSessionSnapshot {
        readySession(sessionA, state: state, replyUUID: reply)
    }

    @Test func finishedOncePerReplyAndNeverAgainAfterARestart() throws {
        let memory = readyStore(folder, clock: clock)
        let deriver = FinishedDeriver()
        let first = derive(deriver, running(), [Line.user("Make the checkout work", uuid: "u1", at: at(0))], memory: memory)
        #expect(first.finished == nil)
        let mark = try #require(derive(deriver, done(), work(minutes: 21), memory: memory) { $0.workStartedAt = at(0) }.finished)
        #expect(mark.replyUUID == "a1" && mark.isOpen && mark.hasItem && !mark.silent && !mark.expired)
        #expect(mark.at == at(21) && abs(mark.ranSeconds - 1260) < 0.01)
        _ = derive(deriver, done(), work(minutes: 21), memory: memory)
        let records: [CodeFinishedRecord] = try #require(memory.read(.finished, session: sessionA))
        #expect(records.count == 1)
        // A restart: a new deriver on the same file says it again, silently.
        memory.flush()
        let again = try #require(derive(FinishedDeriver(), done(), work(minutes: 21), memory: readyStore(folder, clock: clock)).finished)
        #expect(again.replyUUID == "a1" && again.silent && again.isOpen)
    }

    @Test func theThreeMinuteRuleAndTheStatesThatGetNoItem() throws {
        for (minutes, state, item) in [(2.0, CodeSessionState.done, false), (3.0, .done, true), (21.0, .needsYou, false),
                                        (21.0, .problem, false), (21.0, .doneNoSummary, true)] {
            let memory = readyStore(SeamFolder("finish-rule"), clock: clock)
            let deriver = FinishedDeriver()
            _ = derive(deriver, running(), [Line.user("Go", uuid: "u1", at: at(0))], memory: memory)
            let mark = try #require(derive(deriver, done(state: state), work(minutes: minutes), memory: memory).finished)
            #expect(mark.hasItem == item && mark.isOpen == item, "\(minutes) min, \(state)")
        }
        // The setting moves the threshold.
        var settings = CodeSettings()
        settings.finishedMinMinutes = 0
        let memory = readyStore(SeamFolder("finish-zero"), clock: clock)
        let deriver = FinishedDeriver()
        var fields = CodeDerivedFields()
        deriver.derive(deriveInput(running(), digest: digestOf([Line.user("Go", uuid: "u1", at: at(0))]), memory: memory,
                                   settings: settings, files: nil), into: &fields)
        fields = CodeDerivedFields()
        deriver.derive(deriveInput(done(state: .done), digest: digestOf(work(minutes: 1)), memory: memory, settings: settings,
                                   files: nil), into: &fields)
        #expect(fields.finished?.hasItem == true)
    }

    @Test func theSummaryGraceWaits() throws {
        let memory = readyStore(folder, clock: clock)
        let deriver = FinishedDeriver()
        _ = derive(deriver, running(), [Line.user("Go", uuid: "u1", at: at(0))], memory: memory)
        #expect(derive(deriver, done(state: .working), work(minutes: 21), memory: memory).finished == nil)
        #expect(derive(deriver, done(state: .doneNoSummary), work(minutes: 21), memory: memory).finished?.hasItem == true)
    }

    @Test func aFleetSessionFinishesOnceAfterItsLastNoticeTurn() throws {
        let memory = readyStore(folder, clock: clock)
        let deriver = FinishedDeriver()
        var lines = [Line.user("Run the fleet", uuid: "u1", at: at(0))]
        func progress(_ done: Int) -> (inout CodeDerivedFields) -> Void {
            { fields in
                fields.workStartedAt = at(0)
                fields.progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: done, total: 3, since: at(1),
                                               pendingBetweenTurns: done < 3)
            }
        }
        _ = derive(deriver, running(), lines, memory: memory, prepare: progress(0))
        lines.append(Line.text("Launched 3 agents.", uuid: "a1", at: at(2)))
        #expect(derive(deriver, done("a1"), lines, memory: memory, prepare: progress(0)).finished == nil)
        for n in 1...3 {
            lines.append(SeamLine.noticeTurn(noticeText(taskID: "agent-\(n)"), uuid: "n\(n)", at: at(Double(n * 10))))
            _ = derive(deriver, running(), lines, memory: memory, prepare: progress(n - 1))
            lines.append(Line.text("Agent \(n) reported.", uuid: "an\(n)", at: at(Double(n * 10 + 1))))
            let fields = derive(deriver, done("an\(n)"), lines, memory: memory, prepare: progress(n))
            if n < 3 { #expect(fields.finished == nil, "agent \(n) of 3") }
        }
        let records: [CodeFinishedRecord] = try #require(memory.read(.finished, session: sessionA))
        #expect(records.map(\.reply) == ["an3"])
        #expect(abs((records.first?.ranSeconds ?? 0) - at(31).timeIntervalSince(at(0))) < 0.01, "ran from the user's message")
    }

    @Test func workEndingByExpiryIsASilentItem() throws {
        let memory = readyStore(folder, clock: clock)
        let deriver = FinishedDeriver()
        let launch = readyNow.addingTimeInterval(-CodeTuning.backgroundMaxAge)
        _ = derive(deriver, running(), [Line.user("Go", uuid: "u1", at: at(0))], memory: memory)
        _ = derive(deriver, done(), work(minutes: 21), memory: memory) {
            $0.progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 2, total: 3, since: launch,
                                       pendingBetweenTurns: true)
        }
        // Progress gave the last task up after 6 hours: no notice, no new turn; its tally counts it in `expiredTasks`.
        let mark = try #require(derive(deriver, done(), work(minutes: 21), memory: memory) {
            $0.progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 2, total: 2, since: launch,
                                       expiredTasks: 1)
        }.finished)
        #expect(mark.expired && mark.silent && mark.hasItem && mark.at == readyNow)
        #expect(CodeReadyWords.finishedDetail(mark, headline: "“h”", whereText: "in the pit", clock: utcClock)
                == "“h” · a background task never reported back · in the pit")

        // Only given-up tasks left (progress keeps a total of 0), first seen after a restart: a silent item as well.
        let again = try #require(derive(FinishedDeriver(), done(), work(minutes: 21),
                                        memory: readyStore(SeamFolder("finish-expired-restart"), clock: clock)) {
            $0.progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 0, total: 0, since: launch,
                                       expiredTasks: 1)
        }.finished)
        #expect(again.expired && again.silent && again.hasItem && again.at == readyNow)

        // A restart long after: the drop came at most 6 hours after the reply, so the work is old (counted, no item).
        let oldStart = readyNow.addingTimeInterval(-10 * 3600)
        let old = [Line.user("Go", uuid: "u1", at: oldStart), Line.text("Done.", uuid: "old", at: oldStart.addingTimeInterval(600))]
        let stale = try #require(derive(FinishedDeriver(), done("old"), old,
                                        memory: readyStore(SeamFolder("finish-expired-old"), clock: clock)) {
            $0.progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 0, total: 0, since: oldStart,
                                       expiredTasks: 1)
        }.finished)
        #expect(stale.expired && !stale.hasItem && !stale.isOpen
                && stale.at == oldStart.addingTimeInterval(600 + CodeTuning.backgroundMaxAge))
    }

    @Test func workSeenFirstAtStartIsSilentWithinTwoHoursAndNothingOlder() throws {
        let memory = readyStore(folder, clock: clock)
        let recent = try #require(derive(FinishedDeriver(), done(), work(minutes: 21), memory: memory).finished)
        #expect(recent.silent && recent.hasItem && recent.isOpen)
        let oldStart = readyNow.addingTimeInterval(-3 * 3600 - 1260)
        let old = [Line.user("Go", uuid: "u1", at: oldStart), Line.text("Done.", uuid: "old", at: oldStart.addingTimeInterval(1260))]
        let mark = try #require(derive(FinishedDeriver(), done("old"), old, memory: readyStore(SeamFolder("finish-old"), clock: clock)).finished)
        #expect(!mark.isOpen && !mark.hasItem && mark.silent)
    }

    /// Work that finished more than 24 hours ago, seen for the first time (at start), is counted without a
    /// write: the store keeps a record only 24 hours after its `at`, and writing it anyway was logged at every start as
    /// `memory write refused key=finished reason=shape`. Newer work beside it is still written and read back.
    @Test func workOverADayOldIsCountedWithoutAWrite() throws {
        let log = ThisThreadLog()
        defer { log.stop() }
        let folder = SeamFolder("finish-day-old")
        let memory = readyStore(folder, clock: clock)
        let deriver = FinishedDeriver()
        let oldStart = readyNow.addingTimeInterval(-30 * 3600)
        let old = [Line.user("Go", uuid: "u1", at: oldStart), Line.text("Done.", uuid: "old", at: oldStart.addingTimeInterval(1260))]
        #expect(derive(deriver, done("old"), old, memory: memory).finished == nil)
        #expect(derive(deriver, done("old"), old, memory: memory).finished == nil, "counted once: nothing the next time")
        #expect((memory.read(.finished, session: sessionA) as [CodeFinishedRecord]?) == nil)
        #expect(!log.lines.contains { $0.contains("memory write refused") })

        // Work of 3 hours ago in the same session: its record is written, and a restart reads it back.
        let start = readyNow.addingTimeInterval(-3 * 3600 - 1260)
        let newer = old + [Line.user("Again", uuid: "u2", at: start), Line.text("Done again.", uuid: "new", at: start.addingTimeInterval(1260))]
        let mark = try #require(derive(deriver, done("new"), newer, memory: memory).finished)
        #expect(mark.replyUUID == "new" && !mark.hasItem && mark.silent)
        memory.flush()
        let records: [CodeFinishedRecord] = try #require(readyStore(folder, clock: clock).read(.finished, session: sessionA))
        #expect(records.map(\.reply) == ["new"] && records.first?.at == start.addingTimeInterval(1260))
        #expect(!log.lines.contains { $0.contains("memory write refused") })
    }

    @Test func aNoticeAfterTheReplyHoldsTheFinishForItsTurn() throws {
        let memory = readyStore(folder, clock: clock)
        let deriver = FinishedDeriver()
        _ = derive(deriver, running(), [Line.user("Go", uuid: "u1", at: at(0))], memory: memory)
        let lines = work(minutes: 21) + [SeamLine.queueOperation(noticeText(taskID: "late"), at: at(21.5))]
        let held = derive(deriver, done(), lines, now: at(21.6), memory: memory)
        #expect(held.finished == nil && held.deadlines.contains(at(21.5).addingTimeInterval(FinishedDeriver.noticeTurnWait)))
        // No turn came within the wait: it finishes after all.
        #expect(derive(deriver, done(), lines, now: at(23), memory: memory).finished?.replyUUID == "a1")
    }

    @Test func theUsersNewMessageClosesTheItemAndTheETAWasKept() throws {
        let memory = readyStore(folder, clock: clock)
        let deriver = FinishedDeriver()
        let eta = at(25)
        _ = derive(deriver, running(), [Line.user("Go", uuid: "u1", at: at(0))], memory: memory) {
            $0.eta = CodeETA(kind: .stated, at: eta, statedZone: "UTC", statedAt: at(1))
        }
        let mark = try #require(derive(deriver, done(), work(minutes: 21), memory: memory).finished)
        #expect(mark.etaWas == eta && mark.isOpen)
        let next = work(minutes: 21) + [Line.user("Now the other thing", uuid: "u2", at: at(40))]
        let closed = try #require(derive(deriver, running(), next, memory: memory).finished)
        #expect(!closed.isOpen && closed.replyUUID == "a1")
        // OK from the card closes it too.
        let other = readyStore(SeamFolder("finish-ok"), clock: clock)
        let okDeriver = FinishedDeriver()
        _ = derive(okDeriver, running(), [Line.user("Go", uuid: "u1", at: at(0))], memory: other)
        _ = derive(okDeriver, done(), work(minutes: 21), memory: other)
        CodeFinishedRecords.close("a1", session: sessionA, memory: other)
        #expect(derive(okDeriver, done(), work(minutes: 21), memory: other).finished?.isOpen == false)
    }

    @Test func aRecordOfAnotherShapeNeverEmptiesTheList() throws {
        let memory = readyStore(folder, clock: clock)
        memory.write(.finished, session: sessionA, value: [["reply": "x1", "at": iso(readyNow)]])
        let records: [CodeFinishedRecord] = try #require(memory.read(.finished, session: sessionA))
        #expect(records.first?.reply == "x1" && records.first?.silent == true && records.first?.open == false)
    }
}
