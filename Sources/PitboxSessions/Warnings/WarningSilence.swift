import CryptoKit
import Foundation
import PitboxKit

/// One `silenced` record of `code-memory.json`: the rule word, until when, and when OK was
/// pressed. Only rule words, a hash and times are kept: never a path or a headline.
struct WarningSilenceRecord: Codable, Equatable, Sendable {
    /// `failed_in_a_row`, `silence`, or `same_file:<hash16>` (the pair and the file, hashed).
    var rule: String
    var until: Date
    /// When OK was pressed: a "Looks stuck" silence holds for the rest of the work that was running then, so it stops
    /// at the next turn of the user's or another session's.
    var at: Date?

    /// Some record silences `rule` now, for the work that started at `workStartedAt`.
    static func covers(_ records: [WarningSilenceRecord], rule: String, workStartedAt: Date?, now: Date) -> Bool {
        records.contains { record in
            guard record.rule == rule, record.until >= now else { return false }
            guard let at = record.at, let start = workStartedAt else { return true }
            return start <= at
        }
    }
}

/// OK on a warning: "Looks stuck" is silenced for the rest of the work, Same file for that pair and
/// file for 2 hours, in both sessions. The Ready list's OK on a Warning card calls this; the
/// store's change brings the engine back, which then derives the warning away. Nothing is sent to any session.
public enum CodeWarningSilencer {
    /// Silences `warning` of the session `sessionID` (and, for Same file, of the other session too).
    public static func silence(_ warning: CodeWarning, of sessionID: String, memory: CodeMemoryStore, now: Date = Date()) {
        switch warning.kind {
        case .failedInARow, .silence:
            add(WarningSilenceRecord(rule: warning.kind.rawValue, until: now.addingTimeInterval(CodeTuning.workMaxAge), at: now),
                to: sessionID, memory: memory, now: now)
        case .sameFile:
            guard let other = warning.otherSessionID else { return }
            let rule = sameFileRule(sessionIDs: [sessionID, other], path: warning.path ?? "")
            let record = WarningSilenceRecord(rule: rule, until: now.addingTimeInterval(CodeTuning.okSilenceSameFile), at: now)
            add(record, to: sessionID, memory: memory, now: now)
            add(record, to: other, memory: memory, now: now)
        }
        CodeTileLog.info("warning silenced kind=\(warning.kind.rawValue)")
    }

    /// `same_file:<hash16>`: the first 16 hex characters of the SHA-256 of the two session ids (sorted) and the path as
    /// the warning shows it, so the record holds no path.
    static func sameFileRule(sessionIDs: [String], path: String) -> String {
        let text = sessionIDs.sorted().joined(separator: "\n") + "\n" + path
        let digest = SHA256.hash(data: Data(text.utf8))
        return CodeWarning.Kind.sameFile.rawValue + ":" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func add(_ record: WarningSilenceRecord, to sessionID: String, memory: CodeMemoryStore, now: Date) {
        var records: [WarningSilenceRecord] = memory.read(.silenced, session: sessionID) ?? []
        records.removeAll { $0.rule == record.rule || $0.until < now }
        records.append(record)
        memory.write(.silenced, session: sessionID, value: Array(records.suffix(CodeTuning.memorySilencedMax)))
    }
}
