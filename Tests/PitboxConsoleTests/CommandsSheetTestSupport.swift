import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// The terminal side of the sheet, faked: records every request, answers blockers as told.
@MainActor
final class FakeCommandHost: CommandTabHost {
    private(set) var requests: [CommandTabRequest] = []
    private(set) var serverAliases: [String] = []
    private(set) var revealed: [UUID] = []
    var blocker: String?
    /// Refuse every start at once with this reason.
    var refuseWith: String?
    var serverAnswer: String?
    var homeFolder: String

    init(home: String) { homeFolder = home }

    func commandBlocker(role: CommandTabRole) -> String? { blocker }

    func startCommandTab(_ request: CommandTabRequest, events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        requests.append(request)
        if let refuseWith {
            request.folder.close()
            events(.refused(reason: refuseWith))
        } else {
            events(.started(runID: request.runID))
        }
    }

    func openServerTab(alias: String, completion: @escaping @MainActor (String?) -> Void) {
        serverAliases.append(alias)
        completion(serverAnswer)
    }

    func revealRun(_ runID: UUID) -> Bool {
        revealed.append(runID)
        return true
    }
}

/// The session side's click-time check, faked.
final class FakeFreshness: CommandOfferFreshnessChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _answer: CommandOfferFreshness = .fresh
    private var _delay: TimeInterval = 0
    private var _calls = 0

    var answer: CommandOfferFreshness {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }
    var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }

    func freshness(of offer: CommandOffer.ID) async -> CommandOfferFreshness {
        let (answer, delay) = lock.withLock { () -> (CommandOfferFreshness, TimeInterval) in
            _calls += 1
            return (_answer, _delay)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return answer
    }

    /// One result fetch check as asked.
    struct ResultCheck: Equatable {
        var sessionIndex: Int
        var toolUseID: String
        var path: String
    }

    private var _resultAnswer: CommandOfferFreshness = .fresh
    private var _resultChecks: [ResultCheck] = []

    /// What `freshness(ofResultFetch:toolUseID:path:)` answers (after `delay`).
    var resultAnswer: CommandOfferFreshness {
        get { lock.withLock { _resultAnswer } }
        set { lock.withLock { _resultAnswer = newValue } }
    }
    var resultChecks: [ResultCheck] { lock.withLock { _resultChecks } }

    func freshness(ofResultFetch sessionIndex: Int, toolUseID: String, path: String) async -> CommandOfferFreshness {
        let (answer, delay) = lock.withLock { () -> (CommandOfferFreshness, TimeInterval) in
            _resultChecks.append(ResultCheck(sessionIndex: sessionIndex, toolUseID: toolUseID, path: path))
            return (_resultAnswer, _delay)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return answer
    }
}

/// The Fetch file runner, faked: plans and fetches as the test says.
final class FakeFetchRunner: FetchRunning, @unchecked Sendable {
    final class Handle: FetchHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        var cancelled: Bool { lock.withLock { _cancelled } }
        func cancel() { lock.withLock { _cancelled = true } }
    }

    private let lock = NSLock()
    private var _plans: [(request: FetchFileRequest, user: String?)] = []
    private var _started: [FetchPlan] = []
    var planResult: (String?) -> Result<FetchPlan, FetchPlanRefusal>
    private(set) var progress: [@MainActor (Int64) -> Void] = []
    private(set) var completions: [@MainActor (FetchFileOutcome) -> Void] = []
    private(set) var handles: [Handle] = []

    init(planResult: @escaping (String?) -> Result<FetchPlan, FetchPlanRefusal>) { self.planResult = planResult }

    var plans: [(request: FetchFileRequest, user: String?)] { lock.withLock { _plans } }
    var started: [FetchPlan] { lock.withLock { _started } }

    func plan(for request: FetchFileRequest, loginUser: String?) async -> Result<FetchPlan, FetchPlanRefusal> {
        lock.withLock { _plans.append((request, loginUser)) }
        return planResult(loginUser)
    }

    func start(_ plan: FetchPlan, progress: @escaping @MainActor (Int64) -> Void,
               completion: @escaping @MainActor (FetchFileOutcome) -> Void) -> FetchHandle {
        let handle = Handle()
        lock.withLock {
            _started.append(plan)
            self.progress.append(progress)
            completions.append(completion)
            handles.append(handle)
        }
        return handle
    }
}

/// Offers and assessments for sheet tests (tests supply the classifier's answers; a few use the real classifier).
enum SheetFixtures {
    static let home = "/Users/tester"

    static func facts(place: CommandSessionFacts.Place = .local, alias: String? = nil, cwd: String? = nil,
                      origin: CommandTurnOrigin = .human) -> CommandSessionFacts {
        CommandSessionFacts(place: place, sshAlias: alias, resolvedHostName: alias == nil ? nil : "10.0.0.1",
                            serverNames: [], knownSSHHosts: alias.map { [$0] } ?? [], remoteCwd: place == .ssh ? "/home/buildbox/x" : nil,
                            localCwd: cwd, homeDirectory: home, userName: "tester", turnOrigin: origin, turnReadWeb: false)
    }

