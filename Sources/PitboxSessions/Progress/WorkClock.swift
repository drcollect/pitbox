import Foundation
import PitboxKit

/// The work of a session: what the user, or another session, last asked for. It
/// starts with the latest turn of `turnOrigin` human or peer and takes in every turn after it (the turns background
/// notices started since, and turns of unknown origin). When that turn is more than `CodeTuning.workMaxAge` old, or
/// none is in the digest, the work is the current turn.
struct CodeWork: Equatable, Sendable {
    /// How the work's start was found.
    enum Basis: Equatable, Sendable {
        /// The latest turn of human or peer origin in the digest.
        case asked
        /// That turn has dropped out of a truncated digest (its front was cut by the 2 MB or 200-turn bound), and this
        /// deriver saw it earlier: the remembered start stands, every turn in the digest belongs to the work.
        case remembered
        /// No such turn, or it is over 12 hours old: the current turn alone.
        case currentTurn
    }

    /// What a deriver remembers of a work between passes (memory only, per session).
    struct Anchor: Equatable, Sendable {
        var startUUID: String?
        var startedAt: Date
    }

    /// Index in `digest.turns` of the work's first turn.
    var firstTurn: Int
    /// The work's start: its starting entry's timestamp (the server's clock for SSH sessions); nil when no entry of
    /// the turn has one.
    var startedAt: Date?
    /// The starting entry's uuid, when it passes the grammar.
    var startUUID: String?
    var basis: Basis

    /// The anchor to remember for the next pass (only a start that was seen, never a fallback).
    var anchor: Anchor? {
        guard basis != .currentTurn, let startedAt else { return nil }
        return Anchor(startUUID: startUUID, startedAt: startedAt)
    }

    /// Whether the turn at `index` belongs to the work.
    func contains(turn index: Int) -> Bool { index >= firstTurn }
}

/// Finds the work in a digest and words its running time. Pure.
enum WorkClock {
    /// The work at `now`, or nil for an empty digest. `remembered` is what the caller kept from an earlier pass of the
    /// same session (used only when the digest was truncated and lost the asking turn).
    static func work(in digest: CodeTurnDigest, now: Date, remembered: CodeWork.Anchor? = nil) -> CodeWork? {
        guard !digest.turns.isEmpty else { return nil }
        let current = digest.turns.count - 1
        if let index = digest.turns.lastIndex(where: { $0.origin == .human || $0.origin == .peer }) {
            let turn = digest.turns[index]
            let start = startTime(of: turn)
            if let start, now.timeIntervalSince(start) > CodeTuning.workMaxAge {
                return currentTurn(digest, index: current)
            }
            return CodeWork(firstTurn: index, startedAt: start, startUUID: turn.startUUID, basis: .asked)
        }
        if let remembered, digest.truncated, now.timeIntervalSince(remembered.startedAt) <= CodeTuning.workMaxAge,
           startTime(of: digest.turns[0]).map({ $0 >= remembered.startedAt }) ?? true {
            return CodeWork(firstTurn: 0, startedAt: remembered.startedAt, startUUID: remembered.startUUID,
                            basis: .remembered)
        }
        return currentTurn(digest, index: current)
    }

    /// "Running 34 min", "Running 1 h 12 min" (minutes rounded down, at least 1).
    static func runningWords(since start: Date, now: Date) -> String {
        "Running " + CodeDurationText.minutes(CodeDurationText.elapsedMinutes(from: start, to: now))
    }

    /// A turn's start: its starting entry's timestamp, else its first timestamped item (the partial turn at a tail's
    /// front has no start entry).
    static func startTime(of turn: CodeTurnDigest.Turn) -> Date? {
        if let at = turn.startedAt { return at }
        for item in turn.items {
            switch item {
            case .text(let x): if let at = x.at { return at }
            case .toolUse(let x): if let at = x.at { return at }
            case .toolResult(let x): if let at = x.at { return at }
            case .notice(let x): if let at = x.at { return at }
            }
        }
        return nil
    }

    private static func currentTurn(_ digest: CodeTurnDigest, index: Int) -> CodeWork {
        let turn = digest.turns[index]
        return CodeWork(firstTurn: index, startedAt: startTime(of: turn), startUUID: turn.startUUID, basis: .currentTurn)
    }
}
