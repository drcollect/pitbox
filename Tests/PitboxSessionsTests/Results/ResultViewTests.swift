import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The arming of open buttons, the words of results and their colours.
@Suite("Result buttons")
struct ResultViewTests {
    // MARK: Arming, pure

    @Test func aButtonArmsAfterPointEightSeconds() {
        var arming = OpenButtonArming()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 24)
        arming.layout(["a": rect], now: 10, pointer: nil)
        #expect(!arming.accepts("a", downAt: 10.5, downPoint: CGPoint(x: 5, y: 5), upPoint: CGPoint(x: 6, y: 6)))
        #expect(arming.accepts("a", downAt: 10.9, downPoint: CGPoint(x: 5, y: 5), upPoint: CGPoint(x: 6, y: 6)))
        #expect(!arming.accepts("a", downAt: 11, downPoint: CGPoint(x: 5, y: 5), upPoint: CGPoint(x: 150, y: 6)), "up off the button")
        #expect(!arming.accepts("a", downAt: 11, downPoint: CGPoint(x: 150, y: 5), upPoint: CGPoint(x: 6, y: 6)), "down off it")
    }

    @Test func aLayoutChangeReArmsOnlyWhatItMoved() {
        var arming = OpenButtonArming()
        arming.layout(["a": CGRect(x: 0, y: 0, width: 100, height: 24), "b": CGRect(x: 110, y: 0, width: 100, height: 24)], now: 0, pointer: nil)
        arming.layout(["a": CGRect(x: 0, y: 0, width: 100, height: 24), "b": CGRect(x: 110, y: 30, width: 100, height: 24)], now: 5, pointer: nil)
        #expect(arming.isArmed("a", now: 5.1), "a did not move")
        #expect(!arming.isArmed("b", now: 5.5) && arming.isArmed("b", now: 5.9), "a press 0.5 s after the move is ignored, 0.9 s counts")
    }

    @Test func aButtonThatAppearsUnderThePointerSwallowsPressesUntilThePointerLeaves() {
        var arming = OpenButtonArming()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 24)
        arming.layout(["a": rect], now: 0, pointer: CGPoint(x: 10, y: 10))
        #expect(!arming.accepts("a", downAt: 3, downPoint: CGPoint(x: 10, y: 10), upPoint: CGPoint(x: 10, y: 10)))
        arming.pointerMoved(to: CGPoint(x: 20, y: 12))
        #expect(!arming.isArmed("a", now: 3), "still inside its place")
        arming.pointerMoved(to: CGPoint(x: 300, y: 12))
        arming.pointerMoved(to: CGPoint(x: 20, y: 12))
        #expect(arming.accepts("a", downAt: 3, downPoint: CGPoint(x: 20, y: 12), upPoint: CGPoint(x: 21, y: 12)))
        arming.rearmAll(now: 10, pointer: CGPoint(x: 20, y: 12))
        #expect(!arming.isArmed("a", now: 11), "re-armed under the pointer")
    }

    // MARK: The view

    @MainActor
    @Test func theViewCountsOnlyArmedPressesAndCopyLinkActsAtOnce() {
        let clock = Shared<TimeInterval>(100)
        let open = CodeResultButton(resultID: "r1", action: .open, title: "↗ Open artifact", tone: .result, arms: true)
        let copy = CodeResultButton(resultID: "r2", action: .copyLink, title: "Copy link", tone: .neutral, arms: false)
        let view = CodeResultButtonsView(buttons: [open, copy], width: 400)
        view.clock = { clock.value }
        view.update(buttons: [copy, open], note: "+2 more")
        var pressed: [String] = []
        view.onPress = { pressed.append($0.id) }
        guard let openRect = view.frames[open.id], let copyRect = view.frames[copy.id] else {
            Issue.record("both buttons are laid out")
            return
        }
        // Just laid out: the open button ignores a press; Copy link takes it.
        view.press(down: CGPoint(x: openRect.midX, y: openRect.midY))
        view.release(up: CGPoint(x: openRect.midX, y: openRect.midY))
        view.press(down: CGPoint(x: copyRect.midX, y: copyRect.midY))
        view.release(up: CGPoint(x: copyRect.midX, y: copyRect.midY))
        #expect(pressed == [copy.id])
        clock.value += 0.9
        view.press(down: CGPoint(x: openRect.midX, y: openRect.midY))
        view.release(up: CGPoint(x: openRect.midX, y: openRect.midY))
        #expect(pressed == [copy.id, open.id])
    }

    @MainActor
    @Test func aRowInsertedUnderThePointerSwallowsTheFirstPress() {
        let clock = Shared<TimeInterval>(0)
        let open = CodeResultButton(resultID: "r1", action: .open, title: "▤ Open notes.md", tone: .result, arms: true)
        let view = CodeResultButtonsView(buttons: [], width: 300)
        view.clock = { clock.value }
        view.pointerLocation = { CGPoint(x: 20, y: 12) }
        view.update(buttons: [open], note: nil)
        var pressed = 0
        view.onPress = { _ in pressed += 1 }
        clock.value = 2
        view.press(down: CGPoint(x: 20, y: 12))
        view.release(up: CGPoint(x: 20, y: 12))
        #expect(pressed == 0)
        view.pointer(at: CGPoint(x: 290, y: 40))
        view.pointer(at: CGPoint(x: 20, y: 12))
        view.press(down: CGPoint(x: 20, y: 12))
        view.release(up: CGPoint(x: 20, y: 12))
        #expect(pressed == 1)
    }

    // MARK: Words

    @Test func theWordsOfEachKind() {
        func titles(_ kind: CodeResult.Kind, label: String = "report.md", hidden: Bool = false) -> [String] {
            CodeResultWords.buttons(for: CodeResult(kind: kind, origin: .written, path: "/x/\(label)", label: label), hidden: hidden).map(\.title)
        }
        #expect(titles(.preview, label: "localhost:5173") == ["↗ Open preview · localhost:5173"])
        #expect(titles(.artifact) == ["↗ Open artifact"])
        #expect(titles(.document) == ["▤ Open report.md"])
        #expect(titles(.webDocument, label: "index.html") == ["▤ Preview index.html", "Show in Finder"])
        #expect(titles(.otherFile, label: "run.sh") == ["▤ Show run.sh in Finder"])
        #expect(titles(.serverFile, label: "demo.mp4") == ["⤓ Fetch demo.mp4…"])
        #expect(titles(.serverPreview, label: "localhost:5173") == ["Copy link"])
        #expect(titles(.mentionedPath).isEmpty)
        #expect(titles(.document, hidden: true) == ["▤ Open hidden"])
        let long = "a-very-long-report-name-for-the-checkout-tests.md"
        let cut = CodeResultWords.fileName(long, hidden: false)
        #expect(cut.count == 32 && cut.hasPrefix("a-very-long") && cut.hasSuffix("tests.md") && cut.contains("…"))
        #expect(CodeResultWords.fileName("r\u{202E}dm.exe", hidden: false).contains("⟨U+202E⟩"), "B1 shown escaped")
        let arms = CodeResultWords.buttons(for: CodeResult(kind: .serverFile, origin: .handedOver, label: "x.md"))
        #expect(arms.first?.arms == false, "Fetch… opens a sheet with its own arming")
    }

    @Test func theLineAndThePeekLines() {
        let results = [CodeResult(kind: .artifact, origin: .publishedArtifact, url: URL(string: "https://claude.ai/artifact/abcDEF12"), label: "artifact"),
                       CodeResult(kind: .document, origin: .written, path: "/x/r.md", label: "r.md"),
                       CodeResult(kind: .serverPreview, origin: .replyLink, url: URL(string: "http://localhost:5173/"), label: "localhost:5173"),
                       CodeResult(kind: .earlierArtifact, origin: .publishedArtifact, url: URL(string: "https://claude.ai/artifact/oldOLD12"), label: "artifact")]
        let line = CodeResultWords.firstLine(results)
        #expect(line?.button.title == "↗ Open artifact" && line?.more == "+1 more")
        #expect(CodeResultWords.otherLinks(2) == "2 other links in the reply (open them from the session)")
        #expect(CodeResultWords.otherLinks(1) == "1 other link in the reply (open them from the session)")
        #expect(CodeResultWords.otherLinks(0) == nil)
        #expect(CodeResultWords.serverPreviewLine(results[2], alias: "buildbox") == "Preview on buildbox: localhost:5173")
        let note = CodeResult(kind: .mentionedPath, origin: .handedOver, path: "/Volumes/x/y.md", label: "/Volumes/x/y.md",
                              note: LocalReportCheck.networkNote)
        #expect(CodeResultWords.pathLine(note) == "/Volumes/x/y.md · not checked: network path")
    }

    // MARK: The monitor's line and the peek's rows (the block's slots)

    @Test func theMonitorsResultLineIsTheFirstButtonAndHowManyMore() throws {
        let results = [CodeResult(kind: .webDocument, origin: .written, path: "/x/index.html", label: "index.html"),
                       CodeResult(kind: .serverFile, origin: .handedOver, path: "/h/d.mp4", label: "d.mp4", toolUseID: "t"),
                       CodeResult(kind: .earlierArtifact, origin: .publishedArtifact, url: URL(string: "https://claude.ai/artifact/oldOLD12"),
                                  label: "artifact")]
        let line = try #require(CodeMonitorResultLine.make(resultSession(results: results), textHidden: false))
        #expect(line.button.title == "▤ Preview index.html" && line.button.action == .preview && line.button.arms)
        #expect(line.more == "+1 more" && line.label == "Preview the page")
        #expect(CodeMonitorResultLine.make(resultSession(results: results), textHidden: true) == nil, "Hide text: headline and state only")
        #expect(CodeMonitorResultLine.make(resultSession(results: [results[2]]), textHidden: false) == nil, "earlier artifacts are peek only")
    }

    @Test func thePeeksRowsInOrder() {
        let results = [CodeResult(kind: .document, origin: .written, path: "/x/r.md", label: "r.md"),
                       CodeResult(kind: .serverPreview, origin: .replyLink, url: URL(string: "http://localhost:5173/"), label: "localhost:5173"),
                       CodeResult(kind: .mentionedPath, origin: .replyText, path: "/etc/hosts", label: "/etc/hosts"),
                       CodeResult(kind: .earlierArtifact, origin: .publishedArtifact, url: URL(string: "https://claude.ai/artifact/oldOLD12"),
                                  label: "artifact", at: resultNow)]
        let rows = CodeResultPeekRows.rows(results: results, otherLinkCount: 2, alias: "buildbox", hidden: false, time: { _ in "14:00" })
        guard rows.count == 8 else { Issue.record("\(rows)"); return }
        #expect(rows[0] == .label("Results"))
        if case .buttons(let work) = rows[1] { #expect(work.map(\.title) == ["▤ Open r.md"]) } else { Issue.record("\(rows[1])") }
        #expect(rows[2] == .text("Preview on buildbox: localhost:5173", dim: false))
        if case .buttons(let copy) = rows[3] { #expect(copy.map(\.title) == ["Copy link"] && copy[0].arms == false) }
        #expect(rows[4] == .text("2 other links in the reply (open them from the session)", dim: true))
        #expect(rows[5] == .text("/etc/hosts", dim: true))
        #expect(rows[6] == .label("Earlier artifacts"))
        if case .buttons(let earlier) = rows[7] { #expect(earlier.map(\.title) == ["↗ Open artifact · 14:00"]) }
        #expect(CodeResultPeekRows.rows(results: [], otherLinkCount: 0, alias: nil, hidden: false, time: { _ in "" }).isEmpty)
    }

    // MARK: Colours

    typealias P = CodeResultPalette

    @Test func wordsReadAt4_5AndOutlinesAt3() {
        let screen = CodeMonitorPalette.screen
        for tone in [CodeResultButton.Tone.result, .file, .neutral] {
            let dark = P(dark: true), light = P(dark: false)
            #expect(PaletteTests.contrast(dark.text(tone), dark.fill(tone)) >= 4.5, "\(tone) dark")
            #expect(PaletteTests.contrast(light.text(tone), light.fill(tone)) >= 4.5, "\(tone) light")
            #expect(PaletteTests.contrast(dark.outline(tone), screen) >= 3, "\(tone) outline on the screen")
            #expect(PaletteTests.contrast(light.outline(tone), PaletteTests.lightGlass) >= 3, "\(tone) outline on the light glass")
        }
        #expect(PaletteTests.contrast(P.resultLink, screen) >= 4.5 && PaletteTests.contrast(P.file, screen) >= 4.5)
        #expect(PaletteTests.contrast(P.resultLinkLight, PaletteTests.lightGlass) >= 4.5)
        #expect(PaletteTests.contrast(P.fileLight, PaletteTests.lightGlass) >= 4.5)
        #expect(PaletteTests.contrast(P.dimDark, screen) >= 4.5 && PaletteTests.contrast(P.dimLight, PaletteTests.lightGlass) >= 4.5)
    }

    @Test func thePreviewSitsBesideTheStripAndTheSheetNeverUnderThePointer() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let strip = CGRect(x: 1398, y: 0, width: 330, height: 1080)
        let anchor = CGRect(x: 1450, y: 600, width: 160, height: 20)
        let size = CGSize(width: 760, height: 620)
        let plain = CodeWebPreviewPlacement.frame(size: size, anchor: anchor, strip: strip, screen: screen, pointer: nil)
        #expect(plain.maxX == strip.minX - CodeWebPreviewPlacement.gap, "left of the strip")
        #expect(abs(plain.midY - anchor.midY) < 1, "level with the button")
        // A fetched file's Preview from the command sheet: beside the sheet too, covering neither.
        let sheet = CGRect(x: 968, y: 300, width: 420, height: 500)
        let beside = CodeWebPreviewPlacement.frame(size: size, anchor: sheet, strip: strip, beside: sheet, screen: screen, pointer: nil)
        #expect(!beside.intersects(sheet) && !beside.intersects(strip))
        #expect(beside.maxX == sheet.minX - CodeWebPreviewPlacement.gap)
        // Never under the pointer that was already there.
        let pointer = CGPoint(x: plain.midX, y: plain.midY)
        let moved = CodeWebPreviewPlacement.frame(size: size, anchor: anchor, strip: strip, screen: screen, pointer: pointer)
        #expect(!moved.insetBy(dx: -4, dy: -4).contains(pointer))
        // A strip on the left edge: the preview opens to its right.
        let left = CGRect(x: 0, y: 0, width: 330, height: 1080)
        let right = CodeWebPreviewPlacement.frame(size: size, anchor: anchor, strip: left, screen: screen, pointer: nil)
        #expect(right.minX == left.maxX + CodeWebPreviewPlacement.gap && screen.contains(right))
    }
}
