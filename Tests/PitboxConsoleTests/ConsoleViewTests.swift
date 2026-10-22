import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

@MainActor
struct ConsoleViewTests {
    @Test func theConsoleLaysOutAStripOverTheTerminalAndStartsTheShellAtTheRightSize() throws {
        let h = ConsoleHarness(size: CGSize(width: 618, height: 636))
        #expect(h.view.strip.frame == CGRect(x: 0, y: 0, width: 618, height: TabStripView.height))
        let view = try #require(h.selectedView)
        #expect(view.superview != nil && view.frame.width == 618 - 2 * ConsoleView.sidePadding)
        #expect(view.frame.height == 636 - TabStripView.height - ConsoleView.bottomPadding - ConsoleView.topGap)
        #expect(h.processes.count == 1, "one shell, started after the first layout")
        let size = h.launcher.sizes[0]
        #expect(size.cols == view.terminal.cols && size.rows == view.terminal.rows, "\(size) vs \(view.terminal.cols)x\(view.terminal.rows)")
        // SF Mono 13 at 1x: about 8 pt per column, 16 pt per row; the overlay scroller takes 15 pt.
        #expect((60...80).contains(size.cols) && (34...40).contains(size.rows), "a 2x8 console (618 x 636 pt) is about 72x37: \(size)")
        #expect(h.stripTitles == ["~"])
    }

    @Test func theStripFollowsTheSessions() {
        let h = ConsoleHarness(settingsJSON: presetJSON())
        _ = h.manager.newSession()
        h.processes[1].changeDirectory("/tmp")
        h.manager.pollMetadata()
        #expect(h.stripTitles == ["~", "tmp"])
        #expect(h.view.strip.items.map(\.isSelected) == [false, true])
        #expect(h.manager.sessions.map { $0.view.window != nil } == [false, true], "only the selected terminal is in the window")
        h.manager.selectNext()
        #expect(h.view.strip.items.map(\.isSelected) == [true, false])
        #expect(h.manager.sessions.map { $0.view.window != nil } == [true, false])
    }

    @Test func clickingTheStripSelectsClosesAndCreates() {
        let h = ConsoleHarness()
        let strip = h.view.strip
        strip.activate(.newSession, at: .zero)
        #expect(h.manager.sessions.count == 2 && h.keyboardRequests == [true], "a new tab takes the keyboard")
        let first = h.manager.sessions[0].id
        strip.activate(.tab(first), at: .zero)
        #expect(h.manager.selectedID == first)
        #expect(h.keyboardRequests == [true], "selecting a tab with the mouse does not grab the keyboard")
        strip.activate(.close(first), at: .zero)
        #expect(h.manager.sessions.count == 1)
    }