    static func offer(_ text: String, facts: CommandSessionFacts = facts(), headline: String = "service token setup",
                      nickname: String? = "calm otter", asked: String? = "where do I put the service token?",
                      caption: String? = "Store it in your Keychain with hidden input:", complete: Bool = true,
                      display: [CommandOffer.DisplayLine] = [], number: Int = 1, total: Int = 1,
                      supersession: CommandOffer.Supersession? = nil, reply: String? = nil) -> CommandOffer {
        CommandOffer(id: .init(sessionIndex: 3, replyUUID: "reply-uuid-1", number: number), text: text, total: total,
                     blockKind: .tagged("bash"), displayLines: display, caption: caption,
                     source: .init(profileLetter: "A", profileName: "A Work", sessionID: "local_abc", headline: headline,
                                   nickname: nickname, youAsked: asked, replyTime: Date(timeIntervalSince1970: 1_760_965_320)),
                     replyReadCompletely: complete, folder: .init(path: facts.localCwd ?? home, isHomeFallback: false),
                     context: CommandContext(facts: facts, caption: caption), replyText: reply ?? "Here you go:\n\n```bash\n\(text)\n```\n",
                     supersession: supersession)
    }

    static func range(of needle: String, in text: String) -> Range<Int> {
        guard let found = text.range(of: needle) else { return 0..<0 }
        let start = text.utf16.distance(from: text.utf16.startIndex, to: found.lowerBound.samePosition(in: text.utf16) ?? text.utf16.startIndex)
        return start..<(start + needle.utf16.count)
    }

    static func notFlagged(_ text: String, notes: [CommandNote] = [], programs: [String] = []) -> CommandAssessment {
        CommandAssessment(commandClass: .notFlagged, flags: [], notes: notes,
                          segments: programs.enumerated().map { CommandSegment(program: $0.element, line: $0.offset + 1,
                                                                               utf16Range: 0..<1, machine: .thisMac) },
                          machine: .thisMac, machineReason: "For this Mac: the session runs here.",
                          lineCount: max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count),
                          commandCount: max(1, programs.count))
    }

    static func flag(_ rule: CommandRule, _ words: String, _ needle: String, in text: String, line: Int) -> CommandFlag {
        CommandFlag(rule: rule, words: words, line: line, utf16Range: range(of: needle, in: text), segment: line - 1)
    }

    /// The server file of a result fetch: what `ResultServerFiles.request(for:session:severalCopies:)` builds.
    static let resultPath = "/home/buildbox/projects/x/out/eval-report.md"

    static func resultRequest(path: String = resultPath, toolUseID: String? = "toolu_01SendUserFile") -> FetchFileRequest {
        FetchFileRequest(alias: "buildbox", replyUser: nil, remotePath: path, destinationName: nil, sourceToolUseID: toolUseID)
    }

    static func resultSource(headline: String = "buildbox · eval run") -> CommandOffer.Source {
        CommandOffer.Source(profileLetter: nil, profileName: nil, sessionID: "ssh_abc", headline: headline, nickname: "brave finch",
                            youAsked: nil, replyTime: Date(timeIntervalSince1970: 1_760_965_320))
    }

    /// The plan the Fetch file runner makes for `resultRequest()` (the config's user; no reply user).
    static func resultPlan(user: String = "buildbox") -> FetchPlan {
        FetchPlan(alias: "buildbox", loginUser: user, configUser: "buildbox", replyUser: nil, proxyNote: nil,
                  remotePath: resultPath, fileName: "eval-report.md", previewName: "eval-report.md",
                  arguments: ["/usr/bin/scp", "-o", "LogLevel=ERROR", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                              "-o", "UpdateHostKeys=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
                              "-o", "PermitLocalCommand=no", "-o", "ConnectTimeout=15", "--", "\(user)@buildbox:\(resultPath)",
                              "<staging>/eval-report.md"],
                  configFingerprint: "fp")
    }
}

