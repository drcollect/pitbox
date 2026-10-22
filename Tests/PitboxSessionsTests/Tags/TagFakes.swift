import AppKit
import Foundation
import PitboxKit
@testable import PitboxSessions

// Fakes for desk tags: virtual time, the observer's queue, Accessibility, the window server, the button, the system, the
// panel ordering and the actions. Nothing here reads a real window, registers an observer on another app or orders a
// panel in front: panels get frames, never `orderFront`.

/// One virtual timeline for the observer's queue and the main-thread timers, so both run in time order.
final class TagTimeline: @unchecked Sendable {
    struct Entry {
        var at: TimeInterval
        var order: Int
        var work: () -> Void
    }

    private(set) var now: TimeInterval = 1000
    private var entries: [Entry] = []
    private var counter = 0
    /// Work queued with `async`, run by `drain`, first in first out.
    private var immediate: [() -> Void] = []

    func async(_ work: @escaping () -> Void) { immediate.append(work) }

    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        counter += 1
        entries.append(Entry(at: now + max(0, seconds), order: counter, work: work))
    }

    /// Runs queued work until nothing is left (timers that are due included).
    func drain() {
        var guardCount = 0
        while true {
            guardCount += 1
            precondition(guardCount < 100_000, "the fake queue does not settle")
            if !immediate.isEmpty {
                let work = immediate.removeFirst()
                work()
                continue
            }
            guard let index = dueIndex() else { return }
            let entry = entries.remove(at: index)
            entry.work()
        }
    }

    private func dueIndex() -> Int? {
        var best: Int?
        for (index, entry) in entries.enumerated() where entry.at <= now + 1e-9 {
            if let current = best {
                let other = entries[current]
                if (entry.at, entry.order) < (other.at, other.order) { best = index }
            } else {
                best = index
            }
        }
        return best
    }

    /// Moves time forward, running every timer on the way in order.
    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        drain()
        while let next = entries.filter({ $0.at <= end + 1e-9 }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            now = max(now, next.at)
            drain()
        }
        now = end
        drain()
    }

    /// Timers not run yet.
    var pendingTimers: Int { entries.count }
}

final class FakeTagQueue: DeskTagQueue, @unchecked Sendable {
    let timeline: TagTimeline
    init(_ timeline: TagTimeline) { self.timeline = timeline }
    func async(_ work: @escaping () -> Void) { timeline.async(work) }
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) { timeline.after(seconds, work) }
    var runLoop: CFRunLoop? { nil }
}

/// Accessibility with nothing but registrations and reads: there is no way here to set an attribute or perform an
/// action, as in the live seam.
final class FakeTagAX: DeskTagAXObserving {
    var sink: ((pid_t, CGWindowID?, CodeWindowNotification) -> Void)?
    var trusted = true
    /// Answers of `observe`, consumed in order; then success.
    var observeAnswers: [pid_t: [DeskTagAXFailure?]] = [:]
    var fullScreen: [CodeWindowKey: Bool] = [:]
    var focused: [pid_t: CGWindowID] = [:]
    private(set) var observeCalls: [pid_t] = []
    private(set) var unobserveCalls: [pid_t] = []
    private(set) var watchCalls: [CodeWindowKey] = []
    private(set) var unwatchCalls: [CodeWindowKey] = []
    private(set) var fullScreenReads = 0
    private(set) var observing: Set<pid_t> = []

    func isTrusted() -> Bool { trusted }

    func observe(pid: pid_t) -> DeskTagAXFailure? {
        observeCalls.append(pid)
        if var answers = observeAnswers[pid], !answers.isEmpty {
            let answer = answers.removeFirst()
            observeAnswers[pid] = answers
            if let answer { return answer }
        }
        observing.insert(pid)
        return nil
    }

    func unobserve(pid: pid_t) {
        unobserveCalls.append(pid)
        observing.remove(pid)
    }

    func watch(pid: pid_t, number: CGWindowID) -> Bool {
        watchCalls.append(CodeWindowKey(pid: pid, number: number))
        return true
    }

    func unwatch(pid: pid_t, number: CGWindowID) {
        unwatchCalls.append(CodeWindowKey(pid: pid, number: number))
    }

