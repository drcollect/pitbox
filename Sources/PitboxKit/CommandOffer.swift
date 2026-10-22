import Foundation
import CoreGraphics

// Code monitors: command offers. The shared contract between PitboxSessions (finds offers in a session's final
// reply), the scanner and classifier in this package and PitboxConsole (the sheet, command tabs, Type into terminal,
// Fetch file). Plain data, no authority: only the native sheet in PitboxConsole can start a run, after the user's
// click. Never log the text, paths, hosts, titles or replies held here (docs/THREAT_MODEL.md). Change only additively.

// MARK: Session facts

/// Where the turn that produced an offer came from (`turnOrigin` on the transcript's user entry).
public enum CommandTurnOrigin: String, Sendable, Equatable {
    /// The user typed the message that started the turn.
    case human
    /// A background task's notification started the turn (red line R20).
    case taskNotification
    /// Another session started the turn (red line R20).
    case peer
    /// The transcript did not say.
    case unknown
}

/// What the classifier and the sheet know about the session an offer came from. Built by PitboxSessions from the
/// session file and the transcript, never from the reply's own words.
public struct CommandSessionFacts: Sendable, Equatable {
    /// Local only when the session file says so positively; SSH when it has `sshConfig.sshHost` and an `ssh-` mirror;
    /// unknown otherwise, which makes every offer Unclear.
    public enum Place: String, Sendable, Equatable { case local, ssh, unknown }

    public var place: Place
    /// The SSH alias: an exact `Host` token of `~/.ssh/config` matching `^[A-Za-z0-9._-]{1,64}$`, no leading `-`. Nil for
    /// local sessions and when the alias failed that check.
    public var sshAlias: String?
    /// The HostName `ssh -G <alias>` printed, or nil when unknown (a `Match` block, or not looked up).
    public var resolvedHostName: String?
    /// Other names of the server, only from the user's settings file (`serverNames`).
    public var serverNames: [String]
    /// Every exact `Host` token in `~/.ssh/config` and its includes (for R17's look-alike check).
    public var knownSSHHosts: [String]
    /// The session's working folder on the server (SSH sessions), a server path.
    public var remoteCwd: String?
    /// The session's working folder on this Mac (local sessions), when it exists.
    public var localCwd: String?
    /// The session's working folder when the session works on this Mac (its file names no SSH configuration) in a folder
    /// on a refused root: an external or network volume (`/Volumes`, `/net`, `/Network`, an automount point, a network
    /// filesystem from the mount table; docs/THREAT_MODEL.md, T33). Never looked up. Such a session's place is unknown,
    /// and the sheet neither runs nor types its commands (Copy only). Nil otherwise, and always nil for SSH sessions.
    public var refusedLocalCwd: String?
    /// The working folder the session file names when it names no SSH configuration (a local or unknown place), as
    /// written; it exists here only when the place is local. The sheet walks it under the network check when it opens and
    /// again at the click (local lookups only, nothing at or below a refused root), so a folder that became a refused root
    /// after the offer was made counts as one (`refusedLocalCwd`). Nil for SSH sessions.
    public var localWorkFolder: String?
    /// The user's home folder, e.g. `/Users/alex`.
    public var homeDirectory: String
    /// The user's user name, e.g. `alex`.
    public var userName: String
    /// Who started the turn.
    public var turnOrigin: CommandTurnOrigin
    /// The turn used WebFetch, WebSearch, a browser tool or computer use (the first note on the sheet).
    public var turnReadWeb: Bool

    public init(place: Place, sshAlias: String? = nil, resolvedHostName: String? = nil, serverNames: [String] = [],
                knownSSHHosts: [String] = [], remoteCwd: String? = nil, localCwd: String? = nil,
                refusedLocalCwd: String? = nil, localWorkFolder: String? = nil, homeDirectory: String, userName: String,
                turnOrigin: CommandTurnOrigin = .unknown, turnReadWeb: Bool = false) {
        self.place = place; self.sshAlias = sshAlias; self.resolvedHostName = resolvedHostName
        self.serverNames = serverNames; self.knownSSHHosts = knownSSHHosts; self.remoteCwd = remoteCwd
        self.localCwd = localCwd; self.refusedLocalCwd = refusedLocalCwd; self.localWorkFolder = localWorkFolder
        self.homeDirectory = homeDirectory; self.userName = userName
        self.turnOrigin = turnOrigin; self.turnReadWeb = turnReadWeb
    }
}

