import Foundation
import PitboxKit

/// One Agent or Workflow task a session started in the background: its
/// `toolUseResult.status: "async_launched"` result starts it, a `<task-notification>` naming it (by `<task-id>` or
/// `<tool-use-id>`) with status completed, failed, killed or stopped ends it. Background Bash runs are never tasks
/// here (dev servers and watchers never end). Ids are kept only as hashes (the first 16 hex characters of their
/// SHA-256), as `code-memory.json` stores them.
struct CodeBackgroundTask: Equatable, Sendable {
    enum Kind: String, Sendable { case agent, workflow }

    /// The hash of the task id (`agentId` or `taskId`).
    var task: String
    /// The hash of the launching tool_use's id: some notices name only `<tool-use-id>`.
    var toolUse: String?
    var kind: Kind
    /// The launch result's timestamp (the server's clock for SSH sessions).
    var launchedAt: Date
    /// When its ending notice was written; nil while it is pending.
    var endedAt: Date?
    /// The digest turns of the launch and of the ending notice; nil when that part is known from memory only.
    var launchTurn: Int?
    var endTurn: Int?
    /// Workflows: the ending notice's `agents_done` of `agent_count`, for the peek.
    var agentsDone: Int?
    var agentCount: Int?

    var isPending: Bool { endedAt == nil }
}

/// A task as `code-memory.json` keeps it (key `background`): hashes and times only. Pending tasks are kept
/// because their notice can come hours later, after the launch left the tail (workflows ran up to 352 minutes in 30
/// days); the work's tasks that ended are kept too, so "4 of 6 agents done" survives a restart while the work goes on.
/// The store drops a record 6 hours after its launch (`CodeTuning.backgroundMaxAge`) and keeps the newest 64.
struct BackgroundTaskRecord: Codable, Equatable, Sendable {
    var task: String
    var use: String?
    var kind: String?
    var launchedAt: Date
    var endedAt: Date?
}

/// What the work's background tasks add up to.
struct BackgroundTally: Equatable, Sendable {
    /// The tasks counted: launched during the work, or launched before it and still running when it began.
    var counted: [CodeBackgroundTask]
    var done: Int
    var total: Int
    /// The first launch of the counted tasks (the estimate's elapsed time).
    var since: Date?
    var unit: CodeProgress.Unit
    /// The latest workflow notice with agent counts among the counted tasks.
    var workflowAgentsDone: Int?
    var workflowAgentCount: Int?
    /// Tasks of the work dropped after `CodeTuning.backgroundMaxAge` without their notice (they never reported back).
    var expired: Int
    /// When the next pending task expires.
    var nextExpiry: Date?

    var pending: Int { max(0, total - done) }

    static let none = BackgroundTally(counted: [], done: 0, total: 0, since: nil, unit: .agents, workflowAgentsDone: nil,
                                      workflowAgentCount: nil, expired: 0, nextExpiry: nil)
}

/// The background-task rules. Pure.
enum BackgroundTasks {
    /// The statuses that end a task.
    static let endingStatuses: Set<String> = ["completed", "failed", "killed", "stopped"]

    /// The first 16 hex characters of an id's SHA-256 (as the run records hash command texts).
    static func hash(_ id: String) -> String { CodeRunRecords.textHash(id) }

    /// Every Agent and Workflow task the digest launched, oldest first, with its end when the digest holds its notice.
    static func fromDigest(_ digest: CodeTurnDigest) -> [CodeBackgroundTask] {
        var tasks: [CodeBackgroundTask] = []
        var index: [String: Int] = [:]
        for (turnIndex, turn) in digest.turns.enumerated() {
            for item in turn.items {
                guard case .toolResult(let result) = item, let id = result.asyncTaskID, let kind = result.asyncKind,
                      kind != .bash, let at = result.at ?? WorkClock.startTime(of: turn) else { continue }
                let task = hash(id)
                guard index[task] == nil else { continue }
                index[task] = tasks.count
                tasks.append(CodeBackgroundTask(task: task, toolUse: result.toolUseID.map(hash),
                                                kind: kind == .workflow ? .workflow : .agent, launchedAt: at,
                                                launchTurn: turnIndex))
            }
        }
        return tasks
    }

    /// Adds the stored records the digest no longer holds (memory-only tasks), takes stored end times for digest tasks
    /// whose notice left the digest, and matches every pending task with the digest's ending notices.
    static func merge(_ fromDigest: [CodeBackgroundTask], records: [BackgroundTaskRecord],
                      digest: CodeTurnDigest) -> [CodeBackgroundTask] {
        var tasks = fromDigest
        var position: [String: Int] = [:]
        for (offset, task) in tasks.enumerated() { position[task.task] = offset }
        var storedEnds: [Int: Date] = [:]
        for record in records where CodeMemorySchema.isHash16(record.task) {
            if let at = position[record.task] {
                if let ended = record.endedAt { storedEnds[at] = ended }
                continue
            }
            position[record.task] = tasks.count
            let use = record.use.flatMap { CodeMemorySchema.isHash16($0) ? $0 : nil }
            let kind: CodeBackgroundTask.Kind = record.kind == CodeBackgroundTask.Kind.workflow.rawValue ? .workflow : .agent
            tasks.append(CodeBackgroundTask(task: record.task, toolUse: use, kind: kind, launchedAt: record.launchedAt,
                                            endedAt: record.endedAt.map { max($0, record.launchedAt) }))
        }
        // The digest's notices first (they also give the turn of the end); a stored end only where the notice left it.
        applyNotices(digest, to: &tasks)
        for (at, ended) in storedEnds where tasks[at].isPending { tasks[at].endedAt = max(ended, tasks[at].launchedAt) }
        return tasks.sorted { ($0.launchedAt, $0.task) < ($1.launchedAt, $1.task) }
    }