    func isFullScreen(pid: pid_t, number: CGWindowID) -> Bool? {
        fullScreenReads += 1
        return fullScreen[CodeWindowKey(pid: pid, number: number)] ?? false
    }

    func focusedWindowNumber(pid: pid_t) -> CGWindowID? { focused[pid] }

    /// Claude posts a notification (delivered on the observer's queue, as the live run loop would).
    func post(_ note: CodeWindowNotification, pid: pid_t, number: CGWindowID? = nil) {
        sink?(pid, number, note)
    }
}

final class FakeTagServer: DeskTagWindowServer, @unchecked Sendable {
    var windows: [CGWindowID: DeskTagServerWindow] = [:]
    /// The on-screen list, front to back.
    var frontToBack: [DeskTagServerWindow] = []
    private(set) var reads = 0
    private(set) var listReads = 0

    func window(number: CGWindowID) -> DeskTagServerWindow? {
        reads += 1
        return windows[number]
    }

    func onScreenFrontToBack() -> [DeskTagServerWindow] {
        listReads += 1
        return frontToBack
    }
}

final class FakeTagButton: DeskTagButton, @unchecked Sendable {
    var down = false
    func isLeftButtonDown() -> Bool { down }
}

@MainActor
final class FakeTagSystem: DeskTagSystem {
    var displayList: [DeskTagDisplay]
    var primaryHeight: CGFloat
    /// AppKit coordinates.
    var pointer = CGPoint(x: -10_000, y: -10_000)
    var ownActive = false
    var frontmost: pid_t? = 4242
    private(set) var handler: (@MainActor (DeskTagSystemEvent) -> Void)?
    private(set) var escapeMonitors: [ObjectIdentifier: () -> Bool] = [:]
    private(set) var stops = 0

    init(displays: [DeskTagDisplay], primaryHeight: CGFloat) {
        displayList = displays
        self.primaryHeight = primaryHeight
    }

    func displays() -> [DeskTagDisplay] { displayList }
    func pointerLocation() -> CGPoint { pointer }
    func isOwnAppActive() -> Bool { ownActive }
    func frontmostPID() -> pid_t? { frontmost }
    func start(_ handler: @escaping @MainActor (DeskTagSystemEvent) -> Void) { self.handler = handler }
    func stop() { stops += 1; handler = nil }

    final class Token {}

    func addEscapeMonitor(_ handler: @escaping @MainActor () -> Bool) -> AnyObject? {
        let token = Token()
        escapeMonitors[ObjectIdentifier(token)] = handler
        return token
    }

    func removeEscapeMonitor(_ token: AnyObject) { escapeMonitors[ObjectIdentifier(token)] = nil }

    func post(_ event: DeskTagSystemEvent) { handler?(event) }

    /// A key monitor sees Escape: only what a local monitor would see (The app active) reaches it.
    @discardableResult
    func pressEscape() -> Bool {
        guard ownActive else { return false }
        return escapeMonitors.values.contains { $0() }
    }
}

/// Records the ordering; sets frames so views lay out, never orders a panel in.
@MainActor
final class FakeTagWindowing: DeskTagWindowing {
    struct Show: Equatable {
        var panel: ObjectIdentifier
        var frame: CGRect
        var level: NSWindow.Level
        var above: CGWindowID?
        var reorder: Bool
    }

    private(set) var shows: [Show] = []
    private(set) var hides: [ObjectIdentifier] = []
    private(set) var visible: Set<ObjectIdentifier> = []

    func show(_ panel: NSPanel, frame: CGRect, level: NSWindow.Level, above number: CGWindowID?, reorder: Bool) {
        precondition(!panel.isVisible, "a test panel was ordered in")
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        shows.append(Show(panel: ObjectIdentifier(panel), frame: frame, level: level, above: number, reorder: reorder))
        visible.insert(ObjectIdentifier(panel))
    }

    func hide(_ panel: NSPanel) {
        hides.append(ObjectIdentifier(panel))
        visible.remove(ObjectIdentifier(panel))
    }