    @Test func hitTestingFindsTabsCloseButtonsAndTheControls() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession(); _ = h.manager.newSession()
        let strip = h.view.strip
        strip.layoutSubtreeIfNeeded()
        let frames = strip.tabFrames
        #expect(frames.count == 3)
        for (index, entry) in frames.enumerated() {
            let center = CGPoint(x: entry.frame.minX + 20, y: entry.frame.midY)
            #expect(strip.hit(at: center) == .tab(entry.id), "tab \(index)")
        }
        // The close button exists only on the selected tab (or a hovered one).
        let selected = try #require(frames.last)
        #expect(strip.hit(at: CGPoint(x: selected.frame.maxX - 13, y: selected.frame.midY)) == .close(selected.id))
        let other = frames[0]
        #expect(strip.hit(at: CGPoint(x: other.frame.maxX - 13, y: other.frame.midY)) == .tab(other.id), "unselected tabs show no close button")
        #expect(strip.hit(at: CGPoint(x: strip.newFrame.midX, y: strip.bounds.midY)) == .newSession)
        #expect(strip.hit(at: CGPoint(x: strip.menuFrame.midX, y: strip.bounds.midY)) == .presetMenu)
        #expect(strip.menuFrame.maxX <= strip.bounds.width && strip.newFrame.maxX == strip.menuFrame.minX, "the controls sit at the right edge")
        #expect(frames.allSatisfy { $0.frame.maxX <= strip.newFrame.minX }, "tabs never run under the controls")
        #expect(strip.hit(at: CGPoint(x: 2, y: 2)) == nil)
    }

    @Test func theStripIsAccessibleAndPressable() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession()
        let strip = h.view.strip
        strip.layoutSubtreeIfNeeded()
        let children = try #require(strip.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children.count == 4, "two tabs plus New Tab and Presets")
        #expect(children[0].accessibilityRole() == .radioButton && children[0].accessibilityLabel() == "~")
        #expect((children[0].accessibilityValue() as? Int) == 0 && (children[1].accessibilityValue() as? Int) == 1, "the selected tab is marked")
        #expect(children[2].accessibilityLabel() == "New Tab" && children[3].accessibilityLabel() == "Presets")
        #expect(children[0].accessibilityPerformPress())
        #expect(h.manager.selectedIndex == 0, "pressing a tab selects it")
        #expect(children[2].accessibilityPerformPress())
        #expect(h.manager.sessions.count == 3, "pressing New Tab opens one")
        #expect(strip.accessibilityRole() == .tabGroup)
    }

    @Test func hoveringATabShowsItsCloseButtonWithoutMouseMovedTracking() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession()
        let strip = h.view.strip
        strip.layoutSubtreeIfNeeded()
        strip.updateTrackingAreas()
        #expect(!strip.trackingAreas.isEmpty)
        #expect(strip.trackingAreas.allSatisfy { !$0.options.contains(.mouseMoved) },
                "macOS 26 can synthesize clicks for tracking areas that ask for mouse-moved events")
        let other = try #require(strip.tabFrames.first)
        let point = CGPoint(x: other.frame.maxX - 13, y: other.frame.midY)
        #expect(strip.hit(at: point) == .tab(other.id), "no close button on an unselected, unhovered tab")
        strip.setHover(id: other.id, button: nil)
        #expect(strip.hit(at: point) == .close(other.id), "hovering reveals it")
        strip.setHover(id: nil, button: nil)
        #expect(strip.hit(at: point) == .tab(other.id))
    }

    @Test func theChevronMenuListsPresetsAndTheOptions() throws {
        let h = ConsoleHarness(settingsJSON: presetJSON())
        let menu = try #require(h.view.strip.presetMenuProvider?())
        let titles = menu.items.map(\.title).filter { !$0.isEmpty }
        #expect(titles == ["Shell", "Claude", "Top", "Once", "Auto-rotate Tabs"], "\(titles)")
        #expect(!titles.contains("Edit Presets…"), "no settings file carries presets: nothing to edit")
        #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.action != nil }, "every line acts; no file notes")
        // The menu items act: choosing a preset opens a tab.
        let claude = try #require(menu.items.first { $0.title == "Claude" })
        _ = claude.target?.perform(claude.action, with: claude)
        #expect(h.manager.sessions.map(\.preset.id) == ["shell", "claude"])
    }

    @Test func presetsInTheMenuAreDisabledAtTheTabLimit() throws {
        let h = ConsoleHarness(settingsJSON: #"{"maxSessions": 2}"#)
        func item(_ title: String) throws -> NSMenuItem {
            let menu = try #require(h.view.strip.presetMenuProvider?())
            menu.update()   // what AppKit does before it shows the menu
            return try #require(menu.items.first { $0.title == title })
        }
        #expect(try item("Shell").isEnabled, "below the limit a preset opens a tab")
        _ = h.manager.newSession()
        #expect(!h.manager.canCreateSession)
        #expect(try !item("Shell").isEnabled, "at the limit, like +: choosing it could only beep")
        #expect(try item("Auto-rotate Tabs").isEnabled, "the option stays available")
    }

    @Test func theTabLayoutFitsCompressesAndKeepsTheSelectedTabReadable() {
        #expect(TabLayout.widths(count: 0, selectedIndex: nil, available: 500).isEmpty)
        #expect(TabLayout.widths(count: 1, selectedIndex: 0, available: 500) == [TabLayout.maxWidth])
        let roomy = TabLayout.widths(count: 3, selectedIndex: 1, available: 480)
        #expect(roomy.allSatisfy { $0 == roomy[0] } && roomy.reduce(0, +) + 2 * TabLayout.spacing <= 480)
        for count in [4, 6, 9, 12] {
            let widths = TabLayout.widths(count: count, selectedIndex: count - 1, available: 400)
            let total = TabLayout.contentWidth(of: widths)
            let others = widths.dropLast()
            // Either everything fits, or the other tabs are as narrow as they get and the strip scrolls.
            #expect(total <= 400.5 || others.allSatisfy { $0 == TabLayout.minWidth }, "\(count) tabs: \(widths) total \(total)")
            #expect(widths.allSatisfy { $0 >= TabLayout.minWidth })
            #expect(widths[count - 1] >= TabLayout.selectedMinWidth, "the selected tab stays readable")
        }
    }

    @Test func aRebuiltConsoleViewAdoptsTheRunningSessions() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession()
        h.processes[0].emit("keep me\r\n")
        let views = h.manager.sessions.map(\.view)
        let launched = h.processes.count

        // The app rebuilds the console's view (a new drawer, for example): a new view over the same manager.
        let second = h.console.makeConsoleView()
        let window2 = OffscreenWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: true)
        window2.isReleasedWhenClosed = false
        // No order-in/out animation: while the display sleeps it never ends and keeps a GCD pool thread.
        window2.animationBehavior = .none
        window2.contentView = second
        second.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        second.layoutSubtreeIfNeeded()

        #expect(second.manager === h.manager)
        #expect(h.processes.count == launched, "no shell was restarted")
        #expect(h.manager.sessions.map(\.view) == views, "the same terminal views")
        let selectedView = try #require(second.manager.selectedSession?.view)
        #expect(selectedView.window === window2, "the visible terminal was re-parented into the new console")
        #expect(views.filter { $0 !== selectedView }.allSatisfy { $0.window == nil }, "the others stay detached (they keep running)")
        #expect(second.strip.items.count == 2)
        #expect(screenText(views[0]).contains("keep me"), "scrollback survived")
        // Output keeps flowing into the moved view, and it was resized for the new console.
        h.processes[0].emit("after the move\r\n")
        #expect(screenText(views[0]).contains("after the move"))
        h.clock.advance(by: 1)
        #expect(h.processes.allSatisfy { ($0.resizes.last?.cols ?? 0) > 80 }, "programs learned the new size")
        // The old console no longer receives changes.
        h.manager.selectPrevious()
        #expect(second.strip.items.map(\.isSelected).contains(true))
    }

    @Test func hostBasics() throws {
        let h = ConsoleHarness()
        #expect(h.console.sessionCount == 1)
        h.console.focus()
        #expect(h.keyboardRequests.last == true)
        h.console.shutdown()
        #expect(h.processes.allSatisfy { $0.hangUpCount == 1 })
        let saved = SavedState.load(from: h.dir.paths.stateFile)
        #expect(saved?.tabs.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func statusQueriesAreSafeFromAnyThread() async throws {
        // A control-command handler runs on the concurrency pool: reading the counts there must not trap.
        final class Box: @unchecked Sendable {
            let console: ConsoleHost
            init(_ console: ConsoleHost) { self.console = console }
        }
        let h = ConsoleHarness()
        h.processes[0].runJob(named: "vim")
        let box = Box(h.console)
        let counts: [Int] = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: [box.console.sessionCount, box.console.busySessionCount]) }
        }
        #expect(counts == [1, 1])
    }

    @Test func busySessionsAreCountedForAWarningBeforeARestart() throws {
        let h = ConsoleHarness(settingsJSON: presetJSON())
        #expect(h.console.busySessionCount == 0, "an idle shell is not busy")
        h.processes[0].runJob(named: "vim")
        #expect(h.console.busySessionCount == 1)
        let claude = h.manager.presetsForMenu().first { $0.id == "claude" }
        _ = h.manager.newSession(preset: claude)
        #expect(h.console.busySessionCount == 2, "a preset program counts while it runs")
        h.processes[1].end(.exited(0))
        #expect(h.console.busySessionCount == 1)
    }

    @Test func onlyTheSettingsValueDecidesWhatRuns() throws {
        // The host takes no input but its settings value: the defaults run a login shell in the home folder.
        let dir = TempDir()
        let launcher = FakeLauncher()
        let console = ConsoleHost(keyboardRequester: { _ in }, paths: dir.paths, launcher: launcher.launch, clock: ManualClock(),
                                  environment: fixtureEnvironment(), mode: .terminal)
        let view = try #require(console.makeView() as? ConsoleView)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()
        let spec = try #require(launcher.processes.first?.spec)
        #expect(spec.executable == "/bin/zsh" && spec.argv == ["zsh", "-l"] && spec.cwd == "/Users/tester")
        #expect(view.manager.autoRotate == false && view.manager.sessions[0].view.font.pointSize == 13)
        #expect(view.layer?.cornerRadius == 18)
        #expect(console.makeConsoleView(cornerRadius: 999).layer?.cornerRadius == 48, "cosmetic radius is clamped")
    }

    @Test func everyViewSharesTheOneManagerAndStateFile() throws {
        let dir = TempDir()
        let launcher = FakeLauncher()
        let console = ConsoleHost(keyboardRequester: { _ in }, paths: dir.paths, launcher: launcher.launch, clock: ManualClock(),
                                  environment: fixtureEnvironment(), mode: .terminal)
        let a = console.makeConsoleView()
        let b = console.makeConsoleView()
        for view in [a, b] { view.frame = CGRect(x: 0, y: 0, width: 600, height: 400); view.layoutSubtreeIfNeeded() }
        #expect(a.manager === b.manager && console.sessionCount == 1)
        console.shutdown()
        #expect(FileManager.default.fileExists(atPath: dir.paths.stateFile.path))
        #expect(dir.paths.stateFile.lastPathComponent == "console-state.json")
    }

}

