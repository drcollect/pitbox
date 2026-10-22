import Foundation
import PitboxKit

/// "Looks stuck" for one session: only while its work runs, and never more than a display (no glow, no chime, no
/// voice, nothing sent to the session, the state word unchanged).
/// - **Failures in a row:** `CodeTuning.stuckRunLength` (4) Bash tool_results back to back with `is_error: true` and a
///   content starting `Exit code <N>`, no successful Bash call between them, any command. Denials (`<tool_use_error>`,
///   permission texts, a `toolDenialKind`) are neither failures nor successes, nor is a background Bash launch;
///   tool_uses a fork copied from its parent are left out. Clears at the next successful Bash call or the end of
///   the work. The peek shows the last failure's exit code.
/// - **Silence:** the latest turn runs, no tool_use waits for its result, the session is not in Needs you or Problem,
///   and nothing was written for `CodeTuning.stuckSilence` (30 min): for a local session the transcript did not grow;
///   for an SSH session the mirror did not grow and the session file's `lastActivityAt` did not move.
///   Pending background tasks (between turns, or while the turn is quiet: `pendingBetweenTurns`) are no silence.
///   Clears at any growth or move.
/// OK silences a rule for the rest of the work (`CodeWarningSilencer`). Pure: the deriver below feeds it.
enum StuckDetector {
    struct Output: Equatable {
        var warnings: [CodeWarning] = []
        /// When silence would become a warning, while the block is shown (the engine derives again then).
        var deadline: Date?
    }

    static func evaluate(snapshot: CodeSessionSnapshot, digest: CodeTurnDigest, progress: CodeProgress?, now: Date,
                         silenced: [WarningSilenceRecord]) -> Output {
        guard let work = CurrentWork(digest, now: now), work.isRunning(progress: progress) else { return Output() }
        var out = Output()
        if let run = failureRun(work.turns, digest: digest), run.count >= CodeTuning.stuckRunLength,
           !WarningSilenceRecord.covers(silenced, rule: CodeWarning.Kind.failedInARow.rawValue, workStartedAt: work.startedAt, now: now) {
            out.warnings.append(CodeWarning(kind: .failedInARow, since: run.since ?? now, failures: run.count,
                                            lastExitCode: run.lastExitCode))
        }
        // Background tasks pending (between turns, or while the turn is quiet) are no silence: no model owes a reply.
        if progress?.pendingBetweenTurns != true, let quiet = quietSince(snapshot: snapshot, digest: digest) {
            let stuckAt = quiet.addingTimeInterval(CodeTuning.stuckSilence)
            if now >= stuckAt {
                if !WarningSilenceRecord.covers(silenced, rule: CodeWarning.Kind.silence.rawValue, workStartedAt: work.startedAt, now: now) {
                    out.warnings.append(CodeWarning(kind: .silence, since: quiet))
                }
            } else {
                out.deadline = stuckAt
            }
        }
        return out
    }

    /// The trailing run of failing Bash calls of the work: how many, since when, the last exit code.
    static func failureRun(_ turns: [CodeTurnDigest.Turn],
                           digest: CodeTurnDigest) -> (count: Int, since: Date?, lastExitCode: Int?)? {
        var copied = Set<String>()
        for case .toolUse(let tool) in digest.allItems where tool.isCopied { if let id = tool.id { copied.insert(id) } }
        var count = 0
        var since: Date?
        var lastExit: Int?
        for turn in turns {
            for case .toolResult(let result) in turn.items {
                guard result.toolName == "Bash", !result.denied, result.asyncKind == nil,
                      !(result.toolUseID.map(copied.contains) ?? false) else { continue }
                if result.isError == true, let code = result.exitCode {
                    if count == 0 { since = result.at }
                    count += 1
                    lastExit = code
                } else if result.isError == false {
                    count = 0
                    since = nil
                    lastExit = nil
                }
            }
        }
        return count > 0 ? (count, since, lastExit) : nil
    }

    /// Since when the model has been silent: nil while a tool waits, the turn has finished, or the session needs
    /// the user or has a problem (those have their own words).
    static func quietSince(snapshot: CodeSessionSnapshot, digest: CodeTurnDigest) -> Date? {
        guard let turn = digest.latestTurn, !turn.isFinished, turn.pendingToolUses.isEmpty,
              ![.needsYou, .problem, .maybeNeedsYou].contains(snapshot.state) else { return nil }
        let grew = digest.lastGrowthAt ?? turn.lastEntryAt ?? snapshot.lastActivity
        switch snapshot.place {
        case .local:
            return grew
        case .ssh, .unknown:
            return [grew, digest.lastActivityMovedAt].compactMap { $0 }.max()
        }
    }
}

/// The work that runs now: from the latest turn of the user's or another session's (the current turn
/// when that one is over 12 hours old or missing) to the end. It has ended once its last turn finished and no
/// background task is pending (`progress.pendingBetweenTurns`).
struct CurrentWork {
    var turns: [CodeTurnDigest.Turn]
    var startedAt: Date?

    init?(_ digest: CodeTurnDigest, now: Date) {
        guard let last = digest.turns.indices.last else { return nil }
        var start = last
        if let index = digest.turns.lastIndex(where: { $0.origin == .human || $0.origin == .peer }) {
            let age = digest.turns[index].startedAt.map { now.timeIntervalSince($0) } ?? 0
            if age <= CodeTuning.workMaxAge { start = index }
        }
        turns = Array(digest.turns[start...])
        startedAt = turns.first?.startedAt ?? turns.first?.lastEntryAt
    }

    func isRunning(progress: CodeProgress?) -> Bool {
        guard let last = turns.last else { return false }
        return !last.isFinished || progress?.pendingBetweenTurns == true
    }
}

/// The warnings' per-session deriver (order 400, after the progress deriver): failures in a row and silence. Logs a
/// warning when it appears: `warning session=#3 kind=failed_in_a_row` (labels and numbers only).
final class StuckDeriver: CodeSessionDeriver {
    let label = "stuck"
    let order = CodeDeriveOrder.stuck
    private var shown: [String: Set<CodeWarning.Kind>] = [:]

    func derive(_ input: CodeDeriveInput, into fields: inout CodeDerivedFields) {
        let session = input.snapshot
        var warnings: [CodeWarning] = []
        if input.settings.warnings.stuck {
            let silenced: [WarningSilenceRecord] = input.memory.read(.silenced, session: session.id) ?? []
            let out = StuckDetector.evaluate(snapshot: session, digest: input.digest, progress: fields.progress, now: input.now,
                                             silenced: silenced)
            warnings = out.warnings
            if let deadline = out.deadline { fields.deadlines.append(deadline) }
        }
        fields.warnings = warnings
        let kinds = Set(warnings.map(\.kind))
        for kind in kinds.subtracting(shown[session.id] ?? []).sorted(by: { $0.rawValue < $1.rawValue }) {
            CodeLog.info("warning session=#\(session.index) kind=\(kind.rawValue)")
        }
        shown[session.id] = kinds
    }

    func sessionLeft(_ sessionID: String) { shown[sessionID] = nil }
}

public extension CodeDeriverSet {
    /// Warnings: "Looks stuck" (failures in a row, silence) per session and "Same file" across the followed sessions,
    /// on this Mac's home and temporary folders.
    static var warnings: CodeDeriverSet {
        CodeDeriverSet(perSession: [StuckDeriver()], crossSession: [SameFileDeriver(environment: .live())])
    }
}
