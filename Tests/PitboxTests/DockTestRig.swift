import AppKit
import Darwin
import Foundation
@testable import Pitbox
@testable import PitboxDock
import PitboxKit
import PitboxSessions
@testable import PitboxShell

// The app's dock wiring over fakes: a real socket in a short temporary folder, a fake host client in this process
// writing protocol lines, peer checks that pass (a test is not an app bundle), fake host apps, a manual clock, and a
// headless panel on off-screen test displays. Invented data only; the real dock.sock is never touched.

// MARK: Clock

/// A clock the test moves: `advance(by:)` runs the timers that fall due, in order (main-queue ones directly when called
/// on the main thread). Time stands still otherwise, so no test waits for 1, 2, 5 or 15 s.
final class ManualClock: DockClock, @unchecked Sendable {
    final class Entry: DockTimer, @unchecked Sendable {
        let id: Int
        let deadline: TimeInterval
        let queue: DispatchQueue
        let work: @Sendable () -> Void
        private let lock = NSLock()
        private var cancelled = false

        init(id: Int, deadline: TimeInterval, queue: DispatchQueue, work: @escaping @Sendable () -> Void) {
            self.id = id
            self.deadline = deadline
            self.queue = queue
            self.work = work
        }

        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    private let lock = NSLock()
    private var time: TimeInterval = 100
    private var entries: [Entry] = []
    private var nextID = 0

    func now() -> TimeInterval { lock.withLock { time } }

    func after(_ delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> DockTimer {
        lock.withLock {
            nextID += 1
            let entry = Entry(id: nextID, deadline: time + max(delay, 0), queue: queue, work: work)
            entries.append(entry)
            return entry
        }
    }

    func advance(by delta: TimeInterval) {
        let target = lock.withLock { time + delta }
        while true {
            let next: Entry? = lock.withLock {
                entries.removeAll { $0.isCancelled }
                let due = entries.filter { $0.deadline <= target + 1e-9 }
                guard let first = due.min(by: { ($0.deadline, $0.id) < ($1.deadline, $1.id) }) else { return nil }
                entries.removeAll { $0 === first }
                time = max(time, first.deadline)
                return first
            }
            guard let next else { break }
            if next.queue === DispatchQueue.main, Thread.isMainThread { next.work() } else { next.queue.sync(execute: next.work) }
        }
        lock.withLock { time = max(time, target) }
    }
}

// MARK: Peers, apps, folders

/// Peer facts that pass every check: this user, this process (with its real start time), inside an app bundle of this
/// user with the invented host's bundle id.
final class PassingInspector: DockPeerInspecting, @unchecked Sendable {
    func inspect(_ fd: Int32) -> DockPeerFacts {
        DockPeerFacts(uid: getuid(), pid: getpid(), started: ProcessAncestry.identity(of: getpid())?.started ?? 1,
                      bundle: DockPeerBundle(bundleID: DockFixture.hostID, bundleOwner: getuid(), executableOwner: getuid()))
    }
}

@MainActor
final class FakeApps: DockHostApps {
    var running: Set<String>
    var onChange: (@MainActor () -> Void)?

    init(running: Set<String>) { self.running = running }

    func runningBundleIDs() -> Set<String> { running }
}

/// A short private folder for the socket (`sun_path` holds 104 bytes): inside the test run's app-support folder when
/// scripts/test.sh set one (removed with it, so even a killed run leaves nothing), else under /tmp. Tests remove it
/// in a `defer`, so a failing test leaves nothing either.
struct ShortFolder {
    let path: String

    init() throws {
        var template = Array((Self.parent + "/pbwire.XXXXXX").utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw SocketFailure.syscall("mkdtemp", errno)
        }
        path = String(cString: made)
    }

    /// `PITBOX_APP_SUPPORT` when it is set, exists and is short enough for a socket path inside it; else /tmp.
    static var parent: String {
        guard let support = ProcessInfo.processInfo.environment["PITBOX_APP_SUPPORT"], support.hasPrefix("/"),
              support.utf8.count <= 48, FileManager.default.fileExists(atPath: support) else { return "/tmp" }
        return support
    }

    var socketPath: String { path + "/dock.sock" }