@MainActor
struct ConsoleFocusTests {
    @Test func focusFollowsTheFirstResponderOfAKeyWindow() throws {
        let h = ConsoleHarness()
        let view = try #require(h.selectedView)
        #expect(!h.view.isFocused)
        h.window.makeFirstResponder(view)
        #expect(!h.view.isFocused, "first responder but the window is not key")
        h.makeKey()
        #expect(h.view.isFocused, "key window and the terminal is first responder")
        h.window.makeFirstResponder(nil)
        #expect(!h.view.isFocused, "KVO on firstResponder notices the change")
        h.window.makeFirstResponder(view)
        #expect(h.view.isFocused)
        h.makeKey(false)
        #expect(!h.view.isFocused)
    }

    @Test func typingFocusFollowsTheSelection() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession()
        h.makeKey()
        let second = try #require(h.selectedView)
        h.window.makeFirstResponder(second)
        h.manager.selectPrevious()
        let first = try #require(h.selectedView)
        #expect(first !== second && h.window.firstResponder === first, "switching tabs while typing keeps typing")
        #expect(h.view.isFocused)
    }

    @Test func aTabSwitchDoesNotStealFocusThatWasElsewhere() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession()
        h.makeKey()
        let outside = NSTextField(frame: .zero)
        h.view.addSubview(outside)
        h.window.makeFirstResponder(outside)
        h.manager.selectPrevious()
        let editor = h.window.firstResponder as? NSTextView
        #expect(editor?.delegate === outside, "the text field's editor still has the keyboard")
        #expect(!h.manager.sessions.contains { $0.view === h.window.firstResponder })
    }

    @Test func focusTerminalAsksForTheKeyboardAndTakesFirstResponder() throws {
        let h = ConsoleHarness()
        h.makeKey()
        h.view.focusTerminal()
        #expect(h.keyboardRequests == [true])
        #expect(h.window.firstResponder === h.selectedView && h.view.isFocused)
    }

    @Test func closingTheFocusedTabKeepsTypingFocusInTheTerminal() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession()
        h.makeKey()
        let closing = try #require(h.selectedView)
        h.window.makeFirstResponder(closing)
        #expect(h.view.isFocused)
        h.manager.closeNow(h.manager.sessions[1].id)
        let remaining = try #require(h.selectedView)
        #expect(remaining !== closing && closing.superview == nil, "the closed tab's view is gone")
        #expect(h.window.firstResponder === remaining, "typing goes to the tab that took its place")
        #expect(h.view.isFocused)
    }

    @Test func clickingThePaddingFocusesTheTerminal() throws {
        let h = ConsoleHarness()
        h.makeKey()
        let point = CGPoint(x: 3, y: h.view.bounds.height - 3)   // the strip is on top; this is the bottom-left padding
        let hit = h.view.hitTest(h.view.convert(point, to: h.view.superview))
        #expect(hit != nil && !(hit is ConsoleTerminalView))
        h.view.focusTerminal()
        #expect(h.view.isFocused)
    }

    @Test func theUserIsNotPresentInAnUnfocusedOffscreenConsole() {
        let h = ConsoleHarness()
        #expect(!h.view.isUserPresent)
        h.makeKey()
        h.window.makeFirstResponder(h.selectedView)
        #expect(h.view.isUserPresent, "focus counts as present")
        #expect(h.manager.interactionProbe?() == true)
    }
}

