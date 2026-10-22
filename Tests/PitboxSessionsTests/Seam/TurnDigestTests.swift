import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The turn digest: what one tail parse gives the derivers' rules.
@Suite("Turn digest")
struct TurnDigestTests {
    let t0 = fixtureNow.addingTimeInterval(-600)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func aTurnsCallsResultsAndFinalReplyAreKept() throws {
        let prompt = "Rebuild https://dash.example.com/dash/polar-shore/ with the \(secretWord) numbers"
        let lines = [
            Line.user("Ship the \(secretWord) report\nplease", uuid: "u-1", at: at(0)),
            Line.text("Starting.", uuid: "a-1", at: at(1), stop: "tool_use"),
            SeamLine.bash("swift test --filter \(secretWord)", description: "Run the tests", id: "toolu_b1", uuid: "a-2", at: at(2)),
            SeamLine.result("toolu_b1", uuid: "r-1", at: at(3), content: "ok", toolUseResult: ["stdout": "ok", "stderr": ""]),
            SeamLine.edit("/work/repo/Sources/A.swift", id: "toolu_e1", uuid: "a-3", at: at(4)),
            SeamLine.result("toolu_e1", uuid: "r-2", at: at(5), content: "edited"),
            SeamLine.edit("/work/repo/notes.ipynb", id: "toolu_n1", uuid: "a-4", at: at(6), tool: "NotebookEdit"),
            SeamLine.result("toolu_n1", uuid: "r-0", at: at(6.5), content: "edited"),
            SeamLine.sendUserFile(["/work/repo/report.md", "/work/repo/chart.png"], id: "toolu_s1", uuid: "a-5", at: at(7)),
            SeamLine.result("toolu_s1", uuid: "r-3", at: at(8), content: "sent"),
            SeamLine.agent("dashboard-builder", id: "toolu_d1", uuid: "a-6", at: at(9), prompt: prompt),
            SeamLine.agent("general-purpose", id: "toolu_g1", uuid: "a-7", at: at(10), prompt: "Look \(secretWord)", background: false),
            Line.toolUse("Artifact", id: "toolu_art", uuid: "a-8", at: at(11), input: ["title": "\(secretWord)"]),
            SeamLine.result("toolu_art", uuid: "r-4", at: at(12), content: "published",
                            toolUseResult: ["url": "https://claude.ai/artifact/abcdef0123", "status": "published"]),
            SeamLine.result("toolu_d1", uuid: "r-5", at: at(13), content: "launched",
                            toolUseResult: ["status": "async_launched", "agentId": "agent-d1"]),
            SeamLine.result("toolu_g1", uuid: "r-6", at: at(14), content: "launched",
                            toolUseResult: ["status": "async_launched", "agentId": "agent-g1"]),
            Line.toolUse(StepWords.updatePlan, id: "toolu_p", uuid: "a-9", at: at(15), input: ["advance": true]),
            SeamLine.result("toolu_p", uuid: "r-7", at: at(15.5), content: "ok"),
            Line.text("All done: the report is ready.", uuid: "a-final", at: at(16)),
        ]
        let digest = digestOf(lines)
        let turn = try #require(digest.turns.first)
        #expect(digest.turns.count == 1 && !digest.truncated && digest.duplicateUUIDs.isEmpty)
        #expect(turn.startUUID == "u-1" && turn.startedAt == at(0) && turn.origin == .human && turn.startHeld)
        #expect(turn.askedHead == "Ship the \(secretWord) report\nplease")
        #expect(turn.isFinished && turn.finishedAt == at(16) && turn.replyUUID == "a-final" && turn.readCompletely)
        #expect(turn.finalReply.map(\.text) == ["All done: the report is ready."], "the plan call after it is bookkeeping")
        #expect(digest.latestTurn?.replyUUID == "a-final")

        let uses = turn.items.compactMap { item -> CodeTurnDigest.ToolUse? in
            if case .toolUse(let use) = item { return use }
            return nil
        }
        let bash = try #require(uses.first { $0.name == "Bash" })
        #expect(bash.command == "swift test --filter \(secretWord)" && bash.description == "Run the tests")
        #expect(bash.id == "toolu_b1" && bash.uuid == "a-2" && bash.at == at(2) && !bash.isCopied)
        #expect(uses.first { $0.name == "Edit" }?.filePath == "/work/repo/Sources/A.swift")
        #expect(uses.first { $0.name == "NotebookEdit" }?.filePath == "/work/repo/notes.ipynb")
        #expect(uses.first { $0.name == "SendUserFile" }?.files == ["/work/repo/report.md", "/work/repo/chart.png"])
        let builder = try #require(uses.first { $0.subagentType == "dashboard-builder" })
        #expect(builder.promptHead == prompt && builder.runInBackground == true)
        let other = try #require(uses.first { $0.subagentType == "general-purpose" })
        #expect(other.promptHead == nil && other.runInBackground == false, "only dashboard-builder prompts are kept")
        #expect(uses.first { $0.name == "Artifact" }?.command == nil, "commands are kept for Bash only")

        let results = turn.items.compactMap { item -> CodeTurnDigest.ToolResult? in
            if case .toolResult(let result) = item { return result }
            return nil
        }
        #expect(results.count == 8)
        #expect(results.first?.toolName == "Bash" && results.first?.isError == false && results.first?.head == "ok")
        #expect(results.first { $0.toolName == "Artifact" }?.artifactURL == "https://claude.ai/artifact/abcdef0123")
        #expect(results.filter { $0.artifactURL != nil }.count == 1, "only Artifact results carry a url")
        let launched = results.filter { $0.asyncTaskID != nil }
        #expect(launched.map(\.asyncTaskID) == ["agent-d1", "agent-g1"] && launched.allSatisfy { $0.asyncKind == .agent })
        #expect(turn.pendingToolUses.isEmpty && turn.lastEntryAt == at(16))
        #expect(!turn.readWeb)
    }