/// What `lstat` found at a path (R21, R10). Looked up by the caller, never by the classifier (it stays pure).
public enum CommandPathFact: Sendable, Equatable {
    case missing
    case file
    case directory
    /// A symbolic link and what it points to (`readlink`, nothing is read).
    case link(target: String)
}

/// The classifier's input besides the text: the session facts plus the reply's claims.
public struct CommandContext: Sendable, Equatable {
    public var facts: CommandSessionFacts
    /// The two lines of reply text just before the block: a claim, shown in quotes, never deciding.
    public var caption: String?
    /// Programs found on the clean PATH, used only to read untagged blocks (a file lookup, nothing is run). Nil
    /// when the caller did not look; untagged blocks are then not offered.
    public var programsOnCleanPath: Set<String>?
    /// The folder the command would start in, to resolve relative targets. Nil: the home folder.
    public var runFolder: String?
    /// Facts about absolute local paths, looked up by the caller (the sheet) for the paths a first assessment listed in
    /// `CommandAssessment.localTargets`. Empty: R21 is not decided (write targets stay "Writes <path>" notes) and
    /// key-generating `ssh-keygen` counts as R10. Two passes: assess, `lstat` the targets, assess again with the facts.
    public var pathFacts: [String: CommandPathFact]

    public init(facts: CommandSessionFacts, caption: String? = nil, programsOnCleanPath: Set<String>? = nil,
                runFolder: String? = nil, pathFacts: [String: CommandPathFact] = [:]) {
        self.facts = facts; self.caption = caption; self.programsOnCleanPath = programsOnCleanPath
        self.runFolder = runFolder; self.pathFacts = pathFacts
    }
}

// MARK: Assessment

/// Where a command's effects land.
public enum CommandMachine: Sendable, Equatable {
    /// Starts on this Mac and changes this Mac (a transfer from the session's server included).
    case thisMac
    /// Meant to be typed on the session's server: Copy and "Open a terminal on <server>" only.
    case server
    /// Sends a command to another machine (`ssh <host> '…'` and its relatives). Never run.
    case remote(host: String)
    /// Facts are missing or disagree; the user picks This Mac or The server on the sheet.
    case unclear
}

/// One red line (R1-R22) or block reason (B1-B6).
public enum CommandRule: String, CaseIterable, Sendable, Equatable {
    case r1 = "R1", r2 = "R2", r3 = "R3", r4 = "R4", r5 = "R5", r6 = "R6", r7 = "R7", r8 = "R8", r9 = "R9", r10 = "R10"
    case r11 = "R11", r12 = "R12", r13 = "R13", r14 = "R14", r15 = "R15", r16 = "R16", r17 = "R17", r18 = "R18"
    case r19 = "R19", r20 = "R20", r21 = "R21"
    case b1 = "B1", b2 = "B2", b3 = "B3", b4 = "B4", b5 = "B5", b6 = "B6"
    /// Something followed this command's reply: a message of the user's, a reply, or background updates.
    /// Never produced by the classifier: the session side and the sheet add it from `CommandOffer.supersession` or a
    /// `superseded` freshness answer.
    case r22 = "R22"

    /// B1-B6 block Run and Type; R1-R21 need a tick each.
    public var blocks: Bool { rawValue.hasPrefix("B") }
}

/// One red line or block reason found in the text, with where it is, so the sheet can tick and underline it.
public struct CommandFlag: Sendable, Equatable {
    public var rule: CommandRule
    /// Pitbox's words on the sheet, e.g. "Deletes files and folders; not to the Trash: build/".
    public var words: String
    /// 1-based line of the offer text.
    public var line: Int
    /// UTF-16 offsets into the offer text (NSString ranges), for underlining. Empty when the flag has no span (R20).
    public var utf16Range: Range<Int>
    /// Index of the segment it belongs to, nil for whole-text flags (B1, B4, R15, R20).
    public var segment: Int?