@MainActor
struct ConsoleShortcutTests {
    @Test func shortcutsGoThroughTheTerminalViewsKeyEquivalentPath() throws {
        let h = ConsoleHarness()
        h.makeKey()
        let view = try #require(h.selectedView)
        h.window.makeFirstResponder(view)

        #expect(view.performKeyEquivalent(with: h.keyEvent("t", keyCode: 17, modifiers: .command)))
        #expect(h.manager.sessions.count == 2 && h.keyboardRequests.last == true, "Cmd-T opens a tab and takes the keyboard")
        #expect(h.window.firstResponder === h.selectedView, "the new tab has the typing focus")

        let current = try #require(h.selectedView)
        #expect(current.performKeyEquivalent(with: h.keyEvent("\t", keyCode: 48, modifiers: .control)))
        #expect(h.manager.selectedIndex == 0, "Ctrl-Tab: next (wraps)")
        #expect(h.selectedView!.performKeyEquivalent(with: h.keyEvent("\t", keyCode: 48, modifiers: [.control, .shift])))
        #expect(h.manager.selectedIndex == 1, "Ctrl-Shift-Tab: previous")
        #expect(h.selectedView!.performKeyEquivalent(with: h.keyEvent("{", keyCode: 33, modifiers: [.command, .shift])))
        #expect(h.manager.selectedIndex == 0, "Cmd-Shift-[")
        #expect(h.selectedView!.performKeyEquivalent(with: h.keyEvent("}", keyCode: 30, modifiers: [.command, .shift])))
        #expect(h.manager.selectedIndex == 1, "Cmd-Shift-]")
        #expect(h.selectedView!.performKeyEquivalent(with: h.keyEvent("1", keyCode: 18, modifiers: .command)))
        #expect(h.manager.selectedIndex == 0, "Cmd-1")
        #expect(h.selectedView!.performKeyEquivalent(with: h.keyEvent("9", keyCode: 25, modifiers: .command)))
        #expect(h.manager.selectedIndex == 1, "Cmd-9 is the last tab")

        let before = h.keyboardRequests.count
        #expect(h.selectedView!.performKeyEquivalent(with: h.keyEvent("\u{1b}", keyCode: 53, modifiers: .command)))
        #expect(h.keyboardRequests.count == before + 1 && h.keyboardRequests.last == false, "Cmd-Escape hands the keyboard back")

        #expect(h.selectedView!.performKeyEquivalent(with: h.keyEvent("w", keyCode: 13, modifiers: .command)))
        #expect(h.manager.sessions.count == 1, "Cmd-W closes an idle shell")
    }

