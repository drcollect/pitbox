import Foundation
import PitboxKit

/// A tool call that has not had its result yet.
struct PendingTool: Equatable, Sendable {
    var id: String?
    var name: String
    var at: Date?
}

/// The replayed plan of one turn: `mcp__ccd_turn__update_plan` calls, first `{items}`, then `{advance: true}` or
/// `{done: [i], start: j}`. The plan belongs to the turn it was made in; when its start was not seen (the first call of
/// the turn is not a full list, or a call cannot be applied), it is unknown and not shown (no guessing).
struct PlanReplay: Equatable, Sendable {
    /// `done` and `start` count items from this number: 1 (measured over the user's transcripts, counts only: in 8
    /// calls with indices, an index equal to the item count appeared 3 times and 0 never).
    static let indexBase = 1

    /// An `update_plan` call was seen in this turn.
    private(set) var seen = false
    /// The plan; nil while it is unknown.
    private(set) var items: [CodeSessionTodos.Item]?

    mutating func apply(_ input: ToolInputFacts) {
        seen = true
        guard !input.listsIncomplete else {
            items = nil
            return
        }
        if let list = input.planItems { items = list.map(Self.item) }
        let changes = input.done != nil || input.start != nil || input.advance == true
        guard input.planItems != nil || changes else {
            items = nil
            return
        }
        guard var current = items else { return }
        for index in input.done ?? [] {
            guard let k = position(index, count: current.count) else {
                items = nil
                return
            }
            current[k].status = .completed
        }
        if let start = input.start {
            guard let k = position(start, count: current.count) else {
                items = nil
                return
            }
            for i in current.indices where current[i].status == .inProgress { current[i].status = .pending }
            current[k].status = .inProgress
        }
        if input.advance == true { Self.advance(&current) }
        items = current
    }

    /// TodoWrite's full list (every call carries all items), nil when it could not be read.
    static func todoList(_ input: ToolInputFacts) -> [CodeSessionTodos.Item]? {
        guard !input.listsIncomplete, let todos = input.todos else { return nil }
        return todos.map(item)
    }

    /// Completes the item in progress and starts the next pending one (or the first pending one).
    private static func advance(_ items: inout [CodeSessionTodos.Item]) {
        if let current = items.firstIndex(where: { $0.status == .inProgress }) {
            items[current].status = .completed
            if let next = items[(current + 1)...].firstIndex(where: { $0.status == .pending })
                ?? items.firstIndex(where: { $0.status == .pending }) {
                items[next].status = .inProgress
            }
        } else if let first = items.firstIndex(where: { $0.status == .pending }) {
            items[first].status = .inProgress
        }
    }

    private func position(_ index: Int, count: Int) -> Int? {
        let k = index - Self.indexBase
        return (0..<count).contains(k) ? k : nil
    }

    private static func item(_ input: PlanItemInput) -> CodeSessionTodos.Item {
        let status: CodeSessionTodos.Item.Status
        switch input.status?.lowercased() {
        case "completed", "complete", "done": status = .completed
        case "in_progress", "inprogress", "in-progress", "active": status = .inProgress
        default: status = .pending
        }
        return CodeSessionTodos.Item(text: CodeText.oneLine(input.content, limit: 200), status: status)
    }
}

/// Transcript bytes per minute over the last 30 minutes (sizes only): filled from the lines of a fresh tail by
/// their timestamps, then from the growth seen at each read.
struct ActivityBuckets: Equatable, Sendable {
    static let minutes = 30
    private(set) var bytesByMinute: [Int: Int] = [:]

