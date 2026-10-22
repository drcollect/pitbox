import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// What the sheet shows of text it did not write (B1): the hidden-character policy,
/// the plain-text renderer for session text, and the command area.
@MainActor
struct CommandsTextTests {
    @Test func theHiddenCharacterPolicyFollowsB1() {
        let hidden: [UInt32] = [0x00, 0x0D, 0x1B, 0x7F, 0x85, 0x9F, 0xAD, 0x34F, 0x61C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B, 0x180E,
                                0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A, 0x202E, 0x2060, 0x2064, 0x2066, 0x2069,
                                0x3164, 0xFE00, 0xFE0F, 0xFEFF, 0xFFA0, 0xE0001, 0xE0020, 0xE007F, 0xE0100, 0xE01EF,
                                0xA0, 0x1680, 0x2000, 0x200A, 0x202F, 0x205F, 0x3000]
        for value in hidden {
            let scalar = Unicode.Scalar(value)!
            #expect(CommandHiddenCharacters.isHidden(scalar), "U+\(String(value, radix: 16)) is B1")
        }
        for value: UInt32 in [0x09, 0x0A, 0x20, 0x41, 0x7E, 0xE9, 0x301, 0x441, 0x65E5, 0x1F642] {
            #expect(!CommandHiddenCharacters.isHidden(Unicode.Scalar(value)!), "U+\(String(value, radix: 16)) is allowed")
        }
        #expect(CommandHiddenCharacters.escaped(Unicode.Scalar(0x202E)!) == "⟨U+202E⟩")
        #expect(CommandHiddenCharacters.codePoint(Unicode.Scalar(0xE0100)!) == "U+E0100")
        let cleaned = CommandHiddenCharacters.cleaned("a\u{202E}\u{200B}b\u{00A0}c")
        #expect(cleaned.text == "abc" && cleaned.removed == 3 && cleaned.marks == [1, 2])
    }

    @Test func sessionTextIsEscapedWrappedAt80AndCapped() {
        let rendered = CommandPlainText.render("✔ verified safe\u{202E} by Pitbox\n\u{1b}[31mred", maxLines: 4)
        #expect(rendered == "✔ verified safe⟨U+202E⟩ by Pitbox\n⟨U+001B⟩[31mred")
        let long = String(repeating: "word ", count: 40)
        let wrapped = CommandPlainText.render(long, maxLines: 10)
        #expect(wrapped.split(separator: "\n").allSatisfy { $0.count <= CommandPlainText.lineWidth })
        let cut = CommandPlainText.render(String(repeating: "x", count: 1_000), maxLines: 2)
        #expect(cut.split(separator: "\n").count == 2 && cut.hasSuffix("…"))
        #expect(CommandPlainText.singleLine("a\nb\u{2028}c", maxCharacters: 50) == "a ⏎ b⟨U+2028⟩c")
        #expect(CommandPlainText.singleLine(String(repeating: "y", count: 100), maxCharacters: 10).count == 10)
    }

    @Test func theCommandAreaShowsEveryCharacterAndMarksTheRisky() {
        let palette = CommandSheetPalette(dark: true)
        let text = "echo ok" + String(repeating: " ", count: 6) + "; rm -rf ~/x  \n\tcd caf\u{00E9}\n# a comment"
        let range = SheetFixtures.range(of: "rm -rf ~/x", in: text)
        let content = CommandAreaContent.build(text: text, displayLines: [], flags: [
            CommandFlag(rule: .r2, words: "Deletes", line: 1, utf16Range: range)], palette: palette)
        let shown = content.attributed.string
        #expect(shown.contains("echo ok······; rm -rf ~/x··"), "a long space run and trailing spaces are visible: \(shown.count)")
        #expect(shown.contains("→cd caf"), "a tab shows as →")
        #expect(shown.contains("U+00E9"), "non-ASCII carries its code point")
        #expect(content.paragraphs.map(\.number) == [1, 2, 3])
        if let underline = content.underlined.first {
            #expect((shown as NSString).substring(with: underline) == "rm -rf ~/x")
            let style = content.attributed.attribute(.underlineStyle, at: underline.location, effectiveRange: nil) as? Int
            #expect(style == NSUnderlineStyle.thick.rawValue)
        } else {
            Issue.record("the red line's characters are underlined")
        }
        let commentStart = (shown as NSString).range(of: "# a comment").location
        let color = content.attributed.attribute(.foregroundColor, at: commentStart, effectiveRange: nil) as? NSColor
        #expect(color == palette.dim, "full-line comments are dimmed")
        #expect(content.accessibilityText.hasPrefix("1: echo ok"))
    }

