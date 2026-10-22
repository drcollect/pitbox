import AppKit
import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// Command, Type and server tabs in the console.
@MainActor
struct CommandsTabTests {
    @Test func aRunTabRunsExactlyTheDescriptorAfterTheRevealAtTheExpandedSize() throws {
        let h = CommandConsoleHarness()

        h.onReveal = { h.layout(CGSize(width: 618, height: 636)) }   // the expansion happens in the hook
        let request = try h.request("echo hi")
        h.start(request)
        #expect(h.reveals == 1, "the console is revealed and held before anything starts")
        let spec = try #require(h.commands.specs.first)
        #expect(spec.executable == "/bin/zsh")
        #expect(spec.argv == ["/bin/zsh", "-f", "-i", "-o", "interactivecomments", "-o", "nobanghist", "-c", "echo hi"])
        #expect(spec.environment.contains("PATH=\(CommandExecutionDescriptor.cleanPath)"))
        #expect(!spec.environment.contains { $0.hasPrefix("SSH_AUTH_SOCK=") })
        #expect(h.commands.folderPaths == [h.home.path])
        let session = try #require(h.commandSessions.first)
        #expect(h.commands.sizes.first?.rows == session.view.terminal.rows, "the shell starts at the tab's size")
        #expect(session.view.frame.height > 500, "the expanded size, less the bar")
        #expect(session.view.frame.height == h.manager.contentSize.height - CommandTabBar.height)
        #expect(h.manager.selectedSession === session, "added at the end and selected")
        #expect(h.manager.sessions.last === session)
        #expect(session.title == "▶ service token setup")
        #expect(h.events == [.started(runID: request.runID)])
    }

    @Test func theTitleIsCutAt24CharactersAndHiddenCharactersNeverShow() throws {
        let h = CommandConsoleHarness()
        h.start(try h.request("true", headline: "a very long session headline\u{202E} that goes on"))
        let session = try #require(h.commandSessions.first)
        #expect(session.title.count <= 24)
        #expect(session.title.hasPrefix("▶ a very long"))
        #expect(!session.title.unicodeScalars.contains { $0.value == 0x202E })
    }

    @Test func theEchoReachesTheViewAndNeverTheProcess() throws {
        let h = CommandConsoleHarness()
        h.start(try h.request("echo one\necho two"))
        let session = try #require(h.commandSessions.first)
        let process = try #require(h.commands.processes.first)
        let screen = screenText(session.view)
        #expect(screen.contains("$ echo one"))
        #expect(screen.contains("> echo two"))
        #expect(process.written.isEmpty, "nothing was sent to the process")
    }

    @Test func runAndTypeNeverMoveTheKeyboard() throws {
        let h = CommandConsoleHarness()
        h.makeKeyAndFocusFirstTab()
        let firstView = try #require(h.manager.sessions.first?.view)
        #expect(h.window.firstResponder === firstView)
        h.start(try h.request("echo hi"))
        let session = try #require(h.commandSessions.first)
        #expect(h.keyboardRequests.isEmpty, "no keyboardRequester(true) for a command tab")
        #expect(h.window.firstResponder !== session.view, "the command tab is not first responder")
        h.console.focus()   // the terminal hotkey does not reach a command tab either
        #expect(h.window.firstResponder !== session.view)
        #expect(h.keyboardRequests.isEmpty)
        // Only the user's click gives it the keyboard: on the bar ("click here to type") or in the view.
        let bar = try #require(h.view.selectedCommandBar)
        bar.onClickToType?()
        #expect(h.keyboardRequests == [true])
        #expect(h.window.firstResponder === session.view)
    }

