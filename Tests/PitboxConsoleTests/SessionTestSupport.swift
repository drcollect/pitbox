import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// A process that does nothing by itself: tests feed it output and end it by hand.
final class FakeProcess: TerminalProcess {
    private static var counter: pid_t = 20_000
    let pid: pid_t
    var onOutput: (([UInt8]) -> Void)?
    var onExit: ((ProcessExit) -> Void)?
    private(set) var isRunning = true
    private(set) var written: [UInt8] = []
    private(set) var resizes: [TerminalSize] = []
    private(set) var terminateCount = 0
    private(set) var hangUpCount = 0
    /// What `inspect()` answers; nil means "nothing known".
    var info: ForegroundInfo?
    let spec: LaunchSpec

    init(spec: LaunchSpec) {
        Self.counter += 1
        pid = Self.counter
        self.spec = spec
        info = ForegroundInfo(pgid: pid, name: spec.shellName, isSessionLeader: true, cwd: spec.cwd)
    }

    var writtenText: String { String(decoding: written, as: UTF8.self) }

    func write(_ bytes: [UInt8]) { written += bytes }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        resizes.append(TerminalSize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight))
    }
    func terminate() { terminateCount += 1 }
    func hangUp() { hangUpCount += 1 }
    func inspect() -> ForegroundInfo? { isRunning ? info : nil }

    /// The program prints `text`.
    func emit(_ text: String) { onOutput?(Array(text.utf8)) }
    /// The process ends.
    func end(_ status: ProcessExit = .exited(0)) {
        isRunning = false
        onExit?(status)
    }
    /// A job runs in the foreground of the shell.
    func runJob(named name: String) { info = ForegroundInfo(pgid: pid + 1000, name: name, isSessionLeader: false, cwd: info?.cwd) }
    func idle() { info = ForegroundInfo(pgid: pid, name: spec.shellName, isSessionLeader: true, cwd: info?.cwd) }
    func changeDirectory(_ path: String) { info?.cwd = path }
}

@MainActor
final class FakeLauncher {
    private(set) var processes: [FakeProcess] = []
    private(set) var sizes: [TerminalSize] = []
    var failWith: Error?

    var launch: ProcessLauncher {
        { [unowned self] spec, size in
            if let failWith { throw failWith }
            let process = FakeProcess(spec: spec)
            processes.append(process)
            sizes.append(size)
            return process
        }
    }
}

/// Time under the test's control.
final class ManualClock: TerminalClock {
    private struct Entry { var due: Date; var id: Int; var block: () -> Void }
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)
    private var entries: [Entry] = []
    private var counter = 0
    private(set) var pendingCount = 0

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> ClockToken {
        counter += 1
        let id = counter
        entries.append(Entry(due: now.addingTimeInterval(max(0, delay)), id: id, block: block))
        pendingCount = entries.count
        return ClockToken { [weak self] in
            self?.entries.removeAll { $0.id == id }
            self?.pendingCount = self?.entries.count ?? 0
        }
    }

    /// Moves time forward, running every block that comes due, in order (blocks may schedule more).
    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = entries.filter({ $0.due <= target }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            entries.removeAll { $0.id == next.id }
            now = max(now, next.due)
            next.block()
        }
        now = target
        pendingCount = entries.count
    }
}

/// A manager over fakes, with its settings from `settingsJSON` and its state in a private folder.
@MainActor
final class ManagerHarness {
    let dir = TempDir()
    let clock = ManualClock()
    let launcher = FakeLauncher()
    let manager: TerminalSessionManager
    var dark = true
    private(set) var links: [LinkPolicy.Action] = []
    private(set) var clipboard: [String] = []
    var stateFile: URL { dir.paths.stateFile }
    var changes = 0

    /// `mode: .terminal` (the default here) is the plain-shell behaviour the terminal's own tests cover; `.pitbox` is
    /// the app's.
    init(settingsJSON: String? = nil, saved: SavedState? = nil, size: CGSize? = CGSize(width: 800, height: 500),
         start: Bool = true, directories: Set<String> = ["/Users/tester", "/tmp", "/Users/tester/proj", "/Users/tester/gone-not"],
         mode: ConsoleMode = .terminal) {
        if let saved { saved.save(to: dir.paths.stateFile) }
        var box: ManagerHarness?
        manager = TerminalSessionManager(TerminalSessionManager.Dependencies(
            settings: testSettings(settingsJSON), environment: fixtureEnvironment(directories: directories), launcher: launcher.launch,
            stateFile: dir.paths.stateFile, clock: clock,
            performLink: { box?.links.append($0) }, setClipboard: { box?.clipboard.append($0) },
            isDarkAppearance: { box?.dark ?? true }, mode: mode))
        box = self
        manager.onChange = { [unowned self] in changes += 1 }
        if let size { manager.setContentSize(size) }
        if start { manager.startIfNeeded() }
    }

    var titles: [String] { manager.sessions.map(\.title) }
    var ids: [String] { manager.sessions.map(\.preset.id) }
    var selectedIndex: Int? { manager.selectedIndex }
    var processes: [FakeProcess] { launcher.processes }
}

/// Everything the terminal shows, as text (scrollback included).
@MainActor
func screenText(_ view: ConsoleTerminalView) -> String {
    String(decoding: view.terminal.getBufferAsData(), as: UTF8.self)
}

func presetJSON(_ extra: String = "", onExit: String = "closeIfClean", more: String = "") -> String {
    """
    { "onExit": "\(onExit)", \(more) "presets": [ {"id":"shell","name":"Shell"},
      {"id":"claude","name":"Claude","argv":["claude"],"cwd":"~/proj"},
      {"id":"top","name":"Top","script":"top"},
      {"id":"off","name":"Off","argv":["x"],"enabled":false}, {"id":"once","name":"Once","argv":["y"],"restore":false} \(extra) ] }
    """
}
