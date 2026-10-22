import Foundation
import PitboxKit

/// What the guest says about itself in its `hello`.
struct DockGuestHello: Equatable, Sendable {
    var proto: ClosedRange<Int> = DockProtocol.majors
    var minor: Int = DockProtocol.minor
    var app: String = AppIdentity.displayName
    var build: String
    var features: Set<DockFeature>

    var message: GuestMessage {
        .hello(DockHello(proto: proto, minor: minor, role: .guest, app: app, build: build, features: features,
                         wakeWords: [], privateFolders: HostPrivateFolders()))
    }
}

/// The outcome of a handshake: the version and features both sides use, and what the verified host announced.
struct DockHandshake: Equatable, Sendable {
    /// The highest common protocol major.
    var major: Int
    /// The features both sides listed.
    var features: Set<DockFeature>
    /// The host's `hello.app` (clean it before showing it).
    var hostName: String
    var hostBuild: String
    var wakeWords: [String]
    var privateFolders: HostPrivateFolders
    var host: VerifiedHost
}

/// Why a session ended.
enum DockEndReason: Equatable, Sendable {
    /// The host closed the socket (or it was reset).
    case endOfFile
    /// The host's process exited (kqueue `NOTE_EXIT`).
    case processExited
    /// The host said `bye`.
    case bye(DockByeReason)
    /// The host broke a framing or handshake rule (the label names which).
    case violation(String)
    /// No `hello` from the host within 2 s.
    case handshakeTimeout
    /// No common protocol major; `hostApp` is the host's `hello.app` (for the menu line, never the log).
    case version(ours: ClosedRange<Int>, theirs: ClosedRange<Int>, hostApp: String)
    /// The guest closed the link (with its own `bye`).
    case closed(DockByeReason)
    /// Reading failed with this errno.
    case readFailed(Int32)

    /// A label for the log (protocol words only).
    var label: String {
        switch self {
        case .endOfFile: return "end of file"
        case .processExited: return "host process exited"
        case .bye(let why): return "host bye \(why.rawValue)"
        case .violation(let what): return "violation \(what)"
        case .handshakeTimeout: return "handshake timeout"
        case let .version(ours, theirs, _):
            return "no common version ours=\(DockRefusal.words(ours)) theirs=\(DockRefusal.words(theirs))"
        case .closed(let why): return "closed \(why.rawValue)"
        case .readFailed(let code): return "read failed errno=\(code)"
        }
    }
}

/// What a session reports to its owner, in order, on the session's queue.
enum DockSessionEvent: Equatable, Sendable {
    case handshake(DockHandshake)
    case message(HostMessage)
    /// False when the host stopped answering (a ping 10 s old, 15 s without a line); true when a line arrived again.
    case responsive(Bool)
    case ended(DockEndReason)
}

/// Counters of one session, for the log and the tests.
struct DockSessionStats: Equatable, Sendable {
    var linesIn = 0
    var linesOut = 0
    var blankLines = 0
    var unknownTypes = 0
    var unknownFields = 0
    var duplicateKeys = 0
    var badFields = 0
    var featureOff = 0
    var sendDropped = 0
    var pingsSent = 0
    /// Announced private folders refused by the folder rule (too broad, `..`, not absolute).
    var refusedFolders = 0

    var logText: String {
        "in=\(linesIn) out=\(linesOut) unknownTypes=\(unknownTypes) unknownFields=\(unknownFields) "
            + "duplicateKeys=\(duplicateKeys) badFields=\(badFields) featureOff=\(featureOff) sendDropped=\(sendDropped) "
            + "refusedFolders=\(refusedFolders)"
    }
}
