import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The results deriver through the engine: results reach the snapshot, SSH sessions' files are
/// registered for the result fetches' click-time check, and the check then finds the tool_use in the real tail.
@Suite("Results deriver", .serialized)
@MainActor
struct ResultsDeriverTests {
    let tree = FixtureTree("results-deriver")
    let clock = ManualClock(resultNow)
    let candidates = Shared<[ClaudeProcessCandidate]>([])
    let folder = SeamFolder("results-memory")
    let cli = "0f3c2a9e-1111-2222-3333-444455556666"

    init() {
        CodeLog.enabled = false
        candidates.value = [tree.copyA()]
    }

    func engine(_ checker: CodeResultFetchChecker) -> CodeSessionsEngine {
        let clock = self.clock
        let memory = CodeMemoryStore(url: folder.file("code-memory.json"), owner: getuid(), clock: { clock.now }, writeInterval: 0.05,
                                     writeMax: CodeTuning.memoryWriteMax)
        let engine = CodeSessionsEngine(environment: tree.environment(clock: clock, processes: candidates))
        let environment = ResultEnvironment(home: tree.home.path, temporaryDirectory: tree.root.appendingPathComponent("tmp").path,
                                            owner: getuid(), fileSystem: LiveResultFileSystem(), webPreview: true)
        engine.register(CodeDeriverSet(perSession: [ResultsDeriver(environment: environment, fetchChecks: checker)]), memory: memory)
        return engine
    }

    @Test func anSSHSessionsFileIsAResultAndItsCheckFindsTheToolUse() async throws {
        var fixture = SessionFixture()
        fixture.cli = cli
        fixture.summary = ("review_ready", "Sent the video \(secretWord)", "", "a-final")
        try tree.writeSession(sessionA, fixture)
        try tree.writeLines(finishedWork(sendCall(["/home/someone/out/demo.mp4"], id: "toolu_send", at: ago(5)),
                                         reply: "Sent you demo.mp4; the preview is at http://localhost:5173."), to: tree.mirrorURL(cli))
        try tree.write("Host buildbox\n  HostName 192.0.2.10\n", to: tree.sshConfig)
        try tree.writePopouts([sessionA])
        let checker = CodeResultFetchChecker(base: FakeOfferChecker())
        let engine = engine(checker)
        engine.start()
        await engine.waitUntilIdle()
        let session = try #require(engine.sessions.first { $0.id == sessionA })
        #expect(session.place == .ssh)
        #expect(session.results.map(\.kind) == [.serverFile, .serverPreview])
        #expect(session.results.first?.toolUseID == "toolu_send" && session.otherLinkCount == 0)
        #expect(checker.registered(sessionIndex: session.index) != nil)
        #expect(checker.check(sessionIndex: session.index, toolUseID: "toolu_send", path: "/home/someone/out/demo.mp4") == .fresh)
        #expect(await checker.freshness(ofResultFetch: session.index, toolUseID: "toolu_send", path: "/home/someone/out/x.mp4") == .stale)
        engine.stop()
    }

    @Test func aLocalSessionsWrittenReportIsAButton() async throws {
        let work = tree.localFolder("work/toy cube")
        let report = URL(fileURLWithPath: work).appendingPathComponent("report.md")
        try tree.write("# report", to: report)
        var fixture = SessionFixture()
        fixture.cli = cli
        fixture.sshHost = nil
        fixture.cwd = work
        fixture.summary = ("review_ready", "Report \(secretWord)", "", "a-final")
        try tree.writeSession(sessionA, fixture)
        try tree.writeLines(finishedWork(writeCall(report.path, id: "toolu_w", at: ago(4)), reply: "Wrote report.md."),
                            to: tree.localTranscriptURL(cli, cwd: work))
        try tree.writePopouts([sessionA])
        let checker = CodeResultFetchChecker(base: FakeOfferChecker())
        let engine = engine(checker)
        engine.start()
        await engine.waitUntilIdle()
        let session = try #require(engine.sessions.first { $0.id == sessionA })
        #expect(session.place == .local)
        #expect(session.results.map(\.kind) == [.document] && session.results.first?.path == realPath(report))
        #expect(checker.registered(sessionIndex: session.index) == nil, "only SSH sessions are registered for fetches")
        engine.stop()
    }
}
