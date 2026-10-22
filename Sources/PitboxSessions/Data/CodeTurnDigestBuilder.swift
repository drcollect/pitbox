import Foundation
import PitboxKit

/// Builds the turn digest line by line. `TurnTracker` holds one and feeds it every line it sees, fresh tails and
/// appended lines alike, so the digest's latest turn follows the same rules as the tracker's own: a user entry that is
/// not a tool result starts a turn, subagent side chains are left out, and a turn is finished by the transcript's
/// status rule (the session file's `midTurn` is applied by `digest(…)`). Lines must be parsed with
/// `TranscriptEntry.parse(_:digestFacts: true)` for commands, result heads, `toolUseResult` and notices; without those
/// facts the digest still has its turns, texts and tool names.
///
/// Bounds: turns before the oldest one the rules can still need are dropped when a turn starts,
/// then the oldest turns (or a single huge turn's oldest items) go once the digest holds more than
/// `CodeTuning.digestBytesMax` bytes of strings, `CodeTuning.digestTurnsMax` turns or
/// `CodeTuning.digestItemsPerTurnMax` items in one turn.
struct CodeTurnDigestBuilder: Equatable, Sendable {
    typealias Turn = CodeTurnDigest.Turn

    /// The latest turn's state for the finished rule (the same fields as `TurnTracker`'s `TranscriptTurn`).
    private struct Track: Equatable, Sendable {
        var hasAssistant = false
        var lastStopReason: String?
        /// Tool_use ids waiting for their result; a call without an id never gets one (as in `TurnTracker`).
        var pending: [String?] = []
        var userAfterAssistant = false
        var lastAssistantUUID: String?
        var lastAssistantAt: Date?

        var endedByTranscript: Bool { hasAssistant && lastStopReason == "end_turn" && pending.isEmpty && !userAfterAssistant }
    }

    private(set) var turns: [Turn] = []
    /// Per turn (parallel to `turns`): the valid uuids of its entries and the bytes of its strings.
    private var turnUUIDs: [[String]] = []
    private var turnBytes: [Int] = []
    /// Uuids of entries read before any turn (system entries at the tail's start); dropped with the first start.
    private var looseUUIDs: [String] = []
    private var track = Track()
    private var uuidCounts: [String: Int] = [:]
    private(set) var duplicateUUIDs: Set<String> = []
    /// Tool_use ids of the digest with their tool names (for results) and how often each occurs.
    private var toolNames: [String: String] = [:]
    private var toolUseIDCounts: [String: Int] = [:]
    private var bytes = 0
    /// Turns or items the rules wanted were dropped by a bound.
    private(set) var truncated = false

    /// Bytes counted per item beyond its strings, so a flood of tiny items is bounded too.
    static let itemOverhead = 64

    /// The tool_use ids in the digest (for marking fork copies across sessions).
    var toolUseIDs: Set<String> { Set(toolUseIDCounts.keys) }

    /// The string bytes held (tests).
    var byteCount: Int { bytes }

    // MARK: Feeding

    mutating func feed(_ line: TranscriptLine) {
        guard let entry = line.entry else {
            if !turns.isEmpty { turns[turns.count - 1].unreadableLine = true }
            return
        }
        guard !entry.isSidechain else { return }
        switch entry.kind {
        case .user:
            if entry.isToolResult { addResults(entry) } else { startTurn(entry) }
        case .assistant:
            addAssistant(entry)
        case .other:
            addNotices(entry)
        case .system:
            break
        }
        if let uuid = entry.uuid { note(uuid) }
    }

    /// The digest as of now. `midTurn` is the session file's `sshReattach.midTurn` (the latest turn is not finished
    /// while it is true); `copied` holds the tool_use ids also found in another followed session's digest.
    func digest(midTurn: Bool, lastGrowthAt: Date?, lastActivityMovedAt: Date?,
                publishedArtifacts: [CodeTurnDigest.PublishedArtifact], copied: Set<String> = []) -> CodeTurnDigest {
        var out = turns
        for index in out.indices {
            if index == out.count - 1, midTurn {
                out[index].isFinished = false
                out[index].finishedAt = nil
                out[index].replyUUID = nil
            }
            if !copied.isEmpty {
                for k in out[index].items.indices {
                    guard case .toolUse(var tool) = out[index].items[k], let id = tool.id, copied.contains(id) else { continue }
                    tool.isCopied = true
                    out[index].items[k] = .toolUse(tool)
                }
            }
            let turn = out[index]
            out[index].readCompletely = turn.startHeld && !turn.unreadableLine && !turn.itemsDropped
                && !turn.finalReply.contains(where: \.cut)
        }
        let frontCut = out.first.map { !$0.startHeld } ?? false
        return CodeTurnDigest(turns: out, lastGrowthAt: lastGrowthAt, lastActivityMovedAt: lastActivityMovedAt,
                              publishedArtifacts: publishedArtifacts, duplicateUUIDs: duplicateUUIDs,
                              truncated: truncated || frontCut)
    }

