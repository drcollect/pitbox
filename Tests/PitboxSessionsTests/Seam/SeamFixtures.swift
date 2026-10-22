import Darwin
import Foundation
@testable import PitboxSessions
import PitboxKit

// Invented data only, in the measured shapes (counts and field names, never the user's text).

/// A fresh folder, created first and then resolved (so `/var` and `/private/var` cannot differ); removed at the end.
final class SeamFolder: @unchecked Sendable {
    let url: URL

    init(_ name: String) {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        url = raw.resolvingSymlinksInPath()
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    /// The names in the folder (temporary files of a writer would show here).
    var names: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
}

/// The text of one `<task-notification>` (only its tags are ever read).
func noticeText(taskID: String? = nil, toolUseID: String? = nil, status: String = "completed", agentCount: Int? = nil,
                agentsDone: Int? = nil) -> String {
    var parts = ["<task-notification>"]
    if let taskID { parts.append("<task-id>\(taskID)</task-id>") }
    if let toolUseID { parts.append("<tool-use-id>\(toolUseID)</tool-use-id>") }
    parts.append("<status>\(status)</status>")
    parts.append("<summary>\(secretWord) agent summary</summary>")
    if let agentCount { parts.append("<agent_count>\(agentCount)</agent_count>") }
    if let agentsDone { parts.append("<agents_done>\(agentsDone)</agents_done>") }
    parts.append("</task-notification>")
    return parts.joined(separator: "\n")
}

/// Transcript lines for the turn digest, beside `Line` (DataFixtures).
enum SeamLine {
    static func bash(_ command: String, description: String, id: String, uuid: String, at: Date,
                     background: Bool? = nil) -> String {
        var input: [String: Any] = ["command": command, "description": description]
        if let background { input["run_in_background"] = background }
        return Line.toolUse("Bash", id: id, uuid: uuid, at: at, input: input)
    }

    /// A tool_result: `content` as a string (or text blocks), `is_error`, and the entry's `toolUseResult` and
    /// `toolDenialKind` when given.
    static func result(_ toolUseID: String, uuid: String, at: Date, content: Any, isError: Bool? = false,
                       toolUseResult: Any? = nil, denial: String? = nil) -> String {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": toolUseID, "content": content]
        if let isError { block["is_error"] = isError }
        var object: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": iso(at), "isSidechain": false,
                                     "message": ["role": "user", "content": [block]]]
        if let toolUseResult { object["toolUseResult"] = toolUseResult }
        if let denial { object["toolDenialKind"] = denial }
        return jsonLine(object)
    }

    static func agent(_ subagent: String, id: String, uuid: String, at: Date, prompt: String,
                      background: Bool = true) -> String {
        Line.toolUse("Agent", id: id, uuid: uuid, at: at,
                     input: ["description": "Agent \(secretWord)", "prompt": prompt, "subagent_type": subagent,
                             "run_in_background": background])
    }

    /// A user entry whose text is a notice (a turn started by it).
    static func noticeTurn(_ text: String, uuid: String, at: Date, origin: String? = "task_notification") -> String {
        Line.user(text, uuid: uuid, at: at, origin: origin)
    }

    /// A `queued_command` attachment holding a notice (mid-turn).
    static func queuedCommand(_ text: String, uuid: String, at: Date) -> String {
        jsonLine(["type": "attachment", "uuid": uuid, "timestamp": iso(at), "isSidechain": false,
                  "attachment": ["type": "queued_command", "prompt": text, "commandMode": "task-notification"]])
    }

    /// A `queue-operation` entry (enqueue holds the notice; remove does not count).
    static func queueOperation(_ text: String, at: Date, operation: String = "enqueue") -> String {
        jsonLine(["type": "queue-operation", "operation": operation, "timestamp": iso(at), "content": text,
                  "sessionId": "s1"])
    }

    static func sendUserFile(_ files: [String], id: String, uuid: String, at: Date) -> String {
        Line.toolUse("SendUserFile", id: id, uuid: uuid, at: at,
                     input: ["files": files, "status": "normal", "caption": "\(secretWord) caption"])
    }