    public init(rule: CommandRule, words: String, line: Int, utf16Range: Range<Int>, segment: Int? = nil) {
        self.rule = rule; self.words = words; self.line = line; self.utf16Range = utf16Range; self.segment = segment
    }
}

/// A grey note: informational, never changes the button.
public struct CommandNote: Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable {
        case readWeb, connects, writes, deletes, runsSeveral, asksValue, asksSecret, storesKeychainItem
        case readsKeychainItem, usesSSHAgent, notQuarantined, homebrew, keepsRunning, opens, usesVariable, usesGlob
        case fetchShape, untaggedBlock, nonASCII, cleanShell, replyClaim
    }
    public var kind: Kind
    /// The note in Pitbox's words, e.g. "Connects to buildbox".
    public var words: String

    public init(kind: Kind, words: String) { self.kind = kind; self.words = words }
}

/// One command of the text: lists, pipes and newlines split segments.
public struct CommandSegment: Sendable, Equatable {
    /// The program's base name after wrappers and assignments were looked through (`/bin/rm`, `\rm`, `"rm"` → `rm`).
    /// Nil for a segment with no program (a bare assignment, a lone redirection).
    public var program: String?
    /// 1-based line where the segment starts.
    public var line: Int
    public var utf16Range: Range<Int>
    /// Where this segment's effects land.
    public var machine: CommandMachine

    public init(program: String?, line: Int, utf16Range: Range<Int>, machine: CommandMachine) {
        self.program = program; self.line = line; self.utf16Range = utf16Range; self.machine = machine
    }
}

/// A recognised Fetch file shape: one file from the session's server into Downloads.
public struct FetchFileRequest: Sendable, Equatable {
    /// The session's SSH alias Pitbox connects through (never a host from the reply).
    public var alias: String
    /// The user the reply named, offered on the sheet as a visible choice; nil when it named none.
    public var replyUser: String?
    /// The remote path exactly as unquoted from the reply (one file; checked by the Fetch file rules).
    public var remotePath: String
    /// The file name the reply gave after `~/Downloads/`, or nil for the remote base name.
    public var destinationName: String?
    /// For a result fetch (a file a session handed over or wrote on the server): the `SendUserFile`, Write or Edit
    /// tool_use the file came from; nil for a fenced block in the reply.
    public var sourceToolUseID: String?

    public init(alias: String, replyUser: String?, remotePath: String, destinationName: String?,
                sourceToolUseID: String? = nil) {
        self.alias = alias; self.replyUser = replyUser; self.remotePath = remotePath; self.destinationName = destinationName
        self.sourceToolUseID = sourceToolUseID
    }
}

/// What `CommandClassifier.assess(text:context:)` returns: one class, the flags, the notes and the segments.
/// The worst segment decides the class.
public struct CommandAssessment: Sendable, Equatable {
    /// The classes. When several apply, the most restrictive wins (docs/SHELL_LANGUAGE.md §4.3).
    public enum Class: String, CaseIterable, Sendable {
        case notFlagged, risky, needsEditing, otherMachine, forServer, unclearMachine, fetchFile, partlyRead, blocked
    }

    public var commandClass: Class
    /// Red lines and block reasons, in text order.
    public var flags: [CommandFlag]
    public var notes: [CommandNote]
    public var segments: [CommandSegment]
    /// The whole offer's machine.
    public var machine: CommandMachine
    /// The machine result and its reason in Pitbox's words: "For this Mac: it copies from buildbox."
    public var machineReason: String
    /// The reply's own claim about the machine, shown as "The reply says: “on your Mac”". Never decides.
    public var replyClaim: String?
    /// Set when the class is `fetchFile`.
    public var fetch: FetchFileRequest?
    /// The placeholder that makes it Needs editing, e.g. "<server>".
    public var placeholder: String?
    /// For the sheet: "3 lines · 4 commands".
    public var lineCount: Int
    public var commandCount: Int
    /// Absolute local paths whose facts decide R21 or R10: redirection and copy targets (`~` and relative paths resolved
    /// with the facts' home folder and the context's `runFolder`), and `~/.ssh/id_ed25519` / `~/.ssh/id_rsa` when
    /// `ssh-keygen` appears. The caller `lstat`s them and assesses again with `pathFacts` (never by the classifier).
    public var localTargets: [String] = []

