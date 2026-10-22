import Foundation

// The derived values a session snapshot carries: progress, ETA, results, warnings, the dashboard and the finished mark.
// The data side's derivers fill them (one deriver each); the block, the Ready list and desk tags only read them.
// Strings that came from a session (paths, file names, headlines) are session text: shown only through the plain-text
// renderer, never logged. Many parts read these values: change them only additively.

/// How far a session's work is: its background tasks (agents, workflows), a workflow's agents, or its todos.
public struct CodeProgress: Sendable, Equatable {
    /// Where the numbers come from, the first that applies.
    public enum Source: String, Sendable, Equatable {
        /// `Agent` and `Workflow` launches (`async_launched`) against their `<task-notification>`s.
        case backgroundTasks
        /// A local workflow's live agents (not built yet: it waits until it is known whether a local workflow's run
        /// file is rewritten during a run).
        case workflowAgents
        /// The turn's replayed plan.
        case todos
    }

    /// The noun of the words: "4 of 6 agents done", "1 of 2 workflows done", "4 of 6 tasks done" (a mix), "4/7 todos".
    public enum Unit: String, Sendable, Equatable { case agents, workflows, tasks, todos }

    /// Where the numbers come from, and the noun of their words.
    public var source: Source
    public var unit: Unit
    /// Tasks (or todos) done, and all of them counted.
    public var done: Int
    public var total: Int
    /// When the counted work started: the first launch of the pending tasks, or the turn's first plan call (the
    /// estimate's elapsed time).
    public var since: Date?
    /// Tasks are pending while the turn itself has finished: "Background · 4 of 6 agents done". Such a session
    /// counts as running in the summary line; its state word is unchanged.
    public var pendingBetweenTurns: Bool
    /// The latest workflow notice's `agents_done` of `agent_count`, for the peek.
    public var workflowAgentsDone: Int?
    public var workflowAgentCount: Int?
    /// Background tasks dropped because their notice never came (after `backgroundMaxAge`): the finish detector gives
    /// such work a silent Finished item, "a background task never reported back".
    public var expiredTasks: Int

    /// Progress from its parts.
    public init(source: Source, unit: Unit, done: Int, total: Int, since: Date? = nil, pendingBetweenTurns: Bool = false,
                workflowAgentsDone: Int? = nil, workflowAgentCount: Int? = nil, expiredTasks: Int = 0) {
        self.source = source; self.unit = unit; self.done = done; self.total = total; self.since = since
        self.pendingBetweenTurns = pendingBetweenTurns
        self.workflowAgentsDone = workflowAgentsDone; self.workflowAgentCount = workflowAgentCount
        self.expiredTasks = expiredTasks
    }

    /// Tasks not done yet.
    public var pending: Int { max(0, total - done) }
    /// done / total in 0...1 (the bar); 0 without a total.
    public var fraction: Double { total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0 }
}

/// When the work will be done: an ETA the session stated, or the app's estimate.
public struct CodeETA: Sendable, Equatable {
    /// Stated by the session, or estimated by the app
    public enum Kind: String, Sendable, Equatable {
        /// Read from the work's assistant text ("ETA: 23:24", a table column, a label line).
        case stated
        /// The app's formula over the progress: never late, it moves.
        case estimate
    }

    /// Stated or estimate.
    public var kind: Kind
    /// The moment, absolute. Shown in this Mac's local time ("ETA 23:24").
    public var at: Date
    /// Stated only: the IANA zone the clock was read in ("UTC", "Europe/Lisbon"), for "(stated as 22:24 UTC)".
    public var statedZone: String?
    /// Stated only: when it was stated (the entry's timestamp) and in which reply.
    public var statedAt: Date?
    /// Stated only: the reply that stated it.
    public var replyUUID: String?
    /// Estimate only: minutes left when it was computed.
    public var minutesLeft: Int?
    /// A stated ETA that passed while the session still works: orange, "passed 6 min ago".
    public var isLate: Bool
    /// An estimate computed beside a stated ETA, for the peek's "· estimate ≈ 23:31"; nil otherwise.
    public var estimateAt: Date?

