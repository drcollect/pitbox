import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// The console's drawer over fakes: Pitbox's console (no plain shells), a fake command launcher, a manual clock, a block
/// whose answers the test scripts, all in an off-screen window that is never shown.
@MainActor
final class DrawerHarness {
    let dir = TempDir()
    let clock = ManualClock()
    let launcher = FakeLauncher()
    let commands = FakeCommandLauncher()
    let home = CommandTempFolder("drawer")
    let console: ConsoleHost
    let drawer: ConsoleDrawer
    let window: OffscreenWindow
    let block: NSView
    /// What `blockCanShow` answers (false: hidden by the user or a dock host).
    var canShow = true
    /// The block is unfolded.
    var unfolded = true
    /// What `ensureBlockShown` answers (nil: never).
    var unfoldAnswer: Bool? = true
    private(set) var unfoldRequests = 0
    private(set) var heights: [CGFloat] = []
    private(set) var keyboardRequests: [Bool] = []
    private(set) var events: [CommandOfferEvent] = []

    init(settingsJSON: String? = nil) {
        var environment = commandTestEnvironment()
        environment.home = home.path
        var requests: ((Bool) -> Void)?
        console = ConsoleHost(settings: testSettings(settingsJSON), keyboardRequester: { requests?($0) }, paths: dir.paths,
                              launcher: launcher.launch, clock: clock, environment: environment, commandLauncher: commands.launch,
                              commandPathProblem: { nil }, mode: .pitbox)
        var canShowProbe: (() -> Bool)?
        var unfold: ((@escaping (Bool) -> Void) -> Void)?
        drawer = ConsoleDrawer(console: console, blockCanShow: { canShowProbe?() ?? false },
                               ensureBlockShown: { done in unfold?(done) })
        window = OffscreenWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 900), styleMask: [.borderless],
                                 backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.pretendVisible = true
        block = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 900))
        window.contentView = block
        block.addSubview(drawer.view)
        requests = { [unowned self] in keyboardRequests.append($0) }
        canShowProbe = { [unowned self] in canShow }
        unfold = { [unowned self] done in
            unfoldRequests += 1
            guard let answer = unfoldAnswer else { return }
            if answer { unfolded = true }
            done(answer)
        }
        drawer.onHeightChanged = { [unowned self] height in
            heights.append(height)
            placeDrawer()
        }
        placeDrawer()
        (console.consoleView())?.strip.pointerLocation = { nil }
    }

    /// What the block's panel does with a new height: the drawer at the bottom, full width, that tall.
    func placeDrawer() {
        drawer.view.frame = CGRect(x: 0, y: 0, width: block.bounds.width, height: drawer.height)
        drawer.view.layoutSubtreeIfNeeded()
    }

    var manager: TerminalSessionManager? { console.manager }
    var drawerView: ConsoleDrawerView { drawer.drawerView }

    func request(_ text: String, role: CommandTabRole = .run) throws -> CommandTabRequest {
        let kind: CommandExecutionDescriptor.Kind = role == .typeIntoTerminal ? .typeIntoTerminal : .run
        let origin = CommandTabOrigin(headline: "private client headline", profileName: "A Work", machineLabel: "this Mac",
                                      folderShort: "~", replyTime: Date(timeIntervalSince1970: 1_000_000), offer: nil)
        var request = CommandTabRequest(role: role, descriptor: testDescriptor(text, kind: kind, folder: home.path),
                                        folder: try FolderBinding.bind(home.path).get(), origin: origin, runID: UUID(),
                                        typedText: nil)
        request.runAllowed = { true }   // as the sheet's policy reading would say with "commands": "run"
        return request
    }

    /// A Run as the sheet's click hands it over.
    func run(_ text: String, role: CommandTabRole = .run) throws {
        console.startCommandTab(try request(text, role: role)) { [unowned self] event in events.append(event) }
    }

    /// A Run all the way to its started tab (the 0.35 s wait passed).
    func runStarted(_ text: String) throws {
        try run(text)
        clock.advance(by: ConsoleDrawer.layoutWait + 0.01)
    }
}

