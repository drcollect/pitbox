import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import PitboxConsole

@MainActor
struct SessionDelegateTests {
    @Test func osc52ClipboardWriteIsOffByDefaultAndReadIsNeverAllowed() {
        let h = ManagerHarness()
        let session = h.manager.sessions[0]
        session.clipboardCopy(source: session.view, content: Data("planted".utf8))
        #expect(h.clipboard.isEmpty, "a program cannot put text on the clipboard unless allowClipboardWrite is on")
        #expect(session.clipboardRead(source: session.view) == nil, "a program can never read the clipboard")

        let allowed = ManagerHarness(settingsJSON: #"{"allowClipboardWrite": true}"#)
        let s = allowed.manager.sessions[0]
        s.clipboardCopy(source: s.view, content: Data("from vim".utf8))
        #expect(allowed.clipboard == ["from vim"])
        s.clipboardCopy(source: s.view, content: Data(repeating: 65, count: (1 << 20) + 1))
        #expect(allowed.clipboard.count == 1, "oversized writes are dropped")
        #expect(s.clipboardRead(source: s.view) == nil)
    }

    @Test func linksGoThroughThePolicy() throws {
        let h = ManagerHarness()
        let session = h.manager.sessions[0]
        session.requestOpenLink(source: session.view, link: "https://example.com/docs", params: [:])
        session.requestOpenLink(source: session.view, link: "vnc://evil", params: [:])
        session.requestOpenLink(source: session.view, link: "x-apple.systempreferences:com.apple.preference.security", params: [:])
        #expect(h.links == [.open(URL(string: "https://example.com/docs")!), .ignore, .ignore])
    }

    @Test func aProgramCannotReadBackTheTitleOrTypeIntoTheSession() throws {
        // Title reporting (CSI 21 t) is the classic way to turn program output into keystrokes; SwiftTerm answers with an
        // empty title. Check that nothing of the title reaches the process, and that queries are answered by the
        // emulator only (through the same input path the keyboard uses).
        let h = ManagerHarness()
        let session = h.manager.sessions[0]
        let process = h.processes[0]
        session.view.feed(text: "\u{1b}]0;rm -rf ~\r\u{07}")
        session.view.feed(text: "\u{1b}[21t")
        #expect(!process.writtenText.contains("rm -rf"), "\(process.writtenText.debugDescription)")
        #expect(session.oscTitle == "rm -rf ~")
    }

    @Test func aDeadSessionIgnoresInputAndOnlyReturnRestarts() {
        let h = ManagerHarness(settingsJSON: presetJSON(onExit: "keep"))
        let session = h.manager.sessions[0]
        h.processes[0].end(.exited(1))
        session.view.send(txt: "hello")
        session.view.send([0x03])
        #expect(session.hasExited && h.processes.count == 1, "typing into an exited tab does nothing")
        #expect(h.processes[0].writtenText.isEmpty)
        session.view.sendPaste("echo\nboom")
        #expect(session.hasExited && h.processes.count == 1, "a paste that contains Return is not a Return key")
    }

    @Test func userInputReachesTheProcessOnlyThroughTheViewsOwnPaths() {
        let h = ManagerHarness()
        let session = h.manager.sessions[0]
        session.view.send(txt: "ls\r")
        session.view.send([0x03])
        session.view.sendPaste("a\nb")
        #expect(h.processes[0].written == Array("ls\r".utf8) + [0x03] + Array("a\rb".utf8))
        // The surface a caller outside the module sees: TerminalSession/Manager are internal, with no send/write method.
        // (Checked by review and by the absence of any public type besides the factory.)
    }

    @Test func settingsAreAppliedToTheView() {
        let h = ManagerHarness(settingsJSON: #"{"fontSize": 15, "scrollback": 2500, "optionAsMeta": true, "bell": "none", "cursorStyle": "steadyBar"}"#)
        let view = h.manager.sessions[0].view
        #expect(view.font.pointSize == 15 && view.optionAsMetaKey == true && view.bellStyle == .none)
        #expect(view.terminal.options.scrollback == 2500 && view.terminal.options.cursorStyle == .steadyBar)
        #expect(view.terminal.options.termName == "xterm-256color")
        let defaults = ManagerHarness()
        #expect(defaults.manager.sessions[0].view.terminal.options.scrollback == 10_000)
        #expect(defaults.manager.sessions[0].view.optionAsMetaKey == false)
        #expect(defaults.manager.sessions[0].view.font.pointSize == 13)
    }

    @Test func aRedrawnScreenKeepsScrollbackAcrossARestart() {
        let h = ManagerHarness(settingsJSON: presetJSON(onExit: "keep"))
        let session = h.manager.sessions[0]
        h.processes[0].emit("first run\r\n")
        h.processes[0].end(.exited(2))
        session.view.send([0x0d])
        h.processes[1].emit("second run\r\n")
        let text = screenText(session.view)
        #expect(text.contains("first run") && text.contains("second run") && text.contains("Process exited with status 2"))
    }
}
