import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// What a press of a result button does, with recording hooks: nothing opens in a test.
@MainActor
final class RecordingResultHooks {
    var opened: [URL] = []
    var revealed: [URL] = []
    var previewed: [(URL, String)] = []
    var copied: [URL] = []
    var fetches: [(FetchFileRequest, CommandOffer.Source, Int)] = []

    var hooks: CodeResultActions.Hooks {
        CodeResultActions.Hooks(openURL: { self.opened.append($0) }, revealInFinder: { self.revealed.append($0) },
                                preview: { url, name, _ in self.previewed.append((url, name)) }, copyLink: { self.copied.append($0) },
                                presentFetch: { request, source, index, _ in self.fetches.append((request, source, index)) })
    }

    var nothing: Bool { opened.isEmpty && revealed.isEmpty && previewed.isEmpty && copied.isEmpty && fetches.isEmpty }
}

@MainActor
@Suite("Result actions", .serialized)
struct ResultActionsTests {
    let tree = ResultTree("result-actions")
    let hooks = RecordingResultHooks()

    init() {
        CodeTileLog.enabled = false
        CodeTileLog.startRecording()
    }

    func actions() -> CodeResultActions { CodeResultActions(hooks: hooks.hooks, environment: tree.environment()) }

    /// Presses the first button of `kind` with `action` and waits for its outcome.
    func press(_ action: CodeResultButton.Action, on result: CodeResult, session: CodeSessionSnapshot) async -> CodeResultActions.Outcome? {
        var outcome: CodeResultActions.Outcome?
        let button = CodeResultButton(resultID: result.id, action: action, title: "x", tone: .result, arms: true)
        actions().perform(button, session: session, anchor: .zero) { outcome = $0 }
        _ = await onMain(3) { outcome != nil }
        return outcome
    }

