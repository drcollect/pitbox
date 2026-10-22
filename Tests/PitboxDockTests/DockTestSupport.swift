import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxDock

// MARK: Clock

/// A clock the test moves: `advance(by:)` runs every timer that falls due, in order, on its own queue (the main queue's
/// directly when called on the main thread). Time stands still otherwise, so no test waits for 1, 2, 5 or 15 s.
final class ManualDockClock: DockClock, @unchecked Sendable {
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
    private var time: TimeInterval
    private var entries: [Entry] = []
    private var nextID = 0

    init(start: TimeInterval = 100) { time = start }

    func now() -> TimeInterval { lock.withLock { time } }

    func after(_ delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> DockTimer {
        lock.withLock {
            nextID += 1
            let entry = Entry(id: nextID, deadline: time + max(delay, 0), queue: queue, work: work)
            entries.append(entry)
            return entry
        }
    }

    /// Moves the time without firing anything on the way, then fires every timer that is overdue, late (as after a
    /// sleep of the Mac, when timers stop).
    func jump(by delta: TimeInterval) {
        lock.withLock { time += delta }
        advance(by: 0)
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
            guard !next.isCancelled else { continue }
            if next.queue === DispatchQueue.main, Thread.isMainThread {
                next.work()
            } else {
                next.queue.sync(execute: next.work)
            }
        }
        lock.withLock { time = max(time, target) }
    }
}

// MARK: Folders and peers

/// A short private folder for the socket (`sun_path` holds 104 bytes), removed by `remove()` (tests call it in a
/// `defer`, so a failing test leaves nothing): inside the test run's app-support folder when scripts/test.sh set one
/// (removed with it, so even a killed run leaves nothing), else under /tmp.
struct DockTestFolder {
    let path: String

    init() throws {
        var template = Array((Self.parent + "/pbdock.XXXXXX").utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw SocketFailure.syscall("mkdtemp", errno)
        }
        path = String(cString: made)
    }

    var socketPath: String { path + "/dock.sock" }

    func remove() { try? FileManager.default.removeItem(atPath: path) }

    /// `PITBOX_APP_SUPPORT` when it is set, exists and is short enough for a socket path inside it; else /tmp.
    static var parent: String {
        guard let support = ProcessInfo.processInfo.environment["PITBOX_APP_SUPPORT"], support.hasPrefix("/"),
              support.utf8.count <= 48, FileManager.default.fileExists(atPath: support) else { return "/tmp" }
        return support
    }
}

/// Facts about a peer that passes every check by default: this user, a pid, inside an app bundle of this user, with
/// the test host's bundle id.
func passingFacts(pid: pid_t = getpid(), bundleID: String? = "com.example.host") -> DockPeerFacts {
    DockPeerFacts(uid: getuid(), pid: pid, started: ProcessAncestry.identity(of: pid)?.started ?? 1,
                  bundle: DockPeerBundle(bundleID: bundleID, bundleOwner: getuid(), executableOwner: getuid()))
}

/// An inspector that reports the facts the test sets (a test cannot be another user or an app bundle).
final class FakeInspector: DockPeerInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var facts: DockPeerFacts

    init(_ facts: DockPeerFacts = passingFacts()) { self.facts = facts }

    func set(_ new: DockPeerFacts) { lock.withLock { facts = new } }

    func inspect(_ fd: Int32) -> DockPeerFacts {
        lock.withLock { facts }
    }
}

/// The real uid and pid of the peer (`getpeereid`, `LOCAL_PEERPID`) with a made-up bundle of this user: for a real
/// child process that is not an app.
final class RealPeerFakeBundleInspector: DockPeerInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [DockPeerFacts] = []

    func inspect(_ fd: Int32) -> DockPeerFacts {
        let real = SystemPeerInspector().inspect(fd)
        var facts = real
        facts.bundle = DockPeerBundle(bundleID: "com.example.host", bundleOwner: getuid(), executableOwner: getuid())
        lock.withLock { seen.append(real) }
        return facts
    }

    var inspected: [DockPeerFacts] { lock.withLock { seen } }
}

@MainActor
final class FakeHostApps: DockHostApps {
    var running: Set<String>
    var onChange: (@MainActor () -> Void)?

