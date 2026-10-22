import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// The sheet over PitboxKit's real classifier: what it decides is what the sheet shows and allows, with the
/// options the sheet passes. Nothing runs: the terminal is the fake host.
@MainActor
struct CommandsRealClassifierTests {
    @Test func theUsersKeychainPromptIsNotFlaggedAndRunsAfterArming() async throws {
        let h = SheetHarness(realClassifier: ())
        let text = CommandsSheetTests.keychain
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path)))
        let model = try #require(h.model)
        #expect(model.run.title == "Yes, run this" && model.redLines.isEmpty)
        #expect(model.notes.contains { $0.hasPrefix("Stores Keychain item") && $0.contains("SERVICE_TOKEN") })
        #expect(model.notes.contains("Asks for the secret twice, with hidden input"))
        #expect(h.classifierOptions.first == CommandClassifierOptions(shell: .clean, blockKind: .tagged("bash"), recognizesFetchFile: true))
        h.advance(1)
        h.click(try #require(h.view?.runButton))
        #expect(await waitUntil(5) { h.host.requests.count == 1 })
        #expect(h.host.requests.first?.descriptor.text == text, "exactly the reviewed text")
    }

    @Test func hiddenCharactersAreBlockedShownEscapedAndCopiedCleaned() async throws {
        let h = SheetHarness(realClassifier: ())
        let text = "echo \"report\u{202E}txt.exe\""
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path)))
        let model = try #require(h.model)
        #expect(!model.run.state.isShown && !model.type.state.isShown && !model.copy.state.isShown)
        #expect(model.copyCleaned.state == .on)
        #expect(model.cleaned?.text == "echo \"reporttxt.exe\"" && model.cleaned?.marks == [12])
        let area = try #require(h.view?.commandArea)
        #expect(area.content.attributed.string.contains("⟨U+202E⟩"))
        h.advance(1)
        h.click(try #require(h.view?.copyCleanedButton))
        #expect(h.pasteboard.string(forType: .string) == "echo \"reporttxt.exe\"")
        #expect(h.host.requests.isEmpty)
    }

    @Test func aHereDocIntoAFileIsShownOnItsPanelAndTheLoginShellPassesItsShell() async throws {
        let h = SheetHarness(realClassifier: (), shell: .login)
        let text = "cat > notes.txt <<'EOF'\n# not a comment\nEOF"
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path)))
        #expect(h.classifierOptions.allSatisfy { $0.shell == .login })
        let area = try #require(h.view?.commandArea)
        let shown = area.content.attributed.string as NSString
        #expect(area.content.panels.map { shown.substring(with: $0) } == ["text given to cat\n# not a comment"])
        #expect(h.sheet?.state.typedText == text, "the body's # line is typed as it is")
    }
}
