import Foundation
import PitboxKit

/// One session's transcript end as the derivers read it: the turns of the tail with their assistant texts, tool calls,
/// tool results and background-task notices, plus a few session-file facts. Built on the engine's background queue
/// during each tail parse (`TurnTracker` keeps it); handed to the derivers (`CodeSessionDeriver`); never leaves the
/// package and is never logged. Everything in it that a session wrote (texts, commands, paths, heads, URLs) is session
/// text: shown only through the plain-text renderer, never parsed for commands outside the offer rules.
///
/// **Which turns**: every turn from the oldest of (the third-newest finished turn of the user's, another session's or
/// unknown origin: the oldest turn whose offers can still run) and (the work's start: the latest turn of the user's or
/// another session's) to the end, as far as the tail reaches (up to 2 MB), at most `CodeTuning.digestTurnsMax` turns
/// and `CodeTuning.digestBytesMax` bytes of strings. Turns are dropped only from the front, so a turn that is here has
/// every later turn here too. An offer whose turn is not here is out of reach: Copy only.
struct CodeTurnDigest: Sendable, Equatable {
    /// An assistant text block, cut at `CodeTuning.digestTextMax` bytes.
    struct Text: Sendable, Equatable {
        /// The entry's uuid when it matches `^[0-9A-Za-z-]{1,64}$`, else nil: nothing is keyed by it.
        var uuid: String?
        var at: Date?
        var text: String
        /// The text was longer than the digest keeps (a reply holding it is not read completely).
        var cut: Bool
    }

    /// A `tool_use` (or a `server_tool_use`, which the API ran itself) of an assistant entry.
    struct ToolUse: Sendable, Equatable {
        /// The tool_use id (`toolu_…`), nil when missing or malformed: such a call is never matched or deduplicated.
        var id: String?
        var uuid: String?
        var at: Date?
        var name: String
        /// Bash: the command's first `CodeTuning.digestHeadMax` characters, and the description.
        var command: String?
        var description: String?
        /// Edit, Write, MultiEdit (`file_path`) and NotebookEdit (`notebook_path`), as written.
        var filePath: String?
        /// SendUserFile `files`, as written, at most `CodeTuning.digestFilesMax`.
        var files: [String] = []
        /// Agent, Task: `subagent_type`; Agent, Task, Bash: `run_in_background`.
        var subagentType: String?
        var runInBackground: Bool?
        /// The prompt's first `CodeTuning.digestHeadMax` characters, kept only when `subagentType` is
        /// "dashboard-builder".
        var promptHead: String?
        /// A `server_tool_use` (web search or fetch run by the API): no tool_result follows from the client.
        var isServerTool = false
        /// The id also appears in another followed session's digest: a fork's copy of its parent's history.
        /// Set in every session that holds the id; the Same file warning and failure counts leave such calls out.
        var isCopied = false
    }

    /// How a background task was started.
    enum AsyncKind: String, Sendable, Equatable { case agent, workflow, bash }

    /// A `tool_result` block of a user entry.
    struct ToolResult: Sendable, Equatable {
        var toolUseID: String?
        /// The user entry's uuid.
        var uuid: String?
        var at: Date?
        /// The name of the tool_use it answers, when that call is in the digest.
        var toolName: String?
        /// `is_error` as written (Bash results always carry it); nil when absent.
        var isError: Bool?
        /// From `^Exit code (\d+)` at the start of the content.
        var exitCode: Int?
        /// A denial, not a failure: a `toolDenialKind` on the entry, or content starting with `<tool_use_error>`.
        var denied: Bool
        /// The content's first `CodeTuning.digestHeadMax` characters (text blocks joined with newlines).
        var head: String
        /// `toolUseResult.status: "async_launched"` (`agentId`, `taskId`) or `toolUseResult.backgroundTaskId`.
        var asyncTaskID: String?
        var asyncKind: AsyncKind?
        /// An `Artifact` result's `toolUseResult.url`, as written (the results deriver checks its shape).
        var artifactURL: String?
    }

    /// Where a notice was found.
    enum NoticeCarrier: String, Sendable, Equatable {
        /// The text of a user entry (a turn started by `turnOrigin` task_notification, or a user entry without it).
        case userText
        /// A `queued_command` attachment written mid-turn.
        case queuedCommand
        /// A `queue-operation` entry with `operation` "enqueue".
        case queueOperation
    }

    /// One `<task-notification>` block: only its tags are read, its text never. The same notice often arrives
    /// twice (enqueued, then delivered as a turn): match by `taskID` or `toolUseID`, never count occurrences.
    struct Notice: Sendable, Equatable {
        var at: Date?
        var taskID: String?
        var toolUseID: String?
        /// `completed`, `failed`, `killed`, `stopped`, … as written (lowercase identifier).
        var status: String?
        /// Workflows: `agent_count` and `agents_done`.
        var agentCount: Int?
        var agentsDone: Int?
        var carrier: NoticeCarrier
    }

    enum Item: Sendable, Equatable {
        case text(Text)
        case toolUse(ToolUse)
        case toolResult(ToolResult)
        case notice(Notice)
    }