    init(running: Set<String> = []) { self.running = running }

    func runningBundleIDs() -> Set<String> { running }

    func launch(_ bundleID: String) {
        running.insert(bundleID)
        onChange?()
    }

    func quit(_ bundleID: String) {
        running.remove(bundleID)
        onChange?()
    }
}

// MARK: Waiting

/// Polls `condition` on the main actor every 2 ms until it holds or `timeout` (real time) passes.
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}

// MARK: A fake host

/// A dock host made of one client socket in this process: it writes host lines and reads the guest's.
final class FakeHost {
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

    /// A fake host on an already connected socket (one end of a socket pair).
    init(adopting fd: Int32) {
        self.fd = fd
        POSIX.setNonBlocking(fd)
    }

    deinit { Darwin.close(fd) }

    /// Writes raw bytes, waiting (up to 2 s) while the socket is full.
    @discardableResult
    func sendRaw(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        let deadline = Date().addingTimeInterval(2)
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EAGAIN || errno == EINTR, Date() < deadline {
                var poll = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)]
                _ = POSIX.wait(&poll, timeout: 0.05)
                continue
            }
            return false
        }
        return true
    }

    @discardableResult
    func sendRaw(_ text: String) -> Bool { sendRaw(Array(text.utf8)) }

    @discardableResult
    func send(_ message: HostMessage) -> Bool { sendRaw(Array(DockWire.encode(message))) }

    static func hello(proto: ClosedRange<Int> = 1...1, features: Set<DockFeature> = DockFeature.all, app: String = "Host",
                      wakeWords: [String] = [], privateFolders: HostPrivateFolders = HostPrivateFolders()) -> HostMessage {
        .hello(DockHello(proto: proto, minor: 0, role: .host, app: app, build: "7", features: features,
                         wakeWords: wakeWords, privateFolders: privateFolders))
    }

    static func place(seq: Int = 1, live: Bool = false, visible: Bool = true, edge: Edge = .right,
                      host: CGRect = CGRect(x: 3533, y: 98, width: 1587, height: 1312)) -> HostPlace {
        HostPlace(seq: seq, displayID: 1, displayUUID: "UUID-1", edge: edge, host: host, visible: visible, level: .above,
                  live: live, cell: HostPlace.Cell(width: 301.4), maxWidth: 800)
    }

    @discardableResult
    func sendHello(proto: ClosedRange<Int> = 1...1, features: Set<DockFeature> = DockFeature.all, app: String = "Host",
                   wakeWords: [String] = [], privateFolders: HostPrivateFolders = HostPrivateFolders()) -> Bool {
        send(Self.hello(proto: proto, features: features, app: app, wakeWords: wakeWords, privateFolders: privateFolders))
    }

    /// The next complete line from the guest (nil on end of file or after `timeout`, real time).
    @MainActor
    func nextLine(timeout: TimeInterval = 2) async -> [UInt8]? {
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
            if count == 0 {
                sawEndOfFile = true
                continue
            }
            if errno != EAGAIN { sawEndOfFile = true; continue }
            if Date() > deadline { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// The next message from the guest (nil on end of file, timeout or a line that is not a guest message).
    @MainActor
    func next(timeout: TimeInterval = 2) async -> GuestMessage? {
        guard let line = await nextLine(timeout: timeout), let value = try? StrictJSON.parse(line),
              case .message(let message, _) = DockWire.decodeGuest(value) else { return nil }
        return message
    }

    /// The next message the filter accepts, skipping others (nil on end of file or timeout).
    @MainActor
    func next(timeout: TimeInterval = 2, where accept: (GuestMessage) -> Bool) async -> GuestMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let message = await next(timeout: deadline.timeIntervalSinceNow) else { return nil }
            if accept(message) { return message }
        }
        return nil
    }

    /// Reads (and drops) lines until the guest closes the socket. False after `timeout`.
    @MainActor
    func waitForClose(timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await nextLine(timeout: deadline.timeIntervalSinceNow) == nil, sawEndOfFile { return true }
        }
        return sawEndOfFile
    }

    /// The lines left before the end of file, decoded (unknown lines skipped).
    @MainActor
    func remainingMessages(timeout: TimeInterval = 2) async -> [GuestMessage] {
        var messages: [GuestMessage] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, let line = await nextLine(timeout: deadline.timeIntervalSinceNow) {
            if let value = try? StrictJSON.parse(line), case .message(let message, _) = DockWire.decodeGuest(value) {
                messages.append(message)
            }
        }
        return messages
    }
}

