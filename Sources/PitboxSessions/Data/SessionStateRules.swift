import Foundation
import PitboxKit

/// What the state of one session is decided from.
struct SessionStateInput: Sendable {
    /// The session file, nil when it is missing or failed its checks (status unknown).
    var file: ClaudeSessionFile?
    /// The transcript's turn tracker, nil when the transcript is missing or unreadable (status unknown).
    var tracker: TurnTracker?
    /// The transcript's modification time (this Mac's clock: SSH mirrors are written here).
    var transcriptModified: Date?
    /// The session file's modification time.
    var sessionFileModified: Date?
    var now: Date
}

/// The monitor's state and the lines that go with it.
struct SessionStateResult: Equatable, Sendable {
    var state: CodeSessionState
    var word: String
    /// The current summary's `status_detail` and `needs_action`.
    var tldr: String?
    var askLine: String?
    /// While working: the last tool call in words.
    var nowLine: String?
    var lastActivity: Date?
    var quietSince: Date?
    /// When the latest turn ended (its `end_turn`), nil while a turn runs.
    var turnFinishedAt: Date?
    /// The turn is finished by the transcript and `sshReattach.midTurn` is not true: offers may exist.
    var finished: Bool
    /// The earliest time at which the result can change without a file changing (a grace or a wait running out).
    var nextChange: Date?
}

/// The status rules, first match wins, plus the quiet overlay. Measured adjustments: SSH session files move every few
/// seconds during a turn while the mirror lags 20-40 s, so "written" counts the session file too, and "Maybe needs you"
/// also needs a session file that did not move.
enum SessionStateRules {
    static let quietAfter: TimeInterval = 30 * 60
    static let summaryGrace: TimeInterval = 10
    static let toolWait: TimeInterval = 30
    /// Permission modes in which no permission prompt can be pending.
    static let promptFreeModes: Set<String> = ["bypassPermissions", "auto"]

    static func evaluate(_ input: SessionStateInput) -> SessionStateResult {
        let now = input.now
        let lastActivity = [input.transcriptModified, input.file?.lastActivityAt].compactMap { $0 }.max()
        let quiet = lastActivity.map { now.timeIntervalSince($0) >= quietAfter } ?? false
        var result = SessionStateResult(state: .unknown, word: CodeSessionState.unknown.word, lastActivity: lastActivity,
                                        quietSince: quiet ? lastActivity : nil, finished: false)
        var deadlines: [Date] = []
        if let lastActivity, !quiet { deadlines.append(lastActivity.addingTimeInterval(quietAfter)) }
        guard let file = input.file, let tracker = input.tracker else {
            result.nextChange = deadlines.min()
            return result
        }
        let turn = tracker.turn
        let summary = currentSummary(file: file, lastAssistantUUID: tracker.lastAssistantUUID)
        result.tldr = summary?.detail
        result.askLine = summary?.needsAction
        let finished = (turn?.endedByTranscript ?? false) && !file.midTurn
        result.finished = finished
        let endedAt = finished ? turnEnd(turn, transcriptModified: input.transcriptModified) : nil
        result.turnFinishedAt = endedAt

        func set(_ state: CodeSessionState, _ word: String? = nil) {
            result.state = state
            result.word = word ?? state.word
        }

        let category = summary?.category
        if category == "blocked" || category == "need_input" || summary?.needsAction != nil || file.wrapUpNeedsUser
            || (turn?.asksUser ?? false) {
            set(.needsYou)
        } else if file.hasError || file.errorCategory != nil || category == "failed" {
            set(.problem, "failed")
        } else if file.interruptedAwaitingPerson || file.stoppedUntilPersonSends {
            set(.problem, "stopped")
        } else if !finished {
            let recent = lastActivity.map { now.timeIntervalSince($0) < quietAfter } ?? false
            if recent {
                set(.working)
                result.nowLine = turn?.lastToolWords
                if turn?.waitingTool != nil, !promptFreeModes.contains(file.permissionMode ?? "") {
                    let lastWrite = [input.transcriptModified, input.sessionFileModified, file.lastActivityAt]
                        .compactMap { $0 }.max()
                    if let lastWrite {
                        if now.timeIntervalSince(lastWrite) >= toolWait {
                            set(.maybeNeedsYou)
                        } else {
                            deadlines.append(lastWrite.addingTimeInterval(toolWait))
                        }
                    }
                }
            } else {
                set(.quietUnfinished)
            }
        } else if summary == nil, let endedAt, now.timeIntervalSince(endedAt) < summaryGrace {
            // The summary usually lands 2-8 s after the turn's end (measured).
            set(.working)
            deadlines.append(endedAt.addingTimeInterval(summaryGrace))
        } else if category == "review_ready" {
            set(.reviewReady)
        } else if summary != nil {
            set(.done)
        } else {
            set(.doneNoSummary)
        }
        result.nextChange = deadlines.filter { $0 > now }.min()
        return result
    }

    /// `postTurnSummary` counts only when it summarises the transcript's last assistant entry.
    static func currentSummary(file: ClaudeSessionFile, lastAssistantUUID: String?) -> ClaudeSessionFile.Summary? {
        guard let summary = file.summary, let uuid = summary.summarizesUUID, uuid == lastAssistantUUID else { return nil }
        return summary
    }

    /// The end of the turn on this Mac's clock: the end_turn entry's time, never later than the transcript's
    /// modification time (an SSH server's clock may run ahead).
    private static func turnEnd(_ turn: TranscriptTurn?, transcriptModified: Date?) -> Date? {
        guard let stamp = turn?.lastAssistantAt ?? transcriptModified else { return nil }
        guard let transcriptModified else { return stamp }
        return min(stamp, transcriptModified)
    }
}

/// The headline and the worktree nickname of a title.
enum TitleRules {
    /// Claude's separator in titles such as "buildbox · Fix the build".
    static let separator = " \u{00B7} "

    /// The title without a leading `<host> · ` (when `<host>` is one of `hosts`: the session's SSH alias) and without
    /// the trailing "(two words)" nickname, which is returned on its own.
    static func split(title: String, hosts: [String]) -> (headline: String, nickname: String?) {
        var text = CodeText.oneLine(title, limit: ClaudeSessionFile.titleScalars)
        if let range = text.range(of: separator) {
            let prefix = String(text[..<range.lowerBound])
            if !prefix.isEmpty, !prefix.contains(" "), hosts.contains(prefix) {
                text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        var nickname: String?
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
            let words = inner.split(separator: " ", omittingEmptySubsequences: false)
            if words.count == 2, words.allSatisfy({ (1...24).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isLetter } }) {
                let rest = String(text[..<open]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    nickname = String(inner)
                    text = rest
                }
            }
        }
        return (text, nickname)
    }
}
