import CoreGraphics
import Foundation
import PitboxKit
@testable import PitboxSessions

// Fakes for every system call of the window join and the parker: no test touches a real window or Accessibility.

/// A manual queue with virtual time: `async` and `after` only record; `run(for:)` runs what is due, jumping the clock to
/// each next item.
final class WindowsTestQueue: CodeWorkQueue, @unchecked Sendable {
    private(set) var now: TimeInterval = 1_000
    private var items: [(due: TimeInterval, seq: Int, work: () -> Void)] = []
    private var seq = 0

    func async(_ work: @escaping () -> Void) {
        seq += 1
        items.append((now, seq, work))
    }

    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        seq += 1
        items.append((now + max(0, seconds), seq, work))
    }

    /// Runs every item due within `limit` seconds of virtual time.
    func run(for limit: TimeInterval = 30) {
        let end = now + limit
        while let next = items.min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }), next.due <= end {
            items.removeAll { $0.seq == next.seq }
            if next.due > now { now = next.due }
            next.work()
        }
    }

    var pending: Int { items.count }

    /// Moves the clock on by `seconds`, running what falls due on the way.
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        run(for: seconds)
        now = max(now, target)
    }
}

/// One fake window of a fake Claude process.
struct WindowsTestWindow {
    var pid: pid_t
    var number: CGWindowID
    var title: String?
    var frame: CGRect
    var layer = 0
    var onScreen = true
    var minimized = false
    /// False: another Space (or hidden by Claude): AX does not list it.
    var visibleToAX = true
    /// False: the window server dropped it.
    var inServerList = true
    var role = "AXWindow"
}

/// The world behind the fake window server and the fake AX.
final class WindowsTestWorld: @unchecked Sendable {
    var windows: [CGWindowID: WindowsTestWindow] = [:]
    var trusted = true
    var getWindowWorks = true
    /// This many minimize calls change nothing (Claude did not answer) before one takes.
    var minimizeIgnoredCalls = 0
    var restoreIgnoredCalls = 0
    /// Claude hides the window instead of minimizing it (a case to watch for).
    var hideInsteadOfMinimize = false
    var focused: [pid_t: CGWindowID] = [:]
    var frontmostWorks = true
    var failInfo: Set<CGWindowID> = []
    /// Every call that changes something or reads titles, in order ("minimize 11", "frame 11 …").
    var calls: [String] = []
    var infoReads = 0

    func add(_ window: WindowsTestWindow) { windows[window.number] = window }
}

final class WindowsTestServer: CodeWindowServer {
    let world: WindowsTestWorld
    init(_ world: WindowsTestWorld) { self.world = world }

    func windows(ofPIDs pids: Set<pid_t>) -> [CodeServerWindow] {
        world.windows.values.filter { pids.contains($0.pid) && $0.inServerList }.sorted { $0.number < $1.number }.map(Self.server)
    }

    func window(number: CGWindowID) -> CodeServerWindow? {
        guard let window = world.windows[number], window.inServerList else { return nil }
        return Self.server(window)
    }

    static func server(_ w: WindowsTestWindow) -> CodeServerWindow {
        CodeServerWindow(number: w.number, pid: w.pid, bounds: w.frame, layer: w.layer, isOnScreen: w.onScreen)
    }
}

final class WindowsTestAX: CodeAccessibility {
    let world: WindowsTestWorld
    init(_ world: WindowsTestWorld) { self.world = world }

    static func element(_ number: CGWindowID) -> CodeAXElement { CodeAXElement(raw: NSNumber(value: number)) }
    private func number(_ element: CodeAXElement) -> CGWindowID? { (element.raw as? NSNumber)?.uint32Value }
    private func window(_ element: CodeAXElement) -> WindowsTestWindow? { number(element).flatMap { world.windows[$0] } }

    func isTrusted() -> Bool { world.trusted }

    func windows(ofPID pid: pid_t) -> Result<[CodeAXElement], CodeAXFailure> {
        guard world.trusted else { return .failure(.apiDisabled) }
        return .success(world.windows.values.filter { $0.pid == pid && $0.visibleToAX }.sorted { $0.number < $1.number }
            .map { Self.element($0.number) })
    }

