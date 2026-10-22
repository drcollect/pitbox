import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Bash calls for the stuck rules, in the measured shapes: an error's content starts `Exit code <N>`, its
/// `toolUseResult` is a string; a success's is an object.
func bash(_ id: String, at: Date, exit: Int? = nil, content: String? = nil, denial: String? = nil, background: Bool = false) -> [String] {
    var lines = [SeamLine.bash("npm test \(secretWord)", description: "Run the tests", id: id, uuid: "a-\(id)", at: at,
                               background: background ? true : nil)]
    if let exit {
        lines.append(SeamLine.result(id, uuid: "r-\(id)", at: at, content: content ?? "Exit code \(exit)\nFAIL \(secretWord)", isError: true,
                                     toolUseResult: "Error: Exit code \(exit)", denial: denial))
    } else if let content {
        lines.append(SeamLine.result(id, uuid: "r-\(id)", at: at, content: content, isError: true, toolUseResult: "Error: \(content)",
                                     denial: denial))
    } else if background {
        lines.append(SeamLine.result(id, uuid: "r-\(id)", at: at, content: "Command running in background", isError: false,
                                     toolUseResult: ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": "bg-\(id)"]))
    } else {
        lines.append(SeamLine.result(id, uuid: "r-\(id)", at: at, content: "ok", isError: false,
                                     toolUseResult: ["stdout": "ok", "stderr": "", "interrupted": false]))
    }
    return lines
}

/// The user's message `start` minutes ago, then `items`: a running turn.
func runningWork(_ items: [String], start: Double = 30) -> [String] {
    [Line.user("Fix the \(secretWord) tests", uuid: "u-work", at: ago(start))] + items
}

/// "Looks stuck".
@Suite("Looks stuck")
struct StuckDetectorTests {
    let working = resultSession(state: .working)

    func evaluate(_ lines: [String], session: CodeSessionSnapshot? = nil, progress: CodeProgress? = nil, copied: Set<String> = [],
                  lastGrowthAt: Date? = ago(1), lastActivityMovedAt: Date? = nil, silenced: [WarningSilenceRecord] = []) -> StuckDetector.Output {
        StuckDetector.evaluate(snapshot: session ?? working,
                               digest: resultDigest(lines, copied: copied, lastGrowthAt: lastGrowthAt, lastActivityMovedAt: lastActivityMovedAt),
                               progress: progress, now: resultNow, silenced: silenced)
    }

    func failures(_ count: Int, from start: Double = 20, prefix: String = "f") -> [String] {
        (0..<count).flatMap { bash("toolu_\(prefix)\($0)", at: ago(start - Double($0)), exit: $0 == count - 1 ? 2 : 1) }
    }

    @Test func fourFailuresInARowLookStuck() throws {
        let warning = try #require(evaluate(runningWork(failures(4))).warnings.first)
        #expect(warning.kind == .failedInARow && warning.failures == 4 && warning.lastExitCode == 2)
        #expect(warning.since == ago(20), "since the first failure of the run")
        #expect(evaluate(runningWork(failures(3))).warnings.isEmpty)
        #expect(evaluate(runningWork(failures(5))).warnings.first?.failures == 5)
    }

    @Test func aSuccessBetweenBreaksTheRunAndTheNextSuccessClearsIt() {
        let between = failures(2, from: 20, prefix: "a") + bash("toolu_ok", at: ago(17)) + failures(2, from: 16, prefix: "b")
        #expect(evaluate(runningWork(between)).warnings.isEmpty)
        let cleared = failures(4) + bash("toolu_ok", at: ago(10))
        #expect(evaluate(runningWork(cleared)).warnings.isEmpty)
    }

    @Test func denialsAndPermissionTextsAreNoFailures() {
        let denied = failures(3, prefix: "x") + bash("toolu_hook", at: ago(15), content: "<tool_use_error>Blocked by a hook</tool_use_error>")
            + bash("toolu_perm", at: ago(14), content: "Permission to use Bash was denied")
            + bash("toolu_kind", at: ago(13), exit: 1, denial: "automode-blocked")
        #expect(evaluate(runningWork(denied)).warnings.isEmpty, "3 failures and 3 denials")
        // Denials are neither failures nor successes: the run goes on through them.
        let through = failures(2, from: 20, prefix: "p") + bash("toolu_hook", at: ago(17), content: "<tool_use_error>x</tool_use_error>")
            + failures(2, from: 16, prefix: "q")
        #expect(evaluate(runningWork(through)).warnings.first?.failures == 4)
        // A background launch neither.
        let launch = failures(2, from: 20, prefix: "m") + bash("toolu_bg", at: ago(17), background: true) + failures(2, from: 16, prefix: "n")
        #expect(evaluate(runningWork(launch)).warnings.first?.failures == 4)
    }

    @Test func toolUsesAForkCopiedAreLeftOut() {
        let lines = runningWork(failures(4))
        #expect(evaluate(lines, copied: ["toolu_f0", "toolu_f1"]).warnings.isEmpty, "2 own failures only")
    }

    @Test func theEndOfTheWorkClearsItUnlessBackgroundTasksArePending() {
        let ended = runningWork(failures(4)) + [Line.text("I give up on \(secretWord).", uuid: "a-end", at: ago(2))]
        #expect(evaluate(ended).warnings.isEmpty)
        let pending = CodeProgress(source: .backgroundTasks, unit: .agents, done: 1, total: 3, pendingBetweenTurns: true)
        #expect(evaluate(ended, progress: pending).warnings.map(\.kind) == [.failedInARow])
    }

    @Test func silenceIsThirtyMinutesWithNothingWaiting() throws {
        let quiet = runningWork(bash("toolu_1", at: ago(40)), start: 50)
        let warning = try #require(evaluate(quiet, lastGrowthAt: ago(31)).warnings.first)
        #expect(warning.kind == .silence && warning.since == ago(31))
        let early = evaluate(quiet, lastGrowthAt: ago(29))
        #expect(early.warnings.isEmpty && early.deadline == ago(29).addingTimeInterval(CodeTuning.stuckSilence))
        #expect(evaluate(quiet, lastGrowthAt: ago(1)).warnings.isEmpty, "growth clears it")
    }

    @Test func aToolThatWaitsIsNeverSilence() {
        let waiting = runningWork([SeamLine.bash("make build", description: "Build", id: "toolu_long", uuid: "a-long", at: ago(40))], start: 50)
        #expect(evaluate(waiting, lastGrowthAt: ago(40)).warnings.isEmpty, "plain quiet · turn not finished")
    }

    @Test func sshSessionsNeedTheSessionFileStillToo() {
        let ssh = resultSession(place: .ssh, sshHost: "buildbox", state: .working)
        let quiet = runningWork(bash("toolu_1", at: ago(45)), start: 50)
        #expect(evaluate(quiet, session: ssh, lastGrowthAt: ago(40), lastActivityMovedAt: ago(5)).warnings.isEmpty)
        #expect(evaluate(quiet, session: ssh, lastGrowthAt: ago(40), lastActivityMovedAt: ago(31)).warnings.first?.kind == .silence)
    }

    @Test func pendingBackgroundTasksAndNeedsYouAreNoSilence() {
        let between = runningWork(bash("toolu_1", at: ago(45)), start: 50) + [Line.text("Agents launched.", uuid: "a-1", at: ago(44))]
        let pending = CodeProgress(source: .backgroundTasks, unit: .agents, done: 0, total: 4, pendingBetweenTurns: true)
        #expect(evaluate(between, progress: pending, lastGrowthAt: ago(44)).warnings.isEmpty, "the turn has finished")
        let quiet = runningWork(bash("toolu_1", at: ago(45)), start: 50)
        let waiting = CodeProgress(source: .backgroundTasks, unit: .workflows, done: 0, total: 1, pendingBetweenTurns: true)
        #expect(evaluate(quiet, progress: waiting, lastGrowthAt: ago(40)).warnings.isEmpty, "a quiet turn waiting on its tasks")
        for state in [CodeSessionState.needsYou, .problem, .maybeNeedsYou] {
            #expect(evaluate(quiet, session: resultSession(state: state), lastGrowthAt: ago(40)).warnings.isEmpty, "\(state)")
        }
    }

    @Test func okSilencesTheRuleForTheRestOfTheWork() {
        let lines = runningWork(failures(4))
        let ok = WarningSilenceRecord(rule: "failed_in_a_row", until: resultNow.addingTimeInterval(3600), at: ago(1))
        #expect(evaluate(lines, silenced: [ok]).warnings.isEmpty)
        // A new message of the user's starts new work: the old OK no longer holds.
        let next = lines + [Line.user("Try again", uuid: "u-next", at: ago(0.5))] + failures(4, from: 0.4, prefix: "z")
        #expect(evaluate(next, silenced: [ok]).warnings.first?.kind == .failedInARow)
        let expired = WarningSilenceRecord(rule: "failed_in_a_row", until: ago(1), at: ago(2))
        #expect(evaluate(lines, silenced: [expired]).warnings.count == 1)
    }
}