    // MARK: Entries

    private mutating func startTurn(_ entry: TranscriptEntry) {
        let origin = entry.origin ?? .unknown
        let usersOwn = origin == .human && !entry.isMeta && !entry.isCompactSummary
        let text = entry.messageText
        let turn = Turn(startUUID: entry.uuid, startedAt: entry.timestamp, origin: origin, startHeld: true,
                        askedHead: usersOwn ? CodeText.firstLines(text, count: 2, limit: 200) : nil, isFinished: false,
                        finishedAt: nil, replyUUID: nil, readCompletely: false, readWeb: false, unreadableLine: false,
                        itemsDropped: false, items: [])
        for uuid in looseUUIDs { forget(uuid) }
        looseUUIDs = []
        turns.append(turn)
        turnUUIDs.append([])
        turnBytes.append((turn.askedHead?.utf8.count ?? 0) + Self.itemOverhead)
        bytes += turnBytes[turnBytes.count - 1]
        track = Track()
        for notice in TaskNotices.parse(text, at: entry.timestamp, carrier: .userText) { append(.notice(notice)) }
        pruneTurns()
    }

    private mutating func addResults(_ entry: TranscriptEntry) {
        ensureTurn()
        let facts = entry.digest
        var position = 0
        for block in entry.blocks {
            guard case .toolResult(let id) = block else { continue }
            let fact = facts.flatMap { position < $0.results.count ? $0.results[position] : nil }
            position += 1
            if let index = track.pending.firstIndex(where: { $0 != nil && $0 == id }) { track.pending.remove(at: index) }
            let name = id.flatMap { toolNames[$0] }
            let head = fact?.head ?? ""
            var result = CodeTurnDigest.ToolResult(
                toolUseID: id, uuid: entry.uuid, at: entry.timestamp, toolName: name, isError: fact?.isError,
                exitCode: Self.exitCode(head), denied: (facts?.denied ?? false) || (fact?.denied ?? false)
                    || head.hasPrefix("<tool_use_error>"),
                head: head)
            if position == 1, let info = facts?.toolUseResult {
                (result.asyncTaskID, result.asyncKind) = Self.asyncTask(info, toolName: name)
                if name == "Artifact" { result.artifactURL = info.url }
            }
            append(.toolResult(result))
        }
        if track.hasAssistant { track.userAfterAssistant = true }
        updateFinished()
    }

    private mutating func addAssistant(_ entry: TranscriptEntry) {
        ensureTurn()
        for block in entry.blocks {
            switch block {
            case .text(let text, let cut):
                let (kept, shortened) = Self.capped(text, bytes: CodeTuning.digestTextMax)
                append(.text(CodeTurnDigest.Text(uuid: entry.uuid, at: entry.timestamp, text: kept, cut: cut || shortened)))
            case .toolUse(let tool):
                track.pending.append(tool.id)
                if StepWords.readsWeb(tool.name) { turns[turns.count - 1].readWeb = true }
                append(.toolUse(Self.toolUse(tool, entry: entry)))
            case .serverToolUse(let name):
                if name.lowercased().contains("web") { turns[turns.count - 1].readWeb = true }
                append(.toolUse(CodeTurnDigest.ToolUse(id: nil, uuid: entry.uuid, at: entry.timestamp, name: name,
                                                       isServerTool: true)))
            case .thinking, .toolResult, .other:
                break
            }
        }
        track.hasAssistant = true
        track.lastAssistantUUID = entry.uuid
        track.lastAssistantAt = entry.timestamp
        track.lastStopReason = entry.stopReason
        track.userAfterAssistant = false
        updateFinished()
    }

    /// A `queued_command` attachment or a `queue-operation` enqueue (the parser keeps only those, with their texts).
    private mutating func addNotices(_ entry: TranscriptEntry) {
        guard let facts = entry.digest, let carrier = facts.noticeCarrier else { return }
        let notices = facts.noticeTexts.flatMap { TaskNotices.parse($0, at: entry.timestamp, carrier: carrier) }
        guard !notices.isEmpty else { return }
        ensureTurn()
        for notice in notices { append(.notice(notice)) }
    }

