import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

@Suite("Turns and final replies")
struct TurnTrackerTests {
    let t0 = fixtureNow.addingTimeInterval(-300)

    @Test func theFinalReplyIsTheLastRunOfTextAfterToolResults() throws {
        let tracker = track([
            Line.user("Fix it\nplease", uuid: "u1", at: t0),
            Line.text("Let me look.", uuid: "a1", at: t0, stop: "tool_use"),
            Line.toolUse("Read", id: "toolu_1", uuid: "a2", at: t0, input: ["file_path": "/x/y/Main.swift"]),
            Line.toolResult("toolu_1", uuid: "r1", at: t0),
            Line.thinking(uuid: "a3", at: t0),
            Line.text("Here is the fix:", uuid: "a4", at: t0),
            Line.text("```bash\nmake test\n```", uuid: "a5", at: t0),
        ])
        let turn = try #require(tracker.turn)
        #expect(turn.startHeld && turn.youAsked == "Fix it\nplease" && turn.origin == .human)
        #expect(turn.run == ["Here is the fix:", "```bash\nmake test\n```"])
        #expect(turn.endedByTranscript && turn.isReadCompletely)
        #expect(turn.lastAssistantUUID == "a5" && tracker.lastAssistantUUID == "a5")
        #expect(tracker.steps.map(\.words) == ["reading Main.swift"])
    }

