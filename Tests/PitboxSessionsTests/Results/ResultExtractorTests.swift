import Foundation
import Testing
@testable import PitboxSessions

/// Where results come from: artifacts first, files handed over, files written that the reply names, links of the final
/// reply; at most 6, each address or path once; the work counts from the latest turn the user or a peer started.
@Suite("Result sources")
struct ResultExtractorTests {
    let tree = ResultTree("result-sources")
    let artifactA = "https://claude.ai/artifact/aaaaAAAA1111"
    let artifactB = "https://claude.ai/code/artifact/bbbbBBBB2222"
    let artifactOld = "https://claude.ai/artifact/oldOLD000000"

    func extract(_ lines: [String], session: CodeSessionSnapshot? = nil, published: [CodeTurnDigest.PublishedArtifact] = [],
                 midTurn: Bool = false) -> ResultOutput {
        let snapshot = session ?? resultSession(cwd: tree.repo.path)
        return ResultExtractor(environment: tree.environment()).extract(snapshot, digest: resultDigest(lines, published: published, midTurn: midTurn),
                                                                       now: resultNow)
    }

    @Test func sourcesComeInTheirOrderAndEachAddressOnce() throws {
        let sent = tree.write("x", "tmp/handed.md")
        let report = tree.write("x", "home/code/toy-cube/docs/report.html")
        let other = tree.write("x", "home/code/toy-cube/docs/untouched.md")
        let lines = finishedWork(artifactCall(artifactB, id: "toolu_art", at: ago(15)) + sendCall([sent.path], id: "toolu_send", at: ago(12))
                                 + writeCall(report.path, id: "toolu_w1", at: ago(10)) + writeCall(other.path, id: "toolu_w2", at: ago(9)),
                                 reply: """
                                 Done. The report is in docs/report.html, the artifact at \(artifactA) and \(artifactB).
                                 Preview: http://localhost:5173/app. Also see /etc/hosts and `~/notes/plan.md`.
                                 """)
        let published = [CodeTurnDigest.PublishedArtifact(url: artifactA, updatedAt: ago(14)),
                         CodeTurnDigest.PublishedArtifact(url: artifactOld, updatedAt: ago(300))]
        let output = extract(lines, published: published)
        let kinds = output.results.map(\.kind)
        #expect(kinds == [.artifact, .artifact, .document, .webDocument, .preview, .earlierArtifact, .mentionedPath, .mentionedPath])
        #expect(output.results[0].url?.absoluteString == artifactA && output.results[0].origin == .publishedArtifact)
        #expect(output.results[1].url?.absoluteString == artifactB && output.results[1].origin == .artifactTool)
        #expect(output.results[2].path == realPath(sent) && output.results[2].origin == .handedOver)
        #expect(output.results[3].path == realPath(report) && output.results[3].origin == .written)
        #expect(!output.results.contains { $0.path == realPath(other) }, "a written file the reply does not name is no result")
        #expect(output.results[4].url?.absoluteString == "http://localhost:5173/")
        #expect(output.results[5].url?.absoluteString == artifactOld, "published before the work: Earlier artifacts")
        #expect(output.results.suffix(2).map(\.label) == ["/etc/hosts", "~/notes/plan.md"], "path words: peek text only")
        #expect(output.otherLinkCount == 0)
    }

    @Test func atMostSixResults() {
        let links = (0..<9).map { "http://localhost:\(5100 + $0)/" }.joined(separator: " ")
        let output = extract(finishedWork([], reply: "Previews: \(links)"))
        #expect(output.results.filter { $0.kind == .preview }.count == CodeTuning.maxResults)
    }

    @Test func otherLinksAreCountedNeverButtons() {
        let output = extract(finishedWork([], reply: """
        [SAFE](https://claude.ai.evil.com/x) and https://github.com/someone/toy-cube/pull/142 and http://LOCALHOST:5173 \
        and https://dash.example.com/dash/polar-shore/ and https://github.com/someone/toy-cube/pull/142.
        """))
        #expect(output.results.isEmpty)
        #expect(output.otherLinkCount == 3, "the same link counts once; the dashboard link is the dashboards'")
        #expect(!output.results.contains { $0.label.contains("SAFE") })
    }