    static func minute(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 60).rounded(.down)) }

    mutating func add(_ bytes: Int, at date: Date, now: Date) {
        guard bytes > 0 else { return }
        let minute = Self.minute(min(date, now))
        guard minute > Self.minute(now) - Self.minutes else { return }
        bytesByMinute[minute, default: 0] += bytes
    }

    mutating func prune(now: Date) {
        let cutoff = Self.minute(now) - Self.minutes
        bytesByMinute = bytesByMinute.filter { $0.key > cutoff }
    }

    mutating func reset() { bytesByMinute = [:] }

    /// 30 values, oldest first, the current minute last.
    func sparkline(now: Date) -> [Int] {
        let current = Self.minute(now)
        return ((current - Self.minutes + 1)...current).map { bytesByMinute[$0] ?? 0 }
    }

    /// When the picture shifts by itself (the next minute), while anything is in it.
    func nextChange(now: Date) -> Date? {
        guard !bytesByMinute.isEmpty else { return nil }
        return Date(timeIntervalSince1970: Double(Self.minute(now) + 1) * 60)
    }
}

/// The latest turn of a transcript (the entries after the last `user` entry that is not a tool_result).
struct TranscriptTurn: Equatable, Sendable {
    /// The user entry that started it was read (or the read reached the file's start).
    var startHeld: Bool
    var origin: CommandTurnOrigin = .unknown
    /// The first two lines of the message that started the turn, only when its origin is `human` ("You asked").
    var youAsked: String?
    /// WebFetch, WebSearch, a browser tool or computer use ran in this turn (its offers get a note saying so).
    var readWeb = false
    /// A line inside the turn could not be read: the reply may be incomplete (Copy only).
    var unreadableLine = false
    /// The current run of assistant text blocks: the final reply once the turn is finished.
    var run: [String] = []
    /// A text block of the run was cut at `TranscriptEntry.maxTextScalars`.
    var runCut = false
    var hasAssistant = false
    var lastAssistantUUID: String?
    var lastAssistantAt: Date?
    var lastStopReason: String?
    /// The offset just past the last assistant line: where the click-time check starts reading.
    var lastAssistantEnd: Int64?
    var userAfterAssistant = false
    var pending: [PendingTool] = []
    /// The last tool call of the turn that is not bookkeeping, in words (the "Now" line).
    var lastToolWords: String?
    var plan = PlanReplay()

    /// Finished by the transcript: the last assistant entry ended the turn, nothing waits for a result, and no user
    /// entry came after it. (`sshReattach.midTurn` is the session file's part of the rule.)
    var endedByTranscript: Bool { hasAssistant && lastStopReason == "end_turn" && pending.isEmpty && !userAfterAssistant }

    /// Offers may be run only from a turn read completely (otherwise Copy only).
    var isReadCompletely: Bool { startHeld && !unreadableLine && !runCut }

    /// An `AskUserQuestion` call waits for its answer (the Needs you state).
    var asksUser: Bool { pending.contains { $0.name == "AskUserQuestion" } }

    /// The last call still waiting, leaving out subagents (they work in their own transcripts) and bookkeeping.
    var waitingTool: PendingTool? {
        pending.last { !StepWords.isSubagent($0.name) && !StepWords.isBookkeeping($0.name) }
    }
}

/// Follows a transcript entry by entry: the latest turn, the transcript's last assistant uuid (which a current summary
/// must name), the last steps and the TodoWrite list. Subagent side chains are left out. It also keeps the turn digest
/// for the derivers (more turns, the same lines), so the two never see different lines.
struct TurnTracker: Equatable, Sendable {
    static let maxSteps = 5

    /// The turns the derivers read (`CodeTurnDigestBuilder`), fed every line this tracker takes.
    private(set) var digest = CodeTurnDigestBuilder()
    private(set) var turn: TranscriptTurn?
    /// The uuid of the transcript's last assistant entry, of any turn.
    private(set) var lastAssistantUUID: String?
    /// The last 5 steps, newest last.
    private(set) var steps: [CodeSessionStep] = []
    private(set) var todoWrite: [CodeSessionTodos.Item]?
    /// Whether a TodoWrite call was seen (its list may still be unreadable).
    private(set) var sawTodoWrite = false

