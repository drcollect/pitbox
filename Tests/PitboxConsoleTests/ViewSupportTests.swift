import AppKit
import SwiftTerm
import Testing
@testable import PitboxConsole

struct ThemeTests {
    @Test func bothPalettesAreReadableOnTheirBackground() {
        for palette in [TerminalTheme.dark, TerminalTheme.light] {
            let name = palette.isDark ? "dark" : "light"
            #expect(palette.ansi.count == 16, "\(name)")
            #expect(TerminalTheme.contrast(palette.foreground, palette.background) >= 7, "\(name) text")
            for index in 0..<16 {
                let ratio = TerminalTheme.contrast(palette.ansi[index], palette.background)
                let floor = index == 0 ? 1.3 : 3.0   // ANSI black is mostly a background color
                #expect(ratio >= floor, "\(name) ansi \(index): \(ratio)")
            }
            #expect(TerminalTheme.contrast(palette.selectionForeground, palette.selectionBackground) >= 4.5, "\(name) selection")
            // Every bright color differs from its normal color, and on dark backgrounds it is the brighter one.
            for index in 1..<7 {
                let normal = TerminalTheme.luminance(palette.ansi[index]), bright = TerminalTheme.luminance(palette.ansi[index + 8])
                #expect(abs(normal - bright) > 0.005, "\(name) bright \(index) is too close to its normal color")
                if palette.isDark { #expect(bright >= normal, "\(name) bright \(index): \(normal) vs \(bright)") }
            }
        }
        #expect(TerminalTheme.dark.background != TerminalTheme.light.background)
    }

    @Test func distinctColorsSoTheyCanBeTold() {
        for palette in [TerminalTheme.dark, TerminalTheme.light] {
            let colors = palette.ansi.map { TerminalTheme.hexString($0) }
            #expect(Set(colors).count == 16, "\(colors)")
        }
    }

    @Test func fontIsMonospacedAndHonorsSizeAndName() {
        let system = TerminalTheme.font(name: "SF Mono", size: 13)
        #expect(system.pointSize == 13 && system.isFixedPitch)
        #expect(TerminalTheme.font(name: "", size: 13).fontName == system.fontName)
        let menlo = TerminalTheme.font(name: "Menlo", size: 12)
        #expect(menlo.familyName == "Menlo" && menlo.pointSize == 12)
        #expect(TerminalTheme.font(name: "Helvetica", size: 12).isFixedPitch, "a proportional font falls back to the system monospaced one")
        #expect(TerminalTheme.font(name: "NoSuchFont", size: 999).pointSize == 32, "size is clamped")
    }

    @Test func appearanceDetection() {
        #expect(TerminalTheme.isDark(NSAppearance(named: .darkAqua)!))
        #expect(!TerminalTheme.isDark(NSAppearance(named: .aqua)!))
        #expect(TerminalTheme.palette(isDark: true) == TerminalTheme.dark)
        #expect(TerminalTheme.dark.tint(opacity: 0.5).alphaComponent == 0.5)
    }
}

struct ShortcutTests {
    private func key(_ chars: String, _ code: UInt16, cmd: Bool = false, ctrl: Bool = false, opt: Bool = false, shift: Bool = false, repeated: Bool = false) -> KeyInput {
        KeyInput(keyCode: code, characters: chars, command: cmd, control: ctrl, option: opt, shift: shift, isRepeat: repeated)
    }

    @Test func tabsAreRotatedWithCtrlTabAndTheBracketKeys() {
        #expect(TerminalShortcuts.match(key("\t", 48, ctrl: true)) == .nextSession)
        #expect(TerminalShortcuts.match(key("\t", 48, ctrl: true, shift: true)) == .previousSession)
        #expect(TerminalShortcuts.match(key("}", 30, cmd: true, shift: true)) == .nextSession, "Cmd-Shift-]")
        #expect(TerminalShortcuts.match(key("{", 33, cmd: true, shift: true)) == .previousSession, "Cmd-Shift-[")
        #expect(TerminalShortcuts.match(key("ü", 33, cmd: true, shift: true)) == .previousSession, "German layout: the physical [ key")
        #expect(TerminalShortcuts.match(key("\u{f703}", 124, cmd: true, opt: true)) == .nextSession, "Cmd-Option-Right")
        #expect(TerminalShortcuts.match(key("\u{f702}", 123, cmd: true, opt: true)) == .previousSession)
        #expect(TerminalShortcuts.match(key("\t", 48)) == nil, "a plain Tab goes to the program")
        #expect(TerminalShortcuts.match(key("\t", 48, ctrl: true, opt: true)) == nil)
    }