@MainActor
struct ConsoleDrawerTests {
    @Test func aFreshConsoleIsEmptyAndTheDrawerHidden() {
        let h = DrawerHarness()
        #expect(h.console.sessionCount == 0 && h.launcher.processes.isEmpty, "no shell at start")
        #expect(h.drawer.state == .hidden && h.drawer.height == 0)
        #expect(h.drawer.view.frame.height == 0)
        #expect(h.heights.isEmpty, "nothing to report yet")
        #expect(h.console.commandHooks.consoleVisible(), "the drawer is the console's hooks")
    }

    @Test func runUnfoldsTheBlockOpensAndHoldsTheDrawerAndStartsAfterItsLayout() throws {
        let h = DrawerHarness()
        h.unfolded = false
        try h.run("echo hi")
        #expect(h.unfoldRequests == 1 && h.unfolded, "Run unfolds the block")
        #expect(h.drawer.state == .open && h.drawer.isHeld)
        #expect(h.heights == [ConsoleDrawer.heldHeight])
        #expect(h.drawer.view.frame.height == 312)
        h.clock.advance(by: 0.34)
        #expect(h.commands.specs.isEmpty, "nothing starts before the drawer's layout plus 0.35 s")
        h.clock.advance(by: 0.02)
        #expect(h.commands.specs.count == 1)
        let session = try #require(h.manager?.sessions.first)
        #expect(session.view.frame.height == ConsoleDrawer.heldHeight - ConsoleDrawer.barHeight - ConsoleView.bottomPadding
                - ConsoleView.topGap - TabStripView.height - CommandTabBar.height, "the shell starts at the held size")
        #expect(h.commands.sizes.first?.rows == session.view.terminal.rows)
        #expect(h.events.first.map { if case .started = $0 { return true } else { return false } } == true)
    }

    @Test func theDrawerLaysOutItsBarAndTheConsoleBelowIt() throws {
        let h = DrawerHarness()
        try h.runStarted("echo hi")
        let view = h.drawerView
        #expect(view.bar.frame == CGRect(x: 0, y: 0, width: 640, height: ConsoleDrawer.barHeight))
        #expect(view.content.frame == CGRect(x: 0, y: ConsoleDrawer.barHeight, width: 640,
                                             height: ConsoleDrawer.heldHeight - ConsoleDrawer.barHeight))
        #expect(!view.content.isHidden && !view.bar.isHidden && view.bar.isOpen)
    }

    @Test func theHoldLastsWhileACommandRunsAndTwentyFiveSecondsAfterThenFoldsToTheBar() throws {
        let h = DrawerHarness()
        try h.runStarted("sleep 1")
        h.clock.advance(by: 120)
        #expect(h.drawer.state == .open && h.drawer.isHeld, "held while it runs")
        h.commands.processes[0].end(.exited(0))
        h.clock.advance(by: 24.9)
        #expect(h.drawer.state == .open)
        h.clock.advance(by: 0.2)
        #expect(h.drawer.state == .folded && !h.drawer.isHeld)
        #expect(h.drawer.height == ConsoleDrawer.barHeight && h.heights.last == 28)
        #expect(h.drawerView.content.isHidden && !h.drawerView.bar.isHidden)
        #expect(h.manager?.isVisible == false, "a folded console does no polling")
    }

    @Test func oneHoldForAllRunsUntilTheLastOneEnds() throws {
        let h = DrawerHarness()
        try h.runStarted("sleep 1")
        try h.runStarted("sleep 2")
        h.commands.processes[0].end(.exited(0))
        h.clock.advance(by: 30)
        #expect(h.drawer.state == .open, "the second still runs")
        h.commands.processes[1].end(.exited(1))
        h.clock.advance(by: 25.1)
        #expect(h.drawer.state == .folded)
    }

    @Test func aClickOnTheBarOpensAndFoldsAndTheUsersFoldEndsTheHold() throws {
        let h = DrawerHarness()
        try h.runStarted("sleep 1")
        h.drawer.barClicked()
        #expect(h.drawer.state == .folded && !h.drawer.isHeld, "the user's own fold ends the hold")
        #expect(h.manager?.runningCommandCount == 1, "folding stops nothing")
        h.drawer.barClicked()
        #expect(h.drawer.state == .open && !h.drawer.isHeld)
        h.commands.processes[0].end(.exited(0))
        h.clock.advance(by: 25.1)
        #expect(h.drawer.state == .folded, "the linger's release folds a drawer the user opened during the hold")
        h.drawer.barClicked()
        #expect(h.drawer.state == .open)
        h.clock.advance(by: 600)
        #expect(h.drawer.state == .open, "opened by the user, it stays open")
        h.drawer.barClicked()
        #expect(h.drawer.state == .folded)
        #expect(h.heights == [312, 28, 312, 28, 312, 28])
    }

    @Test func aRealClickOnTheBarActsOnMouseUpOverIt() throws {
        let h = DrawerHarness()
        try h.runStarted("echo hi")
        h.commands.processes[0].end(.exited(0))
        h.clock.advance(by: 25.1)
        let bar = h.drawerView.bar
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: bar.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: 1))
        }
        bar.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 14)))
        bar.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100, y: 400)))
        #expect(h.drawer.state == .folded, "a press dragged off the bar is cancelled")
        bar.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 14)))
        bar.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100, y: 14)))
        #expect(h.drawer.state == .open)
        #expect(bar.accessibilityPerformPress() && h.drawer.state == .folded, "VoiceOver's press folds it")
        #expect(bar.acceptsFirstMouse(for: nil) && !bar.acceptsFirstResponder, "it never takes the keyboard")
    }

    @Test func closingTheLastTabHidesTheDrawer() throws {
        let h = DrawerHarness()
        try h.runStarted("echo hi")
        h.commands.processes[0].end(.exited(0))
        let session = try #require(h.manager?.sessions.first)
        h.manager?.closeNow(session.id)
        #expect(h.drawer.state == .hidden && h.drawer.height == 0 && !h.drawer.isHeld)
        #expect(h.heights.last == 0)
        h.clock.advance(by: 30)
        #expect(h.drawer.state == .hidden, "the late release changes nothing")
    }

    @Test func theBarShowsCountsNeverATitle() throws {
        let h = DrawerHarness()
        try h.runStarted("sleep 1")
        let bar = h.drawerView.bar
        #expect(bar.summary == "1 tab · 1 running")
        #expect(bar.accessibilityValue() as? String == "1 tab, 1 running")
        #expect(bar.accessibilityLabel() == "Console" && bar.isAccessibilityExpanded())
        try h.runStarted("echo two")
        h.commands.processes[0].end(.exited(0))
        #expect(bar.summary == "2 tabs · 1 running")
        h.commands.processes[1].end(.exited(0))
        #expect(bar.summary == "2 tabs")
        #expect(!(bar.accessibilityValue() as? String ?? "").contains("headline"))
    }

    @Test func aHiddenBlockStartsNothingAndIsNotUnfolded() throws {
        let h = DrawerHarness()
        h.canShow = false
        #expect(h.console.commandBlocker(role: .run) == ConsoleHost.consoleHiddenReason)
        #expect(h.console.commandBlocker(role: .typeIntoTerminal) == ConsoleHost.consoleHiddenReason)
        try h.run("echo hi")
        h.clock.advance(by: 5)
        #expect(h.unfoldRequests == 0 && h.commands.specs.isEmpty)
        #expect(h.events == [.refused(reason: ConsoleHost.consoleHiddenReason)])
        #expect(h.drawer.state == .hidden)
    }

    @Test func aBlockThatCannotUnfoldStartsNothing() throws {
        let h = DrawerHarness()
        h.unfoldAnswer = false
        try h.run("echo hi")
        h.clock.advance(by: 5)
        #expect(h.commands.specs.isEmpty)
        #expect(h.events == [.refused(reason: "the console couldn't be shown")])
        #expect(h.drawer.state == .hidden && !h.drawer.isHeld)
    }

    @Test func aBlockThatNeverAnswersStartsNothingAfterTwoSeconds() throws {
        let h = DrawerHarness()
        h.unfoldAnswer = nil
        try h.run("echo hi")
        h.clock.advance(by: 1.9)
        #expect(h.events.isEmpty)
        h.clock.advance(by: 0.2)
        #expect(h.events == [.refused(reason: "the console couldn't be shown")])
        #expect(h.commands.specs.isEmpty && h.drawer.state == .hidden)
    }

    @Test func hidingTheBlockOrFoldingTheDrawerDuringTheWaitStartsNothing() throws {
        let hidden = DrawerHarness()
        try hidden.run("echo hi")
        hidden.clock.advance(by: 0.2)
        hidden.drawer.blockHidden()
        hidden.clock.advance(by: 1)
        #expect(hidden.commands.specs.isEmpty)
        #expect(hidden.events == [.refused(reason: "the console couldn't be shown")])
        #expect(hidden.drawer.state == .hidden)

        let folded = DrawerHarness()
        try folded.run("echo hi")
        folded.clock.advance(by: 0.2)
        folded.drawer.barClicked()
        folded.clock.advance(by: 1)
        #expect(folded.commands.specs.isEmpty)
        #expect(folded.events == [.refused(reason: "the console couldn't be shown")])
    }

    @Test func blockHiddenEndsTheHoldAndRunningCommandsGoOn() throws {
        let h = DrawerHarness()
        try h.runStarted("sleep 9")
        h.drawer.blockHidden()
        #expect(h.drawer.state == .folded && !h.drawer.isHeld)
        #expect(h.manager?.runningCommandCount == 1 && h.commands.processes[0].terminates == 0)
    }

    @Test func theLimitsStayThreeRunningAndTenTabs() throws {
        let h = DrawerHarness()
        for index in 0..<3 { try h.runStarted("sleep \(index)") }
        #expect(h.console.commandBlocker(role: .run) == "3 commands are running. Wait for one to finish, or stop one.")
        try h.run("sleep 9")
        #expect(h.events.last == .refused(reason: "3 commands are running. Wait for one to finish, or stop one."))
        #expect(h.manager?.sessions.count == 3, "the fourth Run opened nothing")
        for _ in 0..<7 {
            h.console.startCommandTab(try h.request("echo typed", role: .typeIntoTerminal)) { _ in }
            h.clock.advance(by: ConsoleDrawer.layoutWait + 0.01)
        }
        #expect(h.manager?.sessions.count == 10)
        #expect(h.console.commandBlocker(role: .typeIntoTerminal) == "The console has 10 tabs. Close one.")
        #expect(h.commands.specs.count == 10)
    }

    @Test func foldingGivesTheKeyboardBack() throws {
        let h = DrawerHarness()
        try h.runStarted("read -r x")
        h.window.pretendKey = true
        let consoleView = try #require(h.console.consoleView())
        consoleView.selectedCommandBar?.onClickToType?()   // the user's click: the only way a command tab gets the keyboard
        let session = try #require(h.manager?.sessions.first)
        #expect(h.window.firstResponder === session.view)
        #expect(h.keyboardRequests == [true])
        h.drawer.barClicked()
        #expect(h.window.firstResponder !== session.view)
        #expect(h.keyboardRequests == [true, false])
    }

    @Test func showOutputOpensTheDrawerAndFoldsItAfterTheLinger() throws {
        let h = DrawerHarness()
        try h.runStarted("echo hi")
        h.commands.processes[0].end(.exited(0))
        h.clock.advance(by: 25.1)
        #expect(h.drawer.state == .folded)
        let runID = try #require(h.manager?.sessions.first?.command?.runID)
        h.unfolded = false
        #expect(h.console.selectCommandTab(runID: runID))
        #expect(h.unfoldRequests == 2 && h.drawer.state == .open)
        h.clock.advance(by: 25.5)
        #expect(h.drawer.state == .folded)
    }

    @Test func aFoldedDrawerKeepsTheConsolesSize() throws {
        let h = DrawerHarness()
        try h.runStarted("echo hi")
        let session = try #require(h.manager?.sessions.first)
        let size = session.view.frame.size
        h.drawer.barClicked()
        h.drawer.barClicked()
        h.drawer.barClicked()
        #expect(session.view.frame.size == size, "folding never reflows the terminal")
        #expect(h.drawerView.content.frame.height == ConsoleDrawer.heldHeight - ConsoleDrawer.barHeight)
        // A panel animating the drawer's height (a frame between the bar and the held size): clipped, not reflowed.
        h.drawer.view.frame = CGRect(x: 0, y: 0, width: 640, height: 150)
        h.drawer.view.layoutSubtreeIfNeeded()
        #expect(h.drawerView.content.frame.height == ConsoleDrawer.heldHeight - ConsoleDrawer.barHeight)
        #expect(session.view.frame.size == size)
    }
}
