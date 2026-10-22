import CoreGraphics
import Foundation

/// The constants of Code monitors, in one place so every part reads the same numbers. Times are in seconds, sizes in
/// points, limits in counts or bytes, unless a name says otherwise (`…Minutes`, `…Hours`, `…Days`).
public enum CodeTuning {
    // MARK: Folder sizes and pages

    /// A bucket with this many monitors or more shows them medium (1-4 large, 5-9 medium).
    public static let densityMediumFrom = 5
    /// A bucket with this many monitors or more shows them small.
    public static let densitySmallFrom = 10
    /// Monitors per page at most, per size (4 / 9 / 12) and for slim rows; a narrower block pages sooner.
    public static let perPageLarge = 4
    public static let perPageMedium = 9
    public static let perPageSmall = 12
    public static let perPageRows = 8
    /// Rows a page, per size.
    public static let rowsPerPageLarge = 2
    public static let rowsPerPageMedium = 3
    public static let rowsPerPageSmall = 2
    public static let rowsPerPageRows = 8
    /// Monitor heights per size, and the slim row's height.
    public static let largeHeight: CGFloat = 219
    public static let mediumHeight: CGFloat = 150
    public static let smallHeight: CGFloat = 104
    public static let rowHeight: CGFloat = 36

    // MARK: Buckets

    public static let maxBuckets = 20
    /// Characters a bucket name may have, after trimming.
    public static let bucketNameMax = 32

    // MARK: Ready for you

    /// Cards shown before "4 more ▾", and on a block of `readyTallTileRows` rows or more.
    public static let readyVisibleCards = 3
    public static let readyVisibleCardsTall = 6
    public static let readyTallTileRows = 12
    public static let cardHeight: CGFloat = 60
    /// Items in the list at most (past that the oldest finished items go first, then the oldest Later rows).
    public static let readyMaxItems = 40
    /// Followed sessions at most.
    public static let followMax = 24
    /// Recent main-window sessions are followed for this many hours (0 switches them off; settings 0-48).
    public static let readyRecentHours: Double = 6
    /// Newer replies to turns of the user's or another session's an offer survives (a third drops it).
    public static let newerRepliesMax = 2
    /// Newer replies listed under "▸ Newer replies".
    public static let newerRepliesShown = 4
    /// An SSH session whose `lastActivityAt` is this much later than the offer's reply counts as moved on.
    public static let sshMidTurnSlack: TimeInterval = 10
    public static let dismissUndo: TimeInterval = 5
    public static let resultRowLife: TimeInterval = 10 * 60
    /// Buttons that open something count only this long after they appeared or moved.
    public static let openButtonArmDelay: TimeInterval = 0.8

    // MARK: Desk tags

    public static let tagRightInset: CGFloat = 24
    public static let tagPlaceCoalesce: TimeInterval = 0.016
    public static let tagShowAfterDrag: TimeInterval = 0.15

    // MARK: Running and ETA

    /// A work whose starting turn is older than this is replaced by the current turn.
    public static let workMaxAge: TimeInterval = 12 * 3600
    /// A background task without its notice is dropped after this long.
    public static let backgroundMaxAge: TimeInterval = 6 * 3600
    /// Pending background tasks kept per session (the oldest dropped).
    public static let backgroundMaxPending = 64
    /// A stated clock is placed at the first moment with that time at or after (statement time − this).
    public static let etaBeforeStatement: TimeInterval = 30 * 60
    /// An ETA more than this after its statement is ignored.
    public static let etaMaxAhead: TimeInterval = 12 * 3600
    /// A stated ETA is kept until this long after it.
    public static let etaKeepAfter: TimeInterval = 2 * 3600
    /// Characters after a label within which its value must start, and lines below a label line.
    public static let etaValueWindow = 40
    public static let etaLabelLines = 3
    /// Guards of the estimate: done ≥ 1, total ≥ 3, elapsed ≥ 3 min; over 240 min nothing is shown.
    public static let estimateMinDone = 1
    public static let estimateMinTotal = 3
    public static let estimateMinElapsed: TimeInterval = 3 * 60
    public static let estimateMax: TimeInterval = 240 * 60

    // MARK: Finished

