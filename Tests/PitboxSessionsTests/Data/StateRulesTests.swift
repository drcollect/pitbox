import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

@Suite("State rules")
struct StateRulesTests {
    let now = fixtureNow

    func file(_ change: (inout ClaudeSessionFile) -> Void = { _ in }) -> ClaudeSessionFile {
        var file = ClaudeSessionFile()
        file.permissionMode = "default"
        file.lastActivityAt = now.addingTimeInterval(-3600)
        change(&file)
        return file
    }

    func finishedTurn(at: Date) -> TurnTracker {
        track([Line.user("Go", uuid: "u1", at: at), Line.text("Done", uuid: "a1", at: at)])
    }

    func evaluate(_ file: ClaudeSessionFile?, _ tracker: TurnTracker?, transcript: Date? = nil, sessionFile: Date? = nil,
                  now: Date? = nil) -> SessionStateResult {
        SessionStateRules.evaluate(SessionStateInput(file: file, tracker: tracker, transcriptModified: transcript,
                                                     sessionFileModified: sessionFile, now: now ?? self.now))
    }

    func summary(_ category: String, needs: String? = nil, uuid: String = "a1") -> ClaudeSessionFile.Summary {
        ClaudeSessionFile.Summary(category: category, detail: "TL;DR \(secretWord)", needsAction: needs, summarizesUUID: uuid)
    }

    @Test func finishedTurnsTakeTheSummarysState() {
        let ended = now.addingTimeInterval(-120)
        let tracker = finishedTurn(at: ended)
        let review = evaluate(file { $0.summary = summary("review_ready") }, tracker, transcript: ended)
        #expect(review.state == .reviewReady && review.tldr == "TL;DR \(secretWord)" && review.finished)
        #expect(evaluate(file { $0.summary = summary("completed") }, tracker, transcript: ended).state == .done)
        #expect(evaluate(file { $0.summary = summary("something_new") }, tracker, transcript: ended).state == .done)
        let none = evaluate(file(), tracker, transcript: ended)
        #expect(none.state == .doneNoSummary && none.word == "done · no summary" && none.tldr == nil)
        #expect(none.turnFinishedAt == ended)
    }

    @Test func aSummaryOfAnotherEntryIsNotCurrent() {
        let ended = now.addingTimeInterval(-120)
        let result = evaluate(file { $0.summary = summary("completed", uuid: "older") }, finishedTurn(at: ended), transcript: ended)
        #expect(result.state == .doneNoSummary && result.tldr == nil)
    }

    @Test func theSummaryHasTenSecondsToArrive() {
        let ended = now.addingTimeInterval(-4)
        let early = evaluate(file(), finishedTurn(at: ended), transcript: ended)
        #expect(early.state == .working && early.finished)
        #expect(early.nextChange == ended.addingTimeInterval(10))
        let late = evaluate(file(), finishedTurn(at: ended), transcript: ended, now: now.addingTimeInterval(7))
        #expect(late.state == .doneNoSummary)
        // An SSH server clock ahead of the Mac: the end counts no later than the mirror's write.
        let ahead = evaluate(file(), finishedTurn(at: now.addingTimeInterval(600)), transcript: now.addingTimeInterval(-30))
        #expect(ahead.state == .doneNoSummary)
    }

    @Test func needsYouComesFirst() {
        let ended = now.addingTimeInterval(-60)
        let tracker = finishedTurn(at: ended)
        #expect(evaluate(file { $0.summary = summary("blocked", needs: "Paste the key") }, tracker, transcript: ended).state == .needsYou)
        #expect(evaluate(file { $0.summary = summary("completed", needs: "Look at this") }, tracker, transcript: ended).state == .needsYou)
        #expect(evaluate(file { $0.summary = summary("need_input") }, tracker, transcript: ended).state == .needsYou)
        #expect(evaluate(file { $0.wrapUpNeedsUser = true }, tracker, transcript: ended).state == .needsYou)
        let asking = track([Line.user("Go", uuid: "u1", at: ended), Line.toolUse("AskUserQuestion", id: "q", uuid: "a1", at: ended)])
        let result = evaluate(file { $0.hasError = true }, asking, transcript: ended)
        #expect(result.state == .needsYou && result.askLine == nil)
        let blocked = evaluate(file { $0.summary = summary("blocked", needs: "Paste the key") }, tracker, transcript: ended)
        #expect(blocked.askLine == "Paste the key")
    }