    /// The partial turn at the front of a tail, for entries that come before any turn start.
    private mutating func ensureTurn() {
        guard turns.isEmpty else { return }
        turns.append(Turn(startUUID: nil, startedAt: nil, origin: .unknown, startHeld: false, askedHead: nil,
                          isFinished: false, finishedAt: nil, replyUUID: nil, readCompletely: false, readWeb: false,
                          unreadableLine: false, itemsDropped: false, items: []))
        turnUUIDs.append(looseUUIDs)
        looseUUIDs = []
        turnBytes.append(Self.itemOverhead)
        bytes += Self.itemOverhead
        track = Track()
    }

    private mutating func updateFinished() {
        let index = turns.count - 1
        let finished = track.endedByTranscript
        turns[index].isFinished = finished
        turns[index].finishedAt = finished ? track.lastAssistantAt : nil
        turns[index].replyUUID = finished ? track.lastAssistantUUID : nil
    }

    // MARK: Bookkeeping

    private mutating func note(_ uuid: String) {
        if turns.isEmpty {
            looseUUIDs.append(uuid)
        } else {
            turnUUIDs[turnUUIDs.count - 1].append(uuid)
        }
        let count = (uuidCounts[uuid] ?? 0) + 1
        uuidCounts[uuid] = count
        if count == 2 { duplicateUUIDs.insert(uuid) }
    }

    private mutating func forget(_ uuid: String) {
        guard let count = uuidCounts[uuid] else { return }
        if count <= 1 {
            uuidCounts[uuid] = nil
        } else {
            uuidCounts[uuid] = count - 1
            if count - 1 < 2 { duplicateUUIDs.remove(uuid) }
        }
    }

    private mutating func append(_ item: CodeTurnDigest.Item) {
        let index = turns.count - 1
        if case .toolUse(let tool) = item, let id = tool.id {
            toolUseIDCounts[id, default: 0] += 1
            toolNames[id] = tool.name
        }
        let size = Self.size(of: item)
        turns[index].items.append(item)
        turnBytes[index] += size
        bytes += size
        if turns[index].items.count > CodeTuning.digestItemsPerTurnMax {
            dropItems(ofTurn: index, count: max(1, turns[index].items.count / 8))
            truncated = true
        }
        if bytes > CodeTuning.digestBytesMax { shrink() }
    }

    /// Drops the oldest turns, then the oldest items of the one left, until the strings fit.
    private mutating func shrink() {
        while bytes > CodeTuning.digestBytesMax, turns.count > 1 {
            dropFirstTurn()
            truncated = true
        }
        while bytes > CodeTuning.digestBytesMax, let count = turns.first?.items.count, count > 1 {
            dropItems(ofTurn: 0, count: max(1, count / 8))
            truncated = true
        }
    }

    /// The retention rule (which turns the digest keeps), run when a turn starts.
    private mutating func pruneTurns() {
        // The partial turn at the front goes once it is not the latest ("only turns whose start is in the tail").
        if turns.count > 1, !turns[0].startHeld { dropFirstTurn() }
        // The third-newest finished turn of the user's, another session's or unknown origin (unknown counts as the
        // user's), the latest turn left out (it may still change): offers of turns before it cannot run any more.
        var finished = 0
        var keepFrom: Int?
        var index = turns.count - 2
        while index >= 0 {
            if turns[index].origin != .taskNotification, turns[index].isFinished {
                finished += 1
                if finished == CodeTuning.newerRepliesMax + 1 {
                    keepFrom = index
                    break
                }
            }
            index -= 1
        }
        if var from = keepFrom {
            // The work's start may lie further back (unknown-origin turns after a turn of the user's).
            if let work = turns.lastIndex(where: { $0.origin == .human || $0.origin == .peer }) { from = min(from, work) }
            for _ in 0..<from { dropFirstTurn() }
        }
        while turns.count > CodeTuning.digestTurnsMax {
            dropFirstTurn()
            truncated = true
        }
    }

    private mutating func dropFirstTurn() {
        guard !turns.isEmpty else { return }
        for item in turns[0].items { release(item) }
        for uuid in turnUUIDs[0] { forget(uuid) }
        bytes -= turnBytes[0]
        turns.removeFirst()
        turnUUIDs.removeFirst()
        turnBytes.removeFirst()
    }

    private mutating func dropItems(ofTurn index: Int, count: Int) {
        let n = min(count, turns[index].items.count)
        guard n > 0 else { return }
        var freed = 0
        for item in turns[index].items.prefix(n) {
            release(item)
            freed += Self.size(of: item)
        }
        turns[index].items.removeFirst(n)
        turns[index].itemsDropped = true
        turnBytes[index] -= freed
        bytes -= freed
    }