    /// Work shorter than this gets no card and no sound (settings `finishedMinMinutes`).
    public static let finishedMinRun: TimeInterval = 3 * 60
    /// At start, work that finished within this long and has no record gets a silent item.
    public static let finishedSilentAtStart: TimeInterval = 2 * 3600
    /// "Looking at it": HID input within this long while the window was key in the frontmost app.
    public static let lookingInputWindow: TimeInterval = 60
    /// Finishes within this long make one chime and one phrase.
    public static let alertCoalesce: TimeInterval = 20
    public static let sayMinInterval: TimeInterval = 30
    /// The wake listener resumes this long after the synthesizer finished.
    public static let speechResumeDelay: TimeInterval = 0.5
    /// Away after this many minutes without input (settings `recapAfterMinutes`, 5-120).
    public static let recapAfterMinutes = 15
    public static let recapPollPresent: TimeInterval = 30
    public static let recapPollAway: TimeInterval = 2
    public static let recapLife: TimeInterval = 30 * 60

    // MARK: Results

    public static let maxResults = 6
    /// File candidates checked per work, and the time a session's file checks may take.
    public static let fileCandidatesMax = 6
    public static let fileCheckBudget: TimeInterval = 0.05
    /// Folders walked up from `cwd` looking for `.git`.
    public static let repoSearchDepth = 12

    // MARK: Warnings

    /// Failing Bash calls back to back that make "Looks stuck".
    public static let stuckRunLength = 4
    public static let stuckSilence: TimeInterval = 30 * 60
    public static let sameFileWindow: TimeInterval = 30 * 60
    /// OK on a Same file warning silences that pair and file this long.
    public static let okSilenceSameFile: TimeInterval = 2 * 3600

    // MARK: Dashboards

    /// The one-time scan stops after this many bytes or this much wall time; longer lines are skipped.
    public static let dashboardScanMax = 128 << 20
    public static let dashboardScanSeconds: TimeInterval = 60
    public static let dashboardLineMax = 1 << 20

    // MARK: Drag to park

    public static let dropArmDelay: TimeInterval = 0.25
    public static let dropPollHz = 30
    /// `WindowDropClaims` holds a claim at most this long after the mouse-up, and this long at all; 2 at once.
    public static let claimMaxHoldAfterMouseUp: TimeInterval = 3
    public static let claimMaxAge: TimeInterval = 30
    public static let claimsMax = 2

    // MARK: Files of the app's own

    /// `code-memory.json`: read at most 1 MB, written at most 768 KB.
    public static let memoryReadMax = 1 << 20
    public static let memoryWriteMax = 768 << 10
    /// Memory of a session without activity for this many days is dropped.
    public static let memoryPruneDays = 14
    /// `code-buckets.json` entries not seen for this many days are dropped.
    public static let bucketsPruneDays = 30

    // MARK: Limits of the derivers and the state files

    /// The derivers of one session may take this long per parse; slower runs are logged.
    public static let deriveBudget: TimeInterval = 0.010
    /// Turn digest: an assistant text is kept up to this many UTF-8 bytes; a tool result's head, a Bash command
    /// and a dashboard-builder prompt up to this many characters; `SendUserFile` lists up to this many files.
    public static let digestTextMax = 64 << 10
    public static let digestHeadMax = 4096
    public static let digestFilesMax = 16
    /// The digest holds every turn from the oldest of (the oldest turn whose offers can still run: the third-newest
    /// finished turn of the user's, another session's or unknown origin) and (the work's start), as far as the tail
    /// reaches, bounded by these: at most this many turns, strings of at most this many bytes in all (the tail's own
    /// limit), items per turn at most this many.
    public static let digestTurnsMax = 200
    public static let digestBytesMax = 2 << 20
    public static let digestItemsPerTurnMax = 4000
    /// `code-memory.json` per session: Ready keys, finished records, silenced warnings at most; sessions at most.
    public static let memoryReadyKeysMax = 64
    public static let memoryFinishedMax = 16
    public static let memorySilencedMax = 16
    public static let memorySessionsMax = 200
    /// Finished records live this long (then they are pruned); changes are written at most once per this interval.
    public static let finishedRecordLife: TimeInterval = 24 * 3600
    public static let memoryWriteInterval: TimeInterval = 1
    /// `settings.json`, `code-memory.json` and `code-buckets.json` nest at most this deep.
    public static let stateFileNestingMax = 16
    /// `settings.json` and `code-buckets.json` are read up to this size.
    public static let settingsReadMax = 256 << 10
    /// `recentSessions(within:)` knows at most this many hours back (`readyRecentHours` is 0-48).
    public static let readyRecentHoursMax: Double = 48
}
