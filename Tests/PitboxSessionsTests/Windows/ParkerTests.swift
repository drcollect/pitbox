import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

@MainActor
@Suite("Parking with a fake Accessibility")
struct ParkerTests {
    init() { CodeTileLog.enabled = false }

    static let a = WindowsHarness.pidA
    static let left = CGRect(x: 200, y: 120, width: 900, height: 700)
    static let middle = CGRect(x: 1300, y: 120, width: 900, height: 700)

    /// Two pop-outs of copy A on the desk (11 "Alpha", 12 "Beta"), Claude's main window (10), and the sessions joined.
    private func desk(_ h: WindowsHarness) {
        h.world.add(WindowsTestWindow(pid: Self.a, number: 10, title: "Claude", frame: CGRect(x: 0, y: 30, width: 1330, height: 620)))
        h.world.add(WindowsTestWindow(pid: Self.a, number: 11, title: "Alpha", frame: Self.left))
        h.world.add(WindowsTestWindow(pid: Self.a, number: 12, title: "Beta", frame: Self.middle))
        h.parker.start()
        h.update([windowSession("local_alpha", title: "Alpha", index: 1), windowSession("local_beta", title: "Beta", index: 2)])
    }

    /// Runs an async parker call while the manual queue does its work: yield, run the queue, until the call returned.
    private func run<T>(_ h: WindowsHarness, _ body: @escaping @MainActor () async -> T) async -> T {
        let box = WindowsResultBox<T>()
        let task = Task { @MainActor in
            let value = await body()
            box.value = value
            return value
        }
        for _ in 0..<500 where box.value == nil {
            await Task.yield()
            h.queue.run()
        }
        return await task.value
    }

    private func isParked(_ place: CodeWindowPlace?) -> Bool {
        if case .parked? = place { return true }
        return false
    }

    // MARK: The join