    func isShown(_ panel: NSPanel) -> Bool { visible.contains(ObjectIdentifier(panel)) }

    func lastShow(_ panel: NSPanel) -> Show? { shows.last { $0.panel == ObjectIdentifier(panel) } }

    func reset() { shows = []; hides = [] }
}

@MainActor
final class FakeTagScheduler: DeskTagScheduler {
    final class Timer: DeskTagTimer {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    let timeline: TagTimeline
    init(_ timeline: TagTimeline) { self.timeline = timeline }
    var now: TimeInterval { timeline.now }

    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> DeskTagTimer {
        let timer = Timer()
        timeline.after(seconds) {
            MainActor.assumeIsolated {
                guard !timer.cancelled else { return }
                work()
            }
        }
        return timer
    }
}

@MainActor
final class FakeTagActions: DeskTagActions {
    enum Call: Equatable {
        case offer(CommandOffer.ID, String, CGRect)
        case result(String, String)
        case dashboard(String)
        case park(String)
        case copyLink(String)
    }

    private(set) var calls: [Call] = []

    func openOffer(_ offer: CommandOffer.ID, sessionID: String, anchor: CGRect) { calls.append(.offer(offer, sessionID, anchor)) }
    func openResult(_ resultID: String, sessionID: String, anchor: CGRect) { calls.append(.result(resultID, sessionID)) }
    func openDashboard(sessionID: String) { calls.append(.dashboard(sessionID)) }
    func park(sessionID: String) { calls.append(.park(sessionID)) }
    func copyLink(sessionID: String) { calls.append(.copyLink(sessionID)) }
}

// MARK: Geometry of the tests

/// A 2000 × 1200 display with a 30 pt menu bar, and a second one to its right.
let tagDisplay = DeskTagDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 2000, height: 1200),
                             visibleFrame: CGRect(x: 0, y: 30, width: 2000, height: 1170))
let tagSecondDisplay = DeskTagDisplay(id: 2, frame: CGRect(x: 2000, y: 0, width: 1600, height: 1000),
                                   visibleFrame: CGRect(x: 2000, y: 25, width: 1600, height: 975))
/// The strip on the first display's right edge (Quartz).
let tagStrip = ReservedRegion(displayID: 1, rect: CGRect(x: 1600, y: 0, width: 400, height: 1200), edge: .right)
let tagPID: pid_t = 4242
let tagWindowNumber: CGWindowID = 501
let tagWindowBounds = CGRect(x: 300, y: 200, width: 900, height: 700)

func tagWindow(_ number: CGWindowID = tagWindowNumber, pid: pid_t = tagPID, bounds: CGRect = tagWindowBounds,
               onScreen: Bool = true, layer: Int = 0) -> DeskTagServerWindow {
    DeskTagServerWindow(number: number, pid: pid, bounds: bounds, layer: layer, isOnScreen: onScreen)
}

/// The clock of the tests: UTC, 24-hour.
let tagClock = DeskTagClock(timeZone: TimeZone(identifier: "UTC") ?? .gmt, locale: Locale(identifier: "en_GB"))

/// The controller over fakes, with one desk window by default and feasibility passed.
@MainActor
final class TagHarness {
    let timeline = TagTimeline()
    let ax = FakeTagAX()
    let server = FakeTagServer()
    let button = FakeTagButton()
    let system: FakeTagSystem
    let windowing = FakeTagWindowing()
    let scheduler: FakeTagScheduler
    let actions = FakeTagActions()
    let observer: CodeWindowObserver
    let controller: DeskTagController
    var strips: [ReservedRegion] = [tagStrip]

    init(feasibility: DeskTagFeasibility = .passed, lab: DeskTagLabOptions = DeskTagLabOptions(),
         displays: [DeskTagDisplay] = [tagDisplay, tagSecondDisplay], coverMode: DeskTagCoverMode? = nil) {
        system = FakeTagSystem(displays: displays, primaryHeight: 1200)
        scheduler = FakeTagScheduler(timeline)
        let timeline = self.timeline
        observer = CodeWindowObserver(queue: FakeTagQueue(timeline), ax: ax, server: server, button: button,
                                      uptime: { timeline.now }, deliverToMain: { work in work() })
        weak var holder: TagHarness?
        controller = DeskTagController(observer: observer, actions: actions, system: system, windowing: windowing,
                                    scheduler: scheduler, button: button,
                                    stripRegions: { holder?.strips ?? [tagStrip] }, ownPID: 777,
                                    feasibility: feasibility, lab: lab, clock: tagClock, coverMode: coverMode)
        controller.dateNow = { tileNow }
        controller.homeDirectory = "/Users/alex"
        holder = self
        server.windows[tagWindowNumber] = tagWindow()
    }