    public init(commandClass: Class, flags: [CommandFlag] = [], notes: [CommandNote] = [], segments: [CommandSegment] = [],
                machine: CommandMachine, machineReason: String, replyClaim: String? = nil,
                fetch: FetchFileRequest? = nil, placeholder: String? = nil, lineCount: Int, commandCount: Int) {
        self.commandClass = commandClass; self.flags = flags; self.notes = notes; self.segments = segments
        self.machine = machine; self.machineReason = machineReason; self.replyClaim = replyClaim; self.fetch = fetch
        self.placeholder = placeholder; self.lineCount = lineCount; self.commandCount = commandCount
    }

    /// The red lines that need a tick (R1-R21).
    public var redLines: [CommandFlag] { flags.filter { !$0.rule.blocks } }
    /// The first block reason, if any.
    public var blockReason: CommandRule? { flags.first { $0.rule.blocks }?.rule }
}

// MARK: Offers

/// One shell block of a session's final reply, offered to the user. Built by PitboxSessions.
public struct CommandOffer: Sendable, Equatable, Identifiable {
    public struct ID: Hashable, Sendable, CustomStringConvertible {
        /// The local index of the session in this run of Pitbox (`#3` in logs), never a session id.
        public var sessionIndex: Int
        /// The uuid of the reply's last assistant entry.
        public var replyUUID: String
        /// 1-based number of the block in the reply.
        public var number: Int

        public init(sessionIndex: Int, replyUUID: String, number: Int) {
            self.sessionIndex = sessionIndex; self.replyUUID = replyUUID; self.number = number
        }

        /// `#3.1`: safe to log.
        public var description: String { "#\(sessionIndex).\(number)" }
    }

    /// How the block was marked in the reply.
    public enum BlockKind: Sendable, Equatable {
        /// A tagged block (`bash`, `sh`, `zsh`, `shell`, `terminal`, …) with the tag as written, lowercased.
        case tagged(String)
        /// `console`, `shell-session` or a tagged block with `$ ` / `% ` prompts: output lines are shown, not run.
        case promptStyle
        /// No tag, read as a command because every line starts with a known word ("untagged block" note).
        case untagged
    }

    /// One line as the sheet shows it. Command lines together, in order, are `text`.
    public struct DisplayLine: Sendable, Equatable {
        public enum Role: String, Sendable { case command, output, comment }
        public var role: Role
        public var text: String
        public init(role: Role, text: String) { self.role = role; self.text = text }
    }

    /// Where the offer came from. Session text (headline, nickname, asked, caption, reply) is untrusted: the sheet
    /// shows it in quotes through the plain-text renderer.
    public struct Source: Sendable, Equatable {
        /// The Claude copy's letter and name ("A", "A Work"), nil when only one copy runs.
        public var profileLetter: String?
        public var profileName: String?
        /// The session id (`local_<id>`), for joining back to the monitor. Never logged.
        public var sessionID: String
        public var headline: String
        /// The worktree nickname, e.g. "calm otter".
        public var nickname: String?
        /// The first two lines of the user message that started the turn; nil when no message of the user's did.
        public var youAsked: String?
        /// The reply's last assistant entry time.
        public var replyTime: Date

        public init(profileLetter: String? = nil, profileName: String? = nil, sessionID: String, headline: String,
                    nickname: String? = nil, youAsked: String? = nil, replyTime: Date) {
            self.profileLetter = profileLetter; self.profileName = profileName; self.sessionID = sessionID
            self.headline = headline; self.nickname = nickname; self.youAsked = youAsked; self.replyTime = replyTime
        }
    }

    /// The folder a run would start in, as a path; PitboxConsole binds it by descriptor when the sheet opens.
    public struct Folder: Sendable, Equatable {
        public var path: String
        /// True when the session's own folder does not exist here and the home folder is used instead.
        public var isHomeFallback: Bool
        public init(path: String, isHomeFallback: Bool) { self.path = path; self.isHomeFallback = isHomeFallback }
    }

