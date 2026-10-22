import Foundation

/// Where the guest stands with a dock host.
public enum DockGuestState: Equatable, Sendable {
    /// No host: the app places itself at the screen edge.
    case alone
    /// A listed host app runs: up to 1 s for its first `place` before the app shows (no jump at launch).
    case waitingForHost
    /// Docked beside the host: its latest `place` and the features both sides use.
    case docked(HostPlace, Set<DockFeature>)
    /// The host stopped answering (15 s without a line) while its process lives: the docked area is kept.
    case hostNotResponding(HostPlace, Set<DockFeature>)
    /// Alone, because the last host could not dock (no common version) or a connection was refused.
    case refused(DockRefusal)

    /// The host's place while docked (or not responding).
    public var place: HostPlace? {
        switch self {
        case .docked(let place, _), .hostNotResponding(let place, _): return place
        case .alone, .waitingForHost, .refused: return nil
        }
    }

    /// True while docked or not responding (the area is kept either way).
    public var isDocked: Bool { place != nil }
}

/// A warning for the menu's dock line, beside the state.
public enum DockWarning: Equatable, Sendable {
    /// A listed host app runs but did not connect within 5 s: it may be an old build without dock support that still
    /// parks windows of its own.
    case hostWithoutDockSupport
    /// The dock socket could not be bound (see the log): no host can connect.
    case socketUnavailable
}

/// The host's answer to the guest's wish to speak (`speech.begin`).
public enum SpeechAnswer: Equatable, Sendable {
    /// Speak now; call `DockGuest.endSpeech()` after the phrase.
    case ok
    /// Say nothing aloud.
    case no(SpeechRefusal)
}

/// Why the guest may not speak.
public enum SpeechRefusal: Equatable, Sendable {
    /// The host said `speech.no` (talk, dictation, locked or other).
    case host(DockSpeechNoReason)
    /// No answer within 2 s (a late `ok` is undone at once with `speech.end`).
    case timeout
    /// Docked, but the host does not offer the speech pause: no voice while docked (the chime still plays).
    case unsupported
    /// A listed host app runs but is not docked: it may be listening, so no voice.
    case notDocked
    /// The host does not answer pings.
    case hostNotResponding
    /// The host left while the guest waited.
    case hostGone
    /// Another request is waiting for its answer.
    case busy
}