    /// The todo list to show: this turn's plan when `update_plan` was used in it, else the last TodoWrite list.
    var todos: CodeSessionTodos? {
        if let turn, turn.plan.seen { return turn.plan.items.map { CodeSessionTodos(items: $0) } }
        guard sawTodoWrite else { return nil }
        return todoWrite.map { CodeSessionTodos(items: $0) }
    }

    /// Takes one line; `fallbackTime` dates a step whose entry has no timestamp.
    mutating func feed(_ line: TranscriptLine, fallbackTime: Date) {
        digest.feed(line)
        guard let entry = line.entry else {
            turn?.unreadableLine = true
            return
        }
        guard !entry.isSidechain else { return }
        switch entry.kind {
        case .user:
            if entry.isToolResult {
                var current = turn ?? TranscriptTurn(startHeld: false)
                for block in entry.blocks {
                    guard case .toolResult(let id) = block else { continue }
                    if let index = current.pending.firstIndex(where: { $0.id != nil && $0.id == id }) {
                        current.pending.remove(at: index)
                    }
                }
                if current.hasAssistant { current.userAfterAssistant = true }
                turn = current
            } else {
                startTurn(entry)
            }
        case .assistant:
            var current = turn ?? TranscriptTurn(startHeld: false)
            apply(entry, to: &current, fallbackTime: fallbackTime)
            current.hasAssistant = true
            current.lastAssistantUUID = entry.uuid
            current.lastAssistantAt = entry.timestamp
            current.lastStopReason = entry.stopReason
            current.lastAssistantEnd = line.end
            current.userAfterAssistant = false
            turn = current
            lastAssistantUUID = entry.uuid
        case .system, .other:
            break
        }
    }

    private mutating func startTurn(_ entry: TranscriptEntry) {
        var next = TranscriptTurn(startHeld: true)
        // No `turnOrigin` counts as unknown (docs/SHELL_LANGUAGE.md §8): such turns get R20 and no "You asked".
        next.origin = entry.origin ?? .unknown
        let usersOwn = next.origin == .human && !entry.isMeta && !entry.isCompactSummary
        next.youAsked = usersOwn ? CodeText.firstLines(entry.messageText, count: 2, limit: 200) : nil
        turn = next
    }

    private mutating func apply(_ entry: TranscriptEntry, to turn: inout TranscriptTurn, fallbackTime: Date) {
        let at = entry.timestamp ?? fallbackTime
        for block in entry.blocks {
            switch block {
            case .text(let text, let cut):
                turn.run.append(text)
                if cut { turn.runCut = true }
            case .toolUse(let tool):
                turn.pending.append(PendingTool(id: tool.id, name: tool.name, at: entry.timestamp))
                if StepWords.readsWeb(tool.name) { turn.readWeb = true }
                if StepWords.isBookkeeping(tool.name) {
                    if tool.name == StepWords.updatePlan { turn.plan.apply(tool.input) }
                    if tool.name == StepWords.todoWrite {
                        sawTodoWrite = true
                        todoWrite = PlanReplay.todoList(tool.input)
                    }
                } else {
                    // A real tool call: the text before it is not the final reply.
                    turn.run.removeAll()
                    turn.runCut = false
                    let words = StepWords.words(for: tool)
                    turn.lastToolWords = words
                    addStep(words, at: at)
                }
            case .serverToolUse(let name):
                turn.run.removeAll()
                turn.runCut = false
                if name.lowercased().contains("web") { turn.readWeb = true }
                let words = StepWords.serverToolWords(name)
                turn.lastToolWords = words
                addStep(words, at: at)
            case .thinking, .toolResult, .other:
                break
            }
        }
    }

    private mutating func addStep(_ words: String, at: Date) {
        steps.append(CodeSessionStep(words: words, at: at))
        if steps.count > Self.maxSteps { steps.removeFirst(steps.count - Self.maxSteps) }
    }
}