    /// An ETA from its parts.
    public init(kind: Kind, at: Date, statedZone: String? = nil, statedAt: Date? = nil, replyUUID: String? = nil,
                minutesLeft: Int? = nil, isLate: Bool = false, estimateAt: Date? = nil) {
        self.kind = kind; self.at = at; self.statedZone = statedZone; self.statedAt = statedAt
        self.replyUUID = replyUUID; self.minutesLeft = minutesLeft; self.isLate = isLate; self.estimateAt = estimateAt
    }
}

/// Something a session produced or handed over: a link to open, a file on this Mac, a file on the server, or a line
/// only for the peek. Buttons open only on an armed click; local files are checked again at the click.
public struct CodeResult: Sendable, Equatable, Identifiable {
    /// What the result is, and so which button it gets.
    public enum Kind: String, Sendable, Equatable {
        /// "↗ Open preview · localhost:5173": a local session's preview, opened at its root.
        case preview
        /// "Preview on buildbox: localhost:5173": an SSH session's preview; Copy link only.
        case serverPreview
        /// "↗ Open artifact": a claude.ai artifact.
        case artifact
        /// "▤ Open <file>": a document on this Mac, in its default app.
        case document
        /// "▤ Preview <file>" and "Show in Finder": a web document, never in the browser (docs/THREAT_MODEL.md).
        case webDocument
        /// "▤ Show <file> in Finder": anything else on this Mac; never opened.
        case otherFile
        /// "⤓ Fetch <file>…": a file on the server, through the Fetch file sheet.
        case serverFile
        /// Peek text only: a path the final reply names that the work neither handed over nor wrote.
        case mentionedPath
        /// The peek's "Earlier artifacts" (published before the work, at most 5).
        case earlierArtifact
    }

    /// Where it was found (in this order of preference).
    public enum Origin: String, Sendable, Equatable {
        case publishedArtifact, artifactTool, handedOver, written, replyLink, replyText
    }

    /// What it is and where it was found.
    public var kind: Kind
    public var origin: Origin
    /// Links: the address to open, rebuilt from its parsed parts (never the raw text).
    public var url: URL?
    /// Files: the path (this Mac: the resolved path; server: as written).
    public var path: String?
    /// What the button names: "localhost:5173", a file name (session text, through the renderer).
    public var label: String
    /// Files on this Mac: device and inode when the result was made; the click checks them again.
    public var device: UInt64?
    /// See `device`.
    public var inode: UInt64?
    /// Server files: the `SendUserFile`, Write or Edit tool_use it came from (the Fetch sheet's click-time check,
    /// `FetchFileRequest.sourceToolUseID`).
    public var toolUseID: String?
    /// When it was produced (the artifact's `updatedAt`, the tool call, the reply).
    public var at: Date?
    /// Host words for the peek, such as "not checked: network path".
    public var note: String?

    /// A result from its parts.
    public init(kind: Kind, origin: Origin, url: URL? = nil, path: String? = nil, label: String, device: UInt64? = nil,
                inode: UInt64? = nil, toolUseID: String? = nil, at: Date? = nil, note: String? = nil) {
        self.kind = kind; self.origin = origin; self.url = url; self.path = path; self.label = label
        self.device = device; self.inode = inode; self.toolUseID = toolUseID; self.at = at; self.note = note
    }

    /// The same address or path counts once.
    public var id: String { "\(kind.rawValue):" + (url?.absoluteString ?? path ?? label) }
}

/// A warning on a session: "Looks stuck" or "Same file". It only changes displays: no glow, no chime, nothing
/// sent to the session. OK silences it (`CodeMemoryStore` key `silenced`).
public struct CodeWarning: Sendable, Equatable, Identifiable {
    /// The rule; the raw value is the rule word of `warn:<session id>:<rule>` keys and `silenced` records.
    public enum Kind: String, Sendable, Equatable {
        /// `CodeTuning.stuckRunLength` failing Bash calls back to back.
        case failedInARow = "failed_in_a_row"
        /// Quiet for `CodeTuning.stuckSilence` with no tool waiting.
        case silence
        /// Two working sessions editing one file of one repository.
        case sameFile = "same_file"
    }