    @Test func aBookkeepingToolAfterTheReplyKeepsIt() throws {
        let tracker = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.text("Run this:\n```sh\nls\n```", uuid: "a1", at: t0, stop: "tool_use"),
            Line.toolUse("mcp__ccd_session__mark_chapter", id: "toolu_2", uuid: "a2", at: t0, input: ["title": "x"]),
            Line.toolResult("toolu_2", uuid: "r2", at: t0),
            Line.text("That is all.", uuid: "a3", at: t0),
        ])
        #expect(tracker.turn?.run == ["Run this:\n```sh\nls\n```", "That is all."])
        #expect(tracker.turn?.endedByTranscript == true)
    }

    @Test func aRealToolAfterTextEndsTheRun() {
        let tracker = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.text("```bash\nrm -rf build\n```", uuid: "a1", at: t0, stop: "tool_use"),
            Line.toolUse("Bash", id: "toolu_3", uuid: "a2", at: t0, input: ["description": "Clean the build folder"]),
            Line.toolResult("toolu_3", uuid: "r3", at: t0),
            Line.text("Cleaned.", uuid: "a3", at: t0),
        ])
        #expect(tracker.turn?.run == ["Cleaned."])
        #expect(tracker.turn?.lastToolWords == "running: Clean the build folder")
    }

    @Test func aRunningTurnIsNotFinished() {
        let waiting = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.toolUse("Bash", id: "toolu_4", uuid: "a1", at: t0, input: ["description": "Sleep"]),
        ])
        #expect(waiting.turn?.endedByTranscript == false)
        #expect(waiting.turn?.waitingTool?.name == "Bash")
        let answered = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.toolUse("Bash", id: "toolu_4", uuid: "a1", at: t0),
            Line.toolResult("toolu_4", uuid: "r4", at: t0),
        ])
        #expect(answered.turn?.endedByTranscript == false)
        #expect(answered.turn?.userAfterAssistant == true)
        let newPrompt = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.text("Done", uuid: "a1", at: t0),
            Line.user("And now?", uuid: "u2", at: t0),
        ])
        #expect(newPrompt.turn?.hasAssistant == false && newPrompt.turn?.endedByTranscript == false)
        #expect(newPrompt.lastAssistantUUID == "a1")
    }

    @Test func aPendingQuestionAsksForTheUser() {
        let tracker = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.toolUse("AskUserQuestion", id: "toolu_5", uuid: "a1", at: t0, input: ["questions": [["question": "Which?"]]]),
        ])
        #expect(tracker.turn?.asksUser == true)
        #expect(tracker.turn?.lastToolWords == "asking you")
    }

    @Test func turnsNotStartedByTheUserHaveNoYouAsked() {
        let peer = track([Line.user("From another session", uuid: "u1", at: t0, origin: "peer"), Line.text("Ok", uuid: "a1", at: t0)])
        #expect(peer.turn?.origin == .peer && peer.turn?.youAsked == nil)
        let task = track([Line.user("<task-notification><task-id>t1</task-id></task-notification>", uuid: "u1", at: t0,
                                    origin: "task_notification"), Line.text("Ok", uuid: "a1", at: t0)])
        #expect(task.turn?.origin == .taskNotification && task.turn?.youAsked == nil)
        // Anything but human, task_notification and peer is unknown, an absent origin included
        // (docs/SHELL_LANGUAGE.md §8 A15): no "You asked" for any of them.
        let bare = track([Line.user("<task-notification><status>completed</status></task-notification>", uuid: "u1", at: t0,
                                    origin: nil), Line.text("Ok", uuid: "a1", at: t0)])
        #expect(bare.turn?.origin == .unknown && bare.turn?.youAsked == nil)
        let noOrigin = track([Line.user("Hello there", uuid: "u1", at: t0, origin: nil)])
        #expect(noOrigin.turn?.origin == .unknown && noOrigin.turn?.youAsked == nil)
        for word in ["system", "sdk", "scheduled", "taskNotification"] {
            let other = track([Line.user("Hello", uuid: "u1", at: t0, origin: word)])
            #expect(other.turn?.origin == .unknown && other.turn?.youAsked == nil, "\(word)")
        }
        let meta = track([Line.user("Caveat: generated", uuid: "u1", at: t0, meta: true)])
        #expect(meta.turn?.origin == .human && meta.turn?.youAsked == nil)
        let human = track([Line.user("Hello there", uuid: "u1", at: t0)])
        #expect(human.turn?.origin == .human && human.turn?.youAsked == "Hello there")
    }

    @Test func aTurnWhoseStartIsNotInTheTailIsPartlyRead() {
        let tracker = track([Line.text("```bash\nls\n```", uuid: "a1", at: t0)])
        #expect(tracker.turn?.startHeld == false && tracker.turn?.isReadCompletely == false)
        var withBadLine = TurnTracker()
        let good = Line.user("Go", uuid: "u1", at: t0)
        withBadLine.feed(TranscriptLine(entry: withBytes(good) { TranscriptEntry.parse($0) }, offset: 0, length: good.utf8.count),
                         fallbackTime: fixtureNow)
        withBadLine.feed(TranscriptLine(entry: nil, offset: 100, length: 10), fallbackTime: fixtureNow)
        #expect(withBadLine.turn?.isReadCompletely == false)
    }

    @Test func sideChainsAndWebReads() {
        let tracker = track([
            Line.user("Research", uuid: "u1", at: t0),
            Line.text("subagent text", uuid: "s1", at: t0, stop: "end_turn", sidechain: true),
            Line.toolUse("WebFetch", id: "toolu_6", uuid: "a1", at: t0, input: ["url": "https://example.com"]),
            Line.toolResult("toolu_6", uuid: "r6", at: t0),
            Line.text("Found it.", uuid: "a2", at: t0),
        ])
        #expect(tracker.turn?.readWeb == true)
        #expect(tracker.turn?.run == ["Found it."])
        #expect(tracker.lastAssistantUUID == "a2")
        let browser = track([Line.user("x", uuid: "u", at: t0), Line.toolUse("mcp__claude-in-chrome__navigate", id: "t", uuid: "a", at: t0)])
        #expect(browser.turn?.readWeb == true && browser.turn?.lastToolWords == "claude-in-chrome: navigate")
    }

    @Test func stepWordsNameFilesNeverPaths() {
        func words(_ name: String, _ input: ToolInputFacts = ToolInputFacts()) -> String {
            StepWords.words(for: TranscriptToolUse(id: "t", name: name, input: input))
        }
        var edit = ToolInputFacts()
        edit.filePath = "/Users/someone/\(secretWord)/Sources/App.swift"
        #expect(words("Edit", edit) == "editing App.swift")
        #expect(words("Write", edit) == "editing App.swift")
        #expect(words("Read", edit) == "reading App.swift")
        #expect(words("Grep") == "searching" && words("Glob") == "searching")
        #expect(words("WebSearch") == "reading the web")
        #expect(words("Bash") == "running a command")
        var bash = ToolInputFacts()
        bash.description = "Run the whole test suite with coverage and then summarise"
        #expect(words("Bash", bash).count <= "running: ".count + 40)
        var agent = ToolInputFacts()
        agent.description = "Review the diff"
        #expect(words("Agent", agent) == "subagent: Review the diff")
        #expect(words("mcp__buildbox-box__run_agent") == "buildbox-box: run_agent")
        #expect(words("Skill") == "using Skill")
    }

    @Test func thePlanIsReplayedWithinItsTurn() {
        let items: [[String: Any]] = [["content": "One", "status": "in_progress"], ["content": "Two", "status": "pending"],
                                      ["content": "Three", "status": "pending"]]
        let plan = StepWords.updatePlan
        let tracker = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.toolUse(plan, id: "p1", uuid: "a1", at: t0, input: ["items": items, "scope": "first_task"]),
            Line.toolResult("p1", uuid: "r1", at: t0),
            Line.toolUse(plan, id: "p2", uuid: "a2", at: t0, input: ["advance": true]),
            Line.toolResult("p2", uuid: "r2", at: t0),
        ])
        let todos = tracker.todos
        #expect(todos?.done == 1 && todos?.total == 3 && todos?.current?.text == "Two")
        // Indices count from 1 (measured, see `PlanReplay.indexBase`).
        let jump = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.toolUse(plan, id: "p1", uuid: "a1", at: t0, input: ["items": items]),
            Line.toolUse(plan, id: "p2", uuid: "a2", at: t0, input: ["done": [1, 2], "start": 3]),
        ])
        #expect(jump.todos?.done == 2 && jump.todos?.current?.text == "Three")
        let zero = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.toolUse(plan, id: "p1", uuid: "a1", at: t0, input: ["items": items]),
            Line.toolUse(plan, id: "p2", uuid: "a2", at: t0, input: ["done": [0]]),
        ])
        #expect(zero.todos == nil)
        // A plan that started before the tail (or in an earlier turn) is not shown.
        let partial = track([Line.user("Go", uuid: "u1", at: t0), Line.toolUse(plan, id: "p2", uuid: "a2", at: t0, input: ["advance": true])])
        #expect(partial.todos == nil)
        let outOfRange = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.toolUse(plan, id: "p1", uuid: "a1", at: t0, input: ["items": items]),
            Line.toolUse(plan, id: "p2", uuid: "a2", at: t0, input: ["done": [7]]),
        ])
        #expect(outOfRange.todos == nil)
        let nextTurn = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.toolUse(plan, id: "p1", uuid: "a1", at: t0, input: ["items": items]),
            Line.user("Again", uuid: "u2", at: t0),
        ])
        #expect(nextTurn.todos == nil)
    }

    @Test func todoWriteIsTheFallback() {
        let tracker = track([
            Line.user("Go", uuid: "u1", at: t0),
            Line.toolUse("TodoWrite", id: "w1", uuid: "a1", at: t0, input: ["todos": [
                ["content": "A", "status": "completed", "activeForm": "Doing A"],
                ["content": "B", "status": "in_progress", "activeForm": "Doing B"]]]),
            Line.user("More", uuid: "u2", at: t0),
        ])
        #expect(tracker.todos?.done == 1 && tracker.todos?.current?.text == "B")
    }

    @Test func activityCountsBytesPerMinute() {
        var buckets = ActivityBuckets()
        buckets.add(100, at: fixtureNow.addingTimeInterval(-90), now: fixtureNow)
        buckets.add(50, at: fixtureNow, now: fixtureNow)
        buckets.add(70, at: fixtureNow.addingTimeInterval(-3600), now: fixtureNow)
        let line = buckets.sparkline(now: fixtureNow)
        #expect(line.count == 30 && line.last == 50 && line.reduce(0, +) == 150)
        #expect(buckets.nextChange(now: fixtureNow).map { $0 > fixtureNow } == true)
    }
}