    /// One turn: the entries after a user entry that is not a tool_result, in order.
    struct Turn: Sendable, Equatable {
        var startUUID: String?
        var startedAt: Date?
        /// `turnOrigin` of the starting entry; absent or unrecognised is `unknown`, which R20 treats as not the
        /// user's (docs/SHELL_LANGUAGE.md §8).
        var origin: CommandTurnOrigin
        /// The starting user entry was read; false for the partial turn at the front of a tail (kept only while it is
        /// the latest turn).
        var startHeld: Bool
        /// The first 2 lines of the starting message when the user wrote it (`origin` human, not meta, not a compact
        /// summary): "You asked" and `unansweredMessageHead`.
        var askedHead: String?
        /// Finished, read from the transcript: the last assistant entry ended the turn, no tool waits, no user entry
        /// followed; for the latest turn also `sshReattach.midTurn` not true.
        var isFinished: Bool
        /// The final reply's last assistant entry's timestamp (finished turns only).
        var finishedAt: Date?
        /// The final reply: the uuid of the turn's last assistant entry (finished turns only).
        var replyUUID: String?
        /// The start is held, no line inside could be read, the final reply's texts are whole and no item was dropped.
        var readCompletely: Bool
        /// WebFetch, WebSearch, a browser tool, computer use or a server web tool ran in this turn (its offers get a
        /// note saying so).
        var readWeb: Bool
        /// A line inside the turn could not be read.
        var unreadableLine: Bool
        /// Items were dropped to stay within the digest's bounds (the oldest first).
        var itemsDropped: Bool
        var items: [Item]

        /// The final reply: the texts after the turn's last tool call that is not bookkeeping (`StepWords`).
        var finalReply: [Text] {
            var run: [Text] = []
            for item in items.reversed() {
                switch item {
                case .text(let text): run.append(text)
                case .toolUse(let tool):
                    if tool.isServerTool || !StepWords.isBookkeeping(tool.name) { return run.reversed() }
                case .toolResult, .notice: continue
                }
            }
            return run.reversed()
        }

        /// The tool calls still waiting for their result (by id; calls without an id never get one).
        var pendingToolUses: [ToolUse] {
            var answered = Set<String>()
            for case .toolResult(let result) in items { if let id = result.toolUseID { answered.insert(id) } }
            return items.compactMap { item -> ToolUse? in
                guard case .toolUse(let tool) = item, !tool.isServerTool else { return nil }
                guard let id = tool.id else { return tool }
                return answered.contains(id) ? nil : tool
            }
        }

        /// The newest timestamp of any item (or the start).
        var lastEntryAt: Date? {
            var latest = startedAt
            for item in items {
                let at: Date?
                switch item {
                case .text(let x): at = x.at
                case .toolUse(let x): at = x.at
                case .toolResult(let x): at = x.at
                case .notice(let x): at = x.at
                }
                if let at, latest.map({ at > $0 }) ?? true { latest = at }
            }
            return latest
        }
    }

    /// One entry of the session file's `publishedArtifacts` (its `title` is never read).
    struct PublishedArtifact: Sendable, Equatable {
        /// As written (the results deriver checks the artifact's shape before it becomes a button).
        var url: String
        var updatedAt: Date?
    }

    /// Oldest first, the running one last (see the type's doc for which turns).
    var turns: [Turn]
    /// When the transcript last grew (this Mac's clock: the file's modification time at the read that saw it grow).
    var lastGrowthAt: Date?
    /// When the session file's `lastActivityAt` last moved (the SSH working signal), on this Mac's clock.
    var lastActivityMovedAt: Date?
    /// The session file's `publishedArtifacts`, newest `updatedAt` first, at most `ClaudeSessionFile.maxArtifacts`.
    var publishedArtifacts: [PublishedArtifact]
    /// Entry uuids that appear more than once in the digest: offers of such a reply are stale.
    var duplicateUUIDs: Set<String>
    /// Turns that the rule above would keep were dropped by the byte or turn bound, or the first turn's start was not
    /// read: what lies before `turns.first` is out of reach.
    var truncated: Bool

    /// An empty digest (no transcript read yet).
    static let empty = CodeTurnDigest(turns: [], lastGrowthAt: nil, lastActivityMovedAt: nil, publishedArtifacts: [],
                                      duplicateUUIDs: [], truncated: false)

    /// The latest turn (running or finished).
    var latestTurn: Turn? { turns.last }

    /// The latest turn of the user's or another session's (`turnOrigin` human or peer): where the work starts.
    var latestHumanOrPeerTurn: Turn? { turns.last { $0.origin == .human || $0.origin == .peer } }

    /// Every item of every turn, oldest first.
    var allItems: [Item] { turns.flatMap(\.items) }

    /// Notices by task: the first occurrence of each (`taskID`, else `toolUseID`) with a status, in order.
    var uniqueNotices: [Notice] {
        var seen = Set<String>()
        var out: [Notice] = []
        for case .notice(let notice) in allItems {
            guard let key = notice.taskID.map({ "t:" + $0 }) ?? notice.toolUseID.map({ "u:" + $0 }) else { continue }
            let full = key + ":" + (notice.status ?? "")
            if seen.insert(full).inserted { out.append(notice) }
        }
        return out
    }
}