    @Test func outputLinesAreGreyAndNotPartOfWhatRuns() {
        let palette = CommandSheetPalette(dark: true)
        let display: [CommandOffer.DisplayLine] = [.init(role: .command, text: "ls"), .init(role: .output, text: "a.txt"),
                                                   .init(role: .output, text: "b.txt"), .init(role: .command, text: "pwd")]
        let content = CommandAreaContent.build(text: "ls\npwd", displayLines: display, flags: [], palette: palette)
        #expect(content.paragraphs.map(\.number) == [1, nil, nil, 2])
        #expect(content.attributed.string.contains("shown in the reply, not run"))
        // Display lines that do not add up to the text are ignored: what is shown as running is what runs.
        let bogus: [CommandOffer.DisplayLine] = [.init(role: .command, text: "echo safe"), .init(role: .output, text: "rm -rf ~")]
        let honest = CommandAreaContent.build(text: "rm -rf ~", displayLines: bogus, flags: [], palette: palette)
        #expect(honest.paragraphs.map(\.number) == [1])
        #expect(honest.attributed.string == "rm -rf ~")
    }

    @Test func theCommandAreaWrapsInsteadOfScrollingSideways() {
        let palette = CommandSheetPalette(dark: true)
        let long = "echo " + String(repeating: "abcdefghij", count: 30)
        let view = CommandAreaView(content: CommandAreaContent.build(text: long, displayLines: [], flags: [], palette: palette), palette: palette)
        let narrow = view.height(for: 300)
        let wide = view.height(for: 2_400)
        #expect(narrow > wide * 3, "the long line wraps into several rows")
    }

    @Test func theEchoNeverCarriesControlSequences() {
        let echo = CommandEcho.text(for: "printf a\u{1b}[2Jb\nsecond\u{7}")
        #expect(echo.contains("$ printf a⟨U+001B⟩[2Jb"))
        #expect(echo.contains("> second⟨U+0007⟩"))
        #expect(!echo.contains("\u{1b}[2J"))
        #expect(!echo.contains("\u{7}"))
    }

    @Test func sshConfigExactHostsFollowIncludesAndIgnorePatterns() throws {
        let home = CommandTempFolder("ssh")
        let ssh = home.subfolder(".ssh")
        let included = home.subfolder(".ssh/config.d")
        try Data("""
        # comment
        Host buildbox box-1
          HostName 10.0.0.1
        Host *.example !blocked
        Host "quoted alias"
        Host=equals
        Include config.d/*
        Match exec "anything"
        """.utf8).write(to: ssh.appendingPathComponent("config"))
        try Data("Host included-box\n".utf8).write(to: included.appendingPathComponent("extra"))
        chmod(ssh.appendingPathComponent("config").path, 0o600)
        chmod(included.appendingPathComponent("extra").path, 0o600)
        let reading = SSHConfigHosts.read(home: home.path)
        #expect(reading.hosts == ["buildbox", "box-1", "equals", "included-box"] && !reading.hasProblem)
        #expect(SSHConfigHosts.isExactAlias("buildbox", home: home.path))
        #expect(!SSHConfigHosts.isExactAlias("c0nductor", home: home.path))
        #expect(!SSHConfigHosts.isExactAlias("-oProxyCommand=x", home: home.path))
        #expect(!SSHConfigHosts.isWellFormedAlias("quoted alias") && !SSHConfigHosts.isWellFormedAlias(String(repeating: "a", count: 65)))
        // A config others can write is not trusted (ssh refuses it too).
        chmod(ssh.appendingPathComponent("config").path, 0o666)
        #expect(SSHConfigHosts.read(home: home.path).hosts.isEmpty && SSHConfigHosts.read(home: home.path).hasProblem)
        #expect(!SSHConfigHosts.isExactAlias("buildbox", home: home.path))
    }