    private mutating func release(_ item: CodeTurnDigest.Item) {
        guard case .toolUse(let tool) = item, let id = tool.id, let count = toolUseIDCounts[id] else { return }
        if count <= 1 {
            toolUseIDCounts[id] = nil
            toolNames[id] = nil
        } else {
            toolUseIDCounts[id] = count - 1
        }
    }

    // MARK: Helpers

    static func toolUse(_ tool: TranscriptToolUse, entry: TranscriptEntry) -> CodeTurnDigest.ToolUse {
        let input = tool.input
        let name = tool.name
        var path: String?
        switch name {
        case "Edit", "Write", "MultiEdit": path = input.filePath
        case "NotebookEdit": path = input.notebookPath ?? input.filePath
        default: path = nil
        }
        return CodeTurnDigest.ToolUse(
            id: tool.id, uuid: entry.uuid, at: entry.timestamp, name: name, command: name == "Bash" ? input.command : nil,
            description: input.description, filePath: path,
            files: name == "SendUserFile" ? Array((input.files ?? []).prefix(CodeTuning.digestFilesMax)) : [],
            subagentType: input.subagentType, runInBackground: input.runInBackground,
            promptHead: input.subagentType == "dashboard-builder" ? input.prompt : nil)
    }

    /// The task a result started: `async_launched` with `agentId` or `taskId` (Agent, Task, Workflow), or a
    /// background Bash run's `backgroundTaskId`. Ids that fail `TaskNotices.isTaskID` start nothing.
    static func asyncTask(_ info: ToolUseResultFacts, toolName: String?) -> (String?, CodeTurnDigest.AsyncKind?) {
        if info.status == "async_launched" {
            let kind: CodeTurnDigest.AsyncKind?
            switch toolName {
            case "Workflow"?: kind = .workflow
            case "Agent"?, "Task"?: kind = .agent
            default:
                if info.taskType == "local_workflow" {
                    kind = .workflow
                } else if info.agentID != nil {
                    kind = .agent
                } else if info.taskID != nil {
                    kind = .workflow
                } else {
                    kind = nil
                }
            }
            let id = kind == .workflow ? (info.taskID ?? info.agentID) : (info.agentID ?? info.taskID)
            guard let kind, let id, TaskNotices.isTaskID(id) else { return (nil, nil) }
            return (id, kind)
        }
        if let id = info.backgroundTaskID, TaskNotices.isTaskID(id) { return (id, .bash) }
        return (nil, nil)
    }

    /// `^Exit code (\d+)`: at most 9 digits.
    static func exitCode(_ head: String) -> Int? {
        let prefix = "Exit code "
        guard head.hasPrefix(prefix) else { return nil }
        let digits = head.dropFirst(prefix.count).prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        return Int(digits)
    }

    /// `text` cut to at most `bytes` UTF-8 bytes at a scalar boundary, and whether it was cut.
    static func capped(_ text: String, bytes: Int) -> (String, Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        var kept = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let length = UTF8.width(scalar)
            guard used + length <= bytes else { break }
            kept.append(scalar)
            used += length
        }
        return (String(kept), true)
    }

    /// The bytes an item holds: its strings plus `itemOverhead`.
    static func size(of item: CodeTurnDigest.Item) -> Int {
        switch item {
        case .text(let text):
            return itemOverhead + text.text.utf8.count
        case .toolUse(let tool):
            return itemOverhead + tool.name.utf8.count + (tool.command?.utf8.count ?? 0)
                + (tool.description?.utf8.count ?? 0) + (tool.filePath?.utf8.count ?? 0)
                + tool.files.reduce(0) { $0 + $1.utf8.count } + (tool.promptHead?.utf8.count ?? 0)
        case .toolResult(let result):
            return itemOverhead + result.head.utf8.count + (result.artifactURL?.utf8.count ?? 0)
                + (result.asyncTaskID?.utf8.count ?? 0)
        case .notice:
            return itemOverhead
        }
    }

    // MARK: The fresh tail's reach

    /// Whether a fresh tail window reaches far enough for the digest: it holds the starts of the
    /// latest turn of the user's or another session's (the work) and of the third-newest finished turn of human, peer or
    /// unknown origin (the latest turn left out). `TranscriptReader` grows the window, up to 2 MB, until this holds.
    static func windowHoldsNeededTurns(_ lines: [TranscriptLine]) -> Bool {
        var finishedOthers = 0
        var humanOrPeer = false
        var current: (origin: CommandTurnOrigin, track: Track)?
        var closed: [(origin: CommandTurnOrigin, finished: Bool)] = []
        for line in lines {
            guard let entry = line.entry, !entry.isSidechain else { continue }
            switch entry.kind {
            case .user:
                if entry.isToolResult {
                    guard current != nil else { continue }
                    for block in entry.blocks {
                        guard case .toolResult(let id) = block,
                              let k = current?.track.pending.firstIndex(where: { $0 != nil && $0 == id }) else { continue }
                        current?.track.pending.remove(at: k)
                    }
                    if current?.track.hasAssistant == true { current?.track.userAfterAssistant = true }
                } else {
                    if let previous = current { closed.append((previous.origin, previous.track.endedByTranscript)) }
                    let origin = entry.origin ?? .unknown
                    if origin == .human || origin == .peer { humanOrPeer = true }
                    current = (origin, Track())
                }
            case .assistant:
                guard current != nil else { continue }
                for block in entry.blocks { if case .toolUse(let tool) = block { current?.track.pending.append(tool.id) } }
                current?.track.hasAssistant = true
                current?.track.lastStopReason = entry.stopReason
                current?.track.userAfterAssistant = false
            case .system, .other:
                continue
            }
        }
        for turn in closed where turn.origin != .taskNotification && turn.finished { finishedOthers += 1 }
        return humanOrPeer && finishedOthers >= CodeTuning.newerRepliesMax + 1
    }
}