    /// The work's tasks at `now`: those launched in the work's turns (by time for memory-only ones), and those
    /// launched earlier that had not ended when the work began (a question typed while agents run starts a new work,
    /// and those agents are still its background). Tasks pending past `CodeTuning.backgroundMaxAge` are dropped and
    /// counted as expired.
    static func tally(_ tasks: [CodeBackgroundTask], work: CodeWork, now: Date) -> BackgroundTally {
        var counted: [CodeBackgroundTask] = []
        var expired = 0
        var nextExpiry: Date?
        for task in tasks {
            let launchedInWork = task.launchTurn.map(work.contains(turn:))
                ?? work.startedAt.map { task.launchedAt >= $0 } ?? true
            let stillRunningAtStart: Bool
            if let ended = task.endedAt {
                stillRunningAtStart = task.endTurn.map(work.contains(turn:)) ?? work.startedAt.map { ended >= $0 } ?? false
            } else {
                stillRunningAtStart = true
            }
            guard launchedInWork || stillRunningAtStart else { continue }
            if task.isPending {
                let expiry = task.launchedAt.addingTimeInterval(CodeTuning.backgroundMaxAge)
                guard expiry > now else {
                    expired += 1
                    continue
                }
                nextExpiry = min(nextExpiry ?? expiry, expiry)
            }
            counted.append(task)
        }
        guard !counted.isEmpty else {
            var tally = BackgroundTally.none
            tally.expired = expired
            return tally
        }
        let agents = counted.contains { $0.kind == .agent }, workflows = counted.contains { $0.kind == .workflow }
        let lastWorkflow = counted.filter { $0.kind == .workflow && $0.agentCount != nil }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
        return BackgroundTally(counted: counted, done: counted.filter { !$0.isPending }.count, total: counted.count,
                               since: counted.map(\.launchedAt).min(),
                               unit: agents && workflows ? .tasks : (workflows ? .workflows : .agents),
                               workflowAgentsDone: lastWorkflow?.agentsDone, workflowAgentCount: lastWorkflow?.agentCount,
                               expired: expired, nextExpiry: nextExpiry)
    }

    /// The records to keep for the work's counted tasks, oldest first, the newest `CodeTuning.backgroundMaxPending`.
    static func records(_ counted: [CodeBackgroundTask]) -> [BackgroundTaskRecord] {
        let sorted = counted.sorted { ($0.launchedAt, $0.task) < ($1.launchedAt, $1.task) }
        return sorted.suffix(CodeTuning.backgroundMaxPending).map {
            BackgroundTaskRecord(task: $0.task, use: $0.toolUse, kind: $0.kind.rawValue, launchedAt: $0.launchedAt,
                                 endedAt: $0.endedAt)
        }
    }

    // MARK: Notices

    /// Ends each pending task at the first ending notice after its launch that names its task id or its tool_use id,
    /// from any carrier (a new turn, a `queued_command` attachment, a `queue-operation` enqueue).
    private static func applyNotices(_ digest: CodeTurnDigest, to tasks: inout [CodeBackgroundTask]) {
        var byTask: [String: Int] = [:]
        var byToolUse: [String: Int] = [:]
        for (offset, task) in tasks.enumerated() where task.isPending {
            byTask[task.task] = offset
            if let use = task.toolUse { byToolUse[use] = offset }
        }
        guard !byTask.isEmpty else { return }
        for (turnIndex, turn) in digest.turns.enumerated() {
            for item in turn.items {
                guard case .notice(let notice) = item, let status = notice.status, endingStatuses.contains(status) else {
                    continue
                }
                let offset = notice.taskID.flatMap { byTask[hash($0)] } ?? notice.toolUseID.flatMap { byToolUse[hash($0)] }
                guard let offset, tasks[offset].isPending else { continue }
                if let launch = tasks[offset].launchTurn, turnIndex < launch { continue }
                let at = notice.at ?? WorkClock.startTime(of: turn) ?? tasks[offset].launchedAt
                tasks[offset].endedAt = max(at, tasks[offset].launchedAt)
                tasks[offset].endTurn = turnIndex
                tasks[offset].agentsDone = notice.agentsDone
                tasks[offset].agentCount = notice.agentCount
            }
        }
    }
}
