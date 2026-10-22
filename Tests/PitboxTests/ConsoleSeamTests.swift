import AppKit
import Foundation
import Testing
@testable import Pitbox
import PitboxConsole
import PitboxKit
import PitboxSessions

/// The console as the app wires it: the settings mapped by hand, the run and sandbox policies, the block's presenter
/// (forwards only), and the real console built over fake inputs (no tab, no spawn, nothing shown).
@MainActor
@Suite("Console wiring", .serialized)
struct ConsoleSeamTests {
    @Test func theConsoleSettingsAreMappedByHand() {
        var s = CodeSettings()
        var t = ConsoleSeamFactory.terminalSettings(s)
        #expect(t.fontSize == 12 && t.appearance == .system)
        s.console = CodeSettings.Console(fontSize: 36, theme: .dark)
        t = ConsoleSeamFactory.terminalSettings(s)
        #expect(t.fontSize == TerminalSettings.fontSizeRange.upperBound && t.appearance == .dark)
        s.console = CodeSettings.Console(fontSize: 9, theme: .light)
        t = ConsoleSeamFactory.terminalSettings(s)
        #expect(t.fontSize == 9 && t.appearance == .light)
        #expect(t.fontName == TerminalSettings.standard.fontName, "everything else at the console's defaults")
    }

    @Test func theRunAndSandboxPoliciesComeFromTheSettings() {
        var s = CodeSettings()
        #expect(ConsoleSeamFactory.runPolicy(s) == .copyOnly, "new installs: Copy only")
        s.commands = .run
        #expect(ConsoleSeamFactory.runPolicy(s) == .run)
        s.sandboxDenyFolders = ["~/Secrets"]
        s.sandboxAllowSocketFolders = ["/Users/alex/Library/Application Support/Tool"]
        let memory = SandboxMemory()
        let policy = ConsoleSeamFactory.sandboxPolicy(s, memory: memory)
        #expect(policy.denyFolders == ["~/Secrets"])
        #expect(policy.allowSocketFolders == ["/Users/alex/Library/Application Support/Tool"])
        #expect(policy.announcedFolders == memory.folders && policy.announcedSocketFolders == memory.socketFolders)
        #expect(ConsoleSeamFactory.fetchedOpening(fileName: "notes.pdf") == .open)
        #expect(ConsoleSeamFactory.fetchedOpening(fileName: "tool.sh") == .showInFinderOnly)
    }

    @Test func theBlocksPresenterOnlyForwardsAndNoticesRuns() {
        let sheet = RecordingSheet()
        let presenter = RunWatchingPresenter(sheet: sheet)
        var before = 0
        var runs = 0
        presenter.beforePresent = { before += 1 }
        presenter.onRunEvent = { runs += 1 }
        var events: [CommandOfferEvent] = []
        presenter.present(AppFixture.offer(), anchor: .zero, freshness: FreshFreshness()) { events.append($0) }
        presenter.presentFetch(FetchFileRequest(alias: "buildbox", replyUser: nil, remotePath: "/tmp/report.txt",
                                                destinationName: nil),
                               source: AppFixture.offer().source, sessionIndex: 1, anchor: .zero,
                               freshness: FreshFreshness()) { events.append($0) }
        presenter.offerWentStale(AppFixture.offer().id)
        presenter.dismissSheet()
        presenter.revealRun(UUID())
        #expect(sheet.calls == ["present", "fetch", "stale", "dismiss", "reveal"])
        #expect(before == 2, "the anchor is set before each sheet opens")
        let id = UUID()
        for event in [CommandOfferEvent.copied, .typed, .started(runID: id), .finished(runID: id, exitStatus: 0, seconds: 1),
                      .stopped(runID: id, signal: 2, seconds: 1), .cancelled, .refused(reason: "r")] {
            sheet.events.first?(event)
        }
        #expect(events.count == 7, "the block gets every event, in order")
        #expect(events.first == .copied && events.last == .refused(reason: "r"))
        #expect(runs == 3, "start, finish and stop are noticed")
    }

    @Test func theRealConsoleIsBuiltWithoutStartingAnything() {
        var asked = 0
        let inputs = ConsoleSeamInputs(blockCanShow: { asked += 1; return false },
                                       ensureBlockShown: { done in asked += 1; done(false) },
                                       keyboardRequester: { _ in asked += 1 }, anchorWindow: { nil },
                                       settings: { CodeSettings() }, previewFetchedFile: { _, _ in asked += 1 })
        let console = ConsoleSeamFactory.make(inputs, memory: SandboxMemory())
        let wired = console as? PitboxConsoleSeam
        #expect(wired != nil)
        #expect(console.presenter is RunWatchingPresenter)
        #expect(console.drawerView != nil && console.drawerHeight == 0, "hidden while it has no tabs")
        #expect(!console.commandRunning && wired?.host.sessionCount == 0, "no plain shell at start")
        #expect(wired?.drawer.state == .hidden)
        var heights: [CGFloat] = []
        console.onDrawerHeightChanged = { heights.append($0) }
        console.blockHidden()
        console.update(settings: CodeSettings())
        #expect(heights.isEmpty && asked == 0, "nothing asked of the block while nothing runs")
        console.shutdown()
    }
}
