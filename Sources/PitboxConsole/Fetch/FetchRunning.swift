import Foundation
import PitboxKit

// Fetch file: the seam between the Fetch file sheet (Commands/) and the scp runner (Fetch/). The sheet builds a plan
// when it opens, shows it, and starts it only after the user's click on Fetch file. Change it only together with both
// sides. Never log the values held here (paths, hosts, users, names; docs/THREAT_MODEL.md): log labels and numbers
// only.

/// What one Fetch file will do, frozen when the sheet opens.
struct FetchPlan: Equatable, Sendable {
    /// The exact `~/.ssh/config` alias Pitbox connects through (never a host from the reply).
    var alias: String
    /// The user it logs in as: the config's by default, the reply's when the user picked it (re-arms the sheet).
    var loginUser: String
    /// The user `ssh -G <alias>` gives, and the one the reply named (shown as the visible choice).
    var configUser: String?
    var replyUser: String?
    /// "through <jump>" or "your config runs a proxy command", when the alias uses one.
    var proxyNote: String?
    /// The remote file as unquoted from the reply.
    var remotePath: String
    /// The final file name in Downloads after the name rules (refused names never get a plan).
    var fileName: String
    /// The free name Downloads has right now ("release-notes 2.md"), a preview: the rename decides at the end.
    var previewName: String
    /// The exact scp argument list (argv[0] first), as the sheet shows it; the staging path is a placeholder token
    /// until the run starts.
    var arguments: [String]
    /// Fingerprint of `~/.ssh/config` and its includes (size, time, hash) at opening, checked again before connecting.
    var configFingerprint: String
}

/// Why a Fetch file cannot even be offered; each case has Pitbox's words for the sheet.
enum FetchPlanRefusal: Error, Equatable, Sendable {
    case aliasNotInConfig
    /// The config or an include has a `Match` block, so it cannot be read without running it.
    case configNeedsRunning
    /// The file name is refused, not repaired (B1/B2 characters, `/`, `:`, leading `.` or `-`, too long, hidden type).
    case deceptiveName
    /// Downloads and the staging folder are on different volumes.
    case otherVolume
    /// `~/Downloads` is missing, not a folder, or a link.
    case downloadsUnavailable
    /// Less than 5 GB would remain after the 500 MB limit.
    case notEnoughSpace

    var words: String {
        switch self {
        case .aliasNotInConfig: return "the server isn't an exact entry in your SSH config"
        case .configNeedsRunning: return "couldn't read your SSH config without running it"
        case .deceptiveName: return "the file name looks deceptive: not fetched"
        case .otherVolume: return "Downloads is on another volume"
        case .downloadsUnavailable: return "Downloads isn't available"
        case .notEnoughSpace: return "not enough free space for a fetch"
        }
    }
}

/// A started fetch. `cancel()` stops scp, removes the staging folder and reports `.cancelled`.
protocol FetchHandle: AnyObject, Sendable {
    func cancel()
}

/// Implemented by `FetchRunner`; the sheet and its tests use this protocol.
protocol FetchRunning: AnyObject, Sendable {
    /// Builds the plan for a recognised Fetch file offer, reading the SSH config itself (`ssh -G` only when there is no
    /// `Match` block). `loginUser` nil means the config's user. Runs off the main thread; never connects.
    func plan(for request: FetchFileRequest, loginUser: String?) async -> Result<FetchPlan, FetchPlanRefusal>

    /// Starts the plan: config unchanged check, staging, scp with the size limit, quarantine, exclusive rename into
    /// Downloads. `progress` gets the bytes staged so far (at most every 0.5 s); `completion` gets the
    /// outcome exactly once. Both are called on the main thread.
    func start(_ plan: FetchPlan, progress: @escaping @MainActor (Int64) -> Void,
               completion: @escaping @MainActor (FetchFileOutcome) -> Void) -> FetchHandle
}
