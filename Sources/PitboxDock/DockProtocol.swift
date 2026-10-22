import Foundation

/// The dock protocol's fixed numbers (docs/DOCK_PROTOCOL.md). Both sides use the same values; a change here is a
/// change of the protocol document first.
public enum DockProtocol {
    /// The protocol majors this build speaks (`hello.proto`): `[min, max]`.
    public static let majors: ClosedRange<Int> = 1...1
    /// The minor version of the highest major this build implements (`hello.minor`, informational).
    public static let minor = 0
    /// The version this build implements, as written in the document ("1.0").
    public static var versionText: String { "\(majors.upperBound).\(minor)" }

    /// Bytes per line at most, not counting the newline.
    public static let maxLineBytes = 16 * 1024
    /// Lines per second a side may send: a receiver keeps a bucket of this many tokens, refilled at this rate.
    public static let maxLinesPerSecond = 50
    /// Nesting of objects and arrays at most (the line's own object counts as 1).
    public static let maxNesting = 8
    /// Each side's `hello` must arrive within this many seconds of the connection.
    public static let handshakeTimeout: TimeInterval = 2
    /// A side that received nothing for this long sends `ping` (and again every this many seconds while silent).
    public static let pingAfter: TimeInterval = 5
    /// A peer that sent nothing for this long, with a `ping` outstanding, is "not responding" (never a disconnect).
    public static let notRespondingAfter: TimeInterval = 15
    /// `place` at most this often during a live width drag (the host's limit; not enforced beyond the line rate).
    public static let maxLivePlacesPerSecond = 30
    /// `attention` at most once per this many seconds.
    public static let attentionInterval: TimeInterval = 1
}

/// The optional parts of the protocol. A feature is used only when both sides list it in `hello.features`.
public enum DockFeature: String, CaseIterable, Sendable {
    /// Drop claims mirrored from the guest to the host's window guard (`claim`, `release`, `mouseUp`).
    case guardClaims = "guard.claims"
    /// The host's light/dark and backdrop (`appearance`).
    case appearance
    /// The host's focus key (`focus`).
    case focus
    /// The speech pause (`speech.begin`, `speech.ok`, `speech.no`, `speech.end`).
    case speech
    /// The host's menu folds and unfolds the guest (`fold`).
    case fold
    /// The guest's counts (`attention`).
    case attention

    /// Every feature this build implements.
    public static var all: Set<DockFeature> { Set(allCases) }
}

/// Why a side closes the link normally (`bye.why`). Unknown words read as `other`.
public enum DockByeReason: String, CaseIterable, Sendable {
    /// The app quits.
    case quit
    /// The app is about to be replaced by a newer build.
    case update
    /// The user turned docking off, or the allow list no longer lists the peer.
    case settings
    /// No common protocol major.
    case version
    /// The peer failed the guest's checks (user, app bundle, allow list).
    case refused
    /// The peer broke the framing or the handshake rules.
    case `protocol`
    /// The peer's `hello` did not arrive in time.
    case timeout
    /// A word this build does not know.
    case other
}

/// Why the host said `speech.no` (`speech.no.why`). Unknown words read as `other`.
public enum DockSpeechNoReason: String, CaseIterable, Sendable {
    /// The host's conversation mode holds the audio.
    case talk
    /// Dictation runs.
    case dictation
    /// The screen is locked.
    case locked
    /// A word this build does not know, or none.
    case other
}
