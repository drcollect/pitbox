import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// A fake offer checker under the result-fetch wrapper.
final class FakeOfferChecker: CommandOfferFreshnessChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [CommandOffer.ID] = []
    var answer: CommandOfferFreshness = .fresh

    func freshness(of offer: CommandOffer.ID) async -> CommandOfferFreshness {
        lock.withLock { asked.append(offer) }
        return answer
    }

    var questions: [CommandOffer.ID] { lock.withLock { asked } }
}

/// Files on the server: the Fetch file request for `<alias>:<path>`, and the click-time check that finds the tool_use
/// again in a fresh tail with the same path.
@Suite("Result fetches")
struct ResultFetchTests {
    let tree = FixtureTree("result-fetch")
    let cli = "0f3c2a9e-1111-2222-3333-444455556666"

    func paths() throws -> CodeResultFetchChecker.Session {
        let transcript = try #require(CarefulPath(root: tree.projects.path, components: ["ssh-\(cli)", "\(cli).jsonl"]))
        let file = try #require(CarefulPath(root: tree.appSupport.path,
                                            components: ["Claude", "claude-code-sessions", tree.account, tree.org, "\(sessionA).json"]))
        return CodeResultFetchChecker.Session(transcript: transcript, sessionFile: file, owner: getuid())
    }

    func writeSession(archived: Bool = false, lines: [String]) throws {
        var fixture = SessionFixture()
        fixture.cli = cli
        fixture.archived = archived
        try tree.writeSession(sessionA, fixture)
        try tree.writeLines(lines, to: tree.mirrorURL(cli))
    }

    let handed = "/home/buildbox/out/demo.mp4"

    func lines(path: String? = nil) -> [String] {
        finishedWork(sendCall([path ?? handed, "/home/buildbox/out/other.md"], id: "toolu_send", at: ago(5))
                     + writeCall("/home/buildbox/toy/draft.md", id: "toolu_w", at: ago(4)), reply: "Sent you the video.")
    }

    @Test func theToolUseFoundAgainWithTheSamePathIsFresh() throws {
        try writeSession(lines: lines())
        let checker = CodeResultFetchChecker(base: FakeOfferChecker())
        checker.register(try paths(), sessionIndex: 3)
        #expect(checker.check(sessionIndex: 3, toolUseID: "toolu_send", path: handed) == .fresh)
        #expect(checker.check(sessionIndex: 3, toolUseID: "toolu_send", path: "/home/buildbox/out/other.md") == .fresh)
        #expect(checker.check(sessionIndex: 3, toolUseID: "toolu_w", path: "/home/buildbox/toy/draft.md") == .fresh)
    }

    @Test func anythingElseIsStale() throws {
        try writeSession(lines: lines())
        let checker = CodeResultFetchChecker(base: FakeOfferChecker())
        checker.register(try paths(), sessionIndex: 3)
        #expect(checker.check(sessionIndex: 3, toolUseID: "toolu_send", path: "/home/buildbox/out/swapped.mp4") == .stale)
        #expect(checker.check(sessionIndex: 3, toolUseID: "toolu_gone", path: handed) == .stale)
        #expect(checker.check(sessionIndex: 4, toolUseID: "toolu_send", path: handed) == .stale, "not followed")
        // The transcript rewritten without the tool_use.
        try writeSession(lines: finishedWork([], reply: "Nothing to send."))
        #expect(checker.check(sessionIndex: 3, toolUseID: "toolu_send", path: handed) == .stale)
        // The same tool_use id now naming another path.
        try writeSession(lines: lines(path: "/home/buildbox/out/evil.mp4"))
        #expect(checker.check(sessionIndex: 3, toolUseID: "toolu_send", path: handed) == .stale)
        // An archived session.
        try writeSession(archived: true, lines: lines())
        #expect(checker.check(sessionIndex: 3, toolUseID: "toolu_send", path: handed) == .stale)
        checker.unregister(sessionIndex: 3)
        try writeSession(lines: lines())
        #expect(checker.check(sessionIndex: 3, toolUseID: "toolu_send", path: handed) == .stale)
    }

    @Test func offersGoToTheEngineAndASlowCheckIsUnknown() async throws {
        try writeSession(lines: lines())
        let base = FakeOfferChecker()
        base.answer = .stale
        let checker = CodeResultFetchChecker(base: base, timeout: 0.2)
        checker.register(try paths(), sessionIndex: 3)
        let offer = CommandOffer.ID(sessionIndex: 3, replyUUID: "a-final", number: 1)
        #expect(await checker.freshness(of: offer) == .stale && base.questions == [offer])
        #expect(await checker.freshness(ofResultFetch: 3, toolUseID: "toolu_send", path: handed) == .fresh)
        checker.suspendChecks()
        #expect(await checker.freshness(ofResultFetch: 3, toolUseID: "toolu_send", path: handed) == .unknown)
        checker.resumeChecks()
    }

    @Test func theRequestNamesTheAliasThePathAndTheToolUse() throws {
        let result = CodeResult(kind: .serverFile, origin: .handedOver, path: handed, label: "demo.mp4", toolUseID: "toolu_send", at: ago(5))
        let session = resultSession("local_s9", index: 9, place: .ssh, cwd: "/home/buildbox/toy", sshHost: "buildbox", results: [result])
        let made = try #require(ResultServerFiles.request(for: result, session: session, severalCopies: false))
        #expect(made.request == FetchFileRequest(alias: "buildbox", replyUser: nil, remotePath: handed, destinationName: nil,
                                                 sourceToolUseID: "toolu_send"))
        #expect(made.source.sessionID == "local_s9" && made.source.profileLetter == nil && made.source.replyTime == ago(5))
        #expect(ResultServerFiles.sourceLine(for: .handedOver) == "A file the session handed you:")
        #expect(ResultServerFiles.sourceLine(for: .written) == "A file the session wrote:")
        // Never for a local session, a bad alias or a path that fails the rules.
        #expect(ResultServerFiles.request(for: result, session: resultSession(place: .local, cwd: "/x"), severalCopies: false) == nil)
        #expect(ResultServerFiles.request(for: result, session: resultSession(place: .ssh, sshHost: "-oProxyCommand=x"),
                                          severalCopies: false) == nil)
        var bad = result
        bad.path = "/home/buildbox/out/*.mp4"
        #expect(ResultServerFiles.request(for: bad, session: session, severalCopies: false) == nil)
    }
}