    public var id: ID
    /// The exact bytes that would run: the command lines of the block, joined with "\n". Never changed afterwards.
    public var text: String
    /// How many offers the reply has (for "Command 1 of 3"), at most 8 are offered.
    public var total: Int
    public var blockKind: BlockKind
    /// Every line of the block as shown, command, output and comment lines.
    public var displayLines: [DisplayLine]
    /// The two lines of reply text before the block: a claim.
    public var caption: String?
    public var source: Source
    /// False when the tail did not hold the whole turn or the session file failed its checks: Copy only.
    public var replyReadCompletely: Bool
    public var folder: Folder
    public var context: CommandContext
    /// The whole final reply as plain text, for the sheet's "The whole reply" disclosure.
    public var replyText: String
    /// Set when anything followed this offer's reply: the offer stays runnable behind R22.
    public var supersession: Supersession?

    /// Superseded = a user entry that is not a tool_result, or a final reply, came after the offer's reply, which is
    /// itself still there unchanged. Every form needs R22's tick. The command text is unchanged; what it runs against
    /// may not be, so the sheet shows what happened since in Pitbox's words.
    public struct Supersession: Sendable, Equatable {
        /// One final reply that came after the offer's reply.
        public struct NewerReply: Sendable, Equatable {
            public var at: Date
            /// Who started that reply's turn ("started by a background task").
            public var origin: CommandTurnOrigin
            /// Its first 6 lines: session text, quoted through the plain-text renderer, never vouching for anything.
            public var head: String
            public init(at: Date, origin: CommandTurnOrigin, head: String) {
                self.at = at; self.origin = origin; self.head = head
            }
        }

        /// Finished replies to turns that the user or another session started after this one: 0...2 (a third drops the
        /// offer). 0: a newer turn started and has not finished (`unansweredMessageHead` is set when it was the user's
        /// message; a background or peer turn, or an SSH session whose mirror shows nothing newer yet, has none).
        public var newerReplies: Int
        /// Finished replies to background-task notices since: any number, they never drop the offer.
        public var newerBackgroundUpdates: Int
        /// When the newest message or reply after the offer's reply was written; for an SSH session whose mirror shows
        /// nothing newer yet, the session file's `lastActivityAt`.
        public var latestAt: Date
        /// The newer replies, oldest first: every reply to a turn of the user's or another session's, plus the 2 latest
        /// background ones (at most 4).
        public var replies: [NewerReply]
        /// The first 2 lines of the user's newest message when the session has not finished replying to it yet, else nil.
        public var unansweredMessageHead: String?
        /// The session is working on a newer turn right now.
        public var sessionIsWorking: Bool
        /// Host facts about the turns since the offer's reply, from their tool calls: web pages read (WebFetch,
        /// WebSearch, a browser tool, computer use), files edited or written (Edit, Write, NotebookEdit; names only, at
        /// most 8, with the full count), background tasks that finished.
        public var readWebSince: Bool
        public var filesChangedSince: [String]
        public var filesChangedCount: Int
        public var backgroundTasksFinishedSince: Int

        public init(newerReplies: Int, newerBackgroundUpdates: Int = 0, latestAt: Date, replies: [NewerReply] = [],
                    unansweredMessageHead: String? = nil, sessionIsWorking: Bool, readWebSince: Bool = false,
                    filesChangedSince: [String] = [], filesChangedCount: Int = 0, backgroundTasksFinishedSince: Int = 0) {
            self.newerReplies = newerReplies; self.newerBackgroundUpdates = newerBackgroundUpdates
            self.latestAt = latestAt; self.replies = replies; self.unansweredMessageHead = unansweredMessageHead
            self.sessionIsWorking = sessionIsWorking; self.readWebSince = readWebSince
            self.filesChangedSince = filesChangedSince; self.filesChangedCount = filesChangedCount
            self.backgroundTasksFinishedSince = backgroundTasksFinishedSince
        }
    }

    public init(id: ID, text: String, total: Int, blockKind: BlockKind, displayLines: [DisplayLine], caption: String?,
                source: Source, replyReadCompletely: Bool, folder: Folder, context: CommandContext, replyText: String,
                supersession: Supersession? = nil) {
        self.id = id; self.text = text; self.total = total; self.blockKind = blockKind; self.displayLines = displayLines
        self.caption = caption; self.source = source; self.replyReadCompletely = replyReadCompletely
        self.folder = folder; self.context = context; self.replyText = replyText; self.supersession = supersession
    }