// MARK: A guest with its listener, wired to recorders

@MainActor
final class GuestHarness {
    let folder: DockTestFolder
    let clock: DockClock
    let inspector: DockPeerInspecting
    let listener: DockListener
    let apps: FakeHostApps
    let guest: DockGuest

    var places: [HostPlace?] = []
    var appearances: [DockAppearance] = []
    var focuses: [DockFocus] = []
    var folds: [Bool] = []
    var wakeWords: [[String]] = []
    var privateFolders: [HostPrivateFolders] = []
    /// What `onHostAnnouncement` received (the uncapped announcements).
    var announcements: [HostPrivateFolders] = []
    var states: [DockGuestState] = []

    init(clock: DockClock = SystemDockClock.shared, inspector: DockPeerInspecting = FakeInspector(),
         hosts: [String] = ["com.example.host"], running: Set<String> = [], enabled: Bool = true,
         features: Set<DockFeature> = DockFeature.all, bind: Bool = true) throws {
        let folder = try DockTestFolder()
        self.folder = folder
        self.clock = clock
        self.inspector = inspector
        // The home folder the folder rule measures from is an invented one.
        listener = DockListener(socketPath: folder.socketPath, inspector: inspector, clock: clock, ownUID: getuid(),
                                folderRule: DockFolderRule(home: "/Users/alex"))
        let configuration = DockGuest.Configuration(enabled: enabled, hosts: hosts, build: "test", features: features)
        if bind {
            do {
                try listener.bind(configuration: configuration)
            } catch {
                folder.remove()   // no harness, so no tearDown: the folder goes here
                throw error
            }
        }
        apps = FakeHostApps(running: running)
        guest = DockGuest(listener: listener, configuration: configuration, hostApps: apps, clock: clock)
        guest.onPlace = { [unowned self] in self.places.append($0) }
        guest.onAppearance = { [unowned self] in self.appearances.append($0) }
        guest.onFocus = { [unowned self] in self.focuses.append($0) }
        guest.onFold = { [unowned self] in self.folds.append($0) }
        guest.onHostWakeWords = { [unowned self] in self.wakeWords.append($0) }
        guest.onHostPrivateFolders = { [unowned self] in self.privateFolders.append($0) }
        guest.onHostAnnouncement = { [unowned self] in self.announcements.append($0) }
        guest.onStateChanged = { [unowned self] in self.states.append($0) }
    }

    func start() { guest.start() }

    var manualClock: ManualDockClock? { clock as? ManualDockClock }

    /// A fake host that connected and read the guest's `hello` (and sent its own unless `hello` is false).
    func connect(hello: Bool = true, proto: ClosedRange<Int> = 1...1, features: Set<DockFeature> = DockFeature.all,
                 app: String = "Host", wakeWords: [String] = [],
                 privateFolders: HostPrivateFolders = HostPrivateFolders()) async throws -> FakeHost {
        let host = try FakeHost(connectingTo: folder.socketPath)
        let first = await host.next()
        guard case .hello = first else { throw SocketFailure.syscall("no guest hello", 0) }
        if hello {
            host.sendHello(proto: proto, features: features, app: app, wakeWords: wakeWords, privateFolders: privateFolders)
            _ = await waitUntil { self.guest.isConnected }
        }
        return host
    }

    /// A fake host that is docked: hello, then `place`.
    func dock(features: Set<DockFeature> = DockFeature.all, place: HostPlace = FakeHost.place(),
              wakeWords: [String] = [], privateFolders: HostPrivateFolders = HostPrivateFolders()) async throws -> FakeHost {
        let host = try await connect(features: features, wakeWords: wakeWords, privateFolders: privateFolders)
        host.send(.place(place))
        _ = await waitUntil { self.guest.state.isDocked }
        return host
    }

    func tearDown() {
        guest.stop()
        folder.remove()
    }
}