    func localFile(_ name: String) throws -> (CodeResult, CodeSessionSnapshot, URL) {
        let url = tree.write("x", "home/code/toy-cube/out/\(name)")
        let result = try #require(LocalReportCheck(environment: tree.environment())
            .results(for: [ResultFileCandidate(path: url.path, origin: .written, toolUseID: "toolu_w", at: ago(2))], cwd: tree.repo.path,
                     budget: .unlimited()).first)
        return (result, resultSession("local_a1", index: 3, cwd: tree.repo.path, results: [result]), url)
    }

    @Test func linksOpenTheirRebuiltAddressOnly() async throws {
        let preview = CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"), label: "localhost:5173")
        let artifact = CodeResult(kind: .artifact, origin: .replyLink, url: URL(string: "https://claude.ai/artifact/abcDEF12"), label: "artifact")
        let local = resultSession("local_a1", index: 3, cwd: tree.repo.path, results: [preview, artifact])
        #expect(await press(.open, on: preview, session: local) == .done)
        #expect(await press(.open, on: artifact, session: local) == .done)
        #expect(hooks.opened.map(\.absoluteString) == ["http://localhost:5173/", "https://claude.ai/artifact/abcDEF12"])
        // An SSH session's preview is on the server: never opened here; a tampered address is refused.
        let ssh = resultSession("local_a2", index: 4, place: .ssh, sshHost: "buildbox", results: [preview])
        #expect(await press(.open, on: preview, session: ssh) == .refused("not a local preview"))
        let tampered = CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/admin?x=1"), label: "x")
        #expect(await press(.open, on: tampered, session: resultSession(results: [tampered])) == .refused("not a local preview"))
        #expect(hooks.opened.count == 2)
        #expect(CodeTileLog.recorded.contains("result opened session=#3 kind=preview"))
        #expect(CodeTileLog.recorded.contains("result opened session=#3 kind=artifact"))
    }

    @Test func filesAreCheckedAgainAtTheClick() async throws {
        let (document, session, url) = try localFile("notes.md")
        #expect(await press(.open, on: document, session: session) == .done)
        #expect(hooks.opened.map(\.path) == [realPath(url)])
        try FileManager.default.removeItem(at: url)
        tree.write("swapped", "home/code/toy-cube/out/notes.md")
        #expect(await press(.open, on: document, session: session) == .refused("the file changed after you looked"))
        #expect(hooks.opened.count == 1)
    }

    @Test func webDocumentsPreviewAndOthersOnlyShowInFinder() async throws {
        let (page, pageSession, pageURL) = try localFile("index.html")
        #expect(page.kind == .webDocument)
        #expect(await press(.preview, on: page, session: pageSession) == .done)
        #expect(hooks.previewed.map(\.0.path) == [realPath(pageURL)] && hooks.previewed.first?.1 == "index.html")
        #expect(await press(.showInFinder, on: page, session: pageSession) == .done)
        let (script, scriptSession, scriptURL) = try localFile("run.sh")
        #expect(await press(.open, on: script, session: scriptSession) == .refused("not for this result"), "never opened")
        #expect(await press(.showInFinder, on: script, session: scriptSession) == .done)
        #expect(hooks.revealed.map(\.path) == [realPath(pageURL), realPath(scriptURL)])
        #expect(hooks.opened.isEmpty, "no web document or script ever reaches NSWorkspace.open")
        #expect(await press(.open, on: page, session: pageSession) == .refused("not for this result"))
    }

    @Test func copyLinkAndFetchOpenNothing() async throws {
        let preview = CodeResult(kind: .serverPreview, origin: .replyLink, url: URL(string: "http://localhost:5173/"), label: "localhost:5173")
        let file = CodeResult(kind: .serverFile, origin: .handedOver, path: "/home/buildbox/out/demo.mp4", label: "demo.mp4",
                              toolUseID: "toolu_send", at: ago(3))
        let ssh = resultSession("local_s1", index: 7, place: .ssh, cwd: "/home/buildbox/toy", sshHost: "buildbox", results: [preview, file])
        #expect(await press(.copyLink, on: preview, session: ssh) == .done)
        #expect(hooks.copied.map(\.absoluteString) == ["http://localhost:5173/"])
        #expect(await press(.fetch, on: file, session: ssh) == .done)
        let fetch = try #require(hooks.fetches.first)
        #expect(fetch.0.alias == "buildbox" && fetch.0.remotePath == "/home/buildbox/out/demo.mp4" && fetch.0.sourceToolUseID == "toolu_send")
        #expect(fetch.2 == 7 && hooks.opened.isEmpty)
    }

    @Test func theDeskPeeksSingleButtonIsTheResultsFirst() async throws {
        let (page, session, url) = try localFile("report.html")
        var outcome: CodeResultActions.Outcome?
        actions().performPrimary(resultID: page.id, session: session, anchor: .zero) { outcome = $0 }
        _ = await onMain(3) { outcome != nil }
        #expect(outcome == .done && hooks.previewed.map(\.0.path) == [realPath(url)], "a web document's first button is Preview")
        var gone: CodeResultActions.Outcome?
        actions().performPrimary(resultID: "document:/nowhere", session: session, anchor: .zero) { gone = $0 }
        #expect(gone == .refused("the result is gone"))
    }

    @Test func aFetchedFileOpensOnlyWhileItIsThePlainFileSaved() async throws {
        func outcome(_ run: (@escaping @MainActor (CodeResultActions.Outcome) -> Void) -> Void) async -> CodeResultActions.Outcome? {
            var got: CodeResultActions.Outcome?
            run { got = $0 }
            _ = await onMain(3) { got != nil }
            return got
        }
        let notes = tree.write("x", "home/Downloads/release-notes 2.md")
        let page = tree.write("<p>x</p>", "home/Downloads/report.html")
        tree.write("echo", "home/Downloads/run.sh")
        #expect(await outcome { actions().openFetched(fileName: "release-notes 2.md", anchor: .zero, done: $0) } == .done)
        #expect(await outcome { actions().openFetched(fileName: "report.html", anchor: .zero, done: $0) } == .done)
        #expect(hooks.opened.map(\.path) == [notes.path] && hooks.previewed.map(\.0.path) == [page.path])
        #expect(await outcome { actions().openFetched(fileName: "run.sh", anchor: .zero, done: $0) } == .refused("not a document"))
        #expect(await outcome { actions().openFetched(fileName: "../Library/x.md", anchor: .zero, done: $0) } == .refused("not a document"),
                "a name with a folder in it is refused by the name rules, before any filesystem call")
        // Swapped for a link, or a second hard link: never opened, but Show in Finder still reveals what is there.
        try FileManager.default.removeItem(at: notes)
        try FileManager.default.createSymbolicLink(atPath: notes.path, withDestinationPath: tree.repo.path)
        #expect(await outcome { actions().openFetched(fileName: "release-notes 2.md", anchor: .zero, done: $0) }
                == .refused(CodeResultActions.fetchedChangedWords))
        try FileManager.default.linkItem(at: page, to: tree.home.appendingPathComponent("page-copy.html"))
        #expect(await outcome { actions().openFetched(fileName: "report.html", anchor: .zero, done: $0) }
                == .refused(CodeResultActions.fetchedChangedWords))
        #expect(hooks.opened.count == 1 && hooks.previewed.count == 1)
        #expect(await outcome { actions().showFetchedInFinder(fileName: "release-notes 2.md", done: $0) } == .done)
        #expect(await outcome { actions().showFetchedInFinder(fileName: "gone.md", done: $0) }
                == .refused("the file is no longer in Downloads"))
        #expect(hooks.revealed.map(\.lastPathComponent) == ["release-notes 2.md"])
        #expect(CodeTileLog.recorded.contains("fetched file opened kind=open"))
        #expect(CodeTileLog.recorded.contains("fetched file opened kind=preview"))
    }

    @Test func logLinesCarryNoSessionText() async throws {
        let (document, session, _) = try localFile("\(secretWord).md")
        _ = await press(.open, on: document, session: session)
        for line in CodeTileLog.recorded {
            #expect(!line.contains(secretWord) && !line.contains("/"), "\(line)")
        }
    }
}