    @Test func commandShortcutsForSessions() {
        #expect(TerminalShortcuts.match(key("t", 17, cmd: true)) == .newSession)
        #expect(TerminalShortcuts.match(key("w", 13, cmd: true)) == .closeSession)
        #expect(TerminalShortcuts.match(key("t", 17, cmd: true, repeated: true)) == nil, "holding Cmd-T does not open dozens of tabs")
        #expect(TerminalShortcuts.match(key("w", 13, cmd: true, repeated: true)) == nil)
        #expect(TerminalShortcuts.match(key("1", 18, cmd: true)) == .selectSession(0))
        #expect(TerminalShortcuts.match(key("8", 28, cmd: true)) == .selectSession(7))
        #expect(TerminalShortcuts.match(key("9", 25, cmd: true)) == .selectLastSession)
        #expect(TerminalShortcuts.match(key("\u{1b}", 53, cmd: true)) == .releaseKeyboard)
        #expect(TerminalShortcuts.match(key("f", 3, cmd: true)) == .find)
        #expect(TerminalShortcuts.match(key("\u{7f}", 51, cmd: true)) == .deleteToLineStart)
    }

    @Test func everythingElseFallsThrough() {
        // Cmd-C / Cmd-V / Cmd-A belong to the Edit menu; Ctrl-C and friends belong to the program.
        for (chars, code) in [("c", 8), ("v", 9), ("a", 0), ("x", 7), ("z", 6), ("q", 12)] {
            #expect(TerminalShortcuts.match(key(chars, UInt16(code), cmd: true)) == nil, "Cmd-\(chars)")
        }
        #expect(TerminalShortcuts.match(key("c", 8, ctrl: true)) == nil)
        #expect(TerminalShortcuts.match(key("t", 17, cmd: true, ctrl: true)) == nil)
        #expect(TerminalShortcuts.match(key("t", 17, cmd: true, opt: true)) == nil)
        #expect(TerminalShortcuts.match(key("t", 17)) == nil)
        #expect(TerminalShortcuts.match(key("1", 18)) == nil)
        #expect(TerminalShortcuts.match(key("\u{1b}", 53)) == nil, "Escape belongs to the program")
    }
}

struct OptionKeyTests {
    @Test func optionEditingKeysBecomeWordMotions() {
        func key(_ code: UInt16, opt: Bool = true, shift: Bool = false, cmd: Bool = false, ctrl: Bool = false) -> KeyInput {
            KeyInput(keyCode: code, characters: "", command: cmd, control: ctrl, option: opt, shift: shift)
        }
        #expect(TerminalShortcuts.optionEditingSequence(key(123)) == [0x1b, 0x62], "Option-Left is ESC b (backward-word)")
        #expect(TerminalShortcuts.optionEditingSequence(key(124)) == [0x1b, 0x66], "Option-Right is ESC f (forward-word)")
        #expect(TerminalShortcuts.optionEditingSequence(key(51)) == [0x1b, 0x7f], "Option-Backspace deletes a word")
        #expect(TerminalShortcuts.optionEditingSequence(key(117)) == [0x1b, 0x64], "Option-Delete deletes the next word")
        #expect(TerminalShortcuts.optionEditingSequence(key(123, opt: false)) == nil)
        #expect(TerminalShortcuts.optionEditingSequence(key(123, cmd: true)) == nil, "Cmd-Option-Left switches tabs")
        #expect(TerminalShortcuts.optionEditingSequence(key(123, shift: true)) == nil)
        #expect(TerminalShortcuts.optionEditingSequence(key(123, ctrl: true)) == nil)
        #expect(TerminalShortcuts.optionEditingSequence(key(0)) == nil, "Option-A must still type å or nothing special")
    }
}

struct PasteTests {
    @Test func controlCharactersAreRemovedSoAPasteCannotEscapeItsBrackets() {
        #expect(PasteSanitizer.clean("ls -la") == "ls -la")
        #expect(PasteSanitizer.clean("a\u{1b}[201~rm -rf ~") == "a[201~rm -rf ~", "ESC is gone, so the end marker is just text")
        #expect(PasteSanitizer.clean("x\u{1b}]0;title\u{7}y") == "x]0;titley")
        #expect(PasteSanitizer.clean("a\u{7f}b\u{08}c\u{00}d") == "abcd")
        #expect(PasteSanitizer.clean("a\u{85}b\u{9b}31m") == "ab31m", "C1 controls")
        #expect(PasteSanitizer.clean("tab\there") == "tab\there")
        #expect(PasteSanitizer.clean("é 日本語 🙂 ü") == "é 日本語 🙂 ü")
    }

    @Test func newlinesBecomeCarriageReturns() {
        #expect(PasteSanitizer.clean("a\nb") == "a\rb")
        #expect(PasteSanitizer.clean("a\r\nb") == "a\rb")
        #expect(PasteSanitizer.clean("a\rb") == "a\rb")
        #expect(PasteSanitizer.clean("a\n\nb") == "a\r\rb")
        #expect(PasteSanitizer.clean("a\u{2028}b") == "ab")
    }

