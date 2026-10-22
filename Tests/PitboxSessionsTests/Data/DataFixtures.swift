import Darwin
import Foundation
@testable import PitboxSessions
import PitboxKit

// Invented data only: no line of the user's real session files, pop-out lists or transcripts appears in these tests.

/// "Now" for the fixtures: 2026-10-01 14:37:00 UTC.
let fixtureNow = Date(timeIntervalSince1970: 1_790_865_420)

/// Words that stand for session text (titles, replies, commands): they must never reach a log line.
let secretWord = "SECRET-SESSION-TEXT"

/// A clock tests move by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date = fixtureNow) { value = date }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

/// A value tests change while the engine reads it from its queue.
final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// An ISO timestamp as Claude writes them.
func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// One JSON object as a line (sorted keys, so fixtures are stable).
func jsonLine(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

/// Transcript lines in the measured shape: one entry per content block, `message.stop_reason` on each.
enum Line {
    static func user(_ text: String, uuid: String, at date: Date, origin: String? = "human", meta: Bool = false) -> String {
        var object: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": iso(date), "isSidechain": false,
                                     "userType": "external", "cwd": "/somewhere", "sessionId": "s1",
                                     "message": ["role": "user", "content": text]]
        if let origin { object["turnOrigin"] = origin }
        if meta { object["isMeta"] = true }
        return jsonLine(object)
    }

    static func toolResult(_ toolUseID: String, uuid: String, at date: Date, content: String = "ok \(secretWord)") -> String {
        jsonLine(["type": "user", "uuid": uuid, "timestamp": iso(date), "isSidechain": false,
                  "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolUseID,
                                                           "content": content, "is_error": false]]],
                  "toolUseResult": ["stdout": content, "stderr": "", "interrupted": false]])
    }

    static func text(_ text: String, uuid: String, at date: Date, stop: String? = "end_turn", sidechain: Bool = false) -> String {
        assistant(uuid: uuid, at: date, stop: stop, sidechain: sidechain, block: ["type": "text", "text": text])
    }

    static func thinking(uuid: String, at date: Date, stop: String? = "end_turn") -> String {
        assistant(uuid: uuid, at: date, stop: stop, block: ["type": "thinking", "thinking": "\(secretWord) pondering", "signature": "c2ln"])
    }

    static func toolUse(_ name: String, id: String, uuid: String, at date: Date, input: [String: Any] = [:],
                        stop: String? = "tool_use") -> String {
        assistant(uuid: uuid, at: date, stop: stop, block: ["type": "tool_use", "id": id, "name": name, "input": input])
    }

    static func system(uuid: String, at date: Date) -> String {
        jsonLine(["type": "system", "subtype": "stop_hook_summary", "uuid": uuid, "timestamp": iso(date), "content": "hooks ran"])
    }

    static func assistant(uuid: String, at date: Date, stop: String?, sidechain: Bool = false, block: [String: Any]) -> String {
        var message: [String: Any] = ["role": "assistant", "id": "msg_\(uuid)", "type": "message", "model": "claude-opus-5-5",
                                      "content": [block], "usage": ["input_tokens": 3, "output_tokens": 10]]
        message["stop_reason"] = stop ?? NSNull()
        return jsonLine(["type": "assistant", "uuid": uuid, "timestamp": iso(date), "isSidechain": sidechain,
                         "requestId": "req_\(uuid)", "message": message])
    }
}

/// A session file (`local_<id>.json`) in the shape Claude writes.
struct SessionFixture {
    var title = "buildbox \u{00B7} Fix the \(secretWord) build (quiet fern)"
    var cwd = "/home/someone/project"
    var cli = "0f3c2a9e-1111-2222-3333-444455556666"
    var sshHost: String? = "buildbox"
    var model = "claude-opus-5-5"
    var permissionMode = "default"
    var archived = false
    var lastActivity: Date = fixtureNow.addingTimeInterval(-60)
    var summary: (category: String, detail: String, needs: String, uuid: String)?
    var midTurn: Bool?
    var extra: [String: Any] = [:]

    var json: String {
        var object: [String: Any] = ["title": title, "titleSource": "auto", "previousTitles": ["Earlier \(secretWord) title"],
                                     "cwd": cwd, "cliSessionId": cli, "model": model, "effort": "high",
                                     "permissionMode": permissionMode, "isArchived": archived,
                                     "lastActivityAt": Int(lastActivity.timeIntervalSince1970 * 1000),
                                     "completedTurns": 4, "error": NSNull(), "interruptedAwaitingPerson": NSNull(),
                                     "stoppedUntilPersonSends": NSNull(), "unknownKey": ["nested": [1, 2, 3]]]
        if let sshHost { object["sshConfig"] = ["sshHost": sshHost] }
        if let midTurn { object["sshReattach"] = ["midTurn": midTurn, "recordedAt": 1] }
        if let summary {
            object["postTurnSummary"] = ["status_category": summary.category, "status_detail": summary.detail,
                                         "needs_action": summary.needs, "summarizes_uuid": summary.uuid]
            object["postTurnSummaryFor"] = summary.uuid
        } else {
            object["postTurnSummary"] = NSNull()
        }
        for (key, value) in extra { object[key] = value }
        return jsonLine(object)
    }
}

/// A folder tree that looks like the user's (Application Support with profile folders, `~/.claude/projects`, `~/.ssh`),
/// below a fresh temporary folder (created first, then resolved, so `/private/var` and `/var` cannot differ).
final class FixtureTree: @unchecked Sendable {
    let root: URL
    let appSupport: URL
    let projects: URL
    let ssh: URL
    let home: URL
    let account = "acct-1"
    let org = "org-1"