    func info(of element: CodeAXElement) -> Result<CodeAXWindowInfo, CodeAXFailure> {
        world.infoReads += 1
        guard let window = window(element) else { return .failure(.invalidElement) }
        if world.failInfo.contains(window.number) { return .failure(.cannotComplete) }
        return .success(CodeAXWindowInfo(title: window.title, frame: window.frame, minimized: window.minimized, role: window.role))
    }

    func isMinimized(_ element: CodeAXElement) -> Result<Bool, CodeAXFailure> {
        guard let window = window(element) else { return .failure(.invalidElement) }
        return .success(window.minimized)
    }

    func windowNumber(of element: CodeAXElement) -> CGWindowID? {
        world.getWindowWorks ? number(element).flatMap { world.windows[$0] != nil ? $0 : nil } : nil
    }

    func setMinimized(_ minimized: Bool, of element: CodeAXElement) -> CodeAXFailure? {
        guard let number = number(element), var window = world.windows[number] else { return .invalidElement }
        world.calls.append(minimized ? "minimize \(number)" : "unminimize \(number)")
        if minimized {
            if world.minimizeIgnoredCalls > 0 { world.minimizeIgnoredCalls -= 1; return nil }
            if world.hideInsteadOfMinimize {
                window.onScreen = false
            } else {
                window.minimized = true
                window.onScreen = false
            }
        } else {
            if world.restoreIgnoredCalls > 0 { world.restoreIgnoredCalls -= 1; return nil }
            if window.minimized { window.minimized = false; window.onScreen = true; window.inServerList = true }
        }
        world.windows[number] = window
        return nil
    }

    func setFrame(_ frame: CGRect, of element: CodeAXElement) -> CodeAXFailure? {
        guard let number = number(element), world.windows[number] != nil else { return .invalidElement }
        world.calls.append("frame \(number) \(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
        world.windows[number]?.frame = frame
        return nil
    }

    func raise(_ element: CodeAXElement) -> CodeAXFailure? {
        guard let number = number(element) else { return .invalidElement }
        world.calls.append("raise \(number)")
        return nil
    }

    func setMain(_ element: CodeAXElement) -> CodeAXFailure? {
        guard let number = number(element) else { return .invalidElement }
        world.calls.append("main \(number)")
        return nil
    }

    func focusedWindow(ofPID pid: pid_t) -> Result<CodeAXElement?, CodeAXFailure> {
        guard world.trusted else { return .failure(.apiDisabled) }
        return .success(world.focused[pid].map(Self.element))
    }

    func setFrontmost(pid: pid_t) -> Bool {
        world.calls.append("frontmost \(pid)")
        return world.frontmostWorks
    }

    func forget(pid: pid_t) {}
}

/// What the data side would hand the parker: the running processes, and the last sessions (so a pass can resend them).
@MainActor
final class WindowsTestProcesses {
    var list: [ClaudeProcessInfo] = []
    var sessions: [CodeSessionSnapshot] = []
}

final class WindowsTestWorkspace: CodeWorkspace, @unchecked Sendable {
    var frontmost: pid_t?
    var activations: [pid_t] = []
    var opened: [(url: URL, app: URL)] = []
    var openSucceeds = true
    /// Processes whose app is hidden (⌘H).
    var hidden: Set<pid_t> = []

    @MainActor func frontmostPID() -> pid_t? { frontmost }

    @MainActor func isHidden(pid: pid_t) -> Bool { hidden.contains(pid) }

    /// Processes that ended (Claude quit or relaunched).
    var ended: Set<pid_t> = []
    func isClaudeRunning(pid: pid_t) -> Bool { !ended.contains(pid) }

    func activate(pid: pid_t) -> Bool {
        activations.append(pid)
        return true
    }

    func open(_ url: URL, withApplicationAt appURL: URL, done: @escaping @Sendable (Bool) -> Void) {
        opened.append((url, appURL))
        done(openSucceeds)
    }
}

@MainActor
final class WindowsTestScreens: CodeScreens {
    /// One 5120 × 1440 display (The user's), menu bar 30 pt, Dock 98 pt.
    var list = [CodeDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 5120, height: 1440),
                            visibleFrame: CGRect(x: 0, y: 30, width: 5120, height: 1312))]
    func displays() -> [CodeDisplay] { list }
}

