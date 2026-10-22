import CryptoKit
import Foundation
import PitboxKit

/// Memory of the commands run from offers (shown as "ran 4 min ago · exit 0"): per run only the first 16 hex characters
/// of the SHA-256 of the text, the session index, how it ended, how long it ran and when. No text is kept; nothing
/// survives a restart of the app. The block feeds it the sheet's events and asks it about new offers.
@MainActor
public final class CodeRunRecords {
    /// One run of an offer.
    public struct Record: Equatable, Sendable {
        /// `CodeRunRecords.textHash` of the text that ran.
        public var textHash: String
        /// The session's local index (`#3`).
        public var sessionIndex: Int
        /// The shell's exit status; nil when a signal ended it.
        public var exitStatus: Int32?
        /// The signal that ended it (Stop, Ctrl-C, closing the tab); nil when it exited.
        public var signal: Int32?
        /// How long it ran.
        public var seconds: Double
        /// When it ended.
        public var at: Date
    }

    /// The oldest records go beyond this many.
    public static let maxRecords = 200
    private var records: [Record] = []

    /// An empty memory (nothing survives a restart).
    public init() {}

    /// The first 16 hex characters of the SHA-256 of `text`'s UTF-8 bytes.
    public nonisolated static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Records a finished or stopped run of `offer` (other events change nothing).
    public func note(_ event: CommandOfferEvent, for offer: CommandOffer, at date: Date = Date()) {
        let hash = Self.textHash(offer.text)
        switch event {
        case .finished(_, let status, let seconds):
            append(Record(textHash: hash, sessionIndex: offer.id.sessionIndex, exitStatus: status, signal: nil,
                          seconds: seconds, at: date))
        case .stopped(_, let signal, let seconds):
            append(Record(textHash: hash, sessionIndex: offer.id.sessionIndex, exitStatus: nil, signal: signal,
                          seconds: seconds, at: date))
        default:
            break
        }
    }

    /// The latest run of the same text from the same session, if any.
    public func lastRun(of offer: CommandOffer) -> Record? {
        let hash = Self.textHash(offer.text)
        return records.last { $0.textHash == hash && $0.sessionIndex == offer.id.sessionIndex }
    }

    /// How many runs are remembered.
    public var count: Int { records.count }

    private func append(_ record: Record) {
        records.append(record)
        if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
    }
}