    @Test func pasteboardContentsAndDrops() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("pitbox.console.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("hello", forType: .string)
        #expect(PasteSanitizer.text(from: pb) == "hello")
        #expect(PasteSanitizer.dropText(from: pb) == "hello")

        pb.clearContents()
        let files = [URL(fileURLWithPath: "/Users/me/My File (1).png"), URL(fileURLWithPath: "/tmp/b.txt")]
        pb.writeObjects(files as [NSURL])
        #expect(PasteSanitizer.dropText(from: pb) == #"/Users/me/My\ File\ \(1\).png /tmp/b.txt "# , "escaped paths with a trailing space")
        #expect(PasteSanitizer.text(from: pb) == #"/Users/me/My\ File\ \(1\).png /tmp/b.txt"#, "copied files paste as paths")

        pb.clearContents()
        pb.writeObjects([URL(string: "https://example.com/a?b=c")! as NSURL])
        #expect(PasteSanitizer.dropText(from: pb) == "https://example.com/a?b=c")

        pb.clearContents()
        #expect(PasteSanitizer.text(from: pb) == nil && PasteSanitizer.dropText(from: pb) == nil)
    }
}

struct LinkPolicyTests {
    private func tempFiles() throws -> (dir: String, cleanup: () -> Void) {
        let dir = NSTemporaryDirectory() + "pitbox-link-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/notes.txt", contents: Data("x".utf8))
        FileManager.default.createFile(atPath: dir + "/run.sh", contents: Data("#!/bin/sh".utf8))
        FileManager.default.createFile(atPath: dir + "/tool", contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        try FileManager.default.createDirectory(atPath: dir + "/Some.app", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(atPath: dir) })
    }

    @Test func webAndMailLinksOpenEverythingElseIsIgnored() {
        #expect(LinkPolicy.action(for: "https://example.com/x?y=1", directory: nil) == .open(URL(string: "https://example.com/x?y=1")!))
        #expect(LinkPolicy.action(for: "http://localhost:3000", directory: nil) == .open(URL(string: "http://localhost:3000")!))
        #expect(LinkPolicy.action(for: "mailto:a@example.com", directory: nil) == .open(URL(string: "mailto:a@example.com")!))
        for hostile in ["ssh://host", "vnc://host", "x-apple.systempreferences:com.apple.preference.security", "javascript:alert(1)",
                        "smb://server/share", "tel:123", "itms-apps://x", "pitbox-widget://w/x", "data:text/html,hi", "http://", ""] {
            #expect(LinkPolicy.action(for: hostile, directory: nil) == .ignore, "\(hostile)")
        }
    }

    @Test func filesOpenOnlyWhenOpeningCannotRunCode() throws {
        let (dir, cleanup) = try tempFiles()
        defer { cleanup() }
        #expect(LinkPolicy.action(for: dir + "/notes.txt", directory: nil) == .open(URL(fileURLWithPath: dir + "/notes.txt")))
        #expect(LinkPolicy.action(for: dir + "/sub", directory: nil) == .open(URL(fileURLWithPath: dir + "/sub")))
        #expect(LinkPolicy.action(for: dir + "/run.sh", directory: nil) == .reveal(URL(fileURLWithPath: dir + "/run.sh")))
        #expect(LinkPolicy.action(for: dir + "/tool", directory: nil) == .reveal(URL(fileURLWithPath: dir + "/tool")), "executable")
        #expect(LinkPolicy.action(for: dir + "/Some.app", directory: nil) == .reveal(URL(fileURLWithPath: dir + "/Some.app")))
        #expect(LinkPolicy.action(for: "file://" + dir + "/notes.txt", directory: nil) == .open(URL(fileURLWithPath: dir + "/notes.txt")))
        #expect(LinkPolicy.action(for: "file://" + dir + "/run.sh", directory: nil) == .reveal(URL(fileURLWithPath: dir + "/run.sh")))
        #expect(LinkPolicy.action(for: dir + "/missing.txt", directory: nil) == .ignore)
    }

    @Test func relativePathsAndLineNumbersResolveAgainstTheSessionFolder() throws {
        let (dir, cleanup) = try tempFiles()
        defer { cleanup() }
        let expected = LinkPolicy.Action.open(URL(fileURLWithPath: dir + "/notes.txt"))
        #expect(LinkPolicy.action(for: "notes.txt", directory: dir) == expected)
        #expect(LinkPolicy.action(for: "notes.txt:12", directory: dir) == expected)
        #expect(LinkPolicy.action(for: "notes.txt:12:5", directory: dir) == expected)
        #expect(LinkPolicy.action(for: "./sub/../notes.txt", directory: dir) == expected)
        #expect(LinkPolicy.action(for: "notes.txt", directory: nil) == .ignore, "no folder, no guess")
        #expect(LinkPolicy.action(for: "~/notes.txt", directory: nil, home: dir) == expected)
    }
}