    init(_ name: String = "code") {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = raw.resolvingSymlinksInPath()
        appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        projects = root.appendingPathComponent(".claude/projects", isDirectory: true)
        ssh = root.appendingPathComponent(".ssh", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        for folder in [appSupport, projects, ssh, home] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var sshConfig: URL { ssh.appendingPathComponent("config") }

    func profileFolder(_ profile: CodeProfile) -> URL { appSupport.appendingPathComponent(profile.folderName, isDirectory: true) }

    func sessionFileURL(_ id: String, profile: CodeProfile = .a) -> URL {
        profileFolder(profile).appendingPathComponent("claude-code-sessions/\(account)/\(org)/\(id).json")
    }

    @discardableResult
    func writeSession(_ id: String, _ fixture: SessionFixture, profile: CodeProfile = .a) throws -> URL {
        let url = sessionFileURL(id, profile: profile)
        try write(fixture.json, to: url)
        return url
    }

    func writeRawSession(_ id: String, _ text: String, profile: CodeProfile = .a) throws {
        try write(text, to: sessionFileURL(id, profile: profile))
    }

    func writePopouts(_ ids: [String], titles: [String: String] = [:], profile: CodeProfile = .a) throws {
        let popouts: [[String: Any]] = ids.map { id in
            ["sessionId": id, "sessionType": "code", "isSsh": true, "title": titles[id] ?? "Pop-out \(secretWord)",
             "bounds": ["x": 100, "y": 80, "width": 900, "height": 700]]
        }
        try write(jsonLine(["version": 1, "popouts": popouts]), to: profileFolder(profile).appendingPathComponent("session-popouts.json"))
    }

    func removePopouts(profile: CodeProfile = .a) {
        try? FileManager.default.removeItem(at: profileFolder(profile).appendingPathComponent("session-popouts.json"))
    }

    /// The SSH mirror of `cli`.
    func mirrorURL(_ cli: String) -> URL { projects.appendingPathComponent("ssh-\(cli)/\(cli).jsonl") }

    /// The local transcript of `cli` for a session working in `cwd`.
    func localTranscriptURL(_ cli: String, cwd: String) -> URL {
        projects.appendingPathComponent("\(SessionRecord.projectFolderName(cwd) ?? "bad")/\(cli).jsonl")
    }

    func writeLines(_ lines: [String], to url: URL, append: Bool = false) throws {
        let text = lines.map { $0 + "\n" }.joined()
        if append, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try write(text, to: url)
        }
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A working folder that exists on this Mac (with a space and a dot, like real ones).
    func localFolder(_ name: String = "work/my project.app") -> String {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func environment(clock: ManualClock, processes: Shared<[ClaudeProcessCandidate]>,
                     settings: CodeSettings = CodeSettings(), programs: Set<String>? = ["ls", "git", "brew", "open", "scp", "echo"],
                     hostName: String? = "192.0.2.10", watches: Bool = false, maxWatched: Int = 24) -> CodeSessionsEnvironment {
        // The tests' copies B and C are listed copies (only the default copy A is built in).
        var listed = settings
        if listed.profiles.isEmpty { listed.profiles = [.testB, .testC] }
        let settings = listed
        return CodeSessionsEnvironment(applicationSupport: appSupport, claudeProjects: projects, sshConfig: sshConfig,
                                homeDirectory: home.path, userName: "someone", userID: getuid(),
                                clock: { clock.now }, processes: { processes.value },
                                hostName: { _ in hostName }, programsOnCleanPath: { _ in programs },
                                settings: { settings }, watchesFiles: watches, observesApplications: false,
                                parseInterval: watches ? 0.2 : 0, watchLatency: 0.1, maxWatchedSessions: maxWatched)
    }

    /// The process list with copy A running.
    func copyA() -> ClaudeProcessCandidate {
        ClaudeProcessCandidate(pid: 4242, arguments: ["/Applications/Claude.app/Contents/MacOS/Claude"],
                               bundlePath: "/Applications/Claude.app", version: "2.42304.0")
    }

    func copyB() -> ClaudeProcessCandidate {
        ClaudeProcessCandidate(pid: 4343, arguments: ["/x/Claude.app/Contents/MacOS/Claude",
                                                      "--user-data-dir=\(profileFolder(.b).path)"],
                               bundlePath: "/x/Claude.app", version: "2.42304.0")
    }
}

/// Calls `body` with the bytes of `text`.
func withBytes<T>(_ text: String, _ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
    let bytes = Array(text.utf8)
    return try bytes.withUnsafeBytes { try body($0) }
}

/// Feeds `lines` to a fresh tracker (offsets as if the lines were a file).
func track(_ lines: [String], now: Date = fixtureNow) -> TurnTracker {
    var tracker = TurnTracker()
    var offset: Int64 = 0
    for text in lines {
        let entry = withBytes(text) { TranscriptEntry.parse($0) }
        tracker.feed(TranscriptLine(entry: entry, offset: offset, length: text.utf8.count), fallbackTime: now)
        offset += Int64(text.utf8.count + 1)
    }
    return tracker
}

let sessionA = "local_0aaaaaaa-1111-4111-8111-000000000001"
let sessionB = "local_0bbbbbbb-2222-4222-8222-000000000002"
let sessionC = "local_0ccccccc-3333-4333-8333-000000000003"