    /// Size limits for running; a longer block is "too long to review here" (Copy only, B4).
    public static let maxLines = 40
    public static let maxCharacters = 4_000
    public static let maxLineCharacters = 500
    /// At most this many offers per reply.
    public static let maxOffersPerReply = 8
    /// Offers go stale after this long at the latest.
    public static let maxAge: TimeInterval = 24 * 3600
}

// MARK: Running

/// What one approval covers, frozen when the sheet opens. Built by the sheet when it opens, consumed once by the
/// command tab. Its folder is bound by descriptor inside PitboxConsole; here it is only identified.
public struct CommandExecutionDescriptor: Sendable, Equatable {
    public enum Kind: String, Sendable { case run, typeIntoTerminal }
    /// The clean shell (default) or the user's usual login shell.
    public enum Shell: String, Sendable { case clean, login }

    public var offerID: CommandOffer.ID
    public var kind: Kind
    public var text: String
    public var shell: Shell
    /// Always `/bin/zsh`: offers are classified for, and run by, one shell.
    public var shellPath: String
    /// The options before the text, e.g. `-f -i -o interactivecomments -o nobanghist -c`.
    public var shellArguments: [String]
    /// The fixed PATH, `extraPath` included.
    public var path: String
    /// The names of the environment variables passed (values are taken at spawn time from the allowlist).
    public var environmentNames: [String]
    /// The folder as the sheet showed it, with its device and inode at opening.
    public var folderPath: String
    public var folderDevice: UInt64
    public var folderInode: UInt64
    /// Must be `.thisMac` for `run` and `typeIntoTerminal`: nothing judged for the server or sent to another machine
    /// runs.
    public var machine: CommandMachine

    public init(offerID: CommandOffer.ID, kind: Kind, text: String, shell: Shell, shellPath: String = "/bin/zsh",
                shellArguments: [String], path: String, environmentNames: [String], folderPath: String,
                folderDevice: UInt64, folderInode: UInt64, machine: CommandMachine) {
        self.offerID = offerID; self.kind = kind; self.text = text; self.shell = shell; self.shellPath = shellPath
        self.shellArguments = shellArguments; self.path = path; self.environmentNames = environmentNames
        self.folderPath = folderPath; self.folderDevice = folderDevice; self.folderInode = folderInode
        self.machine = machine
    }

    /// The fixed PATH of the clean shell, before `extraPath`.
    public static let cleanPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    /// The clean shell's options for Run, before `-c <text>`.
    public static let cleanRunArguments = ["-f", "-i", "-o", "interactivecomments", "-o", "nobanghist"]
    /// The clean interactive shell for Type into terminal.
    public static let cleanTypeArguments = ["-f", "-i", "-o", "interactivecomments", "-o", "nobanghist"]
}

/// How a Fetch file ended.
public enum FetchFileOutcome: Sendable, Equatable {
    /// Saved as `fileName` in Downloads (`bytes` long).
    case saved(fileName: String, bytes: Int64)
    /// Not saved; the reason in Pitbox's words ("no such file on buildbox").
    case failed(reason: String)
    case cancelled
}

/// Whether an offer still belongs to the session's latest reply, checked again at the click.
public enum CommandOfferFreshness: Sendable, Equatable {
    /// How long the click-time check may take before it counts as `unknown`.
    public static let checkTimeout: TimeInterval = 0.3

    case fresh
    /// The offer's reply is still there unchanged, but a message or a reply came after it: Run, Type and Fetch need
    /// R22's tick, with the facts found at the click. A sheet that does not handle it treats it like `stale`.
    case superseded(CommandOffer.Supersession)
    /// Gone for good: a third newer reply to a human or peer turn, the session no longer followed, the block gone or
    /// changed, a duplicated uuid, a replaced or cut transcript, an archived session, 24 hours.
    case stale
    /// The files could not be read in time ("couldn't check the session; try again"). Starts nothing.
    case unknown
}

