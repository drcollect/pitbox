import Foundation
import PitboxKit

/// A file a session handed over (`SendUserFile`) or wrote (Write, Edit) on the server, as the monitors hand it to
/// `presentFetch`: the request, the session's "From" facts and its local index for the click-time check.
struct ResultFetchSubject: Equatable {
    var request: FetchFileRequest
    var source: CommandOffer.Source
    var sessionIndex: Int
}

/// Everything the sheet knows while it is open. The controller changes it; `CommandSheetModel` turns it into what is
/// shown and allowed. Nothing here runs anything.
struct CommandSheetState {
    /// What the sheet is about.
    enum Subject: Equatable {
        /// An offer's fenced block: the command text, read by the sheet itself.
        case offer(CommandOffer)
        /// A file on the server from a session's work: no command text, nothing read, typed or run;
        /// only Fetch file, checked at the click by the tool_use the file came from. Never a synthetic offer.
        case resultFetch(ResultFetchSubject)
    }

    enum Mode: Equatable {
        /// The ordinary sheet; `fromFetch` when the user chose "Run in terminal instead" on the Fetch file sheet.
        case ordinary(fromFetch: Bool)
        /// The Fetch file sheet, for an offer or a result fetch.
        case fetch
    }

    /// What a result fetch has in place of the reader's assessment: nothing was read, and anything that looked at it
    /// anyway would find a blocked text on an unclear machine.
    static let noReading = CommandAssessment(commandClass: .blocked, machine: .unclear, machineReason: "", lineCount: 0,
                                             commandCount: 0)

    /// Unclear machine: the user's pick.
    enum MachinePick: Equatable { case thisMac, server }

    /// The folder a run would start in, bound by descriptor when the sheet opened.
    struct Folder: Equatable {
        var path: String
        var shortPath: String
        /// The session's own folder does not exist here; the home folder is used.
        var isHomeFallback: Bool
        /// Nil when bound; else why it could not be.
        var problem: String?
    }

    /// The sheets' disclosures (closed unless listed in `open`).
    enum Disclosure: String, CaseIterable, Equatable, Hashable {
        case howItRuns, wholeReply, newerReplies, newMessage, moreOptions
    }

    /// A line under the buttons: Pitbox's words about the last click or a change.
    struct Message: Equatable {
        enum Tone: Equatable { case info, warning, problem }
        var text: String
        var tone: Tone
    }

    /// The Fetch file sheet's own state.
    struct Fetch: Equatable {
        enum Phase: Equatable {
            case planning
            case planned(FetchPlan)
            case refused(String)
            case fetching(FetchPlan, bytes: Int64)
            case done(FetchFileOutcome)
        }
        var phase: Phase = .planning
        /// The login user the user picked: nil means the config's.
        var chosenUser: String?
        /// The users offered as a choice: the config's and the reply's, when they differ.
        var configUser: String?
        var replyUser: String?
        /// After a saved fetch: Open, Preview or nothing beside Show in Finder.
        var opening: FetchedFileOpening = .showInFinderOnly
    }

    var subject: Subject
    /// The sheet's own assessment, the second pass when `localTargets` needed path facts;
    /// `noReading` for a result fetch.
    var assessment: CommandAssessment
    /// False until the second pass (lstat of `localTargets`) is done: Run, Type and Fetch wait for it.
    var assessmentReady: Bool
    var mode: Mode
    /// Keys of the ticked red lines (`CommandSheetModel.key(of:)`).
    var ticked: Set<String> = []
    var machinePick: MachinePick?
    /// The session moved on for good: Run, Type and Fetch off; Copy works.
    var stale = false
    /// What followed the offer's reply (R22): from the offer, `offerWasSuperseded`, or a
    /// `superseded` answer at the click (`supersededWithoutDetails`).
    var supersession: CommandOffer.Supersession?
    var supersededWithoutDetails = false
    var folder: Folder
    /// The session works on an external or network volume, by the session side's word or decided again by the sheet
    /// (when it opened or at a click): Run and Type stay off, Copy stays. Never taken back while the sheet is open.
    var workFolderRefused = false
    var shell: CommandExecutionDescriptor.Shell
    /// Whether Run is allowed (the settings' `commands`): read when the sheet opens and again at every check while it
    /// is open; it only ever goes from `run` to `copyOnly` while the sheet is open (switching Run on needs a new
    /// sheet).
    var runPolicy: CommandRunPolicy = .copyOnly
    /// Why Run cannot start now (console hidden, limits, spawn path), from the console; nil when it can.
    var terminalBlocker: String?
    /// The same for Type (no 3-running limit: a Type tab runs nothing).
    var typeBlocker: String?
    /// The bottom of the command area has been on screen once.
    var scrolledToEnd = false
    /// The alias for "Open a terminal on <host>", once `~/.ssh/config` confirmed it.
    var serverAlias: String?
    /// A click-time check is running (freshness, files): every action button waits.
    var checking = false
    /// The text has been consumed by a Run or Type (one approval, one run).
    var consumed = false
    var message: Message?
    /// "Copied" shows on these until the time passes.
    var copiedUntil: TimeInterval?
    var copiedCleanedUntil: TimeInterval?
    var openedServerUntil: TimeInterval?
    /// Programs the command names that macOS will not start inside the command sandbox (setuid).
    var setuidPrograms: [String] = []
    var open: Set<Disclosure> = []
    var fetch: Fetch?
    /// Clean or login: what Type would type (full-line comments left out for the login shell), or nil when Type
    /// cannot type it there (a comment after a command).
    var typedText: String?
    /// "How it runs": the frozen shell, PATH, folder, environment rule and spawn path, in Pitbox's words.
    var howItRuns: [[CommandSheetModel.Part]] = []

    /// The offer of an offer's sheet; nil for a result fetch.
    var offer: CommandOffer? {
        if case .offer(let offer) = subject { return offer }
        return nil
    }

    /// The file of a result fetch; nil for an offer's sheet.
    var resultFetch: ResultFetchSubject? {
        if case .resultFetch(let subject) = subject { return subject }
        return nil
    }

    /// What Fetch file plans: the reader's request for an offer of the `fetchFile` class, or the result's.
    var fetchRequest: FetchFileRequest? {
        switch subject {
        case .offer: return assessment.fetch
        case .resultFetch(let subject): return subject.request
        }
    }

    /// The sheet in a log line: the offer's local number (`#3.1`), or the session's local index for a result fetch
    /// (`#3.file`). Never a path, a tool_use id or text.
    var logSubject: CommandLogValue {
        switch subject {
        case .offer(let offer): return .offer(offer.id)
        case .resultFetch(let subject): return .resultFile(subject.sessionIndex)
        }
    }
}