    @Test func sshPreviewsAreCopyOnlyAndUnknownPlacesHaveNone() {
        let ssh = resultSession(place: .ssh, cwd: "/home/buildbox/toy", sshHost: "buildbox")
        let output = extract(finishedWork([], reply: "Running at http://localhost:5173"), session: ssh)
        #expect(output.results.map(\.kind) == [.serverPreview])
        let unknown = resultSession(place: .unknown, cwd: nil)
        let none = extract(finishedWork([], reply: "Running at http://localhost:5173"), session: unknown)
        #expect(none.results.isEmpty && none.otherLinkCount == 1)
    }

    @Test func serverFilesFollowTheFetchRules() {
        let ssh = resultSession(place: .ssh, cwd: "/home/buildbox/toy", sshHost: "buildbox")
        let lines = finishedWork(sendCall(["/home/buildbox/out/demo.mp4", "/home/buildbox/out/*.md", "/home/buildbox/../etc/x.md",
                                           "/home/buildbox/$HOME/x.md", "/home/buildbox/out/notes.md.app", "relative/x.md",
                                           "/home/buildbox/out/run.sh"], id: "toolu_send", at: ago(10))
                                 + writeCall("/home/buildbox/toy/docs/draft.md", id: "toolu_w", at: ago(8)),
                                 reply: "Wrote docs/draft.md and sent the video.")
        let output = extract(lines, session: ssh)
        #expect(output.results.map(\.kind) == [.serverFile, .serverFile])
        #expect(output.results.map(\.path) == ["/home/buildbox/out/demo.mp4", "/home/buildbox/toy/docs/draft.md"])
        #expect(output.results.map(\.origin) == [.handedOver, .written])
        #expect(output.results.map(\.toolUseID) == ["toolu_send", "toolu_w"])
    }

    @Test func aRunningNewerWorkKeepsTheFinishedOnesResults() {
        let lines = finishedWork([], reply: "Preview at http://localhost:5173") + [
            Line.user("Now add \(secretWord) tests", uuid: "u-next", at: ago(0.5)),
            SeamLine.bash("npm test", description: "Run tests", id: "toolu_t", uuid: "a-t", at: ago(0.4)),
        ]
        #expect(extract(lines).results.map(\.kind) == [.preview], "a newer finished work replaces the results")
        let done = lines + [SeamLine.result("toolu_t", uuid: "r-t", at: ago(0.3), content: "ok"),
                            Line.text("Tests added.", uuid: "a-next", at: ago(0.2))]
        #expect(extract(done).results.isEmpty)
    }

    @Test func noticeTurnsBelongToTheWork() {
        let lines = [Line.user("Run the \(secretWord) fleet", uuid: "u1", at: ago(40)),
                     Line.text("Launched agents.", uuid: "a1", at: ago(39)),
                     SeamLine.noticeTurn(noticeText(taskID: "agent-1"), uuid: "n1", at: ago(10)),
                     Line.text("All agents done: \(artifactA)", uuid: "a2", at: ago(9))]
        let output = extract(lines, published: [.init(url: artifactB, updatedAt: ago(30))])
        #expect(output.results.compactMap(\.url?.absoluteString) == [artifactB, artifactA])
    }

    @Test func aWorkOlderThanTwelveHoursIsJustTheCurrentTurn() {
        let lines = [Line.user("Old \(secretWord) ask", uuid: "u1", at: ago(13 * 60)),
                     Line.text("first", uuid: "a1", at: ago(13 * 60 - 1)),
                     SeamLine.noticeTurn(noticeText(taskID: "agent-1"), uuid: "n1", at: ago(10)),
                     Line.text("done", uuid: "a2", at: ago(9))]
        let output = extract(lines, published: [.init(url: artifactA, updatedAt: ago(60))])
        #expect(output.results.map(\.kind) == [.earlierArtifact], "published before the current turn")
    }
}