    /// AppKit offers key equivalents to every view of the key window, not just the first responder. Typing in any other
    /// field must never trigger terminal shortcuts, Option word motions, or write into a session.
    @Test func shortcutsAreIgnoredWhileTheUserTypesElsewhere() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession()
        h.makeKey()
        let askBox = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        h.window.contentView?.addSubview(askBox)
        h.window.makeFirstResponder(askBox)
        let keys: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("t", 17, .command), ("w", 13, .command), ("\t", 48, .control), ("\t", 48, [.control, .shift]), ("1", 18, .command),
            ("9", 25, .command), ("}", 30, [.command, .shift]), ("\u{1b}", 53, .command), ("\u{f702}", 123, .option),
            ("\u{f703}", 124, .option), ("\u{7f}", 51, .option), ("\u{7f}", 51, .command), ("f", 3, .command),
        ]
        for view in h.manager.sessions.map(\.view) {
            for (chars, code, mods) in keys {
                #expect(!view.performKeyEquivalent(with: h.keyEvent(chars, keyCode: code, modifiers: mods)), "\(chars) \(mods) on a view that is not the first responder")
            }
        }
        #expect(h.manager.sessions.count == 2 && h.keyboardRequests.isEmpty)
        #expect(h.processes.allSatisfy { $0.written.isEmpty }, "nothing typed elsewhere reaches a shell")
        #expect(h.window.firstResponder is NSTextView, "the other text field keeps the keyboard")
    }

    /// The window offers a key equivalent to its whole view hierarchy (through any wrapper views, like the block's
    /// glass and SwiftUI host); the terminal must answer only when it is where the user types.
    @Test func theWindowsOwnKeyEquivalentWalkFindsTheTerminalOnlyWhileItHasTheKeyboard() throws {
        let h = ConsoleHarness()
        _ = h.manager.newSession()
        h.makeKey()
        let root = NSView(frame: h.view.frame)
        let wrapper = NSView(frame: root.bounds)
        let inner = NSView(frame: wrapper.bounds)
        h.window.contentView = root   // the console was the content view; now it sits two levels deeper, like under the glass and the hosting view
        root.addSubview(wrapper)
        wrapper.addSubview(inner)
        inner.addSubview(h.view)
        let terminal = try #require(h.selectedView)
        h.window.makeFirstResponder(terminal)
        #expect(h.window.performKeyEquivalent(with: h.keyEvent("\t", keyCode: 48, modifiers: .control)), "found through the hierarchy")
        #expect(h.manager.selectedIndex == 0)

        let askBox = NSTextField(frame: CGRect(x: 0, y: 0, width: 80, height: 20))
        inner.addSubview(askBox)
        h.window.makeFirstResponder(askBox)
        #expect(!h.window.performKeyEquivalent(with: h.keyEvent("\t", keyCode: 48, modifiers: .control)), "typing in another field: not ours")
        #expect(h.manager.selectedIndex == 0)
    }

    @Test func ordinaryKeysAndEditShortcutsAreNotTaken() throws {
        let h = ConsoleHarness()
        let view = try #require(h.selectedView)
        h.window.makeFirstResponder(view)
        for (chars, code, mods) in [("a", 0, NSEvent.ModifierFlags()), ("c", 8, .command), ("v", 9, .command), ("a", 0, .command), ("c", 8, .control),
                                    ("\t", 48, NSEvent.ModifierFlags()), ("\u{1b}", 53, NSEvent.ModifierFlags())] {
            #expect(!view.performKeyEquivalent(with: h.keyEvent(chars, keyCode: UInt16(code), modifiers: mods)), "\(chars) \(mods)")
        }
        #expect(h.manager.sessions.count == 1 && h.keyboardRequests.isEmpty)
    }

    @Test func cmdBackspaceDeletesTheLine() throws {
        let h = ConsoleHarness()
        let view = try #require(h.selectedView)
        h.window.makeFirstResponder(view)
        #expect(view.performKeyEquivalent(with: h.keyEvent("\u{7f}", keyCode: 51, modifiers: .command)))
        #expect(h.processes[0].written == [0x15])
    }

    @Test func optionArrowsMoveByWordWhenOptionIsNotMeta() throws {
        let h = ConsoleHarness()
        let view = try #require(h.selectedView)
        h.window.makeFirstResponder(view)
        #expect(view.optionAsMetaKey == false)
        #expect(view.performKeyEquivalent(with: h.keyEvent("\u{f702}", keyCode: 123, modifiers: .option)))
        #expect(view.performKeyEquivalent(with: h.keyEvent("\u{f703}", keyCode: 124, modifiers: .option)))
        #expect(view.performKeyEquivalent(with: h.keyEvent("\u{7f}", keyCode: 51, modifiers: .option)))
        #expect(h.processes[0].written == [0x1b, 0x62, 0x1b, 0x66, 0x1b, 0x7f])
        // Option must still be free for typing: Option-L is @ on a German layout and is not intercepted.
        #expect(!view.performKeyEquivalent(with: h.keyEvent("@", keyCode: 37, modifiers: .option)))
        #expect(!view.performKeyEquivalent(with: h.keyEvent("|", keyCode: 26, modifiers: .option)))
    }

    @Test func withOptionAsMetaOnSwiftTermHandlesOptionKeysItself() throws {
        let h = ConsoleHarness(settingsJSON: #"{"optionAsMeta": true}"#)
        let view = try #require(h.selectedView)
        h.window.makeFirstResponder(view)
        #expect(view.optionAsMetaKey == true)
        #expect(!view.performKeyEquivalent(with: h.keyEvent("\u{f702}", keyCode: 123, modifiers: .option)), "left to SwiftTerm's own Meta handling")
        #expect(h.processes[0].written.isEmpty)
    }

    @Test func aBusyTabNeedsCmdWTwice() throws {
        let h = ConsoleHarness()
        h.processes[0].runJob(named: "vim")
        let view = try #require(h.selectedView)
        h.window.makeFirstResponder(view)
        #expect(view.performKeyEquivalent(with: h.keyEvent("w", keyCode: 13, modifiers: .command)))
        #expect(h.manager.sessions.count == 1 && h.view.strip.items[0].confirmingClose)
        #expect(view.performKeyEquivalent(with: h.keyEvent("w", keyCode: 13, modifiers: .command)))
        #expect(h.processes[0].terminateCount == 1)
    }

    @Test func aHeldCmdTDoesNotOpenDozensOfTabs() throws {
        let h = ConsoleHarness()
        let view = try #require(h.selectedView)
        h.window.makeFirstResponder(view)
        #expect(!view.performKeyEquivalent(with: h.keyEvent("t", keyCode: 17, modifiers: .command, repeated: true)))
        #expect(h.manager.sessions.count == 1)
    }
}

