import AppKit
import Foundation
import PitboxKit
@testable import PitboxSessions

// Fakes for the block: the data side, the window side, the command sheet and the pasteboard. Nothing here touches a
// real window, file of Claude's, or the general pasteboard.

@MainActor
final class TileTestSource: CodeSessionsSource {
    var sessions: [CodeSessionSnapshot] = [] { didSet { onChange?() } }
    var runningProfiles: [CodeProfile] = [.a] { didSet { onChange?() } }
    var banner: String? { didSet { onChange?() } }
    var runningProcesses: [ClaudeProcessInfo] = [] { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private(set) var watched: [Set<String>] = []
    private(set) var stripVisible: [Bool] = []
    private(set) var starts = 0
    private(set) var stops = 0

    func setWatched(_ sessionIDs: Set<String>) { watched.append(sessionIDs) }
    func setStripVisible(_ visible: Bool) { stripVisible.append(visible) }
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
final class TileTestParker: CodeWindowParking {
    var statuses: [String: CodeWindowStatus] = [:] { didSet { onChange?() } }
    var parkedSessionIDs: Set<String> = [] { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private(set) var updates: [[String]] = []
    private(set) var processUpdates: [[ClaudeProcessInfo]] = []
    private(set) var active: [Bool] = []
    private(set) var performed: [(CodeWindowClick, String)] = []
    private(set) var parkAllCalls: [[String]] = []
    var parkAllResult = CodeParkAllResult()
    var frontmostResult = CodeParkFrontmostResult.parked
    private(set) var starts = 0
    private(set) var stops = 0

    func start() { starts += 1 }
    func stop() { stops += 1 }
    func update(sessions: [CodeSessionSnapshot], processes: [ClaudeProcessInfo]) {
        updates.append(sessions.map(\.id))
        processUpdates.append(processes)
    }
    func setActive(_ active: Bool) { self.active.append(active) }
    func perform(_ click: CodeWindowClick, sessionID: String) { performed.append((click, sessionID)) }
    func parkAllDone(_ sessionIDs: [String]) async -> CodeParkAllResult {
        parkAllCalls.append(sessionIDs)
        return parkAllResult
    }
    func parkFrontmostPopout() async -> CodeParkFrontmostResult { frontmostResult }

    /// Every session on the desk.
    func onDesk(_ ids: [String]) {
        var next = statuses
        for id in ids { next[id] = CodeWindowStatus(place: .onDesk) }
        statuses = next
    }
}

@MainActor
final class TileTestPresenter: CommandOfferPresenting {
    struct Presented {
        var offer: CommandOffer
        var anchor: CGRect
        var events: @MainActor (CommandOfferEvent) -> Void
    }
    private(set) var presented: [Presented] = []
    private(set) var stale: [CommandOffer.ID] = []
    private(set) var superseded: [(CommandOffer.ID, CommandOffer.Supersession)] = []
    private(set) var dismissals = 0

    func offerWasSuperseded(_ offer: CommandOffer.ID, supersession: CommandOffer.Supersession) {
        superseded.append((offer, supersession))
    }

    func present(_ offer: CommandOffer, anchor: CGRect, freshness: CommandOfferFreshnessChecking,
                 events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        presented.append(Presented(offer: offer, anchor: anchor, events: events))
    }
    func offerWentStale(_ offer: CommandOffer.ID) { stale.append(offer) }
    func dismissSheet() { dismissals += 1 }
}

final class TileTestFreshness: CommandOfferFreshnessChecking {
    func freshness(of offer: CommandOffer.ID) async -> CommandOfferFreshness { .fresh }
}

@MainActor
final class TileTestPasteboard: CodeMonitorPasteboard {
    private(set) var copies: [(text: String, privately: Bool)] = []
    func copyPrivately(_ text: String) { copies.append((text, true)) }
    func copy(_ text: String) { copies.append((text, false)) }
}

/// The fixed "now" of the block tests.
let tileNow = Date(timeIntervalSince1970: 1_792_000_000)

/// A session as the data side would give it.
func tileSession(_ id: String, _ headline: String, index: Int = 1, profile: CodeProfile = .a, state: CodeSessionState = .done,
                 nickname: String? = "calm otter", tldr: String? = nil, ask: String? = nil, now: String? = nil,
                 todos: CodeSessionTodos? = nil, offers: [CodeOfferEntry] = [], popout: Bool = true, model: String? = "claude-opus-5-5",
                 minutesAgo: Double = 6, quiet: Bool = false, place: CommandSessionFacts.Place = .local,
                 sshHost: String? = nil, cwd: String? = "/Users/alex/my project") -> CodeSessionSnapshot {
    let activity = tileNow.addingTimeInterval(-minutesAgo * 60)
    let finished: Bool = ![.working, .maybeNeedsYou, .quietUnfinished, .unknown].contains(state)
    return CodeSessionSnapshot(
        id: id, index: index, profile: profile, headline: headline, nickname: nickname,
        title: sshHost.map { "\($0) · \(headline)" } ?? headline + (nickname.map { " (\($0))" } ?? ""),
        place: place, sshHost: sshHost, cwd: cwd, model: model, effort: "high", permissionMode: "auto",
        state: state, lastActivity: activity, quietSince: quiet ? activity : nil, tldr: tldr, askLine: ask, now: now,
        todos: todos, steps: [CodeSessionStep(words: "editing CodeMonitorView.swift", at: tileNow.addingTimeInterval(-300)),
                              CodeSessionStep(words: "running: swift test", at: tileNow.addingTimeInterval(-60))],
        offers: offers, popout: popout ? CodePopoutHint(bounds: CGRect(x: 100, y: 100, width: 900, height: 700)) : nil,
        turnFinishedAt: finished ? activity : nil)
}

/// An offer with a given class (the classifier is `PitboxKit`'s: tests make assessments by hand).
func tileOffer(_ text: String, session: Int = 1, number: Int = 1, total: Int = 1, reply: String? = nil,
               commandClass: CommandAssessment.Class = .notFlagged, block: CommandRule? = nil,
               machine: CommandMachine = .thisMac, fetch: FetchFileRequest? = nil) -> CodeOfferEntry {
    let id = CommandOffer.ID(sessionIndex: session, replyUUID: reply ?? "reply-\(session)", number: number)
    let facts = CommandSessionFacts(place: .local, homeDirectory: "/Users/alex", userName: "alex", turnOrigin: .human)
    let offer = CommandOffer(id: id, text: text, total: total, blockKind: .tagged("zsh"),
                             displayLines: [CommandOffer.DisplayLine(role: .command, text: text)], caption: nil,
                             source: CommandOffer.Source(sessionID: "local_s\(session)", headline: "h", replyTime: tileNow),
                             replyReadCompletely: true, folder: CommandOffer.Folder(path: "/Users/alex", isHomeFallback: false),
                             context: CommandContext(facts: facts), replyText: "reply")
    let flags = block.map { [CommandFlag(rule: $0, words: "blocked", line: 1, utf16Range: 0..<1)] } ?? []
    let assessment = CommandAssessment(commandClass: commandClass, flags: flags, machine: machine, machineReason: "reason",
                                       fetch: fetch, lineCount: 1, commandCount: 1)
    return CodeOfferEntry(offer: offer, assessment: assessment)
}

/// A model over fakes, started, with a fixed clock.
@MainActor
struct TileHarness {
    let source: TileTestSource
    let parker: TileTestParker
    let presenter: TileTestPresenter
    let pasteboard: TileTestPasteboard
    let model: CodeMonitorsModel
    let attentionBox: TileAttentionBox
    /// The fold rail's counts after every rebuild (before the block's once-a-second throttle).
    var attention: [CodeAttentionCounts] { attentionBox.calls }

    init(settings: CodeSettings = CodeSettings()) {
        let source = TileTestSource(), parker = TileTestParker(), presenter = TileTestPresenter()
        let pasteboard = TileTestPasteboard()
        self.source = source; self.parker = parker; self.presenter = presenter; self.pasteboard = pasteboard
        attentionBox = TileAttentionBox()
        model = CodeMonitorsModel(source: source, parker: parker, presenter: presenter, freshness: TileTestFreshness(),
                                  settings: settings, pasteboard: pasteboard)
        model.now = { tileNow }
        model.homeDirectory = "/Users/alex"
        let box = attentionBox
        model.onAttentionCounts = { box.calls.append($0) }
        model.start()
    }

    func set(_ sessions: [CodeSessionSnapshot], onDesk: Bool = true) {
        if onDesk { parker.onDesk(sessions.map(\.id)) }
        source.sessions = sessions
    }
}

@MainActor
final class TileAttentionBox {
    var calls: [CodeAttentionCounts] = []
}

/// A block view in an off-screen window that is never shown (no order-in animation: it would hold a GCD pool thread
/// while the display sleeps).
@MainActor
func makeTileView(_ harness: TileHarness, size: CGSize = CGSize(width: 992, height: 474))
    -> (CodeMonitorsTileView, NSWindow) {
    let view = CodeMonitorsTileView(model: harness.model)
    view.visibilityProbe = { _ in true }
    view.pointerProbe = { nil }
    view.screenFrame = { $0.convert($0.bounds, to: nil) }
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.isOpaque = false
    window.backgroundColor = .clear
    view.frame = CGRect(origin: .zero, size: size)
    window.contentView = view
    view.refresh()
    return (view, window)
}