/// `<task-notification>` blocks in a text: only the tags `task-id`, `tool-use-id`, `status`,
/// `agent_count` and `agents_done` are read; the rest of the text is never kept.
enum TaskNotices {
    static let open = "<task-notification>"
    static let close = "</task-notification>"
    /// At most this many notices are read from one text.
    static let maxPerText = 64

    static func parse(_ text: String, at: Date?, carrier: CodeTurnDigest.NoticeCarrier) -> [CodeTurnDigest.Notice] {
        guard text.contains(open) else { return [] }
        var notices: [CodeTurnDigest.Notice] = []
        var from = text.startIndex
        while notices.count < maxPerText, let start = text.range(of: open, range: from..<text.endIndex) {
            let bodyStart = start.upperBound
            var bodyEnd = text.endIndex
            var resume = text.endIndex
            if let end = text.range(of: close, range: bodyStart..<text.endIndex) {
                bodyEnd = end.lowerBound
                resume = end.upperBound
            }
            if let next = text.range(of: open, range: bodyStart..<text.endIndex), next.lowerBound < bodyEnd {
                bodyEnd = next.lowerBound
                resume = next.lowerBound
            }
            let body = text[bodyStart..<bodyEnd]
            let taskID = tag("task-id", in: body).flatMap { isTaskID($0) ? $0 : nil }
            let toolUseID = tag("tool-use-id", in: body).flatMap { isTaskID($0) ? $0 : nil }
            let status = tag("status", in: body).flatMap(statusWord)
            notices.append(CodeTurnDigest.Notice(at: at, taskID: taskID, toolUseID: toolUseID, status: status,
                                                 agentCount: tag("agent_count", in: body).flatMap(count),
                                                 agentsDone: tag("agents_done", in: body).flatMap(count),
                                                 carrier: carrier))
            from = resume
        }
        return notices
    }

    /// A task or tool_use id as notices and `toolUseResult` write them: 1-128 ASCII letters, digits, `_`, `-`, `.`, `:`.
    static func isTaskID(_ text: String) -> Bool {
        guard (1...128).contains(text.utf8.count) else { return false }
        return text.utf8.allSatisfy { CodeIDs.isAlphanumeric($0) || $0 == 0x5F || $0 == 0x2D || $0 == 0x2E || $0 == 0x3A }
    }

    /// The trimmed text between `<name>` and `</name>`, at most 256 characters.
    private static func tag(_ name: String, in body: Substring) -> String? {
        guard let open = body.range(of: "<\(name)>"),
              let close = body.range(of: "</\(name)>", range: open.upperBound..<body.endIndex) else { return nil }
        let value = body[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256 else { return nil }
        return value
    }

    /// A lowercase status word (letters, `_`, `-`, at most 32).
    private static func statusWord(_ text: String) -> String? {
        let lower = text.lowercased()
        guard (1...32).contains(lower.utf8.count),
              lower.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D }) else { return nil }
        return lower
    }

    /// A whole number 0...1,000,000.
    private static func count(_ text: String) -> Int? {
        guard (1...7).contains(text.utf8.count), text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(text)
    }
}
