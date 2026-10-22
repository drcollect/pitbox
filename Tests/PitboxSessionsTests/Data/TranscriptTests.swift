import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

@Suite("Transcript lines and tails")
struct TranscriptTests {
    func entry(_ line: String) -> TranscriptEntry? { withBytes(line) { TranscriptEntry.parse($0) } }

    @Test func readsUserAssistantAndToolEntries() throws {
        let user = try #require(entry(Line.user("Please fix \(secretWord)\nsecond line\nthird", uuid: "u1", at: fixtureNow)))
        #expect(user.kind == .user && user.uuid == "u1" && user.timestamp == fixtureNow && user.origin == .human)
        #expect(!user.isToolResult && user.messageText.hasPrefix("Please fix"))

        let result = try #require(entry(Line.toolResult("toolu_1", uuid: "u2", at: fixtureNow)))
        #expect(result.kind == .user && result.isToolResult)

        let text = try #require(entry(Line.text("Done.", uuid: "a1", at: fixtureNow)))
        #expect(text.kind == .assistant && text.stopReason == "end_turn" && text.blocks == [.text("Done.", cut: false)])

        let tool = try #require(entry(Line.toolUse("Bash", id: "toolu_9", uuid: "a2", at: fixtureNow,
                                                  input: ["command": "rm -rf \(secretWord)", "description": "Run the tests"])))
        guard case .toolUse(let use) = tool.blocks.first else {
            Issue.record("no tool_use")
            return
        }
        #expect(use.id == "toolu_9" && use.name == "Bash" && use.input.description == "Run the tests")
        // What Claude ran itself is never decoded.
        #expect(!String(describing: use).contains(secretWord))

        let thinking = try #require(entry(Line.thinking(uuid: "a3", at: fixtureNow)))
        #expect(thinking.blocks == [.thinking])
    }

    @Test func turnOriginAsStringOrObject() {
        #expect(entry(Line.user("x", uuid: "u", at: fixtureNow, origin: "task_notification"))?.origin == .taskNotification)
        #expect(entry(Line.user("x", uuid: "u", at: fixtureNow, origin: "peer"))?.origin == .peer)
        #expect(entry(Line.user("x", uuid: "u", at: fixtureNow, origin: "scheduled"))?.origin == .unknown)
        #expect(entry(Line.user("x", uuid: "u", at: fixtureNow, origin: nil))?.origin == nil)
        let object = jsonLine(["type": "user", "uuid": "u", "turnOrigin": ["kind": "peer", "sessionId": "x"],
                               "message": ["role": "user", "content": "hi"]])
        #expect(entry(object)?.origin == .peer)
    }

    @Test func aLineWithADuplicatedKeyCannotBeRead() {
        let line = #"{"type":"assistant","uuid":"a","message":{"content":[{"type":"text","text":"one","text":"two"}]}}"#
        #expect(entry(line) == nil)
        #expect(entry(#"{"type":"user""#) == nil)
        #expect(entry(#"{"type":"queue-operation","operation":"enqueue","content":"x"}"#)?.kind == .other)
    }

    @Test func aFreshTailGrowsUntilItHoldsTheTurnStart() throws {
        let tree = FixtureTree()
        let url = tree.projects.appendingPathComponent("ssh-x/t.jsonl")
        // The prompt, then about 700 KB of tool traffic, then the reply.
        var lines = [Line.user("start", uuid: "u0", at: fixtureNow)]
        let filler = String(repeating: "y", count: 20_000)
        for i in 0..<35 {
            lines.append(Line.toolUse("Read", id: "toolu_\(i)", uuid: "a\(i)", at: fixtureNow, input: ["file_path": "/x/\(i).swift"]))
            lines.append(Line.toolResult("toolu_\(i)", uuid: "r\(i)", at: fixtureNow, content: filler))
        }
        lines.append(Line.text("All done", uuid: "final", at: fixtureNow))
        try tree.writeLines(lines, to: url)
        let path = try #require(CarefulPath(root: tree.projects.path, components: ["ssh-x", "t.jsonl"]))
        let read = try TranscriptReader.read(path, owner: getuid(), cursor: nil).get()
        #expect(read.kind == .fresh(.first))
        #expect(read.holdsTurnStart)
        #expect(read.lines.first?.entry?.uuid == "u0")
        #expect(read.lines.last?.entry?.uuid == "final")
        #expect(read.cursor.nextOffset == read.cursor.identity.size)
    }

    @Test func aTurnLongerThanTwoMegabytesIsNotHeld() throws {
        let tree = FixtureTree()
        let url = tree.projects.appendingPathComponent("ssh-x/t.jsonl")
        var lines = [Line.user("start", uuid: "u0", at: fixtureNow)]
        let filler = String(repeating: "z", count: 100_000)
        for i in 0..<25 { lines.append(Line.toolResult("toolu_\(i)", uuid: "r\(i)", at: fixtureNow, content: filler)) }
        lines.append(Line.text("End", uuid: "final", at: fixtureNow))
        try tree.writeLines(lines, to: url)
        let path = try #require(CarefulPath(root: tree.projects.path, components: ["ssh-x", "t.jsonl"]))
        let read = try TranscriptReader.read(path, owner: getuid(), cursor: nil).get()
        #expect(!read.holdsTurnStart && !read.reachedFileStart)
        #expect(!read.lines.contains { $0.entry?.uuid == "u0" })
        let tracker = track(lines.suffix(3))
        #expect(tracker.turn?.startHeld == false)
    }

    @Test func appendedReadsTakeOnlyNewCompleteLines() throws {
        let tree = FixtureTree()
        let url = tree.projects.appendingPathComponent("ssh-x/t.jsonl")
        try tree.writeLines([Line.user("start", uuid: "u0", at: fixtureNow)], to: url)
        // An unfinished last line is left for later.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let partial = Line.text("Half", uuid: "a1", at: fixtureNow)
        try handle.write(contentsOf: Data(partial.prefix(20).utf8))
        try handle.close()
        let path = try #require(CarefulPath(root: tree.projects.path, components: ["ssh-x", "t.jsonl"]))
        let first = try TranscriptReader.read(path, owner: getuid(), cursor: nil).get()
        #expect(first.lines.count == 1)
        let handle2 = try FileHandle(forWritingTo: url)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: Data((partial.dropFirst(20) + "\n").utf8))
        try handle2.close()
        let second = try TranscriptReader.read(path, owner: getuid(), cursor: first.cursor).get()
        #expect(second.kind == .appended)
        #expect(second.lines.map { $0.entry?.uuid } == ["a1"])
        let third = try TranscriptReader.read(path, owner: getuid(), cursor: second.cursor).get()
        #expect(third.kind == .unchanged && third.lines.isEmpty)
    }

    @Test func replacedCutAndFarAheadFilesStartOver() throws {
        let tree = FixtureTree()
        let url = tree.projects.appendingPathComponent("ssh-x/t.jsonl")
        try tree.writeLines([Line.user("start", uuid: "u0", at: fixtureNow), Line.text("one", uuid: "a1", at: fixtureNow)], to: url)
        let path = try #require(CarefulPath(root: tree.projects.path, components: ["ssh-x", "t.jsonl"]))
        let first = try TranscriptReader.read(path, owner: getuid(), cursor: nil).get()
        // Replaced: a new inode.
        let other = tree.root.appendingPathComponent("other.jsonl")
        try tree.writeLines([Line.user("again", uuid: "u5", at: fixtureNow), Line.text("two", uuid: "a5", at: fixtureNow),
                             Line.text("three", uuid: "a6", at: fixtureNow)], to: other)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: other)
        let replaced = try TranscriptReader.read(path, owner: getuid(), cursor: first.cursor).get()
        #expect(replaced.kind == .fresh(.replaced))
        // Cut: smaller than before.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 10)
        try handle.close()
        let cut = try TranscriptReader.read(path, owner: getuid(), cursor: replaced.cursor).get()
        #expect(cut.kind == .fresh(.cut))
        // More than 2 MB appended: a fresh tail instead of everything since.
        try tree.writeLines([Line.user("start", uuid: "u0", at: fixtureNow)], to: url)
        let base = try TranscriptReader.read(path, owner: getuid(), cursor: nil).get()
        let big = String(repeating: "q", count: 100_000)
        try tree.writeLines((0..<25).map { Line.toolResult("t\($0)", uuid: "r\($0)", at: fixtureNow, content: big) }, to: url, append: true)
        let gap = try TranscriptReader.read(path, owner: getuid(), cursor: base.cursor).get()
        #expect(gap.kind == .fresh(.gap))
    }

    @Test func aSymlinkedTranscriptIsRefused() throws {
        let tree = FixtureTree()
        let real = tree.root.appendingPathComponent("elsewhere.jsonl")
        try tree.writeLines([Line.user("x", uuid: "u", at: fixtureNow)], to: real)
        try FileManager.default.createDirectory(at: tree.projects.appendingPathComponent("ssh-x"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tree.projects.appendingPathComponent("ssh-x/t.jsonl"), withDestinationURL: real)
        let path = try #require(CarefulPath(root: tree.projects.path, components: ["ssh-x", "t.jsonl"]))
        #expect(throws: CarefulReadFailure.link) { try TranscriptReader.read(path, owner: getuid(), cursor: nil).get() }
    }

    @Test func aHugeLineIsSkippedAndCountsAsUnreadable() throws {
        let tree = FixtureTree()
        let url = tree.projects.appendingPathComponent("ssh-x/t.jsonl")
        try tree.writeLines([Line.user("start", uuid: "u0", at: fixtureNow)], to: url)
        let path = try #require(CarefulPath(root: tree.projects.path, components: ["ssh-x", "t.jsonl"]))
        let first = try TranscriptReader.read(path, owner: getuid(), cursor: nil).get()
        let huge = Line.toolResult("t", uuid: "r", at: fixtureNow, content: String(repeating: "h", count: TranscriptReader.maxLineBytes))
        try tree.writeLines([huge, Line.text("after", uuid: "a9", at: fixtureNow)], to: url, append: true)
        // Read in steps below the gap limit is not possible for 8 MB, so the reader starts over; the window drops it.
        let next = try TranscriptReader.read(path, owner: getuid(), cursor: first.cursor).get()
        #expect(next.lines.last?.entry?.uuid == "a9")
        #expect(!next.lines.contains { $0.entry?.uuid == "r" })
    }

    @Test func projectFolderNamesReplaceEverythingOutsideLettersDigitsAndHyphen() {
        #expect(SessionRecord.projectFolderName("/Users/someone/my project") == "-Users-someone-my-project")
        #expect(SessionRecord.projectFolderName("/Users/someone/x/.claude/worktrees/agent-1") == "-Users-someone-x--claude-worktrees-agent-1")
        #expect(SessionRecord.projectFolderName("/a/b_c.d") == "-a-b-c-d")
        #expect(SessionRecord.projectFolderName("/a/ü") == "-a--")
        #expect(SessionRecord.projectFolderName("relative/path") == nil)
        #expect(SessionRecord.projectFolderName("/" + String(repeating: "a", count: 300)) == nil)
    }
}
