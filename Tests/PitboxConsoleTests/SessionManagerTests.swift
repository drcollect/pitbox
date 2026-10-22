import AppKit
import Foundation
import Testing
@testable import PitboxConsole

@MainActor
struct SessionManagerTests {
    // MARK: Starting

    @Test func firstLaunchOpensOneLoginShellInHome() {
        let h = ManagerHarness()
        #expect(h.manager.sessions.count == 1 && h.manager.selectedIndex == 0)
        let spec = h.processes[0].spec
        #expect(spec.argv == ["zsh", "-l"] && spec.cwd == "/Users/tester" && spec.kind == .shell)
        #expect(spec.env.contains("TERM=xterm-256color") && spec.env.contains("TERM_PROGRAM=Pitbox"))
        #expect(h.manager.selectedSession?.isSelected == true)
        #expect(h.launcher.sizes[0].cols > 20 && h.launcher.sizes[0].rows > 10, "started at the real size: \(h.launcher.sizes[0])")
    }

    @Test func nothingStartsUntilTheTerminalAreaHasASize() {
        let h = ManagerHarness(size: nil)
        #expect(h.manager.sessions.count == 1 && h.processes.isEmpty, "the session exists but waits for its size")
        h.manager.setContentSize(CGSize(width: 10, height: 10))
        #expect(h.processes.isEmpty, "a degenerate size does not count")
        h.manager.setContentSize(CGSize(width: 700, height: 420))
        #expect(h.processes.count == 1)
        #expect(h.manager.sessions[0].view.frame.size == CGSize(width: 700, height: 420))
    }

    @Test func resizingTheAreaResizesTheSelectedTabAtOnceAndTheOthersWhenItSettles() throws {
        let h = ManagerHarness()
        _ = h.manager.newSession()
        #expect(h.selectedIndex == 1)
        let before = h.processes.map { $0.resizes.count }
        h.manager.setContentSize(CGSize(width: 1000, height: 700))
        let selected = h.processes[1]
        #expect(selected.resizes.count > before[1], "the selected tab told its program (SIGWINCH) at once")
        let last = try #require(selected.resizes.last)
        #expect(last.cols > h.launcher.sizes[1].cols && last.rows > h.launcher.sizes[1].rows)
        #expect(h.processes[0].resizes.count == before[0], "the background tab waits: no reflow of every tab on each drag step")
        h.manager.setContentSize(CGSize(width: 1010, height: 700))
        h.manager.setContentSize(CGSize(width: 1020, height: 700))
        #expect(h.processes[0].resizes.count == before[0])
        h.clock.advance(by: TerminalSessionManager.resizeSettleDelay + 0.05)
        #expect(h.processes[0].resizes.count == before[0] + 1, "one resize for the whole drag")
        let view = h.manager.sessions[0].view
        #expect(view.frame.size == CGSize(width: 1020, height: 700) && view.terminal.cols == h.processes[0].resizes.last?.cols)
    }

    @Test func aTabIsBroughtToSizeWhenItIsSelected() {
        let h = ManagerHarness()
        _ = h.manager.newSession()
        h.manager.setContentSize(CGSize(width: 1000, height: 700))
        #expect(h.manager.sessions[0].view.frame.size == CGSize(width: 800, height: 500), "still the old size")
        h.manager.select(index: 0)
        #expect(h.manager.sessions[0].view.frame.size == CGSize(width: 1000, height: 700))
        #expect(h.processes[0].resizes.last?.cols == h.manager.sessions[0].view.terminal.cols)
    }

    // MARK: Creating

    @Test func newSessionsAreAppendedAndSelected() {
        let h = ManagerHarness(settingsJSON: presetJSON())
        let claude = h.manager.presetsForMenu().first { $0.id == "claude" }
        let second = h.manager.newSession(preset: claude)
        #expect(second?.preset.id == "claude" && h.manager.selectedSession === second)
        #expect(h.processes[1].spec.argv == ["zsh", "-l", "-i", "-c", "exec 'claude'"] && h.processes[1].spec.cwd == "/Users/tester/proj")
        _ = h.manager.newSession()
        #expect(h.ids == ["shell", "claude", "shell"] && h.selectedIndex == 2)
        #expect(h.manager.sessions.filter(\.isSelected).count == 1)
    }