    /// H4: a link, a file others can write or an `Include` past the limits is a problem, and then no alias is exact.
    @Test func sshConfigHostsFailClosedOnAnyProblem() throws {
        func home(config: String, prepare: (URL) throws -> Void = { _ in }) throws -> CommandTempFolder {
            let home = CommandTempFolder("ssh")
            let ssh = home.subfolder(".ssh")
            try prepare(ssh)
            let file = ssh.appendingPathComponent("config")
            if !FileManager.default.fileExists(atPath: file.path) { try Data(config.utf8).write(to: file) }
            chmod(file.path, 0o600)
            return home
        }
        // A linked include: the host in the main file no longer counts either.
        let linked = try home(config: "Host buildbox\nInclude extra\n") { ssh in
            let real = ssh.deletingLastPathComponent().appendingPathComponent("real.conf")
            try Data("Host other\n".utf8).write(to: real)
            try FileManager.default.createSymbolicLink(atPath: ssh.appendingPathComponent("extra").path, withDestinationPath: real.path)
        }
        #expect(SSHConfigHosts.read(home: linked.path).hasProblem)
        #expect(!SSHConfigHosts.isExactAlias("buildbox", home: linked.path))
        // ~/.ssh/config itself a link.
        let whole = try home(config: "") { ssh in
            let real = ssh.deletingLastPathComponent().appendingPathComponent("dotfiles-config")
            try Data("Host buildbox\n".utf8).write(to: real)
            chmod(real.path, 0o600)
            try FileManager.default.createSymbolicLink(atPath: ssh.appendingPathComponent("config").path, withDestinationPath: real.path)
        }
        #expect(SSHConfigHosts.read(home: whole.path).hasProblem && !SSHConfigHosts.isExactAlias("buildbox", home: whole.path))
        // More includes than the reader takes.
        var many = "Host buildbox\n"
        for index in 0..<70 { many += "Include f\(index)\n" }
        let crowded = try home(config: many) { ssh in
            for index in 0..<70 {
                let file = ssh.appendingPathComponent("f\(index)")
                try Data("Host h\(index)\n".utf8).write(to: file)
                chmod(file.path, 0o600)
            }
        }
        #expect(SSHConfigHosts.read(home: crowded.path).hasProblem && !SSHConfigHosts.isExactAlias("buildbox", home: crowded.path))
        // M2 of the security review: an argument only ssh expands (`%` tokens, `${VAR}`, `~user`) is a problem.
        for include in ["Include hosts/%l.conf", "Include ${HOME}/x.conf", "Include ~alex/ssh.conf"] {
            let expanded = try home(config: "Host buildbox\n\(include)\n")
            #expect(SSHConfigHosts.read(home: expanded.path).hasProblem, "\(include)")
            #expect(!SSHConfigHosts.isExactAlias("buildbox", home: expanded.path), "\(include)")
        }
        // L4: a linked `~/.ssh` folder (a dotfiles setup) is refused like a linked file.
        let folderLinked = CommandTempFolder("ssh")
        let dotfiles = folderLinked.subfolder("dotfiles-ssh")
        try Data("Host buildbox\n".utf8).write(to: dotfiles.appendingPathComponent("config"))
        chmod(dotfiles.appendingPathComponent("config").path, 0o600)
        try FileManager.default.createSymbolicLink(atPath: folderLinked.url.appendingPathComponent(".ssh").path, withDestinationPath: dotfiles.path)
        #expect(SSHConfigHosts.read(home: folderLinked.path).hasProblem && !SSHConfigHosts.isExactAlias("buildbox", home: folderLinked.path))
        // An `Include` on an external or network volume is never looked up there: a problem.
        for include in ["Include /Volumes/pitbox-test-volume/config", "Include /Vol*/pitbox-test-volume/*.conf"] {
            let external = try home(config: "Host buildbox\n\(include)\n")
            #expect(SSHConfigHosts.read(home: external.path).hasProblem, "\(include)")
            #expect(!SSHConfigHosts.isExactAlias("buildbox", home: external.path), "\(include)")
        }
        // A mount-table point (a folder of the test's own stands in for one) and a link of yours into it.
        let mounted = try home(config: "")
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let mount = (Darwin.realpath(mounted.path, &buffer) != nil ? String(cString: buffer) : mounted.path) + "/automounted"
        try FileManager.default.createDirectory(atPath: mount + "/ssh", withIntermediateDirectories: true)
        try Data("Host far\n".utf8).write(to: URL(fileURLWithPath: mount + "/ssh/far.conf"))
        chmod(mount + "/ssh/far.conf", 0o600)
        try FileManager.default.createSymbolicLink(atPath: mounted.path + "/.ssh/remote", withDestinationPath: mount + "/ssh")
        let pathGuard = NetworkPathGuard(mountRoots: [mount])
        for include in ["Include \(mount)/ssh/far.conf", "Include remote/*.conf"] {
            try Data("Host buildbox\n\(include)\n".utf8).write(to: URL(fileURLWithPath: mounted.path + "/.ssh/config"))
            #expect(SSHConfigHosts.read(home: mounted.path, guard: pathGuard).hasProblem, "\(include)")
            #expect(!SSHConfigHosts.isExactAlias("buildbox", home: mounted.path, guard: pathGuard), "\(include)")
        }
        try Data("Host buildbox\nInclude \(mount)/ssh/far.conf\n".utf8).write(to: URL(fileURLWithPath: mounted.path + "/.ssh/config"))
        #expect(SSHConfigHosts.isExactAlias("far", home: mounted.path, guard: .fixed), "an ordinary local folder is read")
        // A missing include is no problem (ssh skips it too).
        let missing = try home(config: "Host buildbox\nInclude nothing-here\n")
        #expect(!SSHConfigHosts.read(home: missing.path).hasProblem && SSHConfigHosts.isExactAlias("buildbox", home: missing.path))
    }