    @Test func failuresCarryTheirExitCodeAndDenialsAreNoFailures() throws {
        let long = String(repeating: "x", count: 10_000)
        let lines = [
            Line.user("Go", uuid: "u-1", at: at(0)),
            SeamLine.bash("make", description: "Build", id: "toolu_1", uuid: "a-1", at: at(1)),
            SeamLine.result("toolu_1", uuid: "r-1", at: at(2), content: "Exit code 2\nmake: *** [all] Error 2", isError: true,
                            toolUseResult: "Error: Exit code 2"),
            SeamLine.bash("rm -rf build", description: "Clean", id: "toolu_2", uuid: "a-2", at: at(3)),
            SeamLine.result("toolu_2", uuid: "r-2", at: at(4), content: "<tool_use_error>Blocked by a hook</tool_use_error>",
                            isError: true),
            SeamLine.bash("git push", description: "Push", id: "toolu_3", uuid: "a-3", at: at(5)),
            SeamLine.result("toolu_3", uuid: "r-3", at: at(6), content: "Permission to use Bash was denied", isError: true,
                            denial: "permission-rule"),
            SeamLine.bash("cat log", description: "Show the log", id: "toolu_4", uuid: "a-4", at: at(7)),
            SeamLine.result("toolu_4", uuid: "r-4", at: at(8), content: [["type": "text", "text": "first"],
                                                                          ["type": "image", "source": ["data": "AAAA"]],
                                                                          ["type": "text", "text": long]]),
            SeamLine.bash("sleep 1", description: "Wait", id: "toolu_5", uuid: "a-5", at: at(9), background: true),
            SeamLine.result("toolu_5", uuid: "r-5", at: at(10), content: "started", toolUseResult: ["backgroundTaskId": "bash_77"]),
        ]
        let results = digestOf(lines).turns[0].items.compactMap { item -> CodeTurnDigest.ToolResult? in
            if case .toolResult(let result) = item { return result }
            return nil
        }
        #expect(results[0].isError == true && results[0].exitCode == 2 && !results[0].denied)
        #expect(results[1].isError == true && results[1].exitCode == nil && results[1].denied, "<tool_use_error>")
        #expect(results[2].denied && results[2].exitCode == nil, "toolDenialKind")
        #expect(results[3].head.hasPrefix("first\n") && results[3].head.count == CodeTuning.digestHeadMax, "a bounded head")
        #expect(results[3].isError == false && !results[3].denied)
        #expect(results[4].asyncTaskID == "bash_77" && results[4].asyncKind == .bash)
        #expect(CodeTurnDigestBuilder.exitCode("Exit code 137") == 137 && CodeTurnDigestBuilder.exitCode("Exit code x") == nil)
        #expect(CodeTurnDigestBuilder.exitCode("exit code 1") == nil && CodeTurnDigestBuilder.exitCode("Exit code 1234567890") == nil)
    }