    static func edit(_ path: String, id: String, uuid: String, at: Date, tool: String = "Edit") -> String {
        Line.toolUse(tool, id: id, uuid: uuid, at: at,
                     input: ["file_path": path, "old_string": "\(secretWord) a", "new_string": "\(secretWord) b"])
    }
}

/// Parses `lines` in digest mode and feeds them to a fresh tracker (offsets as if they were a file).
func digestTracker(_ lines: [String], now: Date = fixtureNow) -> TurnTracker {
    var tracker = TurnTracker()
    var offset: Int64 = 0
    for text in lines {
        let entry = withBytes(text) { TranscriptEntry.parse($0, digestFacts: true) }
        tracker.feed(TranscriptLine(entry: entry, offset: offset, length: text.utf8.count), fallbackTime: now)
        offset += Int64(text.utf8.count + 1)
    }
    return tracker
}

/// The digest of `lines` as the engine would build it.
func digestOf(_ lines: [String], midTurn: Bool = false) -> CodeTurnDigest {
    digestTracker(lines).digest.digest(midTurn: midTurn, lastGrowthAt: nil, lastActivityMovedAt: nil, publishedArtifacts: [])
}

/// A per-session deriver for tests: it records what it was given and lets the test set fields.
final class RecordingDeriver: CodeSessionDeriver, @unchecked Sendable {
    struct Seen {
        var sessionID: String
        var digest: CodeTurnDigest
        var digestVersion: Int
        var snapshot: CodeSessionSnapshot
        var now: Date
        var memory: CodeMemoryStore
        var settings: CodeSettings
        var transcript: CarefulPath?
        var sessionFile: CarefulPath?
    }

    let label: String
    let order: Int
    private let lock = NSLock()
    private var seenInputs: [Seen] = []
    private var leftIDs: [String] = []
    private let body: @Sendable (CodeDeriveInput, inout CodeDerivedFields) -> Void

    init(label: String = "recording", order: Int = CodeDeriveOrder.work,
         body: @escaping @Sendable (CodeDeriveInput, inout CodeDerivedFields) -> Void = { _, _ in }) {
        self.label = label
        self.order = order
        self.body = body
    }

    func derive(_ input: CodeDeriveInput, into fields: inout CodeDerivedFields) {
        lock.withLock {
            seenInputs.append(Seen(sessionID: input.sessionID, digest: input.digest, digestVersion: input.digestVersion,
                                   snapshot: input.snapshot, now: input.now, memory: input.memory, settings: input.settings,
                                   transcript: input.transcript, sessionFile: input.sessionFile))
        }
        body(input, &fields)
    }

    func sessionLeft(_ sessionID: String) { lock.withLock { leftIDs.append(sessionID) } }

    var seen: [Seen] { lock.withLock { seenInputs } }
    var left: [String] { lock.withLock { leftIDs } }
    func runs(for id: String) -> Int { seen.filter { $0.sessionID == id }.count }
}

/// A cross-session deriver for tests.
final class RecordingCrossDeriver: CodeCrossSessionDeriver, @unchecked Sendable {
    let label = "cross"
    let order: Int
    private let lock = NSLock()
    private var inputs: [[CodeCrossSessionInput]] = []
    private let body: @Sendable ([CodeCrossSessionInput], inout [String: CodeDerivedFields]) -> Void

    init(order: Int = CodeDeriveOrder.sameFile,
         body: @escaping @Sendable ([CodeCrossSessionInput], inout [String: CodeDerivedFields]) -> Void = { _, _ in }) {
        self.order = order
        self.body = body
    }

    func derive(_ sessions: [CodeCrossSessionInput], context: CodeCrossDeriveContext,
                into fields: inout [String: CodeDerivedFields]) {
        lock.withLock { inputs.append(sessions) }
        body(sessions, &fields)
    }

    var runs: [[CodeCrossSessionInput]] { lock.withLock { inputs } }
}

/// Waits (suspending, never parking a thread) until `condition` holds or `seconds` pass.
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = MonotonicClock.now() + seconds
    while !condition() {
        if MonotonicClock.now() > deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}
