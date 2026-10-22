import Foundation
import PitboxKit

/// One plan or todo item as a tool call wrote it.
struct PlanItemInput: Equatable, Sendable {
    var content: String
    var status: String?
}

/// What the app looks at in a tool call's input: words for the "Now" line and the plan or todo list. The command a tool
/// ran and every other input are never decoded (what Claude ran itself is never an offer), except for the turn digest
/// (`TranscriptEntry.parse(_:digestFacts: true)`): its fields below are nil otherwise, and they are never offers, never
/// shown as commands and never logged.
struct ToolInputFacts: Equatable, Sendable {
    var description: String?
    var filePath: String?
    var notebookPath: String?
    var subagentType: String?
    /// Digest only: Bash `command` and an Agent or Task `prompt`, their first `CodeTuning.digestHeadMax` characters.
    var command: String?
    var prompt: String?
    /// Digest only: SendUserFile `files` (strings only, at most `CodeTuning.digestFilesMax`).
    var files: [String]?
    /// Digest only: `run_in_background` (Agent, Task, Bash).
    var runInBackground: Bool?
    /// `mcp__ccd_turn__update_plan`: `items`, `advance`, `done`, `start`.
    var planItems: [PlanItemInput]?
    var advance: Bool?
    var done: [Int]?
    var start: Int?
    /// TodoWrite: `todos`.
    var todos: [PlanItemInput]?
    /// A plan or todo list that could not be read completely (too many items, or items of an unknown shape).
    var listsIncomplete = false
}

/// Digest only: what one `tool_result` block says (is it an error, its first characters), in block order.
struct ToolResultFacts: Equatable, Sendable {
    var toolUseID: String?
    var isError: Bool?
    /// The content's first `CodeTuning.digestHeadMax` characters: a string, or text blocks joined with newlines.
    var head: String
    /// The block itself carries a `toolDenialKind`.
    var denied: Bool
}

/// Digest only: an entry's `toolUseResult` object, as far as background work and artifacts need it.
struct ToolUseResultFacts: Equatable, Sendable {
    var status: String?
    var agentID: String?
    var taskID: String?
    var taskType: String?
    var backgroundTaskID: String?
    var url: String?
}

/// Digest only: the fields of an entry that only the turn digest reads.
struct TranscriptDigestFacts: Equatable, Sendable {
    /// One per `tool_result` block of the content, in order.
    var results: [ToolResultFacts] = []
    var toolUseResult: ToolUseResultFacts?
    /// A `toolDenialKind` on the entry or in its `toolUseResult`: its results are denials, not failures.
    var denied = false
    /// Set for a `queued_command` attachment or a `queue-operation` enqueue, with the texts of it that hold a
    /// `<task-notification>` (only their tags are ever read).
    var noticeCarrier: CodeTurnDigest.NoticeCarrier?
    var noticeTexts: [String] = []
}

/// A `tool_use` content block.
struct TranscriptToolUse: Equatable, Sendable {
    var id: String?
    var name: String
    var input: ToolInputFacts
}

/// One content block of a transcript entry, as far as the app needs it.
enum TranscriptBlock: Equatable, Sendable {
    /// A text block and whether it was cut at `TranscriptEntry.maxTextScalars`.
    case text(String, cut: Bool)
    case thinking
    case toolUse(TranscriptToolUse)
    case toolResult(toolUseID: String?)
    /// A tool the API ran itself (web search or fetch): no tool_result follows from the client.
    case serverToolUse(name: String)
    case other
}