    @Test func backgroundWorkAndItsNoticesFromAllThreeCarriers() throws {
        let lines = [
            Line.user("Run the fleet", uuid: "u-1", at: at(0)),
            Line.toolUse("Agent", id: "toolu_a", uuid: "a-1", at: at(1), input: ["subagent_type": "worker", "prompt": "p"]),
            SeamLine.result("toolu_a", uuid: "r-1", at: at(2), content: "launched",
                            toolUseResult: ["status": "async_launched", "agentId": "agent-1", "isAsync": true]),
            Line.toolUse("Workflow", id: "toolu_w", uuid: "a-2", at: at(3), input: ["script": "\(secretWord)"]),
            SeamLine.result("toolu_w", uuid: "r-2", at: at(4), content: "launched",
                            toolUseResult: ["status": "async_launched", "taskType": "local_workflow", "taskId": "wf_42",
                                            "runId": "run-1"]),
            SeamLine.queueOperation(noticeText(taskID: "agent-1"), at: at(5)),
            SeamLine.queueOperation(noticeText(taskID: "ignored"), at: at(5), operation: "remove"),
            SeamLine.queuedCommand(noticeText(taskID: "wf_42", agentCount: 6, agentsDone: 6), uuid: "q-1", at: at(6)),
            Line.text("Waiting for them.", uuid: "a-3", at: at(7)),
            SeamLine.noticeTurn(noticeText(taskID: "agent-1"), uuid: "u-2", at: at(8)),
            Line.text("Agent 1 is back.", uuid: "a-4", at: at(9)),
            SeamLine.noticeTurn(noticeText(toolUseID: "toolu_w", status: "failed"), uuid: "u-3", at: at(10), origin: nil),
        ]
        let digest = digestOf(lines)
        #expect(digest.turns.map(\.origin) == [.human, .taskNotification, .unknown])
        #expect(digest.turns[0].isFinished && digest.turns[1].isFinished && !digest.turns[2].isFinished)
        let first = digest.turns[0].items
        let launches = first.compactMap { item -> CodeTurnDigest.ToolResult? in
            if case .toolResult(let result) = item, result.asyncTaskID != nil { return result }
            return nil
        }
        #expect(launches.map(\.asyncTaskID) == ["agent-1", "wf_42"] && launches.map(\.asyncKind) == [.agent, .workflow])
        let notices = digest.allItems.compactMap { item -> CodeTurnDigest.Notice? in
            if case .notice(let notice) = item { return notice }
            return nil
        }
        #expect(notices.map(\.carrier) == [.queueOperation, .queuedCommand, .userText, .userText])
        #expect(notices[1].taskID == "wf_42" && notices[1].agentCount == 6 && notices[1].agentsDone == 6)
        #expect(notices[3].taskID == nil && notices[3].toolUseID == "toolu_w" && notices[3].status == "failed")
        #expect(notices.allSatisfy { $0.at != nil })
        // The same notice enqueued and then delivered counts once.
        #expect(digest.uniqueNotices.map { $0.taskID ?? $0.toolUseID } == ["agent-1", "wf_42", "toolu_w"])
    }

