import Darwin
import Foundation
import PitboxKit

// The derive hook: where the features built on the parse (progress and ETA, results, warnings, dashboards, finished,
// earlier offers) plug their rules into the engine without touching it. Each feature implements `CodeSessionDeriver`
// (and, for rules over several sessions, `CodeCrossSessionDeriver`) in its own folder and publishes a `CodeDeriverSet`
// for the composition root, which registers them all with `CodeSessionsEngine.register(_:memory:)`. The engine runs
// them on its background queue after each parse and stores their output in the snapshot's derived fields.

/// The derived fields of one session's snapshot as the derivers fill them, plus the times at which they change on
/// their own. Every deriver of a session gets the same value in turn (in `order`), so a later one reads what earlier
/// ones wrote; each feature writes only its own fields.
struct CodeDerivedFields: Sendable, Equatable {
    /// Running and ETA.
    var workStartedAt: Date?
    var progress: CodeProgress?
    var eta: CodeETA?
    /// Results.
    var results: [CodeResult] = []
    var otherLinkCount = 0
    /// Warnings.
    var warnings: [CodeWarning] = []
    /// Dashboards.
    var dashboard: CodeDashboard?
    /// Earlier offers: offers of earlier replies (each `offer.supersession` set), oldest reply first, and what the
    /// click-time check needs for them; the engine registers these before the latest reply's (3 replies at most).
    var earlierOffers: [CodeOfferEntry] = []
    var earlierRegistrations: [CodeOfferFreshnessChecker.Reply] = []
    /// Finished.
    var finished: CodeFinishedMark?
    var unread = false
    /// When any field above changes without a file changing (an ETA passing, an estimate's next minute, 30 minutes
    /// of silence, a record expiring): the engine derives this session again then, while the block is visible, and in
    /// any case at the next publication after it.
    var deadlines: [Date] = []

    /// `snapshot` with these fields (the fields the parse set are never changed by a deriver).
    func applied(to snapshot: CodeSessionSnapshot) -> CodeSessionSnapshot {
        var out = snapshot
        out.workStartedAt = workStartedAt
        out.progress = progress
        out.eta = eta
        out.results = results
        out.otherLinkCount = otherLinkCount
        out.warnings = warnings
        out.dashboard = dashboard
        out.earlierOffers = earlierOffers
        out.finished = finished
        out.unread = unread
        return out
    }
}

/// What a per-session deriver reads. Everything here is session data: never log it (labels and numbers only).
struct CodeDeriveInput {
    /// The parsed snapshot (state, Now, offers, `replyUUID`, …); its derived fields are empty: read earlier derivers'
    /// output from `fields`.
    let snapshot: CodeSessionSnapshot
    /// The turn digest, tool_uses copied from another followed session marked `isCopied`.
    let digest: CodeTurnDigest
    /// Changes whenever the transcript lines or the session file changed: cache expensive work by it.
    let digestVersion: Int
    /// The engine's clock (injected in tests): never call `Date()`.
    let now: Date
    let memory: CodeMemoryStore
    let settings: CodeSettings
    /// Where the transcript and the session file are (the dashboards' one-time scan, the click-time checks of earlier
    /// offers and results), opened only through `CarefulFiles` with `owner`.
    let transcript: CarefulPath?
    let sessionFile: CarefulPath?
    let owner: uid_t

    var sessionID: String { snapshot.id }
}

/// One feature's rules over one session. Implemented in the feature's own folder.
///
/// - Called on the engine's background queue only, one call at a time, after a parse of a followed session whose
///   transcript and session file were read (never for a session beyond the 24 read fully), again when the session's
///   memory records changed from outside the engine, when the settings changed, when a deadline passed, or when the
///   parsed snapshot changed. Otherwise the last output is reused.
/// - Budget: all derivers of one session together within `CodeTuning.deriveBudget` (10 ms); slower runs are logged
///   (`[code] derive over budget …`). Never block: long work (the dashboards' whole-transcript scan) runs on the
///   feature's own serial queue at utility priority, never the engine's, writes its result to `memory`, and the store's
///   change brings the engine back here.
/// - State: per-session caches keyed by session id are fine (the engine's queue serialises the calls); drop them in
///   `sessionLeft`. Persistent facts go to `memory` under the feature's own `CodeMemoryKey`; its own writes from inside
///   `derive` do not trigger another run.
/// - Output: only the feature's own fields of `fields`, and `deadlines` for times its output changes by itself.
protocol CodeSessionDeriver: AnyObject {
    /// A short label for logs: lowercase letters and `-` ("progress", "results").
    var label: String { get }
    /// Lower runs first (`CodeDeriveOrder`).
    var order: Int { get }
    func derive(_ input: CodeDeriveInput, into fields: inout CodeDerivedFields)
    /// The session is no longer read (unfollowed, gone, beyond the 24, or the engine stopped): drop its caches and
    /// cancel its work.
    func sessionLeft(_ sessionID: String)
}