    @Test func aFinishedRunReportsItsExitAndDurationAndStays() throws {
        let h = CommandConsoleHarness(settingsJSON: #"{ "onExit": "close" }"#)
        let request = try h.request("exit 3")
        h.start(request)
        let process = try #require(h.commands.processes.first)
        h.clock.advance(by: 12)
        process.end(.exited(3))
        #expect(h.events == [.started(runID: request.runID), .finished(runID: request.runID, exitStatus: 3, seconds: 12)])
        let session = try #require(h.commandSessions.first)
        #expect(h.manager.sessions.contains { $0 === session }, "onExit: close does not close a command tab")
        let bar = try #require(h.view.selectedCommandBar?.content)
        #expect(bar.state == "Finished · exit 3 · 12 s")
        #expect(!bar.showsStop)
        #expect(h.releases == 0, "the hold lasts the console's linger after the last command")
        h.clock.advance(by: 24)
        #expect(h.releases == 0)
        h.clock.advance(by: 1.1)
        #expect(h.releases == 1, "25 s after the last command finished")
    }

    @Test func aNewRunWithinTheLingerKeepsTheHoldAndTwoRunsHaveOneHold() throws {
        let h = CommandConsoleHarness()
        h.start(try h.request("sleep 1"))
        h.start(try h.request("sleep 2"))
        #expect(h.reveals == 2)
        h.commands.processes[0].end(.exited(0))
        h.clock.advance(by: 30)
        #expect(h.releases == 0, "one Run still runs: the hold stays")
        h.commands.processes[1].end(.exited(0))
        h.clock.advance(by: 10)
        h.start(try h.request("true"))   // within the linger: the pending end is cancelled
        h.clock.advance(by: 20)
        #expect(h.releases == 0)
        h.commands.processes[2].end(.exited(0))
        h.clock.advance(by: 25.1)
        #expect(h.releases == 1)
    }

    @Test func returnInAFinishedCommandTabDoesNothingAndThereIsNoRestart() throws {
        let h = CommandConsoleHarness(settingsJSON: #"{ "onExit": "closeIfClean" }"#)
        h.start(try h.request("true"))
        let process = try #require(h.commands.processes.first)
        process.end(.exited(0))
        let session = try #require(h.commandSessions.first)
        #expect(h.manager.sessions.contains { $0 === session }, "closeIfClean does not close it")
        session.send(source: session.view, data: [0x0d][...])
        h.manager.restart(session.id)
        session.restart()
        #expect(h.commands.specs.count == 1, "nothing restarted")
        #expect(process.written.isEmpty)
        let menu = h.view.tabMenu(for: session.id)
        #expect(!menu.items.contains { $0.title == "Restart" })
        #expect(h.view.contextMenuItems(for: session.view).isEmpty)
    }

    @Test func stopSendsSIGINTThenSIGKILLAndASignalIsReportedAsStopped() throws {
        let h = CommandConsoleHarness()
        let request = try h.request("sleep 30")
        h.start(request)
        let process = try #require(h.commands.processes.first)
        let session = try #require(h.commandSessions.first)
        let bar = try #require(h.view.selectedCommandBar)
        #expect(bar.content?.showsStop == true && bar.content?.stopTitle == "Stop")
        bar.onStop?()
        #expect(process.interrupts == 1 && process.kills == 0)
        #expect(h.view.selectedCommandBar?.content?.stopTitle == "Kill")
        bar.onStop?()
        #expect(process.kills == 1)
        h.clock.advance(by: 4)
        process.end(.signaled(SIGKILL))
        #expect(h.events.last == .stopped(runID: request.runID, signal: SIGKILL, seconds: 4))
        #expect(h.view.selectedCommandBar?.content?.state.hasPrefix("Stopped by signal 9 (SIGKILL)") == true)
        _ = session
    }

    @Test func theBarSaysWhoHasTheKeyboardAndWhenInputIsHidden() throws {
        let h = CommandConsoleHarness()
        h.start(try h.request("read -s x"))
        let process = try #require(h.commands.processes.first)
        h.clock.advance(by: 1)
        #expect(h.view.selectedCommandBar?.content?.state == "running 0:01 · Keyboard: elsewhere, click here to type")
        process.modes = TerminalInputModes(echo: false, canonical: true)
        h.clock.advance(by: 1)
        #expect(h.view.selectedCommandBar?.content?.state == "running 0:02 · asks for hidden input, click here to type")
        h.makeKey()
        h.view.selectedCommandBar?.onClickToType?()
        #expect(h.view.selectedCommandBar?.content?.state == "running 0:02 · asks for hidden input · Keyboard: here")
    }

    @Test func theBarStaysWhatPitboxSaysWhateverTheProgramPrints() throws {
        let h = CommandConsoleHarness()
        h.start(try h.request("printf x"))
        let process = try #require(h.commands.processes.first)
        process.emit("\u{1b}[2J\u{1b}[HPitbox · Finished · exit 0\r\nPassword: ")
        let content = try #require(h.view.selectedCommandBar?.content)
        #expect(content.headline == "service token setup")
        #expect(content.state.hasPrefix("running"), "the bar still says running")
    }

    @Test func commandTabsAreNeverSavedAndNeverComeBack() throws {
        let h = CommandConsoleHarness()
        h.start(try h.request("echo hi"))
        _ = h.manager.openServerTab(alias: "buildbox")
        h.manager.persistNow()
        let saved = try #require(SavedState.load(from: h.dir.paths.stateFile))
        #expect(saved.tabs.count == 1, "only the plain shell")
        #expect(saved.tabs.allSatisfy { $0.preset == "shell" })
        #expect(saved.selected == 0)
    }

    @Test func limitsAreThreeRunningAndMaxSessions() throws {
        let h = CommandConsoleHarness(settingsJSON: #"{ "maxSessions": 5 }"#)
        for index in 0..<3 { h.start(try h.request("sleep \(index)")) }
        #expect(h.manager.runningCommandCount == 3)
        let fourth = try h.request("sleep 9")
        #expect(h.console.commandBlocker(role: .run) == "3 commands are running. Wait for one to finish, or stop one.")
        h.start(fourth)
        #expect(h.events.last == .refused(reason: "3 commands are running. Wait for one to finish, or stop one."))
        #expect(h.commands.specs.count == 3)
        h.commands.processes[0].end(.exited(0))
        #expect(h.console.commandBlocker(role: .run) == nil)
        h.start(try h.request("true"))
        #expect(h.manager.sessions.count == 5)
        #expect(h.console.commandBlocker(role: .typeIntoTerminal) == "The console has 5 tabs. Close one.")
    }

    /// Without an executable `/usr/bin/sandbox-exec` nothing could start: Run and Type are off up front, with the
    /// reason on the sheet, instead of failing at the click. The wrapper's path is injected.
    @Test func aMissingSandboxExecTurnsRunAndTypeOffUpFront() throws {
        let scratch = TempDir()
        let missing = scratch.url.appendingPathComponent("no-sandbox-exec").path
        let plain = scratch.url.appendingPathComponent("not-executable")
        try Data("#!/bin/sh\n".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        #expect(!CommandSpawner.isExecutableFile(missing))
        #expect(!CommandSpawner.isExecutableFile(plain.path))
        #expect(!CommandSpawner.isExecutableFile(scratch.url.path), "a folder is no program")
        #expect(CommandSpawner.isExecutableFile(CommandSpawner.sandboxExecPath), "this Mac has the real one")
        let words = CommandStartFailure.sandboxUnavailable.words
        if CommandSpawner.responsibilityDisclaimer() != nil {
            #expect(CommandSpawner.liveProblem(sandboxExec: missing) == words)
            #expect(CommandSpawner.liveProblem(sandboxExec: plain.path) == words)
            #expect(CommandSpawner.liveProblem(sandboxExec: CommandSpawner.sandboxExecPath) != words)
        } else {
            #expect(CommandSpawner.liveProblem(sandboxExec: missing) == CommandStartFailure.identityUnavailable.words)
        }
        // The console with that problem: Run and Type are refused with the words, the server tab is not affected.
        let h = CommandConsoleHarness(pathProblem: { CommandSpawner.liveProblem(sandboxExec: missing) })
        let reason = try #require(CommandSpawner.liveProblem(sandboxExec: missing))
        #expect(h.console.commandBlocker(role: .run) == reason)
        #expect(h.console.commandBlocker(role: .typeIntoTerminal) == reason)
        #expect(h.console.commandBlocker(role: .server) == nil)
        h.start(try h.request("echo hi"))
        #expect(h.events.last == .refused(reason: reason))
        #expect(h.commands.specs.isEmpty, "nothing was spawned")
    }

    @Test func aHiddenTerminalOrAFailedRevealStartsNothing() throws {
        let h = CommandConsoleHarness()
        h.consoleVisible = false
        h.start(try h.request("echo hi"))
        #expect(h.events == [.refused(reason: ConsoleHost.consoleHiddenReason)])
        h.consoleVisible = true
        h.revealAnswer = false
        h.start(try h.request("echo hi"))
        #expect(h.events.last == .refused(reason: "the console couldn't be shown"))
        h.revealAnswer = nil   // no answer: nothing starts after 2 s
        h.start(try h.request("echo hi"))
        #expect(h.commands.specs.isEmpty)
        h.clock.advance(by: 2.1)
        #expect(h.events.last == .refused(reason: "the console couldn't be shown"))
        #expect(h.commands.specs.isEmpty, "nothing ever started")
    }

    @Test func theDefaultHooksFailClosed() async throws {
        let h = CommandConsoleHarness()
        h.console.commandHooks = ConsoleCommandHooks()   // the app wired nothing
        #expect(h.console.commandBlocker(role: .run) == ConsoleHost.consoleHiddenReason)
        #expect(h.console.commandBlocker(role: .typeIntoTerminal) == ConsoleHost.consoleHiddenReason)
        h.start(try h.request("echo hi"))
        #expect(h.events == [.refused(reason: ConsoleHost.consoleHiddenReason)])
        #expect(await h.console.openServerTab(alias: "buildbox") == ConsoleHost.consoleHiddenReason)
        // Only the visibility wired: the reveal's default answers "not shown", so nothing starts either.
        h.console.commandHooks = ConsoleCommandHooks(consoleVisible: { true })
        h.start(try h.request("echo hi"))
        #expect(h.events.last == .refused(reason: "the console couldn't be shown"))
        #expect(h.commands.specs.isEmpty && h.commandSessions.isEmpty, "nothing ever started")
        #expect(h.reveals == 0 && h.releases == 0, "the test's own hooks were never asked")
    }

    @Test func theTerminalHiddenWhileRevealingStartsNothing() throws {
        let h = CommandConsoleHarness()
        h.onReveal = { h.consoleVisible = false }
        h.start(try h.request("echo hi"))
        #expect(h.commands.specs.isEmpty)
        #expect(h.events == [.refused(reason: "the console couldn't be shown")])
    }

    @Test func aFolderChangedAfterTheSheetOpenedStartsNothing() throws {
        let h = CommandConsoleHarness()
        let folder = h.home.subfolder("project")
        let request = try h.request("touch x", folder: folder.path)
        try FileManager.default.moveItem(at: folder, to: h.home.url.appendingPathComponent("elsewhere"))
        h.home.subfolder("project")
        h.start(request)
        #expect(h.events == [.refused(reason: "the folder changed after you looked; review again")])
        #expect(h.commands.specs.isEmpty)
    }

    @Test func aStartFailureSaysWhyAndReportsRefused() throws {
        let h = CommandConsoleHarness()
        h.commands.immediateResult = nil
        let request = try h.request("echo hi")
        h.start(request)
        let process = try #require(h.commands.processes.first)
        process.end(.exited(126))   // the helper's exit can arrive before its record
        #expect(h.events.isEmpty, "nothing reported before the start result")
        h.commands.resolveStart(.failed(.beforeShell(stage: CommandHelperStage.folder, code: EACCES)))
        #expect(h.events == [.refused(reason: "the folder couldn't be entered; nothing ran")])
        #expect(h.view.selectedCommandBar?.content?.state == "Did not start: the folder couldn't be entered; nothing ran")
    }

    @Test func aSpawnThatThrowsReportsRefusedAndLeavesTheTabSayingSo() throws {
        let h = CommandConsoleHarness()
        h.commands.failWith = .identityUnavailable
        h.start(try h.request("echo hi"))
        #expect(h.events == [.refused(reason: "this Mac can't start the command as its own app")])
        #expect(h.view.selectedCommandBar?.content?.state == "Did not start: this Mac can't start the command as its own app")
    }

    @Test func typeWaitsForBracketedPasteAndTypesOneBracketedPasteWithoutReturn() throws {
        let h = CommandConsoleHarness()
        let request = try h.request("echo one\necho two\n", role: .typeIntoTerminal)
        h.start(request)
        let process = try #require(h.commands.processes.first)
        let spec = try #require(h.commands.specs.first)
        #expect(spec.argv == ["/bin/zsh", "-f", "-i", "-o", "interactivecomments", "-o", "nobanghist"], "an interactive clean shell")
        #expect(process.written.isEmpty, "nothing typed before the shell is ready")
        process.emit("% ")
        #expect(process.written.isEmpty)
        process.emit("\u{1b}[?2004h")
        #expect(process.writtenText == "\u{1b}[200~echo one\recho two\u{1b}[201~", "one paste, CRs between lines, no Return")
        #expect(h.events == [.typed])
        let state = try #require(h.view.selectedCommandBar?.content?.state)
        #expect(state == "Typed, not run · click here, then Return to run it")
        process.emit("\u{1b}[?2004h")
        #expect(process.writtenText.components(separatedBy: "\u{1b}[200~").count == 2, "typed once")
        h.clock.advance(by: 25.1)
        #expect(h.releases == 1, "the hold ends the linger after the text was typed")
    }

    @Test func typeNeverTypesBeforeTheStartIsConfirmed() throws {
        let h = CommandConsoleHarness()
        h.commands.immediateResult = nil
        h.start(try h.request("echo one", role: .typeIntoTerminal))
        let process = try #require(h.commands.processes.first)
        process.emit("\u{1b}[?2004h")
        #expect(process.written.isEmpty)
        h.commands.resolveStart(.started)
        #expect(process.writtenText == "\u{1b}[200~echo one\u{1b}[201~")
    }

    @Test func typeGivesUpAfterFiveSecondsAndTypesNothing() throws {
        let h = CommandConsoleHarness()
        h.start(try h.request("echo one", role: .typeIntoTerminal))
        let process = try #require(h.commands.processes.first)
        h.clock.advance(by: 5.1)
        process.emit("\u{1b}[?2004h")
        #expect(process.written.isEmpty, "nothing typed after the timeout")
        #expect(h.events == [.refused(reason: "the shell wasn't ready; use Copy")])
        #expect(h.view.selectedCommandBar?.content?.state == "Not typed: the shell wasn't ready; use Copy")
    }

    @Test func snapshotsAlwaysCoverCommandTabsAndTheirTitles() throws {
        let h = CommandConsoleHarness(settingsJSON: #"{ "allowSnapshots": true }"#, size: CGSize(width: 618, height: 636))
        h.manager.select(index: 0)
        #expect(!h.view.snapshotCoversTerminal, "a plain shell is shown when allowSnapshots is on")
        h.start(try h.request("echo secret-ish"))
        #expect(h.view.snapshotCoversTerminal, "a command tab is covered even with allowSnapshots")
        let titles = h.view.strip.items.map(\.title)
        let rep = try #require(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        var seenDuring: [String] = []
        h.view.onSnapshotTitles = { seenDuring = $0 }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        #expect(seenDuring.contains("▶ Command") && !seenDuring.contains("▶ service token setup"))
        #expect(h.view.strip.items.map(\.title) == titles, "titles come back after the render")
        _ = h.view.dataWithPDF(inside: h.view.bounds)
        #expect(seenDuring.contains("▶ Command"))
        h.commands.processes.first?.end(.exited(0))
        #expect(h.view.snapshotCoversTerminal, "also after it finished")
    }

    @Test func serverTabsRunSshOfAnExactAliasAndNothingElse() async throws {
        let h = CommandConsoleHarness()
        let ssh = h.home.subfolder(".ssh")
        try Data("Host buildbox\n  HostName 10.0.0.1\nHost *.example\nHost !nope other-box\n".utf8)
            .write(to: ssh.appendingPathComponent("config"))
        chmod(ssh.appendingPathComponent("config").path, 0o600)
        #expect(await h.console.openServerTab(alias: "buildbox") == nil)
        let session = try #require(h.manager.sessions.last)
        #expect(session.preset.argv == ["ssh", "buildbox"])
        #expect(session.preset.kind == .program && session.preset.isFromCommandSheet)
        #expect(h.keyboardRequests.isEmpty)
        #expect(await h.console.openServerTab(alias: "box.example") == "that server isn't an exact entry in your SSH config")
        #expect(await h.console.openServerTab(alias: "-oProxyCommand=x") == "that server isn't an exact entry in your SSH config")
        #expect(await h.console.openServerTab(alias: "nope") == "that server isn't an exact entry in your SSH config")
        #expect(await h.console.openServerTab(alias: "other-box") == nil)
    }

    @Test func selectingACommandTabByRunIDNeverFocusesIt() throws {
        let h = CommandConsoleHarness()
        let request = try h.request("echo hi")
        h.start(request)
        h.manager.select(index: 0)
        #expect(h.console.selectCommandTab(runID: request.runID))
        #expect(h.manager.selectedSession?.command?.runID == request.runID)
        #expect(h.keyboardRequests.isEmpty)
        #expect(!h.console.selectCommandTab(runID: UUID()))
        #expect(h.console.runningCommandCount == 1)
    }

    @Test func theRealHelperRunsACommandTabEndToEnd() async throws {
        let h = CommandConsoleHarness(realHelper: true)
        let request = try h.request(#"print -r -- "hello from $(pwd -P)"; exit 3"#)
        h.start(request)
        let session = try #require(h.commandSessions.first)
        #expect(await waitUntil(10) { h.events.count == 2 })
        #expect(h.events.first == .started(runID: request.runID))
        guard case .finished(let runID, let status, _) = h.events.last else {
            Issue.record("expected finished")
            return
        }
        #expect(runID == request.runID && status == 3)
        let unwrapped = screenText(session.view).replacingOccurrences(of: "\n", with: "")   // long rows wrap
        let home = try #require(CommandSandbox.canonicalPath(h.home.path))
        #expect(unwrapped.contains("hello from \(home)"))
        #expect(unwrapped.contains("[Process exited with status 3]"), "the hint follows the output, nothing overwritten")
        #expect(h.view.selectedCommandBar?.content?.state.hasPrefix("Finished · exit 3") == true)
    }
}

extension CommandConsoleHarness {
    /// The block's window is key and the first (plain shell) tab has the keyboard.
    func makeKeyAndFocusFirstTab() {
        makeKey()
        if let first = manager.sessions.first?.view { window.makeFirstResponder(first) }
        view.updateFocusState()
    }

    func makeKey(_ key: Bool = true) {
        window.pretendKey = key
        NotificationCenter.default.post(name: key ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: window)
    }

    @Test func aRequestWithoutThePolicyReadingNeverRuns() throws {
        // The console's last check before the spawn fails closed: only the sheet's own policy reading allows a Run.
        let h = CommandConsoleHarness()
        var request = try h.request("echo hi")
        let fresh = CommandTabRequest(role: .run, descriptor: request.descriptor, folder: request.folder,
                                      origin: request.origin, runID: UUID(), typedText: nil)
        #expect(!fresh.runAllowed(), "the default refuses")
        request.runAllowed = fresh.runAllowed
        h.start(request)
        #expect(h.commands.specs.isEmpty)
        #expect(h.commandSessions.isEmpty)
    }
}
