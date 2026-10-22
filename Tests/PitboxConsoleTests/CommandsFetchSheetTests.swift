import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// The Fetch file sheet against a fake `FetchRunning`: the plan when it opens, the user choice, the click-time checks,
/// progress, the outcome, Cancel and "Run in terminal instead".
@MainActor
struct CommandsFetchSheetTests {
    static let text = "scp 'alex@buildbox:/home/alex/drafts/release-notes.md' ~/Downloads/"

    static func plan(user: String = "buildbox") -> FetchPlan {
        FetchPlan(alias: "buildbox", loginUser: user, configUser: "buildbox", replyUser: "alex", proxyNote: nil,
                  remotePath: "/home/alex/drafts/release-notes.md", fileName: "release-notes.md", previewName: "release-notes 2.md",
                  arguments: scpArguments(user: user, staging: "<staging>"), configFingerprint: "fp")
    }

    /// The argument list of `FetchCommand.arguments` (with `-o LogLevel=ERROR` in place of `-q`).
    static func scpArguments(user: String, staging: String) -> [String] {
        ["/usr/bin/scp", "-o", "LogLevel=ERROR", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
         "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
         "-o", "ConnectTimeout=15", "--", "\(user)@buildbox:/home/alex/drafts/release-notes.md", "\(staging)/release-notes.md"]
    }

    static func assessment(_ text: String, _ context: CommandContext) -> CommandAssessment {
        var a = SheetFixtures.notFlagged(text, programs: ["scp"])
        a.commandClass = .fetchFile
        a.fetch = FetchFileRequest(alias: "buildbox", replyUser: "alex", remotePath: "/home/alex/drafts/release-notes.md",
                                   destinationName: nil)
        a.machineReason = "For this Mac: it copies from buildbox."
        return a
    }

    private func openSheet(_ runner: FakeFetchRunner) async -> SheetHarness {
        let h = SheetHarness(assess: Self.assessment, fetchRunner: runner)
        await h.present(SheetFixtures.offer(Self.text, facts: SheetFixtures.facts(place: .ssh, alias: "buildbox"), caption: nil))
        _ = await waitUntil(5) { if case .planned? = h.sheet?.state.fetch?.phase { return true }; return false }
        return h
    }

    @Test func theFetchSheetPlansWhenItOpensAndShowsTheExactCommand() async throws {
        let runner = FakeFetchRunner { user in .success(Self.plan(user: user ?? "buildbox")) }
        let h = await openSheet(runner)
        #expect(runner.plans.count == 1 && runner.plans.first?.user == nil, "the config's user by default")
        let model = try #require(h.model)
        #expect(model.title == "Fetch a file from buildbox")
        #expect(!model.run.state.isShown && !model.type.state.isShown)
        #expect(model.copy.title == "Copy command" && model.runInstead.state == .on)
        #expect(model.loginChoice == .init(config: "buildbox", reply: "alex", picked: "buildbox"))
        let runs = try #require(model.rows.first { $0.label == "Runs" })
        #expect(runs.lines.first == [.mono("/usr/bin/scp -o LogLevel=ERROR -o BatchMode=yes -o StrictHostKeyChecking=yes")])
        #expect(runs.lines.dropFirst().first == [.mono("  (6 more options, ▸ The whole scp command)")], "an option and its value count once")
        #expect(runs.lines.last == [.mono("  -- 'buildbox@buildbox:/home/alex/drafts/release-notes.md' '<staging>/release-notes.md'")])
        h.controller.toggle(.moreOptions)
        let opened = try #require(h.model?.rows.first { $0.label == "Runs" })
        #expect(opened.lines.dropFirst().first == [.mono("  -o UpdateHostKeys=no -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -o ConnectTimeout=15")])
        #expect(model.rows.contains { $0.label == "Into" })
        #expect(model.commandCaption == "From the reply, command 1 as it was written:")
        #expect(model.fetch.state == .on)
    }

    @Test func changingTheLoginUserPlansAgainAndReArms() async throws {
        let runner = FakeFetchRunner { user in .success(Self.plan(user: user ?? "buildbox")) }
        let h = await openSheet(runner)
        h.advance(1)
        let view = try #require(h.view)
        h.click(view.replyUserChip)
        #expect(await waitUntil(5) { runner.plans.count == 2 })
        #expect(runner.plans.last?.user == "alex")
        _ = await waitUntil(5) { if case .planned(let p)? = h.sheet?.state.fetch?.phase { return p.loginUser == "alex" }; return false }
        #expect(h.model?.loginChoice?.picked == "alex")
        #expect(!view.fetchButton.isArmed, "a new choice re-arms Fetch file")
        h.advance(0.9)
        view.fetchButton.pointerExited()
        h.click(view.fetchButton)
        #expect(await waitUntil(5) { runner.started.count == 1 })
        #expect(runner.started.first?.loginUser == "alex")
    }

