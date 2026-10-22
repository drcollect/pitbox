import Foundation
import PitboxKit

/// The LED on a monitor's bezel: its colour, its form and whether it pulses.
struct CodeMonitorLED: Equatable {
    enum Form: Equatable { case filled, ring, hollow }
    var color: UInt32
    var form: Form
    var pulses: Bool
}

/// The offer line on a monitor: an offer ("▶ 1 command · risky"), a run ("✓ exit 0 · 3 s") or a fetch result.
struct CodeOfferLine: Equatable {
    enum Tone: Equatable { case offer, running, ok, failed, neutral }
    enum Action: Equatable {
        /// One offer: open its sheet.
        case openSheet(CommandOffer.ID)
        /// Several offers: open the peek's list.
        case openPeek
        /// A run's result: select that terminal tab (wired by the app, `onRevealRun`).
        case revealRun(UUID)
        case none
    }
    /// The app's words: "▶ 3 commands · 1 risky".
    var text: String
    /// The first command line (session text, already plain), shown dimmed on large monitors; nil otherwise.
    var detail: String?
    var tone: Tone
    var action: Action
    /// Offers in the reply, for a small monitor's "▶2" pip; 0 for a run's result.
    var count: Int
}

/// A small monitor's offer badge: "▶" for commands, "⤓" for files; a click does what the offer line does.
struct CodeMonitorPip: Equatable {
    var symbol: String
    var count: Int
    var action: CodeOfferLine.Action
}

/// One "Now" step in the peek.
struct CodePeekStep: Equatable {
    var words: String
    var ago: String
}

/// One todo in the peek.
struct CodePeekTodo: Equatable {
    enum Mark: Equatable { case done, current, pending }
    var text: String
    var mark: Mark
}

/// One row of "Commands in the last reply".
struct CodePeekOfferRow: Equatable {
    var id: CommandOffer.ID
    var number: Int
    /// The button that opens the sheet: "▶ Run…", "⤓ Fetch…" or "Review…". Run itself is
    /// only on the sheet.
    var reviewTitle: String
    /// The first command line, plain text; drawn with middle truncation so the program and the last argument show.
    var firstLine: String
    /// "Not flagged", "Risky", "Needs editing", "For the server", "Other machine", "Unclear", "Partly read", "Blocked",
    /// "Fetch file".
    var classChip: String
    var classTone: CodeOfferLine.Tone
    /// "This Mac", the alias ("buildbox"), or "?".
    var machineChip: String
    /// Copy is off for B1 (Copy cleaned is on the sheet), B2 and B5.
    var canCopy: Bool
    /// "ran 4 min ago · exit 0" when the same text already ran from this session.
    var ranNote: String?
}

/// Everything the peek shows. With text hidden, only `title`, `stateLine` and the buttons are filled.
struct CodeMonitorPeekContent: Equatable {
    /// The full title (2 lines), plain text; the headline when text is hidden.
    var title: String
    /// "A · Claude", only when more than one copy runs.
    var profile: String?
    /// "buildbox · ~/projects/x" or "this Mac · ~/my project".
    var place: String?
    /// "working · 2 min · opus · high · auto".
    var stateLine: String
    var tldr: String?
    var ask: String?
    var steps: [CodePeekStep]
    /// "4 of 7 todos".
    var todosTitle: String?
    var todos: [CodePeekTodo]
    var offers: [CodePeekOfferRow]
    /// "8 of 12 commands; the rest are in the session".
    var offersNote: String?
    /// "Back on track" (restore) or "Pit" (on the desk); nil when neither applies.
    var windowButton: String?
    var windowClick: CodeWindowClick
    /// `claude://claude.ai/epitaxy/local_<id>`, nil when the id fails its check.
    var link: String?
    var textHidden: Bool
    /// Warnings: each warning's statement and its facts (`CodeWarningWords.peekLines`: the last failure's exit code,
    /// since when); empty with text hidden.
    var warnings: [[String]] = []
    /// Results: the results' rows (`CodeResultPeekRows`); empty with text hidden.
    var results: [CodeResultPeekRow] = []
}

/// One monitor as the views draw it. Every string from a session went through `CodePlainText` before it got here.
struct CodeMonitorItem: Equatable, Identifiable {
    var id: String
    /// The session's local index (`#3` in logs).
    var index: Int
    /// 1-based place in the block and the number of monitors, for VoiceOver ("Code monitor 2 of 6").
    var position: Int
    var total: Int
    var profileLetter: String
    /// The copy's own colour from the settings file's `profiles` (nil: the palette's).
    var profileColour: UInt32? = nil
    /// Profile marks on the foot, only when more than one copy runs.
    var profileLabel: String?
    var headline: String
    var nickname: String?
    var tldr: String?
    /// "Now: running tests · 4/7 todos" while working.
    var now: String?
    var ask: String?
    var offer: CodeOfferLine?
    /// The bottom bar of a large monitor: "working · 2 min · opus".
    var status: String
    /// "state · age": the VoiceOver label and narrow bars.
    var statusShort: String
    /// A medium monitor's bottom bar: "working · opus" while working, else "done · 25 min".
    var statusCompact: String
    /// A small monitor's one line: a run's result, else "▶ 2" / "⤓ 1", else the state word.
    var compactLine: String
    var compactTone: CodeOfferLine.Tone?
    /// A small monitor's 18 pt offer badge.
    var pip: CodeMonitorPip?
    /// Done todos of all, while working (the 3 pt bar of medium and small monitors).
    var progress: Double?
    var stateWord: String
    var state: CodeSessionState
    var chip: String
    var chipIsProblem: Bool
    var led: CodeMonitorLED
    /// Needs you (amber) or Problem (red): the bezel glows.
    var glow: UInt32?
    /// Quiet overlay: the screen at 50%.
    var quiet: Bool
    var busy: Bool
    var click: CodeWindowClick
    var tooltip: String?
    /// Hide text, or `showText` false for this copy: headline and state only.
    var textHidden: Bool
    var peek: CodeMonitorPeekContent