    @Test func popOutsAreJoinedByTitleAndHeldByNumber() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        #expect(h.place("local_alpha") == .onDesk)
        #expect(h.place("local_beta") == .onDesk)
        #expect(h.status("local_alpha")?.chip(now: Date()) == "on track")
        // Claude renames the window: it stays held by its number.
        h.world.windows[11]?.title = "Alpha, renamed"
        h.pass()
        #expect(h.place("local_alpha") == .onDesk)
    }

    @Test func nothingIsJoinedByPositionAlone() {
        // A hidden 912 × 622 window of copy A (seen on a real Mac), a stale record at exactly its bounds: not matched.
        let h = WindowsHarness(); defer { h.cleanUp() }
        let hidden = CGRect(x: 3055, y: 40, width: 912, height: 622)
        h.world.add(WindowsTestWindow(pid: Self.a, number: 30, title: nil, frame: hidden, onScreen: false, visibleToAX: false))
        h.parker.start()
        h.update([windowSession("local_gone", title: "A closed pop-out", popout: hidden)])
        #expect(h.place("local_gone") == .notMatched)
    }

    @Test func aHiddenWindowIsNotJoinedEvenWithTheSessionsTitle() {
        // Off screen, not minimized, listed by AX, the session's title: a closed pop-out Claude kept alive.
        let h = WindowsHarness(); defer { h.cleanUp() }
        h.world.add(WindowsTestWindow(pid: Self.a, number: 31, title: "Kept alive", frame: Self.left, onScreen: false))
        h.parker.start()
        h.update([windowSession("local_kept", title: "Kept alive")])
        #expect(h.place("local_kept") == .notMatched)
        // Once it is on screen again it joins.
        h.world.windows[31]?.onScreen = true
        h.pass()
        #expect(h.place("local_kept") == .onDesk)
    }

    @Test func aWindowTheUserMinimizedIsMinimizedAndRestoresWithoutMoving() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        h.world.add(WindowsTestWindow(pid: Self.a, number: 11, title: "Alpha", frame: Self.left, onScreen: false, minimized: true))
        h.parker.start()
        h.update([windowSession("local_alpha", title: "Alpha")])
        #expect(h.place("local_alpha") == .minimized)
        #expect(h.status("local_alpha")?.click == .restore)
        h.parker.perform(.restore, sessionID: "local_alpha")
        h.queue.run()
        #expect(h.world.calls == ["unminimize 11", "raise 11", "frontmost 501", "main 11"])
        #expect(h.place("local_alpha") == .onDesk)
    }

    @Test func profilesNotRunningAndAccessibilityOffAreSaid() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        h.parker.start()
        h.update([windowSession("local_b", title: "On B", profile: .b)])
        #expect(h.place("local_b") == .profileNotRunning(letter: "B"))
        #expect(h.status("local_b")?.chip(now: Date()) == "Claude B is not running")
        #expect(h.status("local_b")?.click == CodeWindowClick.none)
        h.world.trusted = false
        h.update([windowSession("local_a", title: "On A")])
        #expect(h.place("local_a") == .noAccessibility)
    }

    @Test func eachCopyJoinsItsOwnWindows() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        h.processes.list.append(ClaudeProcessInfo(pid: WindowsHarness.pidC, profile: .c, bundlePath: WindowsHarness.appPathC))
        h.world.add(WindowsTestWindow(pid: Self.a, number: 11, title: "Same title", frame: Self.left))
        h.world.add(WindowsTestWindow(pid: WindowsHarness.pidC, number: 41, title: "Same title", frame: Self.middle))
        h.parker.start()
        h.update([windowSession("local_a", title: "Same title", profile: .a), windowSession("local_c", title: "Same title", profile: .c, index: 2)])
        #expect(h.place("local_a") == .onDesk)
        #expect(h.place("local_c") == .onDesk)
        h.parker.perform(.park, sessionID: "local_c")
        h.queue.run()
        #expect(h.world.calls.contains("minimize 41"))
        #expect(!h.world.calls.contains("minimize 11"))
    }

    @Test func anUnchangedDeskCostsNoAccessibilityReads() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        let reads = h.world.infoReads
        for _ in 0..<5 { h.pass() }
        #expect(h.world.infoReads == reads)
    }

    // MARK: Park

    @Test func parkMinimizesConfirmsAndKeepsAPrivateRecord() throws {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        #expect(isParked(h.place("local_alpha")))
        #expect(h.status("local_alpha")?.chip(now: h.clock.now) == "in the pit")
        #expect(h.status("local_alpha")?.chip(now: h.clock.now.addingTimeInterval(12 * 60)) == "in the pit 12 min")
        #expect(h.world.calls == ["minimize 11"])
        #expect(h.parker.parkedSessionIDs == ["local_alpha"])
        let records = h.store.load()
        #expect(records.count == 1)
        #expect(records.first?.windowNumber == 11 && records.first?.pid == Self.a && records.first?.profile == "A")
        #expect(records.first?.frame == Self.left)
        let mode = try FileManager.default.attributesOfItem(atPath: h.store.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let text = try String(contentsOf: h.store.url, encoding: .utf8)
        #expect(!text.contains("Alpha") && !text.contains("title"))
    }

    @Test func parkRetriesOnceThenSaysClaudeDidNotAnswer() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.world.minimizeIgnoredCalls = 2
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run(for: 1)
        #expect(h.status("local_alpha")?.busy == .parking)
        #expect(h.status("local_alpha")?.click == CodeWindowClick.none)
        h.queue.run()
        #expect(h.world.calls.filter { $0 == "minimize 11" }.count == 2)
        #expect(h.place("local_alpha") == .onDesk)
        #expect(h.status("local_alpha")?.problem == "couldn't pit (Claude didn't answer)")
        #expect(h.status("local_alpha")?.chip(now: Date()) == "couldn't pit (Claude didn't answer)")
        #expect(h.store.load().isEmpty)
        #expect(h.parker.parkedSessionIDs.isEmpty)
    }

    @Test func parkSucceedsOnTheRetry() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.world.minimizeIgnoredCalls = 1
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        #expect(isParked(h.place("local_alpha")))
        #expect(h.status("local_alpha")?.problem == nil)
    }

    @Test func parkOfAWindowThatIsGoneFails() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.world.windows[11] = nil
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        #expect(!h.world.calls.contains("minimize 11"))
        #expect(h.store.load().isEmpty)
    }

    @Test func aParkThatClaudeTurnedIntoAHideIsSaid() {
        // A case to watch for: AXMinimized=true can make Claude hide the window instead; AX cannot bring it back.
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.world.hideInsteadOfMinimize = true
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        #expect(h.place("local_alpha") == .hiddenByClaude)
        #expect(h.status("local_alpha")?.chip(now: Date()) == "hidden by Claude")
        #expect(h.status("local_alpha")?.tooltip?.contains("Window menu") == true)
    }

    // MARK: Restore

    @Test func restoreUnminimizesClampsOutsideTheStripRaisesAndActivates() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        // A pop-out partly under the strip (4096-5120) and below the Dock line.
        let under = CGRect(x: 3800, y: 900, width: 900, height: 700)
        h.world.add(WindowsTestWindow(pid: Self.a, number: 21, title: "Wide", frame: under))
        h.parker.start()
        h.update([windowSession("local_wide", title: "Wide")])
        h.parker.perform(.park, sessionID: "local_wide")
        h.queue.run()
        h.world.calls = []
        h.parker.perform(.restore, sessionID: "local_wide")
        h.queue.run()
        // Visible frame y 30...1342; strip from x 4096: the window ends at the strip and above the Dock.
        #expect(h.world.calls == ["unminimize 21", "frame 21 3196,642,900,700", "raise 21", "frontmost 501", "main 21"])
        #expect(h.place("local_wide") == .onDesk)
        #expect(h.store.load().isEmpty)
    }

    @Test func activationFallsBackToNSRunningApplication() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        h.world.frontmostWorks = false
        h.parker.perform(.restore, sessionID: "local_alpha")
        h.queue.run()
        #expect(h.workspace.activations == [Self.a])
    }

    @Test func restoreRetriesOnceThenSaysSo() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        h.world.restoreIgnoredCalls = 2
        h.parker.perform(.restore, sessionID: "local_alpha")
        h.queue.run()
        #expect(h.world.calls.filter { $0 == "unminimize 11" }.count == 2)
        #expect(h.status("local_alpha")?.problem == "couldn't restore (Claude didn't answer)")
        // Still parked: the record goes only after a confirmed restore.
        #expect(isParked(h.place("local_alpha")))
        #expect(h.store.load().count == 1)
    }

    @Test func aWindowTheUserRestoredThemselvesDropsItsRecordAndIsNeverMoved() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        // The user brings it back from the Dock, somewhere else.
        h.world.windows[11]?.minimized = false
        h.world.windows[11]?.onScreen = true
        h.world.windows[11]?.frame = CGRect(x: 2000, y: 300, width: 900, height: 700)
        h.world.calls = []
        // A restore that comes before the next pass still only raises and activates.
        h.parker.perform(.restore, sessionID: "local_alpha")
        h.queue.run()
        #expect(h.world.calls == ["raise 11", "frontmost 501"])
        #expect(h.place("local_alpha") == .onDesk)
        #expect(h.store.load().isEmpty)
    }

    @Test func thePassDropsTheRecordOfAWindowBackOnScreen() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        h.world.windows[11]?.minimized = false
        h.world.windows[11]?.onScreen = true
        h.pass()
        #expect(h.place("local_alpha") == .onDesk)
        #expect(h.parker.parkedSessionIDs.isEmpty)
        #expect(h.store.load().isEmpty)
    }

    // MARK: Other Spaces, hidden, closed

    @Test func aWindowOnAnotherSpaceActivatesItsCopyAndIsSkippedByParkAllDone() async {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.world.windows[11]?.onScreen = false
        h.world.windows[11]?.visibleToAX = false
        h.pass()
        #expect(h.place("local_alpha") == .otherSpace)
        #expect(h.status("local_alpha")?.chip(now: Date()) == "on another Space")
        #expect(h.status("local_alpha")?.click == .activate)
        #expect(h.status("local_alpha")?.tooltip?.contains("switches to that Space") == true)
        h.parker.perform(.activate, sessionID: "local_alpha")
        h.queue.run()
        #expect(h.world.calls.last == "frontmost 501")
        let result = await run(h) { await h.parker.parkAllDone(["local_alpha", "local_beta"]) }
        #expect(result == CodeParkAllResult(parked: 1, skippedOtherSpace: 1, failed: 0))
        #expect(result.note == "1 into the pit · 1 on another Space, not pitted")
        #expect(!h.world.calls.contains("minimize 11"))
    }

    @Test func claudeHiddenSaysSoAndActivates() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.workspace.hidden = [Self.a]
        for number in [10, 11, 12] as [CGWindowID] { h.world.windows[number]?.onScreen = false }
        h.pass()
        #expect(h.place("local_alpha") == .hidden)
        #expect(h.status("local_alpha")?.click == .activate)
    }

    @Test func aWindowClosedWhileParkedOpensTheSessionInItsCopysMainWindow() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        h.world.windows[11] = nil
        h.pass()
        #expect(h.place("local_alpha") == .closed)
        #expect(h.status("local_alpha")?.chip(now: Date()) == "closed · opens in main window")
        #expect(h.status("local_alpha")?.click == .openInMainWindow)
        #expect(h.parker.parkedSessionIDs == ["local_alpha"])
        #expect(h.store.load().isEmpty)
        h.parker.perform(.openInMainWindow, sessionID: "local_alpha")
        h.queue.run()
        #expect(h.workspace.opened.map(\.url.absoluteString) == ["claude://code/continue?session=local_alpha"])
        // That copy's own app (the launcher copy), never /Applications/Claude.app.
        #expect(h.workspace.opened.map(\.app) == [WindowsHarness.appA])
        #expect(h.parker.parkedSessionIDs.isEmpty)
    }

    @Test func aBadSessionIDIsNeverSent() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        h.world.add(WindowsTestWindow(pid: Self.a, number: 11, title: "Alpha", frame: Self.left))
        h.parker.start()
        h.update([windowSession("local_bad id;rm", title: "Alpha")])
        h.parker.perform(.park, sessionID: "local_bad id;rm")
        h.queue.run()
        h.world.windows[11] = nil
        h.pass()
        h.parker.perform(.openInMainWindow, sessionID: "local_bad id;rm")
        h.queue.run()
        #expect(h.workspace.opened.isEmpty)
    }

    @Test func aPopOutClaudeClosedButKeptAliveIsNotOnAnotherSpace() {
        // Seen on a real Mac: closing a pop-out may leave its window alive and hidden; Claude's file then omits it.
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.world.windows[12]?.onScreen = false
        h.world.windows[12]?.visibleToAX = false
        h.update([windowSession("local_alpha", title: "Alpha", index: 1), windowSession("local_beta", title: "Beta", index: 2, popout: nil)])
        #expect(h.place("local_beta") == .notMatched)
        // The same while parked: the monitor says "window closed".
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        h.world.windows[11]?.minimized = false
        h.world.windows[11]?.visibleToAX = false
        h.update([windowSession("local_alpha", title: "Alpha", index: 1, popout: nil)])
        #expect(h.place("local_alpha") == .closed)
    }

    // MARK: Restarts and relaunches

    @Test func afterARestartParkedWindowsAreFoundAgainByNumber() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cm-restart-\(UUID().uuidString)")
        let first = WindowsHarness(folder: folder); defer { first.cleanUp() }
        // Two pop-outs with the same title, told apart by the file's bounds.
        first.world.add(WindowsTestWindow(pid: Self.a, number: 11, title: "Twin", frame: Self.left))
        first.world.add(WindowsTestWindow(pid: Self.a, number: 12, title: "Twin", frame: Self.middle))
        first.parker.start()
        let sessions = [windowSession("local_one", title: "Twin", index: 1, popout: Self.left),
                        windowSession("local_two", title: "Twin", index: 2, popout: Self.middle)]
        first.update(sessions)
        first.parker.perform(.park, sessionID: "local_one")
        first.parker.perform(.park, sessionID: "local_two")
        first.queue.run()
        #expect(first.store.load().count == 2)

        // The app restarts; Claude kept running (same pid, same windows, still minimized).
        let second = WindowsHarness(folder: folder)
        second.world.windows = first.world.windows
        second.parker.start()
        second.update([windowSession("local_one", title: "Twin", index: 1, popout: nil),
                       windowSession("local_two", title: "Twin", index: 2, popout: nil)])
        #expect(isParked(second.place("local_one")) && isParked(second.place("local_two")))
        second.parker.perform(.restore, sessionID: "local_two")
        second.queue.run()
        #expect(second.world.calls.first == "unminimize 12")
    }

    @Test func afterARestartWithoutWindowNumbersTitlesAndSavedFramesFindThem() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cm-restart-\(UUID().uuidString)")
        let first = WindowsHarness(folder: folder); defer { first.cleanUp() }
        first.world.add(WindowsTestWindow(pid: Self.a, number: 11, title: "Twin", frame: Self.left))
        first.world.add(WindowsTestWindow(pid: Self.a, number: 12, title: "Twin", frame: Self.middle))
        first.parker.start()
        first.update([windowSession("local_one", title: "Twin", index: 1, popout: Self.left),
                      windowSession("local_two", title: "Twin", index: 2, popout: Self.middle)])
        first.parker.perform(.park, sessionID: "local_one")
        first.parker.perform(.park, sessionID: "local_two")
        first.queue.run()

        // No `_AXUIElementGetWindow`, and minimized windows left the server list (both unconfirmed on a real Mac).
        let second = WindowsHarness(folder: folder)
        second.world.windows = first.world.windows
        second.world.getWindowWorks = false
        for number in [11, 12] as [CGWindowID] { second.world.windows[number]?.inServerList = false }
        second.parker.start()
        second.update([windowSession("local_one", title: "Twin", index: 1, popout: nil),
                       windowSession("local_two", title: "Twin", index: 2, popout: nil)])
        #expect(isParked(second.place("local_one")) && isParked(second.place("local_two")))
        second.parker.perform(.restore, sessionID: "local_one")
        second.queue.run()
        #expect(second.world.calls.first == "unminimize 11")
    }

    @Test func untilItIsFoundAgainAParkedMonitorSaysNotMatched() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cm-restart-\(UUID().uuidString)")
        let first = WindowsHarness(folder: folder); defer { first.cleanUp() }
        first.world.add(WindowsTestWindow(pid: Self.a, number: 11, title: "Alpha", frame: Self.left))
        first.parker.start()
        first.update([windowSession("local_alpha", title: "Alpha")])
        first.parker.perform(.park, sessionID: "local_alpha")
        first.queue.run()

        let second = WindowsHarness(folder: folder)
        second.world.windows = first.world.windows
        second.world.failInfo = [11]          // Claude does not answer yet
        second.parker.start()
        second.queue.run()
        #expect(second.parker.parkedSessionIDs == ["local_alpha"])
        second.update([windowSession("local_alpha", title: "Alpha", popout: nil)])
        #expect(second.place("local_alpha") == .parkedNotMatched)
        #expect(second.status("local_alpha")?.chip(now: Date()) == "in the pit · window not matched")
        #expect(second.status("local_alpha")?.click == CodeWindowClick.none)
        // Claude answers: found again (the next attempt, at most 10 s later).
        second.world.failInfo = []
        second.queue.advance(by: 11)
        second.pass()
        #expect(isParked(second.place("local_alpha")))
    }

    @Test func aLateProcessListNeverDropsParkedRecords() {
        // The app starts while Claude runs, and the data side has not found Claude yet.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cm-restart-\(UUID().uuidString)")
        let first = WindowsHarness(folder: folder); defer { first.cleanUp() }
        first.world.add(WindowsTestWindow(pid: Self.a, number: 11, title: "Alpha", frame: Self.left))
        first.parker.start()
        first.update([windowSession("local_alpha", title: "Alpha")])
        first.parker.perform(.park, sessionID: "local_alpha")
        first.queue.run()

        let second = WindowsHarness(folder: folder)
        second.world.windows = first.world.windows
        second.processes.list = []
        second.parker.start()
        second.queue.run()
        #expect(second.parker.parkedSessionIDs == ["local_alpha"])
        second.update([windowSession("local_alpha", title: "Alpha", popout: nil)])
        #expect(second.store.load().count == 1)
        #expect(second.place("local_alpha") == .profileNotRunning(letter: "A"))
        second.processes.list = [ClaudeProcessInfo(pid: Self.a, profile: .a, bundlePath: WindowsHarness.appPathA)]
        second.pass()
        #expect(isParked(second.place("local_alpha")))
    }

    @Test func aClaudeRelaunchDropsTheRecordsAndShowsTheNewWindows() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.parker.perform(.park, sessionID: "local_alpha")
        h.queue.run()
        #expect(h.store.load().count == 1)
        // Claude relaunched: a new pid recreates the pop-outs from its own file, un-minimized.
        h.processes.list = [ClaudeProcessInfo(pid: 502, profile: .a, bundlePath: WindowsHarness.appPathA)]
        h.workspace.ended = [Self.a]
        h.world.windows = [:]
        h.world.add(WindowsTestWindow(pid: 502, number: 91, title: "Alpha", frame: Self.left))
        h.pass()
        #expect(h.store.load().isEmpty)
        #expect(h.parker.parkedSessionIDs.isEmpty)
        #expect(h.place("local_alpha") == .onDesk)
    }

    // MARK: ⌃⌥P

    @Test func theHotkeyParksTheFrontPopOut() async {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.workspace.frontmost = Self.a
        h.world.focused[Self.a] = 12
        let result = await run(h) { await h.parker.parkFrontmostPopout() }
        #expect(result == .parked)
        #expect(result.hudLine == "In the pit")
        #expect(isParked(h.place("local_beta")))
        let again = await run(h) { await h.parker.parkFrontmostPopout() }
        #expect(again == .alreadyParked)
    }

    @Test func theHotkeyRefusesTheMainWindowAndOtherApps() async {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.workspace.frontmost = Self.a
        h.world.focused[Self.a] = 10   // the main window "Claude"
        let main = await run(h) { await h.parker.parkFrontmostPopout() }
        #expect(main == .notAPopout)
        #expect(main.hudLine == "The front window isn't a Code pop-out")
        h.workspace.frontmost = 999
        let other = await run(h) { await h.parker.parkFrontmostPopout() }
        #expect(other == .notAPopout)
        h.workspace.frontmost = Self.a
        h.world.trusted = false
        let untrusted = await run(h) { await h.parker.parkFrontmostPopout() }
        #expect(untrusted == .noAccessibility)
        #expect(!h.world.calls.contains { $0.hasPrefix("minimize") })
    }

    @Test func theHotkeyJoinsAFrontPopOutThatAppearedJustNow() async {
        let h = WindowsHarness(); defer { h.cleanUp() }
        desk(h)
        h.world.add(WindowsTestWindow(pid: Self.a, number: 13, title: "Gamma", frame: CGRect(x: 2400, y: 120, width: 900, height: 700)))
        h.parker.update(sessions: [windowSession("local_alpha", title: "Alpha", index: 1),
                                   windowSession("local_beta", title: "Beta", index: 2),
                                   windowSession("local_gamma", title: "Gamma", index: 3)], processes: h.processes.list)
        h.workspace.frontmost = Self.a
        h.world.focused[Self.a] = 13
        let result = await run(h) { await h.parker.parkFrontmostPopout() }
        #expect(result == .parked)
        #expect(h.world.calls.contains("minimize 13"))
    }

    // MARK: Cost

    @Test func thePassRunsOnlyWhileTheStripIsVisible() {
        let h = WindowsHarness(); defer { h.cleanUp() }
        h.parker.start()
        h.queue.run()
        #expect(!h.ticker.isRunning)
        h.parker.setActive(true)
        #expect(h.ticker.isRunning && h.ticker.starts == 1)
        h.parker.setActive(true)
        #expect(h.ticker.starts == 1)
        h.parker.setActive(false)
        #expect(!h.ticker.isRunning && h.ticker.stops == 1)
    }
}

/// Holds an async call's result for `ParkerTests.run`.
@MainActor
final class WindowsResultBox<T> {
    var value: T?
}