/// A sheet over fakes: no window on screen, a manual clock, a private pasteboard.
@MainActor
final class SheetHarness {
    var now: TimeInterval = 1_000
    let folder: CommandTempFolder
    let host: FakeCommandHost
    let freshness = FakeFreshness()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("pitbox-command-sheet-tests-\(UUID().uuidString)"))
    let controller: CommandSheetController
    private(set) var events: [CommandOfferEvent] = []
    /// The classifier's answers: a test's own, or the real classifier's (`SheetHarness(realClassifier:)`).
    var classify: (String, CommandContext, CommandClassifierOptions) -> CommandAssessment
    private(set) var contexts: [CommandContext] = []
    /// The options of every classifier call, in order.
    private(set) var classifierOptions: [CommandClassifierOptions] = []
    var visible = true
    /// What the settings' `commands` says (the sheet tests run with Run on).
    var runPolicy: CommandRunPolicy = .run
    var facts: [String: CommandPathFact] = [:]
    private(set) var factLookups: [[String]] = []
    var exactAliases: Set<String> = []

    /// A sheet whose classifier answers come from `assess` (the options are recorded, not passed).
    convenience init(assess: @escaping (String, CommandContext) -> CommandAssessment, fetchRunner: FetchRunning? = nil,
                     shell: CommandExecutionDescriptor.Shell = .clean) {
        self.init(classify: { text, context, _ in assess(text, context) }, fetchRunner: fetchRunner, shell: shell)
    }

    /// A sheet over the real classifier of PitboxKit.
    convenience init(realClassifier: Void, fetchRunner: FetchRunning? = nil, shell: CommandExecutionDescriptor.Shell = .clean) {
        self.init(classify: { CommandClassifier.assess(text: $0, context: $1, options: $2) }, fetchRunner: fetchRunner, shell: shell)
    }

    init(classify: @escaping (String, CommandContext, CommandClassifierOptions) -> CommandAssessment, fetchRunner: FetchRunning?,
         shell: CommandExecutionDescriptor.Shell) {
        folder = CommandTempFolder("sheet")
        host = FakeCommandHost(home: folder.path)
        self.classify = classify
        var recorded: ((String, CommandContext, CommandClassifierOptions) -> CommandAssessment)!
        var clock: (() -> TimeInterval)!
        controller = CommandSheetController(host: host, classify: { recorded($0, $1, $2) }, fetchRunner: fetchRunner,
                                            commandShell: { shell }, extraPath: { [] }, clock: { clock() },
                                            pasteboard: pasteboard, home: folder.path, userName: "tester")
        recorded = { [unowned self] text, context, options in
            contexts.append(context)
            classifierOptions.append(options)
            return self.classify(text, context, options)
        }
        clock = { [unowned self] in now }
        controller.present = { _ in }
        controller.hide = { _ in }
        controller.isFullyVisible = { [unowned self] _ in visible }
        controller.runPolicy = { [unowned self] in runPolicy }
        controller.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        controller.lookUpFacts = { [unowned self] paths in
            factLookups.append(paths)
            return paths.reduce(into: [:]) { $0[$1] = facts[$1] ?? .missing }
        }
        controller.setuidPrograms = { _, _ in [] }
        controller.isExactAlias = { [unowned self] alias in exactAliases.contains(alias) }
        controller.revealInFinder = { _ in }
        controller.screenFrame = { [unowned self] in screen }
    }

    /// The visible frame the sheet is placed in (never the real screen).
    var screen = CGRect(x: 0, y: 0, width: 2_560, height: 1_400)

    /// Presents `offer` with the folder facts pointing at the harness's folder, and waits for the second pass.
    func present(_ offer: CommandOffer) async {
        controller.present(offer, anchor: CGRect(x: 1_200, y: 400, width: 300, height: 200), freshness: freshness) { [unowned self] event in
            events.append(event)
        }
        _ = await waitUntil(5) { self.controller.sheet?.state.assessmentReady == true }
    }

    /// Presents a result fetch through the protocol, as the monitors do, and waits for its plan (or its refusal) when
    /// `waitForPlan`.
    func presentFetch(_ request: FetchFileRequest = SheetFixtures.resultRequest(), source: CommandOffer.Source = SheetFixtures.resultSource(),
                      sessionIndex: Int = 3, waitForPlan: Bool = true) async {
        let presenter: CommandOfferPresenting = controller
        presenter.presentFetch(request, source: source, sessionIndex: sessionIndex, anchor: CGRect(x: 1_200, y: 400, width: 300, height: 200),
                               freshness: freshness) { [unowned self] event in
            events.append(event)
        }
        guard waitForPlan else { return }
        _ = await waitUntil(5) {
            switch self.controller.sheet?.state.fetch?.phase {
            case .planned?, .refused?: return true
            default: return false
            }
        }
    }

    var sheet: OpenSheet? { controller.sheet }
    var model: CommandSheetModel? { controller.sheet?.model }
    var view: CommandSheetView? { controller.sheet?.view }

    func advance(_ seconds: TimeInterval) { now += seconds }

    /// A real-looking click: the pointer enters (now), the press begins and ends inside.
    func click(_ button: CommandSheetButton, enter: Bool = true) {
        if enter { button.pointerEntered() }
        button.beginPress()
        button.endPress(inside: true)
    }

    func tickAll() {
        for line in model?.redLines ?? [] where !line.ticked {
            if let tick = view?.tickButtons[line.key] { click(tick) }
        }
    }
}