/// Everything a parker test needs.
@MainActor
struct WindowsHarness {
    let world: WindowsTestWorld
    let queue: WindowsTestQueue
    let processes: WindowsTestProcesses
    let workspace: WindowsTestWorkspace
    let screens: WindowsTestScreens
    let folder: URL
    let store: CodeParkedRecordStore
    let clock: WindowsTestClock
    let ticker: WindowsTestTicker
    let parker: CodeWindowParker

    static let pidA: pid_t = 501
    static let pidC: pid_t = 777
    /// Made-up app paths (copy A runs from a launcher copy, never /Applications); nothing is read there.
    static let appPathA = "/private/tmp/cm-tests/Claude Launchers/Apps/a/Claude.app"
    static let appPathC = "/private/tmp/cm-tests/Claude Launchers/Apps/c/Claude.app"
    static let appA = URL(fileURLWithPath: appPathA)
    /// The strip at the right edge of the user's display (Quartz).
    static let strip = [ReservedRegion(displayID: 1, rect: CGRect(x: 4096, y: 30, width: 1024, height: 1312), edge: .right)]

    /// A parker over fakes. `folder` holds `code-monitors.json` (a new temporary folder by default; pass the same one to
    /// play a restart).
    init(folder: URL? = nil) {
        let world = WindowsTestWorld(), queue = WindowsTestQueue(), processes = WindowsTestProcesses()
        let workspace = WindowsTestWorkspace(), screens = WindowsTestScreens(), clock = WindowsTestClock()
        let ticker = WindowsTestTicker()
        let dir = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("cm-parker-\(UUID().uuidString)")
        let store = CodeParkedRecordStore(url: dir.appendingPathComponent("code-monitors.json"))
        let regions = Self.strip
        self.world = world; self.queue = queue; self.processes = processes; self.workspace = workspace
        self.screens = screens; self.clock = clock; self.ticker = ticker; self.folder = dir; self.store = store
        parker = CodeWindowParker(server: WindowsTestServer(world), ax: WindowsTestAX(world),
                                  workspace: workspace, screens: screens, queue: queue, store: store,
                                  clock: { clock.now }, uptime: { queue.now }, stripRegions: { regions },
                                  deliver: { work in work() }, startTicker: { tick in ticker.start(tick) })
        processes.list = [ClaudeProcessInfo(pid: Self.pidA, profile: .a, bundlePath: Self.appPathA)]
    }

    /// Hands the sessions (and the current processes) to the parker and runs the queue (a pass included).
    func update(_ sessions: [CodeSessionSnapshot]) {
        processes.sessions = sessions
        parker.update(sessions: sessions, processes: processes.list)
        queue.run()
    }

    /// One pass with the current processes, then everything it scheduled.
    func pass() {
        parker.update(sessions: processes.sessions, processes: processes.list)
        parker.requestPass()
        queue.run()
    }

    func status(_ id: String) -> CodeWindowStatus? { parker.statuses[id] }
    func place(_ id: String) -> CodeWindowPlace? { parker.statuses[id]?.place }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

final class WindowsTestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_792_000_000)
}

@MainActor
final class WindowsTestTicker {
    private(set) var tick: (@MainActor () -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0

    func start(_ tick: @escaping @MainActor () -> Void) -> (() -> Void) {
        self.tick = tick
        starts += 1
        return { [weak self] in
            MainActor.assumeIsolated {
                self?.stops += 1
                self?.tick = nil
            }
        }
    }

    var isRunning: Bool { tick != nil }
}

/// A session snapshot for window tests.
func windowSession(_ id: String, title: String, profile: CodeProfile = .a, index: Int = 1, previous: [String] = [],
                   popout: CGRect? = CGRect(x: 100, y: 100, width: 900, height: 700), state: CodeSessionState = .working)
    -> CodeSessionSnapshot {
    CodeSessionSnapshot(id: id, index: index, profile: profile, headline: title, title: title, previousTitles: previous,
                        place: .local, state: state, popout: popout.map { CodePopoutHint(bounds: $0) })
}
