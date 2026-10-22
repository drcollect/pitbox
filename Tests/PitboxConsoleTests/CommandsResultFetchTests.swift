import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// Result fetches: `presentFetch` opens the Fetch file sheet for a file a session handed over or wrote on the server,
/// with the same rules and arming as an offer's Fetch file, no command text, and at the click
/// `freshness(ofResultFetch:toolUseID:path:)`, which must answer `fresh`.
@MainActor
struct CommandsResultFetchTests {
    private func opened(_ runner: FakeFetchRunner = FakeFetchRunner { user in .success(SheetFixtures.resultPlan(user: user ?? "buildbox")) },
                        request: FetchFileRequest = SheetFixtures.resultRequest()) async -> SheetHarness {
        let h = SheetHarness(assess: { _, _ in
            Issue.record("a result fetch is never read by the classifier")
            return CommandSheetState.noReading
        }, fetchRunner: runner)
        await h.presentFetch(request)
        return h
    }

    @Test func theProtocolOpensTheFetchSheetWithoutCommandText() async throws {
        let runner = FakeFetchRunner { user in .success(SheetFixtures.resultPlan(user: user ?? "buildbox")) }
        let h = await opened(runner)
        let model = try #require(h.model)
        #expect(model.title == "Fetch a file from buildbox")
        #expect(model.rows.map(\.label) == ["From", "File", "Server", "Log in as", "Path", "Into", "Limits", "Note", "Runs"],
                "no You asked, no Said, no Command")
        #expect(model.commandCaption == "A file from the session:")
        #expect(model.sourceLines == [[.session(SheetFixtures.resultPath)]])
        #expect(!model.showsCommandArea && h.view?.commandArea == nil, "no command area: there is no command")
        #expect(!model.copy.state.isShown && !model.runInstead.state.isShown && !model.copyCleaned.state.isShown)
        #expect(!model.run.state.isShown && !model.type.state.isShown && !model.server.state.isShown)
        #expect(model.redLines.isEmpty && model.checkText == nil && !model.isRisky)
        #expect(model.loginChoice == nil, "the configured login user only")
        #expect(!model.sections.contains { $0.disclosure == .wholeReply || $0.disclosure == .howItRuns })
        #expect(model.sections.contains { $0.disclosure == .moreOptions })
        #expect(model.fetch.state == .on)
        let plan = try #require(runner.plans.first)
        #expect(runner.plans.count == 1 && plan.user == nil, "planned once, for the config's user")
        #expect(plan.request == SheetFixtures.resultRequest(), "the request exactly as the monitors made it")
        #expect(h.contexts.isEmpty && h.classifierOptions.isEmpty, "nothing was classified")
        #expect(runner.started.isEmpty && h.freshness.resultChecks.isEmpty, "nothing connects before the click")
    }

    @Test func fetchStartsOnlyOnAnArmedClickAfterAFreshResultCheck() async throws {
        let runner = FakeFetchRunner { user in .success(SheetFixtures.resultPlan(user: user ?? "buildbox")) }
        let h = await opened(runner)
        let fetch = try #require(h.view?.fetchButton)
        h.click(fetch)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.started.isEmpty && h.freshness.resultChecks.isEmpty, "not armed yet: the press counts for nothing")
        h.advance(1)
        fetch.pointerExited()
        h.click(fetch)
        #expect(await waitUntil(5) { runner.started.count == 1 })
        #expect(h.freshness.resultChecks == [.init(sessionIndex: 3, toolUseID: "toolu_01SendUserFile", path: SheetFixtures.resultPath)])
        #expect(h.freshness.calls == 0, "never an offer's check")
        #expect(runner.started.first == SheetFixtures.resultPlan())
        #expect(h.model?.fetch.title == "Fetching…" && h.model?.cancel.title == "Cancel fetch")
        runner.progress.first?(2_048)
        #expect(h.model?.rows.contains { $0.label == "Progress" } == true)
        runner.completions.first?(.saved(fileName: "eval-report.md", bytes: 4_096))
        #expect(h.events == [.fetched(.saved(fileName: "eval-report.md", bytes: 4_096))])
        #expect(h.model?.showInFinder.state == .on && h.model?.cancel.title == "Close")
        h.controller.dismissSheet()
        #expect(h.events.count == 1, "closing after a fetch is no cancel")
    }

    @Test func aStaleOrSupersededAnswerStartsNothingForGood() async throws {
        for answer in [CommandOfferFreshness.stale,
                       .superseded(CommandOffer.Supersession(newerReplies: 1, latestAt: Date(timeIntervalSince1970: 1_760_965_400), sessionIsWorking: false))] {
            let runner = FakeFetchRunner { user in .success(SheetFixtures.resultPlan(user: user ?? "buildbox")) }
            let h = await opened(runner)
            h.freshness.resultAnswer = answer
            h.advance(1)
            h.click(try #require(h.view?.fetchButton))
            #expect(await waitUntil(5) { h.sheet?.state.stale == true })
            #expect(runner.started.isEmpty)
            #expect(h.model?.fetch.state == .off(CommandSheetModel.resultStaleWords))
            #expect(h.model?.message?.text == CommandSheetModel.resultStaleWords)
            #expect(h.model?.redLines.isEmpty == true, "no R22 tick can bring it back")
            h.advance(5)
            h.click(try #require(h.view?.fetchButton))
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(runner.started.isEmpty && h.freshness.resultChecks.count == 1)
        }
    }

    @Test func anUnknownOrSlowAnswerStartsNothingAndCanBeTriedAgain() async throws {
        let runner = FakeFetchRunner { user in .success(SheetFixtures.resultPlan(user: user ?? "buildbox")) }
        let h = await opened(runner)
        h.freshness.resultAnswer = .unknown
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { h.sheet?.state.message?.text == "Couldn't check the session; try again." })
        #expect(runner.started.isEmpty)
        // Slower than 300 ms counts as unknown too, whatever the answer would have been.
        h.freshness.resultAnswer = .fresh
        h.freshness.delay = 1
        h.sheet?.state.message = nil
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { h.sheet?.state.message?.text == "Couldn't check the session; try again." })
        #expect(runner.started.isEmpty)
        h.freshness.delay = 0
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { runner.started.count == 1 })
    }

    @Test func aRequestWithoutItsToolUseIsNeverPlannedOrFetched() async throws {
        let runner = FakeFetchRunner { user in .success(SheetFixtures.resultPlan(user: user ?? "buildbox")) }
        let h = await opened(runner, request: SheetFixtures.resultRequest(toolUseID: nil))
        #expect(runner.plans.isEmpty, "not even the SSH config is read")
        #expect(h.model?.fetch.state == .off(CommandSheetController.uncheckableWords))
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.started.isEmpty && h.freshness.resultChecks.isEmpty)
    }

    @Test func aRefusedPlanSaysWhyAndOffersNothingInstead() async throws {
        let h = await opened(FakeFetchRunner { _ in .failure(.deceptiveName) })
        let model = try #require(h.model)
        #expect(model.fetch.state == .off("the file name looks deceptive: not fetched"))
        #expect(!model.runInstead.state.isShown && !model.copy.state.isShown, "there is no command to fall back to")
    }

    @Test func withoutARunnerFetchFileSaysItIsNotAvailable() async throws {
        let h = SheetHarness(assess: { _, _ in CommandSheetState.noReading })
        await h.presentFetch()
        #expect(h.model?.fetch.state == .off(CommandSheetController.fetchUnavailableWords))
        #expect(h.model?.run.state.isShown == false && h.view?.commandArea == nil, "never the ordinary sheet")
    }

    @Test func openAndShowInFinderAfterASavedResultFetchWorkLikeAnOffers() async throws {
        var openedFiles: [URL] = []
        var revealed: [URL] = []
        let runner = FakeFetchRunner { user in .success(SheetFixtures.resultPlan(user: user ?? "buildbox")) }
        let h = await opened(runner)
        h.controller.fetchedFileOpening = { name in name.hasSuffix(".md") ? .open : .showInFinderOnly }
        h.controller.openFetchedFile = { openedFiles.append($0) }
        h.controller.revealInFinder = { revealed.append($0) }
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { runner.started.count == 1 })
        let downloads = URL(fileURLWithPath: h.folder.path).appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("# report".utf8).write(to: downloads.appendingPathComponent("eval-report 2.md"))
        runner.completions.first?(.saved(fileName: "eval-report 2.md", bytes: 8))
        #expect(h.model?.openFetched.title == "Open" && h.model?.openFetched.state == .on)
        let open = try #require(h.view?.openFetchedButton)
        h.click(open)
        #expect(openedFiles.isEmpty, "Open arms like Show in Finder")
        h.advance(1)
        open.pointerExited()
        h.click(open)
        #expect(openedFiles == [downloads.appendingPathComponent("eval-report 2.md")])
        h.click(try #require(h.view?.showInFinderButton))
        #expect(revealed == [downloads.appendingPathComponent("eval-report 2.md")])
    }

    @Test func cancelBeforeAndDuringAFetch() async throws {
        let before = await opened()
        before.click(try #require(before.view?.cancelButton))
        #expect(before.sheet == nil && before.events == [.cancelled])

        let runner = FakeFetchRunner { user in .success(SheetFixtures.resultPlan(user: user ?? "buildbox")) }
        let during = await opened(runner)
        during.advance(1)
        during.click(try #require(during.view?.fetchButton))
        #expect(await waitUntil(5) { runner.started.count == 1 })
        during.click(try #require(during.view?.cancelButton))
        #expect(runner.handles.first?.cancelled == true, "Cancel fetch stops the copy")
        #expect(during.sheet == nil)
        runner.completions.first?(.cancelled)
        #expect(during.events == [.fetched(.cancelled)], "a started fetch reports its outcome, not a cancel")
    }

    @Test func aResultFetchReplacesAnOfferSheetAndOfferCallsLeaveItAlone() async throws {
        let runner = FakeFetchRunner { user in .success(SheetFixtures.resultPlan(user: user ?? "buildbox")) }
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) }, fetchRunner: runner)
        let offer = SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path))
        await h.present(offer)
        await h.presentFetch()
        #expect(h.events == [.cancelled], "the offer's sheet closed as a Cancel")
        #expect(h.sheet?.state.resultFetch != nil)
        h.controller.offerWentStale(offer.id)
        h.controller.offerWasSuperseded(offer.id, supersession: CommandOffer.Supersession(newerReplies: 1, latestAt: Date(), sessionIsWorking: false))
        #expect(h.sheet?.state.stale == false && h.sheet?.state.supersession == nil)
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { runner.started.count == 1 })
        #expect(h.host.requests.isEmpty, "no command tab, ever")
    }

    @Test func theLogNamesTheSessionByNumberOnly() async throws {
        let lock = NSLock()
        var lines: [String] = []
        let recorder = CommandLog.addRecorder { category, line in lock.withLock { lines.append("[\(category)] \(line)") } }
        defer { CommandLog.removeRecorder(recorder) }
        let runner = FakeFetchRunner { user in .success(SheetFixtures.resultPlan(user: user ?? "buildbox")) }
        let path = "/home/buildbox/very-private-client/notes.md"
        let h = SheetHarness(assess: { _, _ in CommandSheetState.noReading }, fetchRunner: runner)
        await h.presentFetch(SheetFixtures.resultRequest(path: path, toolUseID: "toolu_private_marker"),
                             source: SheetFixtures.resultSource(headline: "very private headline"), sessionIndex: 7)
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { runner.started.count == 1 })
        let recorded = lock.withLock { lines }
        #expect(recorded.contains { $0.contains("fetch sheet opened") && $0.contains("#7.file") })
        #expect(recorded.contains { $0.contains("fetch started") && $0.contains("#7.file") })
        #expect(!recorded.contains { $0.contains("very-private-client") || $0.contains("toolu_private_marker") || $0.contains("very private") })
    }
}