/// One line of a Claude Code transcript, read strictly (the line fails as a whole on bad syntax, a
/// duplicated key or nesting over 64) while decoding only these fields; tool results, thinking, attachments and tool
/// inputs other than `ToolInputFacts` are checked and skipped, never decoded.
struct TranscriptEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case user, assistant, system, other }

    var kind: Kind
    var uuid: String?
    var timestamp: Date?
    var isSidechain = false
    var isMeta = false
    var isCompactSummary = false
    /// `turnOrigin`: nil when the entry does not say, `.unknown` when it says something not known here.
    var origin: CommandTurnOrigin?
    var stopReason: String?
    var blocks: [TranscriptBlock] = []
    /// The turn digest's extra facts; nil unless parsed with `digestFacts: true`.
    var digest: TranscriptDigestFacts?

    /// A text block longer than this is cut, and a reply holding it counts as partly read.
    static let maxTextScalars = 200_000
    /// Digest only: a notice-carrying text is read up to this many characters.
    static let maxNoticeTextScalars = 64 * 1024
    /// At most this many content blocks are kept per entry.
    static let maxBlocks = 512
    static let maxListItems = 64

    /// A user entry that carries tool results (it does not start a turn).
    var isToolResult: Bool {
        blocks.contains { block in
            if case .toolResult = block { return true }
            return false
        }
    }

    /// The text of a user message: its string content or its text blocks.
    var messageText: String {
        blocks.compactMap { block -> String? in
            if case .text(let text, _) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    /// The entry in `line`, or nil when the line is not a well-formed JSON object by the strict rules. With
    /// `digestFacts`, the fields only the turn digest needs are decoded too (`digest`, the digest-only input fields).
    static func parse(_ line: UnsafeRawBufferPointer, digestFacts: Bool = false) -> TranscriptEntry? {
        do {
            return try StrictJSONReader.read(line) { reader -> TranscriptEntry in
                var entry = TranscriptEntry(kind: .other)
                var type: String?
                var stamp: String?
                var facts = TranscriptDigestFacts()
                var attachmentType: String?
                var attachmentTexts: [String] = []
                var operation: String?
                var queueContent: String?
                try reader.readObject { r, key in
                    switch key {
                    case "type": type = try r.string(max: 64)
                    case "uuid": entry.uuid = CodeIDs.entryUUID(try r.string(max: 128))
                    case "timestamp": stamp = try r.string(max: 64)
                    case "isSidechain": entry.isSidechain = try r.bool() ?? false
                    case "isMeta": entry.isMeta = try r.bool() ?? false
                    case "isCompactSummary": entry.isCompactSummary = try r.bool() ?? false
                    case "turnOrigin": entry.origin = try readOrigin(&r)
                    case "message":
                        try r.object { m, field in
                            switch field {
                            case "stop_reason": entry.stopReason = CodeText.identifier(try m.string(max: 64))
                            case "content": entry.blocks = try readContent(&m, digest: digestFacts, results: &facts.results)
                            default: try m.skipValue()
                            }
                        }
                    case "toolUseResult" where digestFacts:
                        facts.toolUseResult = try readToolUseResult(&r, denied: &facts.denied)
                    case "toolDenialKind" where digestFacts:
                        if try isDenial(&r) { facts.denied = true }
                    case "attachment" where digestFacts:
                        try readAttachment(&r, type: &attachmentType, texts: &attachmentTexts)
                    case "operation" where digestFacts:
                        operation = try r.string(max: 64)
                    case "content" where digestFacts:
                        queueContent = try r.string(max: maxNoticeTextScalars)
                    default: try r.skipValue()
                    }
                }
                switch type {
                case "user": entry.kind = .user
                case "assistant": entry.kind = .assistant
                case "system": entry.kind = .system
                default: entry.kind = .other
                }
                entry.timestamp = stamp.flatMap(CodeDates.parse)
                if digestFacts {
                    if type == "attachment", attachmentType == "queued_command", !attachmentTexts.isEmpty {
                        facts.noticeCarrier = .queuedCommand
                        facts.noticeTexts = attachmentTexts
                    } else if type == "queue-operation", operation == "enqueue", let content = queueContent,
                              content.contains(TaskNotices.open) {
                        facts.noticeCarrier = .queueOperation
                        facts.noticeTexts = [content]
                    }
                    entry.digest = facts
                }
                return entry
            }
        } catch {
            return nil
        }
    }

    // MARK: Parts

    private static func readContent(_ r: inout StrictJSONReader, digest: Bool,
                                    results: inout [ToolResultFacts]) throws -> [TranscriptBlock] {
        switch try r.kind() {
        case .string:
            guard let (text, cut) = try r.stringValue(max: maxTextScalars) else { return [] }
            return [.text(text, cut: cut)]
        case .array:
            var blocks: [TranscriptBlock] = []
            try r.readArray { element in
                guard blocks.count < maxBlocks else {
                    try element.skipValue()
                    return
                }
                let (block, result) = try readBlock(&element, digest: digest)
                blocks.append(block)
                if let result { results.append(result) }
            }
            return blocks
        default:
            try r.skipValue()
            return []
        }
    }

    /// One content block; in digest mode a `tool_result` block also gives its facts.
    private static func readBlock(_ r: inout StrictJSONReader, digest: Bool) throws -> (TranscriptBlock, ToolResultFacts?) {
        var type: String?
        var text: (text: String, cut: Bool)?
        var id: String?
        var name: String?
        var toolUseID: String?
        var input = ToolInputFacts()
        var isError: Bool?
        var head = ""
        var denied = false
        let isObject = try r.object { b, key in
            switch key {
            case "type": type = try b.string(max: 64)
            case "text": text = try b.stringValue(max: maxTextScalars)
            case "id": id = toolID(try b.string(max: 128))
            case "name": name = try b.string(max: 256)
            case "tool_use_id": toolUseID = toolID(try b.string(max: 128))
            case "input": input = try readInput(&b, digest: digest)
            case "is_error" where digest: isError = try b.bool()
            case "content" where digest: head = try readHead(&b)
            case "toolDenialKind" where digest: denied = try isDenial(&b)
            default: try b.skipValue()
            }
        }
        guard isObject else { return (.other, nil) }
        switch type {
        case "text": return (.text(text?.text ?? "", cut: text?.cut ?? false), nil)
        case "thinking", "redacted_thinking": return (.thinking, nil)
        case "tool_use": return (.toolUse(TranscriptToolUse(id: id, name: name ?? "", input: input)), nil)
        case "tool_result":
            let facts = digest ? ToolResultFacts(toolUseID: toolUseID, isError: isError, head: head, denied: denied) : nil
            return (.toolResult(toolUseID: toolUseID), facts)
        case "server_tool_use": return (.serverToolUse(name: name ?? ""), nil)
        default: return (.other, nil)
        }
    }

    private static func readInput(_ r: inout StrictJSONReader, digest: Bool) throws -> ToolInputFacts {
        var input = ToolInputFacts()
        try r.object { i, key in
            switch key {
            case "description": input.description = try i.string(max: 512)
            case "file_path": input.filePath = try i.string(max: 4096)
            case "notebook_path": input.notebookPath = try i.string(max: 4096)
            case "subagent_type": input.subagentType = try i.string(max: 128)
            case "command" where digest: input.command = try i.string(max: CodeTuning.digestHeadMax)
            case "prompt" where digest: input.prompt = try i.string(max: CodeTuning.digestHeadMax)
            case "run_in_background" where digest: input.runInBackground = try i.bool()
            case "files" where digest: input.files = try readStrings(&i, max: CodeTuning.digestFilesMax)
            case "items":
                let list = try readItems(&i)
                input.planItems = list?.items
                if list?.complete == false { input.listsIncomplete = true }
            case "todos":
                let list = try readItems(&i)
                input.todos = list?.items
                if list?.complete == false { input.listsIncomplete = true }
            case "advance": input.advance = try i.bool()
            case "done":
                let numbers = try readIntegers(&i)
                input.done = numbers
                if numbers == nil { input.listsIncomplete = true }
            case "start":
                if let value = try i.number() {
                    if let index = integer(value) { input.start = index } else { input.listsIncomplete = true }
                }
            default: try i.skipValue()
            }
        }
        return input
    }

    /// An array of `{content, status}` objects (or plain strings); nil when the value is not an array.
    private static func readItems(_ r: inout StrictJSONReader) throws -> (items: [PlanItemInput], complete: Bool)? {
        var items: [PlanItemInput] = []
        var complete = true
        let isArray = try r.array { element in
            guard items.count < maxListItems else {
                complete = false
                try element.skipValue()
                return
            }
            switch try element.kind() {
            case .string:
                items.append(PlanItemInput(content: try element.string(max: 512) ?? "", status: nil))
            case .object:
                var content: String?
                var status: String?
                try element.readObject { o, key in
                    switch key {
                    case "content": content = try o.string(max: 512)
                    case "status": status = try o.string(max: 32)
                    default: try o.skipValue()
                    }
                }
                items.append(PlanItemInput(content: content ?? "", status: status))
            default:
                complete = false
                try element.skipValue()
            }
        }
        return isArray ? (items, complete) : nil
    }

    /// An array of whole numbers 0...10,000; nil when anything else is in it (or it is not an array).
    private static func readIntegers(_ r: inout StrictJSONReader) throws -> [Int]? {
        var numbers: [Int] = []
        var ok = true
        let isArray = try r.array { element in
            guard numbers.count < maxListItems, let value = try element.number(), let index = integer(value) else {
                ok = false
                return
            }
            numbers.append(index)
        }
        return isArray && ok ? numbers : nil
    }

    // MARK: Digest-only parts

    /// A tool result's content head: a string, or the `text` of its blocks joined with newlines, at most
    /// `CodeTuning.digestHeadMax` characters (other blocks, such as images, are skipped unread).
    private static func readHead(_ r: inout StrictJSONReader) throws -> String {
        let limit = CodeTuning.digestHeadMax
        switch try r.kind() {
        case .string:
            return try r.string(max: limit) ?? ""
        case .array:
            var parts: [String] = []
            var used = 0
            try r.readArray { element in
                guard used < limit else {
                    try element.skipValue()
                    return
                }
                var text: String?
                try element.object { b, key in
                    if key == "text" { text = try b.string(max: limit - used) } else { try b.skipValue() }
                }
                if let text {
                    parts.append(text)
                    used += text.unicodeScalars.count + 1
                }
            }
            return parts.joined(separator: "\n")
        default:
            try r.skipValue()
            return ""
        }
    }

    /// An array's string elements (at most `max` kept, each at most 4,096 characters); nil when it is not an array.
    private static func readStrings(_ r: inout StrictJSONReader, max: Int) throws -> [String]? {
        var strings: [String] = []
        let isArray = try r.array { element in
            guard strings.count < max else {
                try element.skipValue()
                return
            }
            if let text = try element.string(max: 4096) { strings.append(text) }
        }
        return isArray ? strings : nil
    }

    /// `toolUseResult` when it is an object (for errors it is a string: skipped).
    private static func readToolUseResult(_ r: inout StrictJSONReader, denied: inout Bool) throws -> ToolUseResultFacts? {
        var info = ToolUseResultFacts()
        let isObject = try r.object { o, key in
            switch key {
            case "status": info.status = CodeText.identifier(try o.string(max: 64))
            case "agentId": info.agentID = try o.string(max: 160)
            case "taskId": info.taskID = try o.string(max: 160)
            case "taskType": info.taskType = CodeText.identifier(try o.string(max: 64))
            case "backgroundTaskId": info.backgroundTaskID = try o.string(max: 160)
            case "url": info.url = try o.string(max: 2048)
            case "toolDenialKind": if try isDenial(&o) { denied = true }
            default: try o.skipValue()
            }
        }
        return isObject ? info : nil
    }

    /// An attachment's `type` and the strings of it (or of its text blocks) that hold a `<task-notification>`, at most
    /// 8, each read up to `maxNoticeTextScalars` characters; everything else is skipped unread.
    private static func readAttachment(_ r: inout StrictJSONReader, type: inout String?, texts: inout [String]) throws {
        func keep(_ text: String?) {
            guard let text, texts.count < 8, text.contains(TaskNotices.open) else { return }
            texts.append(text)
        }
        try r.object { a, key in
            if key == "type" {
                type = try a.string(max: 64)
                return
            }
            switch try a.kind() {
            case .string:
                keep(try a.string(max: maxNoticeTextScalars))
            case .array:
                try a.readArray { element in
                    switch try element.kind() {
                    case .string:
                        keep(try element.string(max: maxNoticeTextScalars))
                    case .object:
                        var text: String?
                        try element.readObject { b, field in
                            if field == "text" { text = try b.string(max: maxNoticeTextScalars) } else { try b.skipValue() }
                        }
                        keep(text)
                    default:
                        try element.skipValue()
                    }
                }
            default:
                try a.skipValue()
            }
        }
    }

    /// A `toolDenialKind` that is set: a non-empty string or `true`.
    private static func isDenial(_ r: inout StrictJSONReader) throws -> Bool {
        switch try r.kind() {
        case .string: return !(try r.string(max: 64) ?? "").isEmpty
        case .bool: return try r.bool() ?? false
        default:
            try r.skipValue()
            return false
        }
    }

    private static func integer(_ value: Double) -> Int? {
        guard value.isFinite, value == value.rounded(), value >= 0, value <= 10_000 else { return nil }
        return Int(value)
    }

    /// `turnOrigin` as a string, or an object naming it under `kind`, `type`, `origin` or `source`.
    private static func readOrigin(_ r: inout StrictJSONReader) throws -> CommandTurnOrigin? {
        switch try r.kind() {
        case .string:
            return origin(named: try r.string(max: 64))
        case .object:
            var name: String?
            try r.readObject { o, key in
                if name == nil, ["kind", "type", "origin", "source"].contains(key) {
                    name = try o.string(max: 64)
                } else {
                    try o.skipValue()
                }
            }
            return origin(named: name)
        default:
            try r.skipValue()
            return nil
        }
    }

    /// The turn origin (docs/SHELL_LANGUAGE.md §8): `human`, `task_notification` and `peer` as they are,
    /// anything else (`system`, `sdk`, `scheduled`, unknown words) `unknown`.
    static func origin(named name: String?) -> CommandTurnOrigin {
        switch name {
        case "human": return .human
        case "task_notification": return .taskNotification
        case "peer": return .peer
        default: return .unknown
        }
    }

    /// Tool ids are short identifiers (`toolu_…`); anything else is not matched.
    private static func toolID(_ text: String?) -> String? {
        guard let text, (1...128).contains(text.utf8.count),
              text.utf8.allSatisfy({ CodeIDs.isAlphanumeric($0) || $0 == 0x2D || $0 == 0x5F }) else { return nil }
        return text
    }
}