    @Test func problemsSayFailedOrStopped() {
        let ended = now.addingTimeInterval(-60)
        let tracker = finishedTurn(at: ended)
        let failed = evaluate(file { $0.hasError = true }, tracker, transcript: ended)
        #expect(failed.state == .problem && failed.word == "failed")
        #expect(evaluate(file { $0.errorCategory = "overloaded" }, tracker, transcript: ended).word == "failed")
        #expect(evaluate(file { $0.summary = summary("failed") }, tracker, transcript: ended).word == "failed")
        let stopped = evaluate(file { $0.interruptedAwaitingPerson = true }, tracker, transcript: ended)
        #expect(stopped.state == .problem && stopped.word == "stopped")
        #expect(evaluate(file { $0.stoppedUntilPersonSends = true }, tracker, transcript: ended).word == "stopped")
    }

    @Test func aLongToolRunStaysWorkingThenTurnsQuietNeverRed() {
        let started = now.addingTimeInterval(-240)
        let tracker = track([Line.user("Run it", uuid: "u1", at: started),
                             Line.toolUse("Bash", id: "t1", uuid: "a1", at: started, input: ["description": "Sleep four minutes"])])
        let bypass = file { $0.permissionMode = "bypassPermissions" }
        let working = evaluate(bypass, tracker, transcript: started)
        #expect(working.state == .working && working.nowLine == "running: Sleep four minutes")
        #expect(working.nextChange == started.addingTimeInterval(30 * 60))
        let quiet = evaluate(bypass, tracker, transcript: started, now: started.addingTimeInterval(31 * 60))
        #expect(quiet.state == .quietUnfinished && quiet.word == "quiet · turn not finished")
        #expect(quiet.quietSince == started)
    }

    @Test func maybeNeedsYouIsASoftHintAfterThirtySilentSeconds() {
        let started = now.addingTimeInterval(-45)
        let tracker = track([Line.user("Edit", uuid: "u1", at: started), Line.toolUse("Edit", id: "t1", uuid: "a1", at: started)])
        let quietFiles = file { $0.lastActivityAt = started }
        #expect(evaluate(quietFiles, tracker, transcript: started, sessionFile: started).state == .maybeNeedsYou)
        // The SSH session file moving every few seconds means the session works (measured).
        let moving = file { $0.lastActivityAt = started }
        #expect(evaluate(moving, tracker, transcript: started, sessionFile: now.addingTimeInterval(-5)).state == .working)
        #expect(evaluate(file { $0.lastActivityAt = started; $0.permissionMode = "auto" }, tracker, transcript: started).state == .working)
        let recent = evaluate(quietFiles, tracker, transcript: now.addingTimeInterval(-10), sessionFile: started)
        #expect(recent.state == .working && recent.nextChange == now.addingTimeInterval(20))
        // A subagent works in its own transcript.
        let agent = track([Line.user("Go", uuid: "u1", at: started), Line.toolUse("Agent", id: "t1", uuid: "a1", at: started)])
        #expect(evaluate(quietFiles, agent, transcript: started, sessionFile: started).state == .working)
    }

    @Test func aRunningTurnOnTheServerIsNotFinished() {
        let ended = now.addingTimeInterval(-60)
        let result = evaluate(file { $0.midTurn = true; $0.lastActivityAt = now.addingTimeInterval(-3) }, finishedTurn(at: ended),
                              transcript: ended)
        #expect(result.state == .working && !result.finished)
    }

    @Test func quietDimsFinishedSessions() {
        let ended = now.addingTimeInterval(-40 * 60)
        let result = evaluate(file { $0.summary = summary("completed"); $0.lastActivityAt = ended }, finishedTurn(at: ended),
                              transcript: ended)
        #expect(result.state == .done && result.quietSince == ended)
    }

    @Test func missingFilesAreUnknown() {
        #expect(evaluate(nil, finishedTurn(at: now), transcript: now).state == .unknown)
        let noTranscript = evaluate(file(), nil)
        #expect(noTranscript.state == .unknown && noTranscript.word == "status unknown" && !noTranscript.finished)
    }

    @Test func headlinesAndNicknames() {
        #expect(TitleRules.split(title: "buildbox \u{00B7} Fix the build (quiet fern)", hosts: ["buildbox"]) == ("Fix the build", "quiet fern"))
        #expect(TitleRules.split(title: "buildbox \u{00B7} Fix", hosts: []) == ("buildbox \u{00B7} Fix", nil))
        #expect(TitleRules.split(title: "Fix the build (fork)", hosts: []) == ("Fix the build (fork)", nil))
        #expect(TitleRules.split(title: "(calm otter)", hosts: []) == ("(calm otter)", nil))
        #expect(TitleRules.split(title: "Tidy\u{0007}  up (calm otter)", hosts: []) == ("Tidy up", "calm otter"))
    }
}
