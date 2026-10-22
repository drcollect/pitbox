import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The progress and dashboard sets registered with the real engine, over an invented session in a temporary folder
/// tree: the one-time scan finds a link far behind the tail on its own queue, and its mark brings the engine back; the
/// progress fields reach the snapshot.
@Suite("Progress and dashboards through the engine", .serialized)
@MainActor
struct DashboardEngineTests {
    let tree = FixtureTree("progress-dashboards-engine")
    let clock = ManualClock(Date())
    let candidates = Shared<[ClaudeProcessCandidate]>([])
    let folder = SeamFolder("progress-dashboards-memory")
    let cli = "2f3c2a9e-1111-2222-3333-444455556666"

    init() {
        CodeLog.enabled = false
        candidates.value = [tree.copyA()]
    }

    var now: Date { clock.now }
    /// A clock time 20 minutes from now (its minute).
    var etaTime: Date { now.addingTimeInterval(20 * 60) }

    func store() -> CodeMemoryStore {
        let clock = self.clock
        return CodeMemoryStore(url: folder.file("code-memory.json"), owner: getuid(), clock: { clock.now },
                               writeInterval: 0.05, writeMax: CodeTuning.memoryWriteMax)
    }

    /// The link in an early reply, then over 3 MB of work, then three short exchanges: the tail never reaches it.
    func writeSession() throws {
        let start = now.addingTimeInterval(-5 * 3600)
        var lines = [Line.user("Set up the fleet board", uuid: "u0", at: start),
                     Line.text("Board: https://dash.example.com/dash/polar-shore/", uuid: "a0", at: start.addingTimeInterval(30)),
                     Line.user("Now run the long job", uuid: "u1", at: start.addingTimeInterval(60))]
        for n in 0..<700 {
            let at = start.addingTimeInterval(120 + Double(n))
            lines.append(SeamLine.bash("make part\(n)", description: "part \(n)", id: "toolu_m\(n)", uuid: "m\(n)", at: at))
            lines.append(SeamLine.result("toolu_m\(n)", uuid: "mr\(n)", at: at,
                                         content: String(repeating: "build output \(n)\n", count: 300)))
        }
        lines.append(Line.text("The long job is done.", uuid: "a1", at: start.addingTimeInterval(900)))
        for n in 2...4 {
            let at = now.addingTimeInterval(-Double(10 - n) * 60)
            lines.append(Line.user("Question \(n)", uuid: "u\(n)", at: at))
            lines.append(Line.text("Answer \(n). ETA: \(clockUTC.string(etaTime)) UTC", uuid: "a\(n)", at: at.addingTimeInterval(5)))
        }
        var fixture = SessionFixture()
        fixture.cli = cli
        fixture.lastActivity = now.addingTimeInterval(-60)
        try tree.writeSession(sessionA, fixture)
        try tree.writeLines(lines, to: tree.mirrorURL(cli))
        try tree.write("Host buildbox\n  HostName 192.0.2.10\n", to: tree.sshConfig)
        try tree.writePopouts([sessionA])
        let size = (try FileManager.default.attributesOfItem(atPath: tree.mirrorURL(cli).path)[.size] as? Int) ?? 0
        #expect(size > 3 << 20)
    }

    @Test func theOneTimeScanFindsALinkTheTailNeverHoldsAndProgressFieldsArrive() async throws {
        try writeSession()
        let memory = store()
        let engine = CodeSessionsEngine(environment: tree.environment(clock: clock, processes: candidates))
        engine.register(.progress + .dashboards(sites: .test), memory: memory)
        engine.start()
        await engine.waitUntilIdle()
        let found = await eventually(15) { engine.sessions.first { $0.id == sessionA }?.dashboard?.handle == "polar-shore" }
        #expect(found, "the scan's mark brought the engine back")
        let mark: DashboardScanRecord? = memory.read(.dashboardScan, session: sessionA)
        #expect(mark?.found == true && mark?.handle == "polar-shore" && (mark?.bytes ?? 0) > 3 << 20)
        let stored: DashboardRecord? = memory.read(.dashboard, session: sessionA)
        #expect(stored?.handle == "polar-shore")
        let session = try #require(engine.sessions.first { $0.id == sessionA })
        let start = try #require(session.workStartedAt)
        #expect(abs(start.timeIntervalSince(now.addingTimeInterval(-6 * 60))) < 0.01, "the latest question starts the work")
        let eta = try #require(session.eta)
        #expect(eta.kind == .stated && eta.statedZone == "UTC" && !eta.isLate)
        #expect(abs(eta.at.timeIntervalSince(etaTime)) < 60, "its minute")
        engine.stop()
        memory.flush()
    }
}
