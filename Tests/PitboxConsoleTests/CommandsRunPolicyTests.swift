import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// `commands: copyOnly` (the default for new installs) shows no Run button and starts no Run tab; Copy, Type into
/// terminal and Fetch file stay. The policy is read when the sheet opens, again while it is open, and again at the
/// click.
@MainActor
struct CommandsRunPolicyTests {
    private func sheet(_ policy: CommandRunPolicy, text: String = "echo hi") async -> SheetHarness {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        h.runPolicy = policy
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path)))
        return h
    }

    @Test func theSettingsValueMapsFailClosed() {
        #expect(CommandRunPolicy(settingsValue: "run") == .run)
        for value in [nil, "copyOnly", "Run", "RUN", "yes", "true", "", " run"] as [String?] {
            #expect(CommandRunPolicy(settingsValue: value) == .copyOnly, "\(value ?? "nil")")
        }
    }

    @Test func thePublicSheetDefaultsToCopyOnly() {
        let dir = TempDir()
        let console = ConsoleHost(keyboardRequester: { _ in }, paths: dir.paths, launcher: FakeLauncher().launch, clock: ManualClock(),
                                  environment: fixtureEnvironment())
        let controller = CommandSheetController(console: console)
        #expect(controller.runPolicy() == .copyOnly, "without a policy from the settings, Run is off")
    }

    @Test func copyOnlyShowsNoRunButtonAndSaysHowToTurnItOn() async throws {
        let h = await sheet(.copyOnly)
        let model = try #require(h.model)
        #expect(model.run.state == .hidden)
        #expect(try #require(h.view?.runButton).isHidden)
        #expect(model.footer == "Run is off. To allow it, set \"commands\": \"run\" in the settings file.")
        #expect(model.copy.state == .on)
        #expect(model.type.state.isShown, "Type into terminal stays")
        h.controller.dismissSheet()
    }

    @Test func copyOnlyCanStartNothingEvenThroughTheHandler() async throws {
        let h = await sheet(.copyOnly)
        h.advance(5)
        h.click(try #require(h.view?.runButton))
        h.controller.runOrType(.run)   // the handler itself, as if a hidden button had been pressed
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(h.host.requests.isEmpty)
        #expect(h.freshness.calls == 0, "not even the click-time check started")
        #expect(h.sheet?.state.consumed == false, "the approval is not used")
        h.controller.dismissSheet()
    }

    @Test func typeIntoTerminalStaysInCopyOnly() async throws {
        let h = await sheet(.copyOnly)
        h.advance(1)
        h.click(try #require(h.view?.typeButton))
        #expect(await waitUntil(5) { h.host.requests.count == 1 })
        #expect(h.host.requests.first?.role == .typeIntoTerminal)
        #expect(!h.host.requests.contains { $0.role == .run })
    }

    @Test func aPolicySwitchedOffWhileTheSheetIsOpenRefusesTheClick() async throws {
        let h = await sheet(.run)
        let run = try #require(h.view?.runButton)
        #expect(h.model?.run.state == .on)
        h.advance(1)
        h.runPolicy = .copyOnly
        h.click(run)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(h.host.requests.isEmpty, "the click reads the policy again")
        #expect(h.model?.run.state == .hidden, "Run is gone from the open sheet")
        #expect(h.model?.message?.text == CommandSheetModel.runOffWords)
        #expect(h.sheet != nil, "the sheet stays; Copy still works")
        h.controller.dismissSheet()
    }

    @Test func aPolicySwitchedOffDuringTheClickTimeCheckStartsNothing() async throws {
        let h = await sheet(.run)
        h.freshness.delay = 0.15
        h.advance(1)
        h.click(try #require(h.view?.runButton))
        #expect(await waitUntil(5) { h.sheet?.state.checking == true })
        h.runPolicy = .copyOnly
        #expect(await waitUntil(5) { h.sheet?.state.checking == false })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(h.host.requests.isEmpty)
        #expect(h.sheet?.state.consumed == false)
        #expect(h.model?.run.state == .hidden)
        h.controller.dismissSheet()
    }

    @Test func anOpenSheetLosesRunWithoutAClickButNeverGainsIt() async throws {
        let off = await sheet(.copyOnly)
        off.runPolicy = .run
        off.controller.environmentChanged(reassess: false)
        #expect(off.model?.run.state == .hidden, "switching Run on needs a new sheet")
        off.controller.dismissSheet()

        let on = await sheet(.run)
        on.runPolicy = .copyOnly
        on.controller.environmentChanged(reassess: false)
        #expect(on.model?.run.state == .hidden)
        #expect(on.model?.footer == CommandSheetModel.runOffWords)
        on.controller.dismissSheet()
    }

    /// The policy is asked once more after the console's reveal (0.35 s or more after the click), right before the
    /// spawn. The sheet hands the console its own reading.
    @Test func theRequestCarriesThePolicyForTheLastCheckBeforeTheSpawn() async throws {
        let h = await sheet(.run)
        h.advance(1)
        h.click(try #require(h.view?.runButton))
        #expect(await waitUntil(5) { h.host.requests.count == 1 })
        let request = try #require(h.host.requests.first)
        #expect(request.runAllowed())
        h.runPolicy = .copyOnly
        #expect(!request.runAllowed(), "switched off after the click: the console's last check refuses")
    }

    @Test func aPolicySwitchedOffDuringTheRevealStartsNothing() throws {
        let h = DrawerHarness()
        var allowed = true
        var request = try h.request("echo hi")
        request.runAllowed = { allowed }
        var events: [CommandOfferEvent] = []
        h.console.startCommandTab(request) { events.append($0) }
        h.clock.advance(by: 0.2)
        allowed = false
        h.clock.advance(by: 0.2)
        #expect(h.commands.specs.isEmpty, "nothing was spawned")
        #expect(events == [.refused(reason: CommandSheetModel.runOffWords)])
        #expect(h.drawer.state == .hidden && !h.drawer.isHeld, "the hold ended with the refusal")
        // Type is not a Run: the policy does not apply to it.
        var typed = try h.request("echo typed", role: .typeIntoTerminal)
        typed.runAllowed = { false }
        h.console.startCommandTab(typed) { _ in }
        h.clock.advance(by: 0.4)
        #expect(h.commands.specs.count == 1)
    }

    @Test func redLinesArmTypeWhileRunIsOff() async throws {
        let h = SheetHarness(assess: { text, _ in CommandsSheetTests.risky(text) })
        h.runPolicy = .copyOnly
        await h.present(SheetFixtures.offer("rm -rf build\nswift build", facts: SheetFixtures.facts(cwd: h.folder.path)))
        #expect(h.model?.checkText == "2 red lines. Tick each one to arm Type into terminal.")
        #expect(h.model?.run.state == .hidden)
        h.controller.dismissSheet()
    }

    @Test func fetchFileStaysAndRunInsteadIsNotOffered() async throws {
        let runner = FakeFetchRunner { user in .success(CommandsFetchSheetTests.plan(user: user ?? "buildbox")) }
        let h = SheetHarness(assess: CommandsFetchSheetTests.assessment, fetchRunner: runner)
        h.runPolicy = .copyOnly
        await h.present(SheetFixtures.offer(CommandsFetchSheetTests.text, facts: SheetFixtures.facts(place: .ssh, alias: "buildbox"),
                                            caption: nil))
        _ = await waitUntil(5) { if case .planned? = h.sheet?.state.fetch?.phase { return true }; return false }
        let model = try #require(h.model)
        #expect(model.fetch.state == .on, "Fetch file runs Pitbox's own scp argument list, never the reply's text")
        #expect(model.runInstead.state == .hidden, "it would lead to a Run button")
        #expect(model.copy.state == .on)
        h.controller.runInsteadPressed()
        #expect(h.sheet?.state.mode == .fetch, "the handler refuses too")
        h.advance(1)
        h.click(try #require(h.view?.fetchButton))
        #expect(await waitUntil(5) { runner.started.count == 1 })
        #expect(h.host.requests.isEmpty)
    }
}