/// What the sheet reports back to the block. The block turns these into the offer line ("✓ exit 0 · 3 s").
public enum CommandOfferEvent: Sendable, Equatable {
    case copied
    /// The text was typed into a new clean shell tab, not run.
    case typed
    case started(runID: UUID)
    /// The shell ended: its exit status and how long it ran.
    case finished(runID: UUID, exitStatus: Int32, seconds: Double)
    /// Ended by a signal (Stop, Ctrl-C, closing the tab).
    case stopped(runID: UUID, signal: Int32, seconds: Double)
    case fetched(FetchFileOutcome)
    /// The sheet closed without doing anything.
    case cancelled
    /// Nothing started; the reason in Pitbox's words ("the folder changed after you looked; review again").
    case refused(reason: String)
}

/// Implemented by PitboxSessions: the session side of the click-time check.
public protocol CommandOfferFreshnessChecking: AnyObject, Sendable {
    /// Reads the transcript end and the session file again, off the main thread, within
    /// `CommandOfferFreshness.checkTimeout`; slower counts as `unknown`.
    func freshness(of offer: CommandOffer.ID) async -> CommandOfferFreshness

    /// The same check for a result fetch: the tool_use is still in the session's tail and still
    /// names `path`.
    func freshness(ofResultFetch sessionIndex: Int, toolUseID: String, path: String) async -> CommandOfferFreshness
}

public extension CommandOfferFreshnessChecking {
    /// Default: cannot tell, so nothing starts.
    func freshness(ofResultFetch sessionIndex: Int, toolUseID: String, path: String) async -> CommandOfferFreshness {
        .unknown
    }
}

/// Implemented by PitboxConsole: shows the native confirmation or Fetch file sheet. It never runs anything by
/// itself; the only run path starts from a real click on the sheet's Run or Fetch button.
@MainActor
public protocol CommandOfferPresenting: AnyObject {
    /// Shows the sheet for `offer` beside the block, next to `anchor` (the monitor's frame in screen coordinates).
    /// The sheet classifies the text again itself and asks `freshness` at the click. `events` receives every outcome,
    /// on the main thread. Presenting another offer replaces an open sheet (one at a time).
    func present(_ offer: CommandOffer, anchor: CGRect, freshness: CommandOfferFreshnessChecking,
                 events: @escaping @MainActor (CommandOfferEvent) -> Void)
    /// The session side saw the offer go stale while its sheet is open: Run, Type and Fetch switch off.
    func offerWentStale(_ offer: CommandOffer.ID)
    /// The session replied again while the offer's sheet is open: Run, Type and Fetch switch off, R22 is added with
    /// `supersession`, and the sheet re-arms.
    func offerWasSuperseded(_ offer: CommandOffer.ID, supersession: CommandOffer.Supersession)
    /// Closes any open sheet as a Cancel (the block hidden or folded).
    func dismissSheet()
    /// Selects the command tab of run `runID` and expands the terminal (a click on a result line). It never
    /// runs anything. A requirement (not only an extension method), so calls through the protocol reach the sheet.
    func revealRun(_ runID: UUID)
    /// Shows the Fetch file sheet for a file a session handed over or wrote on the server, with the
    /// same rules and arming as an offer's. A requirement, so calls through the protocol reach the sheet.
    func presentFetch(_ request: FetchFileRequest, source: CommandOffer.Source, sessionIndex: Int, anchor: CGRect,
                      freshness: CommandOfferFreshnessChecking, events: @escaping @MainActor (CommandOfferEvent) -> Void)
}

public extension CommandOfferPresenting {
    /// Default for a sheet that does not know R22 yet: fail toward "off".
    func offerWasSuperseded(_ offer: CommandOffer.ID, supersession: CommandOffer.Supersession) {
        offerWentStale(offer)
    }

    /// Default for a presenter without command tabs: nothing happens.
    func revealRun(_ runID: UUID) {}

    /// Default for a presenter that does not show result fetches yet: nothing happens.
    func presentFetch(_ request: FetchFileRequest, source: CommandOffer.Source, sessionIndex: Int, anchor: CGRect,
                      freshness: CommandOfferFreshnessChecking, events: @escaping @MainActor (CommandOfferEvent) -> Void) {}
}