extension CodeSessionDeriver {
    func sessionLeft(_ sessionID: String) {}
}

/// One session as a cross-session deriver sees it.
struct CodeCrossSessionInput {
    /// The parsed snapshot with every per-session deriver's fields applied.
    let snapshot: CodeSessionSnapshot
    let digest: CodeTurnDigest
    let digestVersion: Int

    var sessionID: String { snapshot.id }
}

/// What a cross-session deriver shares across the sessions.
struct CodeCrossDeriveContext {
    let now: Date
    let memory: CodeMemoryStore
    let settings: CodeSettings
    let owner: uid_t
}

/// Rules over all followed sessions at once (the Same file warning; the unread dot, which must see every other
/// warning). Runs on the engine's queue once per publication, after every per-session deriver, in `order`, over the
/// sessions whose digests were read (ordered by copy, then first seen). Same rules for budget, blocking and state as
/// `CodeSessionDeriver`; it changes only its own fields in `fields` (keyed by session id).
protocol CodeCrossSessionDeriver: AnyObject {
    var label: String { get }
    var order: Int { get }
    func derive(_ sessions: [CodeCrossSessionInput], context: CodeCrossDeriveContext,
                into fields: inout [String: CodeDerivedFields])
    func sessionLeft(_ sessionID: String)
}

extension CodeCrossSessionDeriver {
    func sessionLeft(_ sessionID: String) {}
}

/// The order each feature's deriver takes (lower first), so a feature reads what the features it depends on wrote.
enum CodeDeriveOrder {
    /// Running and ETA: the work, background progress, the ETA and the estimate (Finished and Warnings read them).
    static let work = 100
    /// Results (the Finished card and the unread dot read them).
    static let results = 200
    /// Dashboards: the dashboard.
    static let dashboards = 300
    /// Warnings: failures in a row and silence (reads the pending tasks).
    static let stuck = 400
    /// Finished: the finished mark (reads the work and pending tasks).
    static let finished = 500
    /// Earlier replies' offers and their supersession.
    static let earlierOffers = 600

    /// Cross-session, Warnings: Same file.
    static let sameFile = 100
    /// Cross-session, Finished: the unread dot (needs every warning, Same file included, and every result and offer).
    static let unread = 200
}

/// Derivers for the composition root to hand to `CodeSessionsEngine.register(_:memory:)`. Each feature adds its own
/// as a computed `public static var` in its own folder, so every engine gets fresh deriver objects:
///
/// ```swift
/// public extension CodeDeriverSet {
///     /// The work, progress, ETA and estimate.
///     static var progress: CodeDeriverSet { CodeDeriverSet(perSession: [ProgressDeriver()]) }
/// }
/// // Composition root:
/// engine.register(.progress + .results + .dashboards + .warnings + .finished + .ready, memory: memory)
/// ```
public struct CodeDeriverSet: @unchecked Sendable {
    // The derivers are used only on the engine's queue (`@unchecked`: they are classes the queue serialises).
    let perSession: [any CodeSessionDeriver]
    let crossSession: [any CodeCrossSessionDeriver]

    init(perSession: [any CodeSessionDeriver] = [], crossSession: [any CodeCrossSessionDeriver] = []) {
        self.perSession = perSession
        self.crossSession = crossSession
    }

    /// No derivers: the snapshot's derived fields stay empty.
    public static var none: CodeDeriverSet { CodeDeriverSet() }

    /// Both sets' derivers (the engine runs them by `order`, ties in this order).
    public static func + (lhs: CodeDeriverSet, rhs: CodeDeriverSet) -> CodeDeriverSet {
        CodeDeriverSet(perSession: lhs.perSession + rhs.perSession, crossSession: lhs.crossSession + rhs.crossSession)
    }

    /// No derivers at all.
    public var isEmpty: Bool { perSession.isEmpty && crossSession.isEmpty }

    /// The per-session derivers by `order`, ties in registration order.
    var orderedPerSession: [any CodeSessionDeriver] {
        perSession.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
    }

    var orderedCrossSession: [any CodeCrossSessionDeriver] {
        crossSession.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
    }
}