    @Test func entryUUIDsFollowTheGrammarAndDuplicatesAreFound() throws {
        let long = String(repeating: "a", count: 600)
        let lines = [
            Line.user("Hi", uuid: "u-1", at: at(0)),
            Line.text("Under", uuid: "bad_uuid", at: at(1), stop: "tool_use"),
            Line.toolUse("Read", id: "toolu_r", uuid: long, at: at(2)),
            SeamLine.result("toolu_r", uuid: "r-1", at: at(3), content: "x"),
            Line.text("Twice", uuid: "dup-1", at: at(4), stop: "tool_use"),
            Line.toolUse("Read", id: "toolu_s", uuid: "a-2", at: at(5)),
            SeamLine.result("toolu_s", uuid: "dup-1", at: at(6), content: "x"),
            Line.text("Final", uuid: "bad uuid", at: at(7)),
        ]
        let digest = digestOf(lines)
        let turn = digest.turns[0]
        let texts = turn.items.compactMap { item -> CodeTurnDigest.Text? in
            if case .text(let text) = item { return text }
            return nil
        }
        #expect(texts.map(\.uuid) == [nil, "dup-1", nil])
        #expect(turn.items.contains { item in
            if case .toolUse(let use) = item { return use.id == "toolu_r" && use.uuid == nil }
            return false
        })
        #expect(digest.duplicateUUIDs == ["dup-1"])
        #expect(turn.isFinished && turn.replyUUID == nil, "a reply without a valid uuid makes no key")
        #expect(CodeIDs.entryUUID("0f3c2a9e-1111-2222-3333-444455556666") != nil)
        #expect(CodeIDs.entryUUID("with_underscore") == nil && CodeIDs.entryUUID("") == nil)
        #expect(CodeIDs.entryUUID(String(repeating: "a", count: 65)) == nil)
    }

    @Test func midTurnKeepsTheLatestTurnRunning() {
        let lines = [Line.user("Go", uuid: "u-1", at: at(0)), Line.text("Done", uuid: "a-1", at: at(1))]
        #expect(digestOf(lines).latestTurn?.isFinished == true)
        let running = digestOf(lines, midTurn: true)
        #expect(running.latestTurn?.isFinished == false && running.latestTurn?.replyUUID == nil && running.latestTurn?.finishedAt == nil)
    }

    @Test func theLatestTurnFollowsThePhaseOneTracker() {
        let sequences: [[String]] = [
            [Line.user("a", uuid: "u", at: at(0)), Line.toolUse("Bash", id: "toolu_1", uuid: "a1", at: at(1))],
            [Line.user("a", uuid: "u", at: at(0)), Line.toolUse("Bash", id: "toolu_1", uuid: "a1", at: at(1)),
             SeamLine.result("toolu_1", uuid: "r", at: at(2), content: "x")],
            [Line.user("a", uuid: "u", at: at(0)), Line.text("done", uuid: "a2", at: at(1))],
            [Line.text("done", uuid: "a2", at: at(1)), SeamLine.result("toolu_x", uuid: "r", at: at(2), content: "late")],
            [Line.text("partial turn", uuid: "a3", at: at(1))],
            [Line.user("a", uuid: "u", at: at(0)), Line.toolUse("Bash", id: "toolu_1", uuid: "a1", at: at(1)),
             Line.text("side", uuid: "s1", at: at(2), sidechain: true)],
        ]
        for lines in sequences {
            let tracker = digestTracker(lines)
            let digest = tracker.digest.digest(midTurn: false, lastGrowthAt: nil, lastActivityMovedAt: nil, publishedArtifacts: [])
            #expect(digest.latestTurn?.isFinished == tracker.turn?.endedByTranscript)
            #expect(digest.latestTurn?.startHeld == tracker.turn?.startHeld)
            #expect(digest.latestTurn?.origin == tracker.turn?.origin)
        }
        // The partial turn at the front is kept only while it is the latest.
        let partial = digestOf([Line.text("tail start", uuid: "a0", at: at(0), stop: "tool_use"),
                                Line.toolUse("Read", id: "toolu_0", uuid: "a00", at: at(0)),
                                Line.user("next", uuid: "u-1", at: at(1)), Line.text("ok", uuid: "a1", at: at(2))])
        #expect(partial.turns.count == 1 && partial.turns[0].startUUID == "u-1" && !partial.truncated)
        let onlyPartial = digestOf([Line.text("tail start", uuid: "a0", at: at(0))])
        #expect(onlyPartial.turns.count == 1 && !onlyPartial.turns[0].startHeld && onlyPartial.truncated
                && !onlyPartial.turns[0].readCompletely)
    }

    @Test func aLongTextIsCutAndItsReplyIsNotReadCompletely() throws {
        let text = String(repeating: "é", count: 40_000)  // 80,000 bytes
        let digest = digestOf([Line.user("Write a lot", uuid: "u-1", at: at(0)), Line.text(text, uuid: "a-1", at: at(1))])
        let reply = try #require(digest.latestTurn?.finalReply.first)
        #expect(reply.cut && reply.text.utf8.count <= CodeTuning.digestTextMax && reply.text.utf8.count > 60_000)
        #expect(digest.latestTurn?.readCompletely == false && digest.latestTurn?.isFinished == true)
        let (kept, cut) = CodeTurnDigestBuilder.capped("añb", bytes: 2)
        #expect(kept == "a" && cut, "never splits a character")
    }

    /// Every turn from the oldest live offer's turn, however many notice turns came between.
    @Test func turnsAreKeptBackToTheOldestTurnWhoseOffersCanStillRun() {
        var lines: [String] = []
        var clock = 0.0
        func turn(_ name: String, origin: String?) {
            clock += 10
            lines.append(Line.user("\(name) \(secretWord)", uuid: "u-\(name)", at: at(clock), origin: origin))
            lines.append(Line.text("reply \(name)", uuid: "a-\(name)", at: at(clock + 1)))
        }
        turn("h0", origin: "human")
        turn("h1", origin: "human")              // an offer here
        for i in 1...7 { turn("b\(i)", origin: "task_notification") }
        turn("h2", origin: "human")
        turn("h3", origin: "human")
        var digest = digestOf(lines)
        #expect(digest.turns.first?.startUUID == "u-h0" && digest.turns.count == 11, "h1's facts need every turn since")
        turn("h4", origin: "human")
        digest = digestOf(lines)
        #expect(digest.turns.first?.startUUID == "u-h1", "h0's offers can no longer run: dropped")
        #expect(digest.turns.count == 11 && !digest.truncated)
        turn("u5", origin: nil)                  // unknown origin counts as the user's
        digest = digestOf(lines)
        #expect(digest.turns.first?.startUUID == "u-h2")
        // An unfinished turn of the user's does not count: the offer two finished replies back stays.
        lines.append(Line.user("h6", uuid: "u-h6", at: at(clock + 20)))
        lines.append(Line.toolUse("Bash", id: "toolu_long", uuid: "a-h6", at: at(clock + 21)))
        lines.append(Line.user("h7", uuid: "u-h7", at: at(clock + 30)))
        digest = digestOf(lines)
        #expect(digest.turns.first?.startUUID == "u-h3", "h4, u5 finished; h6 unfinished; h3 is the third")
    }

    @Test func theWorksStartIsKeptBehindUnknownTurns() {
        var lines = [Line.user("peer asks", uuid: "u-p", at: at(0), origin: "peer"), Line.text("ok", uuid: "a-p", at: at(1))]
        for i in 1...5 {
            lines.append(Line.user("x\(i)", uuid: "u-x\(i)", at: at(Double(i) * 10), origin: nil))
            lines.append(Line.text("r\(i)", uuid: "a-x\(i)", at: at(Double(i) * 10 + 1)))
        }
        let digest = digestOf(lines)
        #expect(digest.turns.first?.startUUID == "u-p" && digest.latestHumanOrPeerTurn?.startUUID == "u-p")
    }

    @Test func theBoundsDropTheOldestTurnsFirst() {
        // 250 notice turns after one turn of the user's: the 200-turn bound drops from the front.
        var lines = [Line.user("Start the fleet", uuid: "u-0", at: at(0)), Line.text("Started", uuid: "a-0", at: at(1))]
        for i in 1...250 {
            lines.append(SeamLine.noticeTurn(noticeText(taskID: "t\(i)"), uuid: "u-\(i)", at: at(Double(i) * 5)))
            lines.append(Line.text("Noted \(i)", uuid: "a-\(i)", at: at(Double(i) * 5 + 1)))
        }
        var digest = digestOf(lines)
        #expect(digest.turns.count == CodeTuning.digestTurnsMax && digest.truncated)
        #expect(digest.turns.last?.startUUID == "u-250" && digest.turns.first?.startUUID == "u-51")
        // More than 2 MB of strings: the oldest turns go until it fits.
        let big = String(repeating: "z", count: 60_000)
        lines = []
        for i in 0..<45 {
            lines.append(Line.user("Turn \(i)", uuid: "u-\(i)", at: at(Double(i))))
            lines.append(Line.text(big, uuid: "a-\(i)", at: at(Double(i) + 0.5), stop: "tool_use"))
            lines.append(Line.toolUse("Bash", id: "toolu_\(i)", uuid: "b-\(i)", at: at(Double(i) + 0.6)))
        }
        let tracker = digestTracker(lines)
        digest = tracker.digest.digest(midTurn: false, lastGrowthAt: nil, lastActivityMovedAt: nil, publishedArtifacts: [])
        #expect(tracker.digest.byteCount <= CodeTuning.digestBytesMax && digest.truncated)
        #expect(digest.turns.last?.startUUID == "u-44" && digest.turns.count < 45 && digest.turns.count > 25)
        // One turn with more items than a turn keeps: its oldest items go.
        lines = [Line.user("Many", uuid: "u-m", at: at(0))]
        for i in 0..<(CodeTuning.digestItemsPerTurnMax + 10) {
            lines.append(Line.toolUse("Read", id: "toolu_m\(i)", uuid: "m-\(i)", at: at(1)))
        }
        digest = digestOf(lines)
        #expect(digest.turns.count == 1 && digest.turns[0].itemsDropped && !digest.turns[0].readCompletely)
        #expect(digest.turns[0].items.count <= CodeTuning.digestItemsPerTurnMax)
    }

    @Test func aFreshTailGrowsUntilItHoldsTheTurnsTheDigestNeeds() throws {
        // Three finished turns of the user's, then 600 KB of notice turns, then the latest turn.
        let filler = String(repeating: "f", count: 20_000)
        var lines: [String] = []
        for name in ["h0", "h1", "h2"] {
            lines.append(Line.user(name, uuid: "u-\(name)", at: at(0)))
            lines.append(Line.text("r \(name)", uuid: "a-\(name)", at: at(1)))
        }
        for i in 0..<30 {
            lines.append(SeamLine.noticeTurn(noticeText(taskID: "t\(i)"), uuid: "n-\(i)", at: at(2)))
            lines.append(Line.text(filler, uuid: "nr-\(i)", at: at(3)))
        }
        lines.append(Line.user("latest", uuid: "u-latest", at: at(4)))
        lines.append(Line.toolUse("Bash", id: "toolu_l", uuid: "a-l", at: at(5)))
        let tree = FixtureTree("reach")
        let url = tree.projects.appendingPathComponent("reach.jsonl")
        try tree.writeLines(lines, to: url)
        let path = try #require(CarefulPath(root: tree.projects.path, components: ["reach.jsonl"]))

        guard case .success(let phaseOne) = TranscriptReader.read(path, owner: getuid(), cursor: nil) else {
            Issue.record("the parsed read failed")
            return
        }
        #expect(phaseOne.holdsTurnStart && !phaseOne.lines.contains { $0.entry?.uuid == "u-h0" }, "256 KB holds the latest start")
        guard case .success(let reach) = TranscriptReader.read(path, owner: getuid(), cursor: nil, digestFacts: true,
                                                               reaches: CodeTurnDigestBuilder.windowHoldsNeededTurns) else {
            Issue.record("digest read failed")
            return
        }
        #expect(reach.lines.contains { $0.entry?.uuid == "u-h0" } && reach.lines.count > phaseOne.lines.count)
        #expect(reach.lines.first { $0.entry?.uuid == "u-h1" }?.entry?.digest != nil, "parsed for the digest")
        #expect(CodeTurnDigestBuilder.windowHoldsNeededTurns(reach.lines))
        #expect(!CodeTurnDigestBuilder.windowHoldsNeededTurns(phaseOne.lines))
    }

    @Test func publishedArtifactsAreReadWithoutTheirTitles() throws {
        var artifacts: [[String: Any]] = []
        for i in 0..<40 {
            artifacts.append(["url": "https://claude.ai/artifact/id\(i)abcdef", "title": "\(secretWord) \(i)",
                              "updatedAt": 1_790_000_000_000 + i * 1000, "sourcePath": "/x/\(i)"])
        }
        artifacts.append(["title": "no url"])
        var fixture = SessionFixture()
        fixture.extra = ["publishedArtifacts": artifacts, "latestUserFrameAt": "2026-10-01T14:00:00.000Z"]
        let file = try ClaudeSessionFile.parse(Data(fixture.json.utf8)).get()
        #expect(file.publishedArtifacts.count == ClaudeSessionFile.maxArtifacts)
        #expect(file.publishedArtifacts.first?.url == "https://claude.ai/artifact/id39abcdef", "newest first")
        #expect(file.publishedArtifacts.first?.updatedAt == Date(timeIntervalSince1970: 1_790_000_039))
        #expect(file.latestUserFrameAt == CodeDates.parse("2026-10-01T14:00:00.000Z"))
        // A duplicated key inside an artifact fails the whole file, as everywhere.
        let twice = #"{"title":"t","publishedArtifacts":[{"url":"https://a","url":"https://b"}]}"#
        #expect(throws: ClaudeFileFailure.self) { try ClaudeSessionFile.parse(Data(twice.utf8)).get() }
    }

    @Test func noticeTagsOnlyAndBounded() {
        let many = (0..<80).map { noticeText(taskID: "t\($0)") }.joined(separator: "\n")
        #expect(TaskNotices.parse(many, at: nil, carrier: .userText).count == TaskNotices.maxPerText)
        let hostile = "<task-notification><task-id>../../etc</task-id><status>COMPLETED</status><agent_count>99999999</agent_count>"
        let parsed = TaskNotices.parse(hostile, at: nil, carrier: .userText)
        #expect(parsed.count == 1 && parsed[0].taskID == nil && parsed[0].status == "completed" && parsed[0].agentCount == nil)
        #expect(TaskNotices.parse("no notice here", at: nil, carrier: .userText).isEmpty)
    }
}
