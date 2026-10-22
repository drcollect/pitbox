import AppKit
import Foundation
import Testing
@testable import PitboxConsole

@MainActor
struct HostingTests {
    /// The drawer hosts the console like this: a container with the view as its only content, autoresized to it.
    @Test func theConsoleAdaptsWhenItsContainerIsResized() throws {
        let h = ConsoleHarness(size: CGSize(width: 618, height: 636))
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 618, height: 636))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        h.window.contentView = NSView(frame: container.frame)
        h.window.contentView?.addSubview(container)
        h.view.frame = container.bounds
        h.view.autoresizingMask = [.width, .height]
        container.addSubview(h.view)
        h.view.layoutSubtreeIfNeeded()
        let before = try #require(h.selectedView).terminal.cols
        let resizesBefore = h.processes[0].resizes.count

        container.setFrameSize(CGSize(width: 1248, height: 474))   // the console became 4 columns wide and 6 rows (474 pt) tall
        h.view.layoutSubtreeIfNeeded()
        let view = try #require(h.selectedView)
        #expect(h.view.frame.size == CGSize(width: 1248, height: 474))
        #expect(view.terminal.cols > before * 3 / 2 && view.terminal.rows < 30, "\(view.terminal.cols)x\(view.terminal.rows)")
        #expect(h.processes[0].resizes.count > resizesBefore, "the program was told (SIGWINCH)")
        #expect(h.processes[0].resizes.last?.cols == view.terminal.cols)
        #expect(h.view.strip.frame.width == 1248, "the strip follows")
    }

    @Test func cmdFOpensSwiftTermsFindBar() throws {
        let h = ConsoleHarness()
        let view = try #require(h.selectedView)
        h.window.makeFirstResponder(view)
        let before = view.subviews.count
        #expect(view.performKeyEquivalent(with: h.keyEvent("f", keyCode: 3, modifiers: .command)))
        #expect(view.subviews.count > before || view.subviews.contains { String(describing: type(of: $0)).contains("FindBar") })
    }

    @Test(.timeLimit(.minutes(1))) func closedSessionsAreReleased() async throws {
        let h = ManagerHarness()
        weak var weakView: ConsoleTerminalView?
        weak var weakSession: TerminalSession?
        autoreleasepool {
            let session = h.manager.newSession()!
            weakView = session.view
            weakSession = session
            h.manager.closeNow(session.id)
            h.processes.last?.end(.signaled(1))
        }
        #expect(await waitUntil(5) { weakSession == nil && weakView == nil }, "a closed and ended session must not stay alive")
    }

    @Test(.timeLimit(.minutes(1))) func closedTabsOfALiveConsoleAreReleased() async throws {
        let h = ConsoleHarness()
        weak var weakView: ConsoleTerminalView?
        weak var weakSession: TerminalSession?
        autoreleasepool {
            let session = h.manager.newSession()!
            weakView = session.view
            weakSession = session
            h.manager.closeNow(session.id)
            h.processes.last?.end(.signaled(1))
        }
        #expect(await waitUntil(5) { weakSession == nil && weakView == nil }, "the console's wiring must not keep a closed tab alive")
        #expect(h.manager.sessions.count == 1)
    }

    @Test func onlyTheSelectedTerminalIsInTheWindowSoBackgroundTabsGetNoBroadcastEvents() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession(); _ = h.manager.newSession()
        for (index, session) in h.manager.sessions.enumerated() {
            #expect((session.view.window != nil) == (index == h.manager.selectedIndex), "tab \(index)")
        }
        h.manager.select(index: 0)
        #expect(h.manager.sessions[0].view.window != nil && h.manager.sessions[2].view.window == nil)
        // A detached tab keeps working: output still lands in its emulator.
        h.processes[2].emit("still running\r\n")
        #expect(screenText(h.manager.sessions[2].view).contains("still running"))
        // And it comes back with its contents.
        h.manager.select(index: 2)
        #expect(h.manager.sessions[2].view.window != nil && screenText(h.manager.sessions[2].view).contains("still running"))
    }

    @Test(.timeLimit(.minutes(1))) func aReplacedConsoleViewIsReleased() async throws {
        let h = ConsoleHarness()
        weak var oldView: ConsoleView?
        autoreleasepool {
            let dir = h.dir
            _ = dir
            let temp = h.console.makeConsoleView()
            oldView = temp
            _ = h.console.makeConsoleView()   // replaces it as the observer of the manager
        }
        #expect(await waitUntil(5) { oldView == nil }, "the manager holds no strong reference to a console view")
    }

    @Test func explicitHyperlinksOpenTheirTargetNotTheirLabel() throws {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.view.feed(text: "click \u{1b}]8;;https://real.example.org/page\u{07}https://fake.example.com\u{1b}]8;;\u{07} here")
        let p = f.point(col: 12, row: 0)
        f.view.mouseDown(with: f.mouse(.leftMouseDown, at: p, modifiers: .command))
        f.view.mouseUp(with: f.mouse(.leftMouseUp, at: p, modifiers: .command))
        #expect(f.delegate.links == ["https://real.example.org/page"], "\(f.delegate.links)")
        // The session then passes it through the policy with what the link showed: it shows another address, so
        // nothing opens. Shown as itself, it would.
        let link = f.delegate.links[0]
        #expect(f.view.shownTexts(ofLink: link) == ["https://fake.example.com"])
        #expect(LinkPolicy.action(for: link, directory: nil, shownText: f.view.shownTexts(ofLink: link)) == .misleading)
        #expect(LinkPolicy.action(for: link, directory: nil, shownText: [link]) == .open(URL(string: "https://real.example.org/page")!))
    }
}