    @Test func aNewShellStartsInHomeOrInTheCurrentFolderPerSetting() {
        let home = ManagerHarness()
        home.processes[0].changeDirectory("/tmp")
        home.manager.pollMetadata()
        _ = home.manager.newSession()
        #expect(home.processes[1].spec.cwd == "/Users/tester", "default: $HOME")

        let current = ManagerHarness(settingsJSON: #"{"newTabLocation":"current"}"#)
        current.processes[0].changeDirectory("/tmp")
        current.manager.pollMetadata()
        _ = current.manager.newSession()
        #expect(current.processes[1].spec.cwd == "/tmp", "newTabLocation: current")
    }

    @Test func theSessionLimitIsEnforced() {
        let h = ManagerHarness(settingsJSON: #"{"maxSessions": 2}"#)
        #expect(h.manager.newSession() != nil)
        #expect(h.manager.canCreateSession == false && h.manager.newSession() == nil)
        #expect(h.manager.sessions.count == 2)
    }

    @Test func presetsForTheMenuHideDisabledOnesAndFollowNewSettings() {
        let h = ManagerHarness(settingsJSON: presetJSON())
        #expect(h.manager.presetsForMenu().map(\.id) == ["shell", "claude", "top", "once"])
        h.manager.update(settings: testSettings(#"{"presets":[{"id":"only","name":"Only","argv":["htop"]}]}"#))
        #expect(h.manager.presetsForMenu().map(\.id) == ["shell", "only"], "new settings apply when the menu opens")
    }

    // MARK: Selecting and rotating

    @Test func rotationWrapsAroundBothWays() {
        let h = ManagerHarness()
        _ = h.manager.newSession(); _ = h.manager.newSession()
        #expect(h.selectedIndex == 2)
        h.manager.selectNext(); #expect(h.selectedIndex == 0, "wraps to the first")
        h.manager.selectPrevious(); #expect(h.selectedIndex == 2, "wraps to the last")
        h.manager.selectPrevious(); #expect(h.selectedIndex == 1)
        h.manager.select(index: 0); #expect(h.selectedIndex == 0)
        h.manager.selectLast(); #expect(h.selectedIndex == 2)
        h.manager.select(index: 9); #expect(h.selectedIndex == 2, "out of range is ignored")
        #expect(h.manager.sessions.filter(\.isSelected).count == 1)
    }

    @Test func rotationWithOneTabDoesNothing() {
        let h = ManagerHarness()
        h.manager.selectNext(); h.manager.selectPrevious()
        #expect(h.selectedIndex == 0)
    }

    // MARK: Closing

    @Test func closingAnIdleShellIsImmediateAndSelectsTheNeighbor() {
        let h = ManagerHarness()
        _ = h.manager.newSession(); _ = h.manager.newSession()
        let ids = h.manager.sessions.map(\.id)
        h.manager.select(id: ids[1])
        #expect(h.manager.requestClose(ids[1]) == .closed)
        #expect(h.manager.sessions.map(\.id) == [ids[0], ids[2]])
        #expect(h.manager.selectedID == ids[2], "the tab that took its place")
        #expect(h.processes[1].terminateCount == 1, "its shell is hung up")
        h.manager.select(id: ids[2])
        _ = h.manager.requestClose(ids[2])
        #expect(h.manager.selectedID == ids[0], "closing the last tab selects the one before it")
    }

    @Test func aBusyTabAsksForConfirmationOnce() {
        let h = ManagerHarness()
        let id = h.manager.sessions[0].id
        h.processes[0].runJob(named: "vim")
        #expect(h.manager.requestClose(id) == .needsConfirmation)
        #expect(h.manager.closeConfirmationID == id && h.manager.sessions.count == 1)
        #expect(h.processes[0].terminateCount == 0, "nothing is killed by the first request")
        #expect(h.manager.requestClose(id) == .closed, "the second request within the window confirms")
        #expect(h.processes[0].terminateCount == 1)
    }

    @Test func theConfirmationExpires() {
        let h = ManagerHarness()
        let id = h.manager.sessions[0].id
        h.processes[0].runJob(named: "vim")
        #expect(h.manager.requestClose(id) == .needsConfirmation)
        h.clock.advance(by: TerminalSessionManager.confirmWindow + 0.1)
        #expect(h.manager.closeConfirmationID == nil)
        #expect(h.manager.requestClose(id) == .needsConfirmation, "asks again instead of closing")
        #expect(h.manager.sessions.count == 1)
    }

    @Test func programTabsAreAlwaysBusyUntilTheyEnd() {
        let h = ManagerHarness(settingsJSON: presetJSON())
        let claude = h.manager.presetsForMenu().first { $0.id == "claude" }
        let session = h.manager.newSession(preset: claude)!
        #expect(session.isBusy)
        #expect(h.manager.requestClose(session.id) == .needsConfirmation)
        h.processes[1].end(.exited(2))
        #expect(!session.isBusy)
        #expect(h.manager.requestClose(session.id) == .closed, "an exited tab closes without asking")
    }

    @Test func theLastTabIsReplacedByAFreshShell() {
        let h = ManagerHarness()
        let first = h.manager.sessions[0].id
        _ = h.manager.requestClose(first)
        #expect(h.manager.sessions.count == 1 && h.manager.sessions[0].id != first)
        #expect(h.processes.count == 2 && h.manager.selectedIndex == 0)
    }

    // MARK: Exit

    @Test func cleanExitClosesTheTabByDefault() {
        let h = ManagerHarness()
        _ = h.manager.newSession()
        let closing = h.manager.sessions[1]
        h.processes[1].end(.exited(0))
        #expect(!h.manager.sessions.contains { $0 === closing })
        #expect(h.manager.sessions.count == 1)
    }

    @Test func aFailedExitKeepsTheTabWithARestartHint() throws {
        let h = ManagerHarness()
        _ = h.manager.newSession()
        let session = h.manager.sessions[1]
        h.processes[1].emit("boom\r\n")
        h.processes[1].end(.exited(3))
        #expect(h.manager.sessions.contains { $0 === session } && session.state == .exited(.exited(3)))
        let text = screenText(session.view)
        #expect(text.contains("boom") && text.contains("Process exited with status 3") && text.contains("Press Return to restart"), "\(text)")

        // Return restarts it in place with a new process.
        session.view.send([0x0d])
        #expect(session.state == .running && h.processes.count == 3)
        #expect(h.processes[2].spec == h.processes[1].spec)
        // Other keys do not.
        h.processes[2].end(.exited(1))
        session.view.send(txt: "x")
        #expect(h.processes.count == 3 && session.hasExited)
    }

    @Test func exitPolicyKeepAndClose() {
        let keep = ManagerHarness(settingsJSON: presetJSON(onExit: "keep"))
        _ = keep.manager.newSession()
        keep.processes[1].end(.exited(0))
        #expect(keep.manager.sessions.count == 2, "keep: a clean exit stays too")

        let close = ManagerHarness(settingsJSON: presetJSON(onExit: "close"))
        _ = close.manager.newSession()
        close.processes[1].end(.exited(9))
        #expect(close.manager.sessions.count == 1, "close: even a failure closes")
    }

    @Test func aSignalKilledProgramIsExplained() {
        let h = ManagerHarness(settingsJSON: presetJSON(onExit: "keep"))
        h.processes[0].end(.signaled(11))
        #expect(screenText(h.manager.sessions[0].view).contains("Process ended by signal 11"))
    }

    @Test func aLaunchFailureShowsAHintAndCanBeRetried() {
        let h = ManagerHarness(start: false)
        h.launcher.failWith = PTYError.notExecutable("/bin/zsh")
        h.manager.startIfNeeded()
        let session = h.manager.sessions[0]
        guard case .failed(let message) = session.state else { Issue.record("expected failure, got \(session.state)"); return }
        #expect(message.contains("not an executable"))
        #expect(screenText(session.view).contains("Could not start"))
        h.launcher.failWith = nil
        session.view.send([0x0d])
        #expect(session.state == .running && h.processes.count == 1)
    }

    // MARK: Auto-rotate

    @Test func autoRotateIsOffByDefaultAndConfigurable() {
        let off = ManagerHarness()
        _ = off.manager.newSession(); _ = off.manager.newSession()
        off.manager.select(index: 0)
        off.clock.advance(by: 600)
        #expect(off.selectedIndex == 0 && off.manager.autoRotate == false)

        let on = ManagerHarness(settingsJSON: #"{"autoRotate": true, "autoRotateSeconds": 10}"#)
        #expect(on.manager.autoRotate && on.manager.autoRotateInterval == 10)
    }

    @Test func autoRotateStepsThroughTheTabsOnTheInterval() {
        let h = ManagerHarness(settingsJSON: #"{"autoRotate": true, "autoRotateSeconds": 10}"#)
        _ = h.manager.newSession(); _ = h.manager.newSession()
        h.manager.select(index: 0)
        h.clock.advance(by: 9.5); #expect(h.selectedIndex == 0)
        h.clock.advance(by: 1.0); #expect(h.selectedIndex == 1)
        h.clock.advance(by: 10.0); #expect(h.selectedIndex == 2)
        h.clock.advance(by: 10.0); #expect(h.selectedIndex == 0, "wraps")
        h.clock.advance(by: 30.0); #expect(h.selectedIndex == 0 || h.selectedIndex == 1 || h.selectedIndex == 2)
    }

    @Test func autoRotateWaitsWhileTheUserIsUsingTheConsole() {
        let h = ManagerHarness(settingsJSON: #"{"autoRotate": true, "autoRotateSeconds": 10}"#)
        _ = h.manager.newSession()
        h.manager.select(index: 0)
        var busy = true
        h.manager.interactionProbe = { busy }
        h.clock.advance(by: 60)
        #expect(h.selectedIndex == 0, "focused or hovered: no rotation")
        busy = false
        h.clock.advance(by: 9.5)
        #expect(h.selectedIndex == 0, "a full interval after the user left")
        h.clock.advance(by: 1.5)
        #expect(h.selectedIndex == 1)
    }

    @Test func typingRestartsTheCountdown() {
        let h = ManagerHarness(settingsJSON: #"{"autoRotate": true, "autoRotateSeconds": 10}"#)
        _ = h.manager.newSession()
        h.manager.select(index: 0)
        h.clock.advance(by: 8)
        h.manager.sessions[0].view.send(txt: "l")   // the user typed
        h.clock.advance(by: 8)
        #expect(h.selectedIndex == 0)
        h.clock.advance(by: 3)
        #expect(h.selectedIndex == 1)
    }

    @Test func aManualSwitchRestartsTheCountdownAndTheToggleWorksAtRuntime() {
        let h = ManagerHarness()
        _ = h.manager.newSession(); _ = h.manager.newSession()
        h.manager.select(index: 0)
        h.manager.setAutoRotate(true)
        #expect(h.manager.autoRotate)
        h.clock.advance(by: 15)
        h.manager.selectNext()          // by hand at t=15 (interval 20 from settings)
        let now = h.selectedIndex
        h.clock.advance(by: 19); #expect(h.selectedIndex == now)
        h.clock.advance(by: 2); #expect(h.selectedIndex != now)
        h.manager.setAutoRotate(false)
        let stopped = h.selectedIndex
        h.clock.advance(by: 200); #expect(h.selectedIndex == stopped)
    }

    @Test func aSingleTabNeverRotatesAndTheTimerStops() {
        let h = ManagerHarness(settingsJSON: #"{"autoRotate": true, "autoRotateSeconds": 3}"#)
        h.clock.advance(by: 60)
        #expect(h.selectedIndex == 0)
        // Only the metadata poll is pending, not the rotation check.
        #expect(h.clock.pendingCount <= 2)
    }

    // MARK: Activity, titles, appearance

    @Test func backgroundActivityAndBellAreFlaggedUntilTheTabIsShown() {
        let h = ManagerHarness()
        _ = h.manager.newSession()
        let background = h.manager.sessions[0]
        h.processes[0].emit("tick\r\n")
        #expect(background.hasUnseenActivity)
        h.processes[0].emit("\u{07}")
        #expect(background.needsAttention)
        h.manager.select(id: background.id)
        #expect(!background.hasUnseenActivity && !background.needsAttention)
        h.processes[0].emit("more\r\n")
        #expect(!background.hasUnseenActivity, "the selected tab is never flagged")
    }

    @Test func titlesFollowTheFolderAndTheRunningProgram() {
        let h = ManagerHarness()
        #expect(h.titles == ["~"])
        h.processes[0].changeDirectory("/Users/tester/proj")
        h.manager.pollMetadata()
        #expect(h.titles == ["proj"], "an idle shell shows its folder")
        h.processes[0].runJob(named: "vim")
        h.manager.pollMetadata()
        #expect(h.titles == ["vim"], "a running program shows its name")
        h.processes[0].idle()
        h.manager.pollMetadata()
        #expect(h.titles == ["proj"])
    }

    @Test func programTabsShowTheProgramNotTheShell() {
        let h = ManagerHarness(settingsJSON: presetJSON())
        let claude = h.manager.presetsForMenu().first { $0.id == "claude" }!
        let session = h.manager.newSession(preset: claude)!
        #expect(session.title == "Claude", "until the shell has exec'ed the program")
        h.processes[1].info = ForegroundInfo(pgid: h.processes[1].pid, name: "claude", isSessionLeader: true, cwd: "/Users/tester/proj")
        h.manager.pollMetadata()
        #expect(session.title == "claude")
    }

    @Test func titlesFromProgramsAreCleaned() {
        let h = ManagerHarness()
        h.processes[0].runJob(named: "ev\u{1b}il\u{202E}txt")
        h.manager.pollMetadata()
        #expect(h.titles == ["eviltxt"])
        let session = h.manager.sessions[0]
        session.view.feed(text: "\u{1b}]0;my\u{202E} title\u{07}")
        #expect(session.oscTitle == "my title")
        #expect(session.tooltip.contains("my title"))
    }

    @Test func aChangeOfAppearanceRecolorsEveryTab() {
        let h = ManagerHarness()
        _ = h.manager.newSession()
        #expect(h.manager.currentPalette == TerminalTheme.dark)
        h.dark = false
        h.manager.appearanceChanged()
        #expect(h.manager.currentPalette == TerminalTheme.light)
        for session in h.manager.sessions {
            #expect(session.view.nativeForegroundColor.usingColorSpace(.sRGB)?.redComponent == TerminalTheme.light.foreground.usingColorSpace(.sRGB)?.redComponent)
        }
        let added = h.manager.newSession()!
        #expect(added.view.nativeForegroundColor.usingColorSpace(.sRGB)?.redComponent == TerminalTheme.light.foreground.usingColorSpace(.sRGB)?.redComponent, "new tabs use the current palette")
    }

    // MARK: Quit

    @Test func shutdownHangsUpEveryShellAndSavesTheTabs() throws {
        let h = ManagerHarness()
        _ = h.manager.newSession()
        h.manager.shutdown()
        #expect(h.processes.allSatisfy { $0.hangUpCount == 1 })
        let saved = try #require(SavedState.load(from: h.stateFile))
        #expect(saved.tabs.map(\.preset) == ["shell", "shell"])
    }

    @Test func shutdownTwiceIsHarmless() throws {
        let h = ManagerHarness()
        h.manager.shutdown()
        h.manager.shutdown()
        h.processes[0].end(.signaled(1))
        #expect(SavedState.load(from: h.stateFile)?.tabs.count == 1)
    }

    @Test func closedTabsThatAreStillRunningAreHungUpAtQuitToo() {
        let h = ManagerHarness()
        _ = h.manager.newSession()
        let id = h.manager.sessions[1].id
        _ = h.manager.requestClose(id)
        #expect(h.processes[1].terminateCount == 1)
        h.manager.shutdown()
        #expect(h.processes[1].hangUpCount == 1, "a process that has not exited yet is still hung up")
    }
}

/// Auto-rotation must stay cheap while idle: it does not rewrite `console-state.json` on every rotation.
@MainActor
struct AutoRotatePersistenceTests {
    private func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return stat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    @Test func automaticRotationDoesNotRewriteTheStateFileEveryInterval() throws {
        let h = ManagerHarness(settingsJSON: #"{"autoRotate": true, "autoRotateSeconds": 5}"#)
        _ = h.manager.newSession()
        h.clock.advance(by: 10)   // start-up saves done
        var inodes: [UInt64] = []
        var selections: [Int?] = []
        for _ in 0..<4 {
            h.clock.advance(by: 5 + TerminalSessionManager.saveDelay)
            inodes.append(try #require(inode(h.stateFile)))
            selections.append(h.selectedIndex)
        }
        #expect(Set(selections).count == 2, "the tabs did rotate: \(selections)")
        #expect(Set(inodes).count == 1, "rewritten (new inode) on every rotation: \(inodes)")
        // A selection the user makes is still saved, and quitting saves wherever rotation left the tabs.
        h.manager.selectNext()
        h.clock.advance(by: TerminalSessionManager.saveDelay + 0.1)
        #expect(inode(h.stateFile) != inodes[0] && SavedState.load(from: h.stateFile)?.selected == h.selectedIndex, "Ctrl-Tab is saved")
        h.clock.advance(by: 6)   // one more automatic rotation, not saved
        let rotated = try #require(h.selectedIndex)
        #expect(SavedState.load(from: h.stateFile)?.selected != rotated)
        h.manager.shutdown()
        #expect(SavedState.load(from: h.stateFile)?.selected == rotated)
    }
}

@MainActor
struct SystemClockTests {
    /// Waits for the timers' own callbacks instead of a deadline: on a loaded Mac a 0.05 s timer has fired 6 s late.
    @Test(.timeLimit(.minutes(1))) func scheduledBlocksRunOnceAndCancelledOnesDoNot() async {
        let clock = SystemClock()
        var cancelledRan = false
        let cancelled = clock.schedule(after: 0.05) { cancelledRan = true }
        cancelled.cancel()
        var ran = 0
        var keep: ClockToken?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            keep = clock.schedule(after: 0.05) {
                ran += 1
                if ran == 1 { done.resume() }   // a second run is caught below, never a double resume
            }
        }
        // A later timer: the cancelled one (due earlier) had every chance to run by the time this one does.
        var later: ClockToken?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            later = clock.schedule(after: 0.1) { done.resume() }   // keep the token: dropping it cancels the timer
        }
        #expect(ran == 1 && !cancelledRan)
        #expect(abs(clock.now.timeIntervalSinceNow) < 1)
        _ = (keep, later)
    }

    @Test(.timeLimit(.minutes(1))) func aTokenThatIsDroppedCancelsItsBlock() async {
        let clock = SystemClock()
        var ran = false
        var token: ClockToken? = clock.schedule(after: 0.05) { ran = true }
        token = nil
        _ = token
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(!ran)
    }
}
