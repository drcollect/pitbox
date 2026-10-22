import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The per-session warnings deriver and the words of warnings: settings, OK through the store, deadlines, log lines
/// with labels only, Hide text.
@Suite("Warnings deriver and words", .serialized)
struct WarningDeriverTests {
    let folder = SeamFolder("warning-memory")
    let clock = ManualClock(resultNow)

    func store() -> CodeMemoryStore {
        let clock = self.clock
        return CodeMemoryStore(url: folder.file("code-memory.json"), owner: getuid(), clock: { clock.now }, writeInterval: 0.05,
                               writeMax: CodeTuning.memoryWriteMax)
    }

    func input(_ lines: [String], session: CodeSessionSnapshot, memory: CodeMemoryStore, settings: CodeSettings = CodeSettings(),
               lastGrowthAt: Date? = ago(1)) -> CodeDeriveInput {
        CodeDeriveInput(snapshot: session, digest: resultDigest(lines, lastGrowthAt: lastGrowthAt), digestVersion: 1, now: resultNow,
                        memory: memory, settings: settings, transcript: nil, sessionFile: nil, owner: getuid())
    }

    func failing(_ count: Int) -> [String] {
        runningWork((0..<count).flatMap { bash("toolu_w\($0)", at: ago(20 - Double($0)), exit: 1) })
    }

    @Test func theDeriverWritesWarningsAndOKSilencesThemThroughTheStore() throws {
        let memory = store()
        let session = resultSession("local_w1", index: 5, state: .working)
        let deriver = StuckDeriver()
        let lines = Shared<[String]>([])
        let token = CodeLog.observe { line in lines.value.append(line) }
        defer { CodeLog.stopObserving(token) }
        CodeLog.enabled = false
        var fields = CodeDerivedFields()
        deriver.derive(input(failing(4), session: session, memory: memory), into: &fields)
        let warning = try #require(fields.warnings.first)
        #expect(warning.kind == .failedInARow)
        #expect(lines.value.contains("INFO warning session=#5 kind=failed_in_a_row"))
        #expect(lines.value.allSatisfy { !$0.contains(secretWord) && !$0.contains("npm") })
        CodeWarningSilencer.silence(warning, of: session.id, memory: memory, now: resultNow)
        var again = CodeDerivedFields()
        deriver.derive(input(failing(4), session: session, memory: memory), into: &again)
        #expect(again.warnings.isEmpty, "OK silences it for the rest of the work")
        let records: [WarningSilenceRecord] = memory.read(.silenced, session: session.id) ?? []
        #expect(records.map(\.rule) == ["failed_in_a_row"])
    }

    @Test func switchedOffThereAreNone() {
        var settings = CodeSettings()
        settings.warnings.stuck = false
        var fields = CodeDerivedFields()
        StuckDeriver().derive(input(failing(5), session: resultSession(state: .working), memory: store(), settings: settings), into: &fields)
        #expect(fields.warnings.isEmpty)
    }

    @Test func silenceSetsADeadlineBeforeItIsAWarning() {
        var fields = CodeDerivedFields()
        let quiet = runningWork(bash("toolu_1", at: ago(20)), start: 25)
        StuckDeriver().derive(input(quiet, session: resultSession(state: .working), memory: store(), lastGrowthAt: ago(20)), into: &fields)
        #expect(fields.warnings.isEmpty && fields.deadlines == [ago(20).addingTimeInterval(CodeTuning.stuckSilence)])
    }

    // MARK: Words

    let failed = CodeWarning(kind: .failedInARow, since: ago(12), failures: 4, lastExitCode: 1)
    let silent = CodeWarning(kind: .silence, since: ago(72))
    let same = CodeWarning(kind: .sameFile, since: ago(5), otherSessionID: "local_x", otherHeadline: "Toy Cube · cart \u{202E}x",
                           path: "src/checkout.tsx")

