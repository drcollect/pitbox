import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The derivers run on the engine's utility queue (never the main thread) and their 10 ms budget is a soft target, so a
/// slow pass changes nothing but one log line: at most one per slowest deriver per 10 minutes, naming the deriver, how
/// many passes it was slowest in since its last line (of any session, so no session is named) and the slowest of them,
/// then the kind of the pass that wrote the line with its wall and CPU time.
@Suite("Derive budget lines")
struct DeriveBudgetTests {
    init() { CodeLog.enabled = false }

    @Test func oneLinePerSlowestDeriverPerTenMinutesWithACount() throws {
        let log = ThisThreadLog()
        defer { log.stop() }
        let clock = Shared<TimeInterval>(1000)
        let cpu = Shared<TimeInterval>(5)
        let spend = Shared<TimeInterval>(0.060)
        let runner = CodeDeriveRunner(clock: { clock.value }, threadCPUTime: { cpu.value })
        let quick = RecordingDeriver(label: "progress", order: CodeDeriveOrder.work) { _, _ in clock.value += 0.001 }
        let slow = RecordingDeriver(label: "earlier-offers", order: CodeDeriveOrder.earlierOffers) { _, fields in
            clock.value += spend.value
            cpu.value += 0.004
            fields.unread = true
        }
        let cross = RecordingCrossDeriver { _, _ in clock.value += 0.030 }
        runner.replace(with: CodeDeriverSet(perSession: [slow, quick], crossSession: [cross]), leaving: [])
        let folder = SeamFolder("derive-budget")
        let memory = readyStore(folder, clock: ManualClock(readyNow))
        let record = SessionRecord(id: sessionA, index: 6, firstSeen: 0, profile: .a, popout: nil)
        func pass(_ n: Int) -> CodeDerivedFields {
            // Another snapshot each time: nothing is reused.
            runner.derive(record, snapshot: readySession(sessionA, index: 6, lastActivity: readyNow.addingTimeInterval(Double(n))),
                          digest: .empty, copied: [], memoryVersion: 0, settingsVersion: 0, memory: memory,
                          settings: CodeSettings(), owner: getuid(), now: readyNow)
        }
        func budgetLines() -> [String] { log.lines.filter { $0.hasPrefix("WARN derive over budget") } }

        #expect(pass(0).unread == true, "the fields are what the derivers set")
        #expect(budgetLines() == ["WARN derive over budget slowest=earlier-offers passes=1 max_ms=61 last=session ms=61 cpu_ms=4"])
        // Thirteen more slow passes within 10 minutes: no line, only counted (the slowest 70 ms).
        for n in 1...13 {
            spend.value = n == 7 ? 0.069 : 0.020
            clock.value += 30
            _ = pass(n)
        }
        // A pass within budget is not counted.
        spend.value = 0.001
        _ = pass(14)
        #expect(budgetLines().count == 1)
        // Another slowest deriver has its own line (the cross-session pass).
        var fields: [String: CodeDerivedFields] = [:]
        runner.crossDerive([CodeDeriveRunner.Session(id: sessionA, snapshot: readySession(sessionA), digest: .empty, digestVersion: 1)],
                           fields: &fields, context: CodeCrossDeriveContext(now: readyNow, memory: memory, settings: CodeSettings(),
                                                                            owner: getuid()))
        #expect(budgetLines().last == "WARN derive over budget slowest=cross passes=1 max_ms=30 last=cross sessions=1 ms=30 cpu_ms=0")
        // 10 minutes after its first line, the next slow pass of earlier-offers is logged with the count since.
        clock.value = 1000 + CodeDeriveRunner.budgetLogInterval + 1
        spend.value = 0.020
        _ = pass(15)
        #expect(budgetLines().count == 3)
        #expect(budgetLines().last == "WARN derive over budget slowest=earlier-offers passes=14 max_ms=70 last=session ms=21 cpu_ms=4")
        #expect(!budgetLines().contains { $0.contains("#6") || $0.contains("session=") }, "no one session is named")
        #expect(CodeDeriveRunner.budgetLogInterval == 600)
        withExtendedLifetime(folder) {}
    }

    @Test func theThreadCPUTimeIsThisThreads() {
        let before = CodeDeriveRunner.currentThreadCPUTime()
        var x = 0.0
        for i in 0..<200_000 { x += Double(i).squareRoot() }
        let after = CodeDeriveRunner.currentThreadCPUTime()
        #expect(x > 0 && after > before && after - before < 5)
    }
}