    /// Which rule fired.
    public var kind: Kind
    /// When the condition began.
    public var since: Date
    /// failedInARow: how many in a row, and the last failure's exit code (the peek shows it).
    public var failures: Int?
    /// See `failures`.
    public var lastExitCode: Int?
    /// sameFile: the other session, its headline (session text) and the path relative to the repository's toplevel, at
    /// most its last 2 parts ("src/checkout.tsx").
    public var otherSessionID: String?
    /// See `otherSessionID`.
    public var otherHeadline: String?
    /// See `otherSessionID`.
    public var path: String?

    /// A warning from its parts.
    public init(kind: Kind, since: Date, failures: Int? = nil, lastExitCode: Int? = nil, otherSessionID: String? = nil,
                otherHeadline: String? = nil, path: String? = nil) {
        self.kind = kind; self.since = since; self.failures = failures; self.lastExitCode = lastExitCode
        self.otherSessionID = otherSessionID; self.otherHeadline = otherHeadline; self.path = path
    }

    /// One warning per rule, and per other session for Same file.
    public var id: String { otherSessionID.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }
}

/// A session's dashboard on one of the configured sites (`CodeDashboardSites`), kept for the session's life. The app
/// never fetches it.
public struct CodeDashboard: Sendable, Equatable {
    /// `^[a-z0-9]+(?:-[a-z0-9]+)*$`, 1-64 characters, and the site's own pattern.
    public let handle: String
    /// The site the link was on.
    public let site: CodeDashboardSite
    /// When the link was first seen.
    public var firstSeen: Date
    /// The latest `dashboard-builder` Agent call ("updated 23:14"), never earlier than `firstSeen`.
    public var lastBuilderCallAt: Date?

    /// Nil when `handle` fails the site's grammar.
    public init?(handle: String, site: CodeDashboardSite, firstSeen: Date, lastBuilderCallAt: Date? = nil) {
        guard site.isValidHandle(handle) else { return nil }
        self.handle = handle
        self.site = site
        self.firstSeen = firstSeen
        self.lastBuilderCallAt = lastBuilderCallAt.map { max($0, firstSeen) }
    }

    /// `https://<host><pathPrefix><handle>/`, built from the checked parts.
    public var url: URL? { site.url(handle: handle) }

    /// Lowercase ASCII letters and digits in groups joined by single hyphens, 1-64 characters.
    public static func isValidHandle(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count) else { return false }
        var previousWasHyphen = true
        for byte in text.utf8 {
            let isWordByte = (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
            if byte == 0x2D {
                if previousWasHyphen { return false }
                previousWasHyphen = true
            } else if isWordByte {
                previousWasHyphen = false
            } else {
                return false
            }
        }
        return !previousWasHyphen
    }
}

/// A piece of work that finished, once per final reply; its record lives in `CodeMemoryStore` (key
/// `finished`), so a restart neither repeats nor loses it.
public struct CodeFinishedMark: Sendable, Equatable {
    /// The final reply's uuid (`fin:<session id>:<reply uuid>`).
    public var replyUUID: String
    /// The reply's last assistant entry's time, else when the app saw `end_turn`.
    public var at: Date
    /// `at` − the start of the work.
    public var ranSeconds: TimeInterval
    /// The Finished item stands: not OK'd, no new message from the user, under 24 hours.
    public var isOpen: Bool
    /// The work makes a Finished item (ran at least `finishedMinMinutes`, ended in Review ready, Done or Done · no
    /// summary); without one only the unread dot marks it.
    public var hasItem: Bool
    /// No chime and no voice: work that ended by expiry, or that finished before the app started.
    public var silent: Bool
    /// Ended because a background task never reported back (dropped after 6 h): "a background task never reported back".
    public var expired: Bool
    /// The ETA the work had stated, for "· ETA was 23:24".
    public var etaWas: Date?

    /// A finished mark from its parts.
    public init(replyUUID: String, at: Date, ranSeconds: TimeInterval, isOpen: Bool = true, hasItem: Bool = true,
                silent: Bool = false, expired: Bool = false, etaWas: Date? = nil) {
        self.replyUUID = replyUUID; self.at = at; self.ranSeconds = ranSeconds; self.isOpen = isOpen
        self.hasItem = hasItem; self.silent = silent; self.expired = expired; self.etaWas = etaWas
    }
}