    @Test func fetchStartsAfterTheChecksAndReportsProgressAndTheOutcome() async throws {
        let runner = FakeFetchRunner { _ in .success(Self.plan()) }
        let h = await openSheet(runner)
        let fetch = try #require(h.view?.fetchButton)
        h.advance(0.5)
        h.click(fetch)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.started.isEmpty, "armed only after 0.8 s")
        h.advance(0.5)
        fetch.pointerExited()
        h.click(fetch)
        #expect(await waitUntil(5) { runner.started.count == 1 })
        #expect(h.freshness.calls == 1)
        #expect(h.model?.fetch.title == "Fetching…")
        #expect(h.model?.cancel.title == "Cancel fetch")
        runner.progress.first?(42_000)
        #expect(h.model?.rows.contains { $0.label == "Progress" } == true)
        runner.completions.first?(.saved(fileName: "release-notes 2.md", bytes: 42_000))
        #expect(h.events == [.fetched(.saved(fileName: "release-notes 2.md", bytes: 42_000))])
        #expect(h.model?.showInFinder.state == .on)
        h.advance(1)
        h.click(try #require(h.view?.cancelButton))
        #expect(h.sheet == nil)
        #expect(h.events == [.fetched(.saved(fileName: "release-notes 2.md", bytes: 42_000))], "closing after a fetch is no Cancel")
    }

    @Test func cancelDuringAFetchCancelsIt() async throws {
        let runner = FakeFetchRunner { _ in .success(Self.plan()) }
        let h = await openSheet(runner)
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { runner.started.count == 1 })
        h.click(try #require(h.view?.cancelButton))
        #expect(runner.handles.first?.cancelled == true)
        #expect(h.sheet == nil)
        runner.completions.first?(.cancelled)
        #expect(h.events == [.fetched(.cancelled)])
    }

    @Test func aDismissedSheetLeavesARunningFetchRunning() async throws {
        let runner = FakeFetchRunner { _ in .success(Self.plan()) }
        let h = await openSheet(runner)
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { runner.started.count == 1 })
        h.controller.dismissSheet()
        #expect(runner.handles.first?.cancelled == false)
        runner.completions.first?(.failed(reason: "no such file on buildbox"))
        #expect(h.events == [.fetched(.failed(reason: "no such file on buildbox"))], "the outcome still reaches the monitors")
    }

    @Test func aStaleOfferFetchesNothing() async throws {
        let runner = FakeFetchRunner { _ in .success(Self.plan()) }
        let h = await openSheet(runner)
        h.freshness.answer = .stale
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { h.sheet?.state.stale == true })
        #expect(runner.started.isEmpty)
        #expect(h.model?.fetch.state.isOn == false)
    }

    @Test func aRefusedPlanSaysWhyAndOffersRunInTerminalInstead() async throws {
        let runner = FakeFetchRunner { _ in .failure(.deceptiveName) }
        let h = SheetHarness(assess: Self.assessment, fetchRunner: runner)
        await h.present(SheetFixtures.offer(Self.text, facts: SheetFixtures.facts(place: .ssh, alias: "buildbox")))
        _ = await waitUntil(5) { if case .refused? = h.sheet?.state.fetch?.phase { return true }; return false }
        #expect(h.model?.fetch.state == .off("the file name looks deceptive: not fetched"))
        h.advance(1)
        h.click(try #require(h.view?.runInsteadButton))
        let model = try #require(h.model)
        #expect(model.title == "Run a command from Code")
        #expect(model.warnings == ["This skips Fetch file's protections: it may replace a file, and nothing is quarantined."])
        #expect(model.run.state.isShown && !model.fetch.state.isShown)
        #expect(h.view?.runButton.isArmed == false, "the switch re-arms")
        #expect(h.classifierOptions.first?.recognizesFetchFile == true)
        #expect(await waitUntil(5) { h.classifierOptions.last?.recognizesFetchFile == false },
                "the ordinary sheet reads the scp as a command, not as a Fetch file")
    }

    @Test func withoutARunnerAFetchOfferOpensTheOrdinarySheetWithItsWarning() async throws {
        let h = SheetHarness(assess: Self.assessment)
        await h.present(SheetFixtures.offer(Self.text, facts: SheetFixtures.facts(place: .ssh, alias: "buildbox")))
        #expect(h.model?.warnings.first == "This skips Fetch file's protections: it may replace a file, and nothing is quarantined.")
        #expect(h.model?.run.state.isShown == true)
    }

    @Test func r22AndR20GateFetchFileWithTheirTicks() async throws {
        let runner = FakeFetchRunner { _ in .success(Self.plan()) }
        let h = SheetHarness(assess: { text, context in
            var a = Self.assessment(text, context)
            a.flags = [CommandFlag(rule: .r20, words: "No message from you started this turn: a background task did", line: 0,
                                   utf16Range: 0..<0)]
            return a
        }, fetchRunner: runner)
        await h.present(SheetFixtures.offer(Self.text, facts: SheetFixtures.facts(place: .ssh, alias: "buildbox", origin: .taskNotification)))
        _ = await waitUntil(5) { if case .planned? = h.sheet?.state.fetch?.phase { return true }; return false }
        #expect(h.model?.fetch.state == .off("Tick the red line first."))
        h.advance(1)
        h.tickAll()
        h.advance(2.1)
        let fetch = try #require(h.view?.fetchButton)
        h.click(fetch)
        #expect(await waitUntil(5) { runner.started.count == 1 })
    }

    @Test func showInFinderRevealsAndNeverOpens() async throws {
        var revealed: [URL] = []
        let runner = FakeFetchRunner { _ in .success(Self.plan()) }
        let h = await openSheet(runner)
        h.controller.revealInFinder = { revealed.append($0) }
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { runner.started.count == 1 })
        runner.completions.first?(.saved(fileName: "release-notes 2.md", bytes: 10))
        h.advance(1)
        h.click(try #require(h.view?.showInFinderButton))
        #expect(revealed == [URL(fileURLWithPath: h.folder.path).appendingPathComponent("Downloads/release-notes 2.md")])
    }
}