    @Test func loginTypeLeavesOutFullLineCommentsAndRefusesTrailingOnes() {
        #expect(FrozenCommand.loginTypedText("# step one\necho a\n  # indented\necho b") == "echo a\necho b")
        #expect(FrozenCommand.loginTypedText("echo a # trailing") == nil)
        #expect(FrozenCommand.loginTypedText("echo a#b") == "echo a#b")
        // Not comments: a here-doc body and a quoted string keep their `#` lines exactly.
        let hereDoc = "cat > notes.txt <<'EOF'\n# the file's first line\nEOF"
        #expect(FrozenCommand.loginTypedText(hereDoc) == hereDoc)
        let quoted = "echo \"one\n# two\""
        #expect(FrozenCommand.loginTypedText(quoted) == quoted)
        // Leaving out a comment line that a `\` joins onto the line before would join the lines around it.
        #expect(FrozenCommand.loginTypedText("rm -rf ./build \\\n# old\n/") == nil)
        #expect(FrozenCommand.loginTypedText("echo ${(e)x}") == nil, "a text the scanner cannot read is not typed")
    }

    @Test func theScannerDecidesWhatIsACommentAndWhoReadsAHereDoc() {
        let text = "echo a # trailing\nprintf '%s\\n' \"# not a comment\"\ncat > notes.txt <<'EOF'\n# kept: the file's first line\nbody\nEOF\n"
            + "while read line; do echo \"$line\"; done <<END\nx\nEND"
        let marks = CommandScriptMarks(text: text)
        let units = Array(text.utf16)
        #expect(marks.comments.map { String(decoding: units[$0], as: UTF16.self) } == ["# trailing"])
        #expect(marks.hereDocuments.map(\.program) == ["cat", "while"])
        if let first = marks.hereDocuments.first {
            #expect(String(decoding: units[first.body], as: UTF16.self) == "# kept: the file's first line\nbody\n")
        }
        #expect(CommandScriptMarks(text: "echo ${(e)x} # c") == CommandScriptMarks.empty, "nothing is marked in a text the scanner cannot read")
    }