@MainActor
struct ConsoleVisibilityTests {
    @Test func nothingIsPolledWhileTheStripIsHiddenAndTitlesRefreshWhenItReturns() {
        let h = ManagerHarness()
        h.clock.advance(by: 3)   // the start-up save and first poll are done
        var visible = false
        h.manager.visibilityProbe = { visible }
        h.processes[0].changeDirectory("/tmp")
        h.clock.advance(by: 60)
        #expect(h.titles == ["~"], "hidden: the tick does no work")
        visible = true
        h.clock.advance(by: TerminalSessionManager.metadataInterval + 0.1)
        #expect(h.titles == ["tmp"], "the next tick after the strip is shown refreshes the titles")
    }

    @Test func autoRotateWaitsWhileHiddenAndRestartsItsCountdownOnReturn() {
        let h = ManagerHarness(settingsJSON: #"{"autoRotate": true, "autoRotateSeconds": 10}"#)
        _ = h.manager.newSession()
        h.manager.select(index: 0)
        var visible = false
        h.manager.visibilityProbe = { visible }
        h.clock.advance(by: 120)
        #expect(h.selectedIndex == 0, "hidden tabs are not rotated")
        visible = true
        h.clock.advance(by: 9)
        #expect(h.selectedIndex == 0, "a full interval after coming back")
        h.clock.advance(by: 2)
        #expect(h.selectedIndex == 1)
    }

    @Test func theConsoleAsksItsWindowNotANotification() {
        let h = ConsoleHarness()
        #expect(h.manager.isVisible == true, "the harness window pretends to be shown")
        h.window.pretendVisible = false   // nothing is ever ordered onto the screen in these tests
        #expect(h.manager.isVisible == false, "no notification is needed: visibility is read when it matters")
        h.window.pretendVisible = true
        #expect(h.manager.isVisible == true)
    }
}