    @Test func theWordsOfEachPlace() {
        #expect(CodeWarningWords.line(failed, now: resultNow) == "⚠ Looks stuck: 4 commands failed in a row")
        #expect(CodeWarningWords.line(silent, now: resultNow) == "⚠ Looks stuck: quiet for 1 h 12 min, nothing running")
        #expect(CodeWarningWords.line(same, now: resultNow) == "⚠ Also edited by “Toy Cube · cart ⟨U+202E⟩x”: src/checkout.tsx")
        #expect(CodeWarningWords.short(failed) == "⚠ stuck" && CodeWarningWords.short(same) == "⚠ same file")
        #expect(CodeWarningWords.cardTitle(silent) == "⚠ Looks stuck" && CodeWarningWords.cardTitle(same) == "⚠ Same file in two sessions")
        #expect(CodeWarningWords.reason(failed, now: resultNow) == "4 commands failed in a row; the last one ended with exit code 1.")
        #expect(CodeWarningWords.reason(silent, now: resultNow) == "Quiet for 1 h 12 min, nothing running.")
        #expect(CodeWarningWords.tag(same) == "⚠ Same file as “Toy Cube · cart ⟨U+202E⟩x”" && CodeWarningWords.tag(failed) == "⚠ Looks stuck")
        #expect(CodeWarningWords.peekLines(failed, now: resultNow, time: { _ in "13:48" })
                == ["Looks stuck: 4 commands failed in a row", "Last failure: exit code 1", "Failing since 13:48"])
        #expect(CodeWarningWords.duration(since: ago(30), now: resultNow) == "30 min")
        #expect(CodeWarningWords.duration(since: ago(120), now: resultNow) == "2 h")
    }

    @Test func theMonitorsWarningLine() throws {
        var session = resultSession(state: .working)
        #expect(CodeMonitorWarningLine.make(session, now: resultNow, textHidden: false) == nil)
        session.warnings = [failed, same]
        let line = try #require(CodeMonitorWarningLine.make(session, now: resultNow, textHidden: false))
        #expect(line.text == "⚠ Looks stuck: 4 commands failed in a row  +1" && line.short == "⚠ stuck" && line.label == "Looks stuck")
        session.warnings = [same]
        let hidden = try #require(CodeMonitorWarningLine.make(session, now: resultNow, textHidden: true))
        #expect(hidden.text.hasSuffix(": hidden") && hidden.short == "⚠ same file" && hidden.label == "Same file in two sessions")
    }

    @Test func hideTextKeepsHeadlinesAndHidesReasonsAndPaths() {
        #expect(CodeWarningWords.reason(failed, now: resultNow, hidden: true) == "hidden")
        #expect(CodeWarningWords.line(same, now: resultNow, hidden: true) == "⚠ Also edited by “Toy Cube · cart ⟨U+202E⟩x”: hidden")
        #expect(CodeWarningWords.tag(same, hidden: true) == "⚠ Same file in two sessions")
    }

    // MARK: Colours

    @Test func warningWordsReadAt4_5AndTheOutlineAt3() {
        let screen = CodeMonitorPalette.screen
        #expect(PaletteTests.contrast(CodeWarningPalette.orange, screen) >= 4.5)
        #expect(PaletteTests.contrast(CodeWarningPalette.detail, screen) >= 4.5)
        #expect(PaletteTests.contrast(CodeWarningPalette.orange, CodeWarningPalette.cardFill) >= 4.5)
        #expect(PaletteTests.contrast(CodeWarningPalette.orangeLight, PaletteTests.lightGlass) >= 4.5)
        #expect(PaletteTests.contrast(CodeWarningPalette.detailLight, PaletteTests.lightGlass) >= 4.5)
        #expect(PaletteTests.contrast(CodeWarningPalette.outline, screen) >= 3)
        #expect(PaletteTests.contrast(CodeWarningPalette.outline, CodeWarningPalette.cardFill) >= 3)
    }
}