    @Test func hereDocBodiesSitOnTheirPanelAndOnlyShellCommentsAreDimmed() {
        let palette = CommandSheetPalette(dark: true)
        let text = "cat > notes.txt <<'EOF'\n# kept\nEOF\necho done # trailing"
        let content = CommandAreaContent.build(text: text, displayLines: [], flags: [], palette: palette)
        let shown = content.attributed.string as NSString
        #expect(content.paragraphs.map(\.number) == [1, nil, 2, 3, 4])
        #expect(content.paragraphs.count > 1 && content.paragraphs[1].role == .label)
        #expect(content.panels.map { shown.substring(with: $0) } == ["text given to cat\n# kept"])
        let bodyAt = shown.range(of: "# kept").location
        #expect(content.displayLocation[24] == bodyAt, "the body's first character maps to its place under the label")
        let bodyInk = content.attributed.attribute(.foregroundColor, at: bodyAt, effectiveRange: nil) as? NSColor
        #expect(bodyInk == palette.screenFG, "a # line in a here-doc body is text given to cat, not a comment")
        let trailing = shown.range(of: "# trailing").location
        #expect(content.attributed.attribute(.foregroundColor, at: trailing, effectiveRange: nil) as? NSColor == palette.dim)
        let echo = shown.range(of: "echo done").location
        #expect(content.attributed.attribute(.foregroundColor, at: echo, effectiveRange: nil) as? NSColor == palette.screenFG)
        #expect(content.accessibilityText.contains("text given to cat:"))
    }

    @Test func theBarSaysWhatHappenedInPitboxWords() {
        let folder = CommandTempFolder("bar")
        let binding = try? FolderBinding.bind(folder.path).get()
        guard let binding else { Issue.record("no folder"); return }
        let spec = CommandLaunchSpec(unchecked: "/bin/zsh", argv: ["/bin/zsh"], environment: [])
        let origin = CommandTabOrigin(headline: "deploy\u{202E} fix", profileName: "B Acme", machineLabel: "this Mac", folderShort: "~/x",
                                      replyTime: Date(timeIntervalSince1970: 0), offer: nil)
        let tab = CommandTab(role: .run, origin: origin, text: "true", spec: spec, folder: binding, events: { _ in })
        let start = Date(timeIntervalSince1970: 1_000)
        var content = CommandBarContent.make(tab, now: start)
        #expect(content.state == "Starting…")
        #expect(content.headline == "deploy⟨U+202E⟩ fix", "session text escaped")
        #expect(content.originTail == "B Acme · this Mac · ~/x")
        tab.spawned()
        tab.started(at: start)
        content = CommandBarContent.make(tab, now: start.addingTimeInterval(75))
        #expect(content.state == "running 1:15 · Keyboard: elsewhere, click here to type" && content.showsStop)
        tab.ended(.exited(127), at: start.addingTimeInterval(80))
        content = CommandBarContent.make(tab, now: start.addingTimeInterval(81))
        #expect(content.state.hasPrefix("Finished · exit 127 · 1 min 20 s · a program wasn't found in the clean shell's PATH"))
        #expect(content.tone == .failed && !content.showsStop)
        #expect(origin.tabTitle == "▶ deploy fix")
        #expect(origin.tooltip == "Command from Code · B Acme · \(CommandTimeFormat.clock(Date(timeIntervalSince1970: 0)))")
    }
}