    /// Started, block shown, settings default.
    func start(stripVisible: Bool = true) {
        controller.start()
        controller.setStripVisible(stripVisible)
        settle()
    }

    func settle() { timeline.drain() }

    func advance(_ seconds: TimeInterval) { timeline.advance(by: seconds) }

    /// One session on the desk in window 501.
    func desk(_ sessions: [CodeSessionSnapshot], windows: [DeskTagDeskWindow]? = nil) {
        let list = windows ?? sessions.enumerated().map { index, session in
            DeskTagDeskWindow(sessionID: session.id, pid: tagPID, windowNumber: tagWindowNumber + CGWindowID(index))
        }
        controller.update(sessions: sessions, deskWindows: list)
        settle()
    }

    func tag(_ id: String) -> DeskTagController.Tag? { controller.tags[id] }
    func panel(_ id: String) -> DeskTagPanel? { controller.tags[id]?.panel }
    func isShown(_ id: String) -> Bool {
        guard let panel = panel(id) else { return false }
        return windowing.isShown(panel.panel) && controller.tags[id]?.shownFrame != nil
    }

    /// The shown tag's frame in Quartz coordinates.
    func quartzFrame(_ id: String) -> CGRect? { controller.tags[id]?.shownLayout?.frame }

    /// Claude moves window `number` to `bounds` and posts the notification.
    func move(_ number: CGWindowID = tagWindowNumber, to bounds: CGRect, note: CodeWindowNotification = .moved) {
        server.windows[number]?.bounds = bounds
        ax.post(note, pid: tagPID)
        settle()
    }

    /// The point in the middle of a shown tag's pill `index`, AppKit screen coordinates.
    func pillCenter(_ id: String, _ index: Int = 0) -> CGPoint? {
        guard let panel = panel(id), panel.view.pillRects.indices.contains(index) else { return nil }
        let local = panel.view.pillRects[index]
        let inWindow = panel.view.convert(local, to: nil)
        let screen = panel.panel.convertToScreen(inWindow)
        return CGPoint(x: screen.midX, y: screen.midY)
    }

    /// A left click on pill `index` (mouse down and up inside, through the view's own handlers).
    func click(_ id: String, _ index: Int = 0) {
        guard let panel = panel(id), panel.view.pillRects.indices.contains(index) else { return }
        let rect = panel.view.pillRects[index]
        let point = panel.view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                              windowNumber: panel.panel.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                if type == .leftMouseDown { panel.view.mouseDown(with: event) } else { panel.view.mouseUp(with: event) }
            }
        }
        settle()
    }
}

/// A session snapshot for tags (on top of the block tests' `tileSession`).
func tagSession(_ id: String = "local_t1", _ headline: String = "Weather app · forecast refactor", index: Int = 1,
                state: CodeSessionState = .done, offers: [CodeOfferEntry] = [], earlierOffers: [CodeOfferEntry] = [],
                warnings: [CodeWarning] = [], dashboard: CodeDashboard? = nil, eta: CodeETA? = nil,
                progress: CodeProgress? = nil, workStartedAt: Date? = nil, results: [CodeResult] = [],
                place: CommandSessionFacts.Place = .local, sshHost: String? = nil) -> CodeSessionSnapshot {
    var session = tileSession(id, headline, index: index, state: state, offers: offers, place: place, sshHost: sshHost)
    session.earlierOffers = earlierOffers
    session.warnings = warnings
    session.dashboard = dashboard
    session.eta = eta
    session.progress = progress
    session.workStartedAt = workStartedAt
    session.results = results
    return session
}