    // MARK: Warnings, slim rows, marks, runs and results

    /// The session has an active warning: its page dot gets the amber ring like Needs you.
    var hasWarning = false
    /// A slim row's button: "▶ Run…", "⤓ Fetch…" or "Review…" when there is an offer (it opens what the offer
    /// line opens); nil otherwise or with text hidden.
    var rowAction: String?
    /// Marks other features add (the unread dot, the ▦ pill, …): `CodeMonitorMark`.
    var marks: [CodeMonitorMark] = []
    /// The short run text ("ETA 23:24 · 4/6 agents", "≈ 9 min left"), shown on a slim row's right in place of
    /// "state · age"; nil until `CodeRunDecoration` sets it through an item decorator.
    var runText: String?
    /// The run line and bar on large and medium monitors, set by `CodeRunDecoration`.
    var runLine: CodeRunLine?
    /// The result line: the first result's button and "+2 more", drawn in the offer line's place on large and
    /// medium monitors when there is no offer line; its click is armed like an opening mark. Nil with text hidden.
    var resultLine: CodeMonitorResultLine?
    /// The warning: the orange line on large and medium monitors, "⚠ stuck" / "⚠ same file" on small ones (in
    /// place of the state word), and the orange screen outline on every size.
    var warningLine: CodeMonitorWarningLine?
}

/// A small mark another feature puts on a monitor or a slim row: the block's slot for chips (the unread dot, the ▦
/// pill, and the like). A feature adds marks through `CodeMonitorsModel.itemDecorators`; the monitor draws them at
/// their place in every size, and a click on one goes to `CodeMonitorsModel.onMarkClick` (never to the window click).
/// A mark that opens something (`opens`) counts a click only `CodeTuning.openButtonArmDelay` after it appeared or
/// moved, and never the first press when it appeared under the pointer. Host words only, never session text.
struct CodeMonitorMark: Equatable {
    enum Place: Equatable {
        /// An 11 pt dot on the bezel's top-left corner (rows: before the LED). The unread dot.
        case cornerDot
        /// A pill on the bezel's bottom bar at the left (rows: before the status words). The ▦ pill.
        case footPill
    }
    /// What `onMarkClick` receives with the session id; nil for a mark a click ignores.
    var id: String?
    var place: Place
    /// The pill's words on large monitors and rows ("▦ Dashboard"), and on medium and small ones (`short`, "▦").
    var text: String
    var short: String
    /// Fill and ink, `0xRRGGBB` (a monitor is a dark object in both appearances).
    var fill: UInt32
    var ink: UInt32
    /// VoiceOver's words ("Open the dashboard").
    var label: String
    /// It opens something (a link, a file, a dashboard): the click is armed (see the type's note).
    var opens: Bool
}

/// The header band: "4 in the pit · 2 on track · 1 needs you", Hide text, Pit all done (n), + New bucket.
struct CodeMonitorsHeader: Equatable {
    /// Monitors shown.
    var count: Int
    /// Followed sessions in Needs you (pop-outs on the desk too).
    var needYou: Int
    var hideText: Bool
    /// Monitors Pit all done would pit now; the button is off at 0.
    var parkAllDone: Int
    /// Pit all done's result for a few seconds ("3 into the pit · 1 on another Space, not pitted").
    var note: String?
    /// Monitors of parked sessions, closed-while-parked included.
    var parked = 0
    /// Matched pop-outs on the desk.
    var onDesk = 0
    /// "+ New bucket" is on (fewer than 20 buckets); off with the tooltip "20 buckets is the limit".
    var canCreateBucket = true
}

/// What the block shows at one moment.
struct CodeMonitorsSnapshot: Equatable {
    /// Every monitor, bucket by bucket in the buckets' order (`sections`), each bucket in its stable order.
    var monitors: [CodeMonitorItem] = []
    var header = CodeMonitorsHeader(count: 0, needYou: 0, hideText: false, parkAllDone: 0, note: nil)
    /// "Claude's session files changed (Claude <version>). Showing titles only."
    var banner: String?
    /// The one-time line after the first pit stop (`CodePitHint.text`).
    var hint: String?
    var showsProfiles = false
    /// When there is no monitor: a title and a detail line.
    var emptyTitle: String?
    var emptyDetail: String?

    // MARK: Buckets

    /// Every bucket with its monitors and header counts, Unsorted first.
    var sections: [CodeBucketSection] = []
    /// The user made a bucket: every bucket draws its header. With Unsorted alone the block looks as it does without
    /// buckets (no bucket header, the block's own empty state); Unsorted's header appears with the user's first bucket.
    var bucketMode = false
    /// Monitors or slim rows (`look`).
    var look: CodeSettings.Look = .monitors
    /// "Your buckets couldn't be read; a copy was kept." until the user's next change.
    var bucketNote: String?
}

/// One bucket as the block draws it: its header's facts and its monitors in their stable order.
struct CodeBucketSection: Equatable, Identifiable {
    var bucket: CodeBucket
    var monitors: [CodeMonitorItem]
    var counts: CodeBucketCounts
    var id: String { bucket.id }
}