    var socketExists: Bool {
        var info = stat()
        return lstat(socketPath, &info) == 0
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

// MARK: A fake host

/// A dock host made of one client socket in this process: it writes host lines (plain JSON text, as a host app of its
/// own would) and reads the guest's.
@MainActor
final class TestHost {
    let fd: Int32
    private var buffer: [UInt8] = []
    private(set) var sawEndOfFile = false

    init(connectingTo path: String) throws {
        fd = try POSIX.makeSocket()
        let address = try POSIX.makeUnixAddress(path)
        guard POSIX.connect(fd, to: address) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketFailure.syscall("connect", code)
        }
        POSIX.setNonBlocking(fd)
    }

    isolated deinit { close() }

    private var closed = false

    /// End of file for the guest.
    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    /// Writes one line (a newline is added).
    @discardableResult
    func send(_ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        return bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == bytes.count
    }

    func hello(features: [String] = DockFixture.allFeatures, app: String = "Host", proto: String = "[1,1]",
               wakeWords: [String] = [], folders: [String] = [], socketFolders: [String] = []) {
        let list = { (words: [String]) in "[" + words.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        let fields = [#""t":"hello","proto":\#(proto),"minor":0,"role":"host","app":"\#(app)","build":"7""#,
                      #""features":\#(list(features)),"wakeWords":\#(list(wakeWords))"#,
                      #""private":{"folders":\#(list(folders)),"socketFolders":\#(list(socketFolders))}"#]
        send("{" + fields.joined(separator: ",") + "}")
    }

    func place(seq: Int, visible: Bool = true, live: Bool = false, level: String = "above", edge: String = "right",
               host: CGRect = DockFixture.hostFrame) {
        let frame = #"{"x":\#(Int(host.minX)),"y":\#(Int(host.minY)),"w":\#(Int(host.width)),"h":\#(Int(host.height))}"#
        let fields = [#""t":"place","seq":\#(seq),"displayID":12,"displayUUID":"BBBB-ULTRAWIDE","edge":"\#(edge)""#,
                      #""host":\#(frame),"visible":\#(visible),"level":"\#(level)","live":\#(live)"#,
                      #""cell":{"width":301.4,"gutter":12,"padding":16,"row":69},"maxWidth":800"#]
        send("{" + fields.joined(separator: ",") + "}")
    }

    /// The next message from the guest (nil on end of file or after `timeout`, real time: a ceiling that only a
    /// missing message reaches).
    func next(timeout: TimeInterval = 5) async -> GuestMessage? {
        guard let line = await nextLine(timeout: timeout), let value = try? StrictJSON.parse(line),
              case .message(let message, _) = DockWire.decodeGuest(value) else { return nil }
        return message
    }

    /// The next message the filter accepts, skipping others (nil on end of file or timeout).
    func next(timeout: TimeInterval = 5, where accept: (GuestMessage) -> Bool) async -> GuestMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let message = await next(timeout: deadline.timeIntervalSinceNow) else { return nil }
            if accept(message) { return message }
        }
        return nil
    }

    /// Every message that arrives within `timeout` (real time).
    func drain(timeout: TimeInterval = 0.15) async -> [GuestMessage] {
        var seen: [GuestMessage] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, let message = await next(timeout: max(0, deadline.timeIntervalSinceNow)) {
            seen.append(message)
        }
        return seen
    }

    /// Reads (and drops) lines until the guest closes the socket. False after `timeout`.
    func waitForClose(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await nextLine(timeout: deadline.timeIntervalSinceNow) == nil, sawEndOfFile { return true }
        }
        return sawEndOfFile
    }

    private func nextLine(timeout: TimeInterval) async -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            if sawEndOfFile { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { POSIX.read(fd, into: $0) }
            if count > 0 {
                buffer.append(contentsOf: chunk[..<count])
                continue
            }
            if count == 0 || errno != EAGAIN {
                sawEndOfFile = true
                continue
            }
            if Date() > deadline { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

// MARK: The app's wiring over the fakes

/// The invented host and the off-screen geometry the tests use.
enum DockFixture {
    static let hostID = "com.example.host"
    /// Every feature of dock protocol 1.0, as a host offers them in its `hello`.
    static let allFeatures = ["appearance", "attention", "focus", "fold", "guard.claims", "speech"]
    static let primaryHeight: CGFloat = 1440
    /// A 1512 × 982 display far off screen (x 20000): menu bar 33 pt, Dock 70 pt.
    static let notebook = BlockDisplay(displayID: 11, uuid: "AAAA-NOTEBOOK", name: "Built-in Display",
                                       frame: CGRect(x: 20000, y: 0, width: 1512, height: 982),
                                       visibleFrame: CGRect(x: 20000, y: 70, width: 1512, height: 879), isMain: true)
    /// Where the block stands alone at the right edge of `notebook` (two 323 pt columns).
    static let aloneFrame = CGRect(x: 20822, y: 70, width: 690, height: 879)
    /// The host's strip (far off screen, on the right edge of its display).
    static let hostFrame = CGRect(x: 23533, y: 98, width: 1587, height: 1312)
    /// Beside `hostFrame` on its window side (two columns of the host's 301.4 pt cell: 631 pt).
    static let dockedFrame = CGRect(x: 22902, y: 98, width: 631, height: 1312)
}

/// A `DockWiring` as the app makes it, over a temporary socket and fakes, driving a headless panel and recording what
/// reaches the block, the sandbox memory and the menu.
@MainActor
final class DockRig {

    let folder: ShortFolder
    let clock = ManualClock()
    let apps: FakeApps
    let wiring: DockWiring
    let panel: BlockPanelController

    private(set) var shows = 0
    /// Where the panel was placed when it was first shown (no jump: docked when a host placed it in time).
    private(set) var placementAtFirstShow: BlockPlacement?
    private(set) var focuses: [String?] = []
    private(set) var wakeWords: [Set<String>] = []
    private(set) var remembered: [(folders: [String], socketFolders: [String])] = []
    private(set) var stateChanges = 0
    /// Every `folded` the link asked the app to write.
    private(set) var persistedFolds: [Bool] = []

    init(enabled: Bool = true, hosts: [String] = [DockFixture.hostID], running: Set<String> = [], bind: Bool = true) throws {
        folder = try ShortFolder()
        apps = FakeApps(running: running)
        let path = folder.socketPath
        let clock = clock
        let apps = apps
        let factory = DockWiring.Factory(
            listener: {
                DockListener(socketPath: path, inspector: PassingInspector(), clock: clock, ownUID: getuid(),
                             folderRule: DockFolderRule(home: "/Users/alex"))
            },
            guest: { listener, configuration in
                DockGuest(listener: listener, configuration: configuration, hostApps: apps, clock: clock)
            },
            after: { delay, work in
                let timer = clock.after(delay, on: .main) { MainActor.assumeIsolated { work() } }
                return { timer.cancel() }
            })
        wiring = DockWiring(factory: factory, build: "test")
        wiring.primaryHeight = { DockFixture.primaryHeight }
        panel = BlockPanelController(settings: BlockSettings())
        panel.isHeadless = true
        panel.displayProvider = { [DockFixture.notebook] }
        panel.primaryHeightProvider = { DockFixture.primaryHeight }
        // As the app wires the panel (PitboxApp.wirePanel): the area and the alone override reach the link.
        panel.onAreaChanged = { [weak wiring] _, _, _ in wiring?.panelAreaChanged() }
        panel.onAloneOverrideChanged = { [weak wiring] on in wiring?.aloneOverrideChanged(on) }
        if bind { wiring.bind(CodeSettings.Dock(enabled: enabled, hosts: hosts)) }
    }

    var targets: DockWiring.Targets {
        DockWiring.Targets(setFocus: { [weak self] in self?.focuses.append($0) },
                           setHostWakeWords: { [weak self] in self?.wakeWords.append($0) },
                           rememberPrivateFolders: { [weak self] in self?.remembered.append(($0, $1)) },
                           stateChanged: { [weak self] in self?.stateChanges += 1 },
                           persistFolded: { [weak self] in self?.persistedFolds.append($0) })
    }

    /// The app is wired: the link starts; the first placement shows the panel.
    func start() {
        wiring.start(panel: panel, targets: targets, whenPlaced: { [weak self] in
            guard let self else { return }
            if self.shows == 0 { self.placementAtFirstShow = self.panel.placement }
            self.shows += 1
            self.panel.show()
        })
    }

    /// A fake host that connected and read the guest's `hello` (and sent its own).
    func connect(features: [String] = DockFixture.allFeatures, app: String = "Host", wakeWords: [String] = [],
                 folders: [String] = [], socketFolders: [String] = []) async throws -> TestHost {
        let host = try TestHost(connectingTo: folder.socketPath)
        guard case .hello = await host.next() else { throw SocketFailure.syscall("no guest hello", 0) }
        host.hello(features: features, app: app, wakeWords: wakeWords, folders: folders, socketFolders: socketFolders)
        _ = await eventually(10) { self.wiring.guest?.isConnected == true }
        return host
    }

    /// A fake host that is docked: hello, then `place` (seq 1), and the guest's `area` for it read.
    func dock(features: [String] = DockFixture.allFeatures, wakeWords: [String] = []) async throws -> TestHost {
        let host = try await connect(features: features, wakeWords: wakeWords)
        host.place(seq: 1)
        _ = await host.next { if case .area = $0 { return true } else { return false } }
        return host
    }

    func tearDown() {
        wiring.stop()
        panel.invalidate()
        folder.remove()
    }
}
