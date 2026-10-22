import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// Renders the sheet off-screen for people to look at: a not-flagged command, a risky one with two red lines, a blocked
/// one with hidden characters, an unclear-machine one, the Fetch file sheet, and a command tab's bar. PNGs go to
/// `PITBOX_SHEET_PNG_DIR`, else the test artifact folder.
@MainActor
@Suite(.serialized)
struct CommandsSheetVisualTests {
    static var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["PITBOX_SHEET_PNG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return artifactDirectory()
    }

    private func render(_ h: SheetHarness, name: String, dark: Bool = true) throws {
        let view = try #require(h.view)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.palette = CommandSheetPalette(dark: dark)
        let size = view.bounds.size
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // Composite over a desk-like backdrop so the card's corners show.
        let canvas = NSImage(size: CGSize(width: size.width + 40, height: size.height + 40))
        canvas.lockFocus()
        (dark ? NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.87, blue: 0.9, alpha: 1)).setFill()
        CGRect(origin: .zero, size: canvas.size).fill()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.draw(in: CGRect(x: 20, y: 20, width: size.width, height: size.height))
        canvas.unlockFocus()
        let tiff = try #require(canvas.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: Self.outputDirectory.appendingPathComponent(name))
    }

    @Test func notFlaggedCommand() async throws {
        let text = #"security add-generic-password -U -a "$USER" -s SERVICE_TOKEN -w"#
        let h = SheetHarness(assess: { text, _ in
            SheetFixtures.notFlagged(text, notes: [CommandNote(kind: .storesKeychainItem, words: "Stores Keychain item SERVICE_TOKEN"),
                                                  CommandNote(kind: .asksSecret, words: "Asks twice for a secret, with hidden input")],
                                     programs: ["security"])
        })
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.advance(1)
        h.controller.refresh()
        try render(h, name: "sheet-not-flagged.png")
        try render(h, name: "sheet-not-flagged-light.png", dark: false)
    }

    /// The real classifier's reading: a trailing comment dimmed, a here-doc body on its panel (its `#` line is text
    /// given to cat, not a comment).
    @Test func hereDocCommandWithTheRealClassifier() async throws {
        let h = SheetHarness(realClassifier: ())
        let text = "mkdir -p notes # the drafts folder\ncat > notes/release.md <<'EOF'\n# Release 1.4\n- fixes the login loop\nEOF"
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path), headline: "release notes",
                                            nickname: "quiet heron", asked: "write the release notes into notes/",
                                            caption: "This writes the notes file:"))
        h.advance(1)
        h.controller.refresh()
        try render(h, name: "sheet-heredoc.png")
    }

    @Test func riskyCommandWithTwoRedLines() async throws {
        let text = "cd ~/my\\ project\nrm -rf build   # the old output\nswift build"
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text, programs: ["cd", "rm", "swift"])
            a.commandClass = .risky
            a.flags = [SheetFixtures.flag(.r2, "Deletes files and folders; not to the Trash: build", "rm -rf build", in: text, line: 2),
                       SheetFixtures.flag(.r18, "Runs code from ~/my project (Package.swift) that is not shown here", "swift build", in: text, line: 3)]
            a.notes = [CommandNote(kind: .runsSeveral, words: "Runs 3 commands; later lines run even if one fails")]
            a.lineCount = 3
            a.commandCount = 3
            return a
        })
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path), headline: "Docs site · build cleanup",
                                            nickname: "quiet fern", asked: "the build folder is stale, can you clean it?",
                                            caption: "Then rebuild from scratch:"))
        let first = try #require(h.model?.redLines.first?.key)
        h.advance(1)
        h.controller.toggleTick(first)
        try render(h, name: "sheet-risky.png")
    }

    @Test func blockedCommandWithHiddenCharacters() async throws {
        let text = "echo \"report\u{202E}fdp.exe\"\u{00A0}&& open ~/Downloads/r\u{00E9}sum\u{00E9}.pdf"
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text, programs: ["echo", "open"])
            a.commandClass = .blocked
            a.flags = [CommandFlag(rule: .b1, words: "Hidden or deceptive characters: U+202E, U+00A0", line: 1, utf16Range: 0..<0)]
            return a
        })
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path), headline: "invoice \u{202E}cod.exe report"))
        try render(h, name: "sheet-blocked-hidden.png")
    }

    @Test func unclearMachineCommand() async throws {
        let text = "tail -n 50 /var/log/app.log > ~/Downloads/app-tail.txt"
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text, programs: ["tail"])
            a.commandClass = .unclearMachine
            a.machine = .unclear
            a.machineReason = "Unclear: it names /var/log (a server path) and ~/Downloads (this Mac)."
            a.replyClaim = "on the server"
            a.notes = [CommandNote(kind: .writes, words: "Writes ~/Downloads/app-tail.txt")]
            return a
        })
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(place: .ssh, alias: "buildbox"), headline: "buildbox · log triage",
                                            caption: "Run this on the server to grab the log tail:"))
        try render(h, name: "sheet-unclear.png")
    }

    @Test func fetchFileSheet() async throws {
        let text = "scp 'alex@buildbox:/home/alex/drafts/release-notes.md' ~/Downloads/"
        let plan = FetchPlan(alias: "buildbox", loginUser: "buildbox", configUser: "buildbox", replyUser: "alex", proxyNote: nil,
                             remotePath: "/home/alex/drafts/release-notes.md", fileName: "release-notes.md", previewName: "release-notes.md",
                             arguments: CommandsFetchSheetTests.scpArguments(user: "buildbox", staging: "<Pitbox staging folder>"),
                             configFingerprint: "x")
        let runner = FakeFetchRunner { _ in .success(plan) }
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text, programs: ["scp"])
            a.commandClass = .fetchFile
            a.fetch = FetchFileRequest(alias: "buildbox", replyUser: "alex", remotePath: "/home/alex/drafts/release-notes.md",
                                       destinationName: nil)
            a.machineReason = "For this Mac: it copies from buildbox."
            return a
        }, fetchRunner: runner)
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(place: .ssh, alias: "buildbox"), headline: "Docs site · link checker",
                                            nickname: "quiet fern", asked: "can you send me the release notes?", caption: nil))
        _ = await waitUntil(5) { if case .planned? = h.sheet?.state.fetch?.phase { return true }; return false }
        try render(h, name: "sheet-fetch.png")
    }

    /// A result fetch: the same sheet for a file the session handed over, with no command text.
    @Test func resultFetchSheet() async throws {
        let runner = FakeFetchRunner { _ in .success(SheetFixtures.resultPlan()) }
        let h = SheetHarness(assess: { _, _ in CommandSheetState.noReading }, fetchRunner: runner)
        await h.presentFetch()
        h.advance(1)
        h.controller.refresh()
        try render(h, name: "sheet-result-fetch.png")
    }

    @Test func supersededCommand() async throws {
        let text = "rm -rf build"
        let s = CommandOffer.Supersession(newerReplies: 1, latestAt: Date(timeIntervalSince1970: 1_760_966_400),
                                          replies: [.init(at: Date(timeIntervalSince1970: 1_760_966_400), origin: .human,
                                                          head: "Wait: don't run that, it deletes your cache too.\nUse `swift package clean` instead.")],
                                          sessionIsWorking: false, readWebSince: true, filesChangedSince: ["release.sh", "Package.swift"],
                                          filesChangedCount: 3, backgroundTasksFinishedSince: 2)
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text, programs: ["rm"])
            a.commandClass = .risky
            a.flags = [SheetFixtures.flag(.r2, "Deletes files and folders; not to the Trash: build", "rm -rf build", in: text, line: 1)]
            return a
        })
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path), supersession: s))
        try render(h, name: "sheet-superseded.png")
    }

    /// What a render of the console showing a command tab gets, with `allowSnapshots` on: the cover and
    /// "▶ Command" in the strip, never the output, the bar or the headline.
    @Test func consoleSnapshotWithACommandTab() throws {
        let h = CommandConsoleHarness(settingsJSON: #"{ "allowSnapshots": true }"#, size: CGSize(width: 618, height: 400))
        h.start(try h.request("echo secret-output", headline: "private client headline"))
        h.commands.processes.first?.emit("secret-output\r\n")
        let url = Self.outputDirectory.appendingPathComponent("console-command-snapshot.png")
        #expect(renderPNG(of: h.view, over: (false, h.view.bounds.size), to: url))
        #expect(h.view.strip.items.last?.title == "▶ private client headli…", "the live strip keeps the real title, at most 24 characters")
    }

    @Test func commandTabBar() throws {
        let bar = CommandTabBar(frame: CGRect(x: 0, y: 0, width: 600, height: CommandTabBar.height))
        bar.palette = TerminalTheme.dark
        bar.content = CommandBarContent(headline: "service token setup", originTail: "A Work · this Mac · ~/my project",
                                        state: "running 0:12 · asks for hidden input, click here to type", tone: .running,
                                        showsStop: true, stopTitle: "Stop")
        bar.layoutSubtreeIfNeeded()
        let rep = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
        bar.cacheDisplay(in: bar.bounds, to: rep)
        // Over the terminal's own tint, as in the console.
        let canvas = NSImage(size: bar.bounds.size)
        canvas.lockFocus()
        TerminalTheme.dark.background.withAlphaComponent(0.9).setFill()
        CGRect(origin: .zero, size: canvas.size).fill()
        let image = NSImage(size: bar.bounds.size)
        image.addRepresentation(rep)
        image.draw(in: CGRect(origin: .zero, size: bar.bounds.size))
        canvas.unlockFocus()
        let tiff = try #require(canvas.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: Self.outputDirectory.appendingPathComponent("command-tab-bar.png"))
    }
}
