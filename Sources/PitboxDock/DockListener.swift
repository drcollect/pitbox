import Darwin
import Foundation
import PitboxKit

/// Why the dock socket could not be bound.
public enum DockListenerError: Error, Equatable, Sendable {
    /// The socket's folder is not a private folder of yours (not a folder, a symlink, or someone else's).
    case unsafeFolder
    /// A live listener answers on the socket (another copy of the app): it is never removed.
    case inUse
    /// Something other than a socket sits at the socket's path: it is never removed.
    case notASocket
    /// The path does not fit a Unix socket address (104 bytes).
    case pathTooLong
    /// A system call failed (name and errno).
    case failed(String, Int32)
}

/// The guest's end of the dock link: the one Unix socket a dock host connects to (docs/DOCK_PROTOCOL.md "Transport").
///
/// The app binds it first thing at launch, right after its single-instance lock and before any window
/// (`bind(configuration:)`), and it **accepts at once**: a host that connects while the app is still starting gets its
/// `hello` within the handshake time, and the verified link waits, its events held, until the guest is wired
/// (`DockGuest.start()` takes it over). For each connection the listener checks the peer (same user, a start time, an
/// app bundle owned by you or root, a bundle id in `dock.hosts`), keeps one host at a time (a second one gets `busy` and
/// is closed), refuses everything while docking is off (`bye` with `settings`), and hands a verified connection to a
/// `DockSession`.
///
/// The socket is created under a temporary name in the private folder, set to 0600, then renamed to `dock.sock`, so the
/// name never shows a wider mode. A leftover `dock.sock` is removed only after a connect to it failed (no live listener);
/// a live one, or anything that is not a socket, is never removed. `stop()` removes the socket only while it is still
/// the one this listener bound. All work runs on the listener's own queue with a dispatch source on a non-blocking
/// socket; no call waits.
public final class DockListener: @unchecked Sendable {
    /// The socket's path.
    public let socketPath: String
    private let inspector: DockPeerInspecting
    private let clock: DockClock
    private let ownUID: uid_t
    private let folderRule: DockFolderRule
    private let queue = DispatchQueue(label: "pitbox.dock.listener")
    private let lock = NSLock()

    // Under `lock`.
    private var allowed: [String] = []
    private var enabled = true
    private var hello = DockGuestHello(build: "0", features: DockFeature.all)
    private var listenFD: Int32 = -1
    private var boundFile: (dev: dev_t, ino: ino_t)?
    private var source: DispatchSourceRead?
    private var active: DockSession?
    private var nextSessionID = 1
    private var stopped = false
    private var sessionHandler: (@Sendable (DockSession) -> Void)?
    private var refusalHandler: (@Sendable (DockRefusal) -> Void)?
    /// A verified session accepted before the guest was wired, waiting to be taken over.
    private var pending: DockSession?
    /// The last refusal before the guest was wired.
    private var pendingRefusal: DockRefusal?

    /// A listener for `socketPath` (default: `dock.sock` in the app's private folder). Nothing happens before `bind`.
    public convenience init(socketPath: String = Paths.dockSocketPath) {
        self.init(socketPath: socketPath, inspector: SystemPeerInspector(), clock: SystemDockClock.shared, ownUID: getuid())
    }

    init(socketPath: String, inspector: DockPeerInspecting, clock: DockClock, ownUID: uid_t,
         folderRule: DockFolderRule = DockFolderRule()) {
        self.socketPath = socketPath
        self.inspector = inspector
        self.clock = clock
        self.ownUID = ownUID
        self.folderRule = folderRule
    }

    deinit {
        let (reader, fd) = lock.withLock { (source, listenFD) }
        if let reader { reader.cancel() } else if fd >= 0 { Darwin.close(fd) }
    }

    /// True once `bind(configuration:)` succeeded and until `stop()`.
    public var isBound: Bool { lock.withLock { listenFD >= 0 } }

    /// The bundle ids allowed to dock (`dock.hosts`). A change applies to the next connection; the guest closes a
    /// connected host that is no longer listed.
    var allowedHosts: [String] {
        get { lock.withLock { allowed } }
        set { lock.withLock { allowed = newValue } }
    }

    /// False while the user turned docking off: every connection gets `bye` with `settings` and is closed.
    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// The settings and the `hello` for the next connections.
    func update(_ configuration: DockGuest.Configuration) {
        lock.withLock {
            allowed = configuration.hosts
            enabled = configuration.enabled
            hello = DockGuestHello(build: configuration.build, features: configuration.features)
        }
    }

    // MARK: Bind

    /// Binds and starts accepting with the app's dock settings (`dock.enabled`, `dock.hosts`, the build): the folder
    /// is made private (0700, yours), a leftover socket without a live listener is removed, the new socket is 0600.
    /// Throws without touching a live socket or a file that is not a socket. Pass the same configuration to the
    /// `DockGuest` later.
    public func bind(configuration: DockGuest.Configuration) throws {
        guard !isBound else { return }
        update(configuration)
        let folder = (socketPath as NSString).deletingLastPathComponent
        try preparePrivateFolder(folder)
        let address: sockaddr_un
        do { address = try POSIX.makeUnixAddress(socketPath) } catch { throw DockListenerError.pathTooLong }
        try removeStaleSocket(address)

        // Created under a private temporary name (mode 0600 set before it gets its real name), then renamed.
        let temporary = folder + "/.dock-\(getpid())"
        let temporaryAddress: sockaddr_un
        do { temporaryAddress = try POSIX.makeUnixAddress(temporary) } catch { throw DockListenerError.pathTooLong }
        unlink(temporary)
        let fd: Int32
        do { fd = try POSIX.makeSocket() } catch { throw DockListenerError.failed("socket", errno) }
        func fail(_ call: String, _ code: Int32) -> DockListenerError {
            Darwin.close(fd)
            unlink(temporary)
            return code == EADDRINUSE ? .inUse : .failed(call, code)
        }
        guard POSIX.bind(fd, to: temporaryAddress) == 0 else { throw fail("bind", errno) }
        guard chmod(temporary, 0o600) == 0 else { throw fail("chmod", errno) }
        guard listen(fd, 8) == 0 else { throw fail("listen", errno) }
        guard rename(temporary, socketPath) == 0 else { throw fail("rename", errno) }
        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw DockListenerError.failed("lstat", code)
        }
        POSIX.setNonBlocking(fd)
        lock.withLock {
            listenFD = fd
            boundFile = (info.st_dev, info.st_ino)
            stopped = false
        }
        Log.info("dock: listening", "dock")
        beginAccepting(fd)
    }

    private func preparePrivateFolder(_ folder: String) throws {
        if mkdir(folder, 0o700) != 0, errno != EEXIST { throw DockListenerError.failed("mkdir", errno) }
        var info = stat()
        guard lstat(folder, &info) == 0, POSIX.fileType(info.st_mode) == mode_t(S_IFDIR), info.st_uid == ownUID else {
            throw DockListenerError.unsafeFolder
        }
        if info.st_mode & 0o777 != 0o700, chmod(folder, 0o700) != 0 { throw DockListenerError.unsafeFolder }
    }

    /// Removes a socket at the path only when nothing listens on it.
    private func removeStaleSocket(_ address: sockaddr_un) throws {
        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            if errno == ENOENT { return }
            throw DockListenerError.failed("lstat", errno)
        }
        guard POSIX.fileType(info.st_mode) == mode_t(S_IFSOCK) else { throw DockListenerError.notASocket }
        guard let probe = try? POSIX.makeSocket() else { throw DockListenerError.failed("socket", errno) }
        defer { Darwin.close(probe) }
        POSIX.setNonBlocking(probe)
        if POSIX.connect(probe, to: address) == 0 { throw DockListenerError.inUse }
        let code = errno
        // A full backlog (EAGAIN) or a connect in progress means a live listener too.
        guard code == ECONNREFUSED || code == ENOENT else { throw DockListenerError.inUse }
        unlink(socketPath)
        Log.info("dock: stale socket removed", "dock")
    }

    // MARK: Accept

    private func beginAccepting(_ fd: Int32) {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        lock.withLock { source = reader }
        reader.setEventHandler { [weak self] in self?.acceptAll(fd: fd) }
        reader.setCancelHandler { Darwin.close(fd) }
        reader.resume()
    }

    /// The guest is wired: verified sessions go to `onSession` (on the listener's queue; each has started: its `hello`
    /// is out and its events are held until a handler attaches), refused peers to `onRefusal`. Returns the session
    /// accepted before (still open) and the last refusal before, for the guest to take over at once.
    func attachGuest(onSession: @escaping @Sendable (DockSession) -> Void,
                     onRefusal: @escaping @Sendable (DockRefusal) -> Void) -> (session: DockSession?, refusal: DockRefusal?) {
        lock.withLock {
            sessionHandler = onSession
            refusalHandler = onRefusal
            defer {
                pending = nil
                pendingRefusal = nil
            }
            let waiting = pending.flatMap { $0 === active ? $0 : nil }
            return (waiting, pendingRefusal)
        }
    }

    private func acceptAll(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                if code != EAGAIN, code != EWOULDBLOCK { pauseAccepting(errno: code) }
                return
            }
            POSIX.setCloseOnExec(client)
            POSIX.setNonBlocking(client)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            admit(client)
        }
    }

    private func admit(_ client: Int32) {
        let facts = inspector.inspect(client)
        let (hosts, on, busy, stopping) = lock.withLock { (allowed, enabled, active != nil, stopped) }
        if stopping {
            Darwin.close(client)
            return
        }
        let host: VerifiedHost
        switch DockPeerCheck.verdict(facts, allowedHosts: hosts, ownUID: ownUID) {
        case .failure(let refusal):
            Log.info("dock: peer refused (\(Self.label(refusal)))", "dock")
            if refusal != .otherUser { say(.bye(.refused), on: client) }
            Darwin.close(client)
            let handler = lock.withLock { () -> (@Sendable (DockRefusal) -> Void)? in
                if refusalHandler == nil { pendingRefusal = refusal }
                return refusalHandler
            }
            handler?(refusal)
            return
        case .success(let verified):
            host = verified
        }
        guard on else {
            Log.info("dock: connection refused, docking is off", "dock")
            say(.bye(.settings), on: client)
            Darwin.close(client)
            return
        }
        guard !busy else {
            Log.info("dock: second host refused (busy)", "dock")
            say(.busy, on: client)
            Darwin.close(client)
            return
        }
        let (session, handler): (DockSession, (@Sendable (DockSession) -> Void)?) = lock.withLock {
            let made = DockSession(id: nextSessionID, fd: client, host: host, hello: hello, clock: clock,
                                   folderRule: folderRule)
            nextSessionID += 1
            active = made
            if sessionHandler == nil { pending = made }
            return (made, sessionHandler)
        }
        session.setEndedCallback { [weak self] ended in
            guard let self else { return }
            self.lock.withLock {
                if self.active === ended { self.active = nil }
                if self.pending === ended { self.pending = nil }
            }
        }
        session.start()
        handler?(session)
    }

    /// Out of descriptors (or another accept failure): the pending connection stays in the backlog and the source would
    /// fire again at once, so accepting rests for a second instead of spinning.
    private func pauseAccepting(errno code: Int32) {
        guard let reader = lock.withLock({ source }) else { return }
        Log.warn("dock: accept failed errno=\(code), pausing 1 s", "dock")
        reader.suspend()
        queue.asyncAfter(deadline: .now() + 1) { reader.resume() }
    }

    /// One line on a socket that is about to be closed (a fresh socket takes a short line at once; never waited for).
    private func say(_ message: GuestMessage, on client: Int32) {
        _ = POSIX.writeAll(client, DockWire.encode(message))
    }

    static func label(_ refusal: DockRefusal) -> String {
        switch refusal {
        case .version: return "version"
        case .notListed: return "not in dock.hosts"
        case .notAnApp: return "not an app of this user"
        case .otherUser: return "other user"
        }
    }

    // MARK: Stop

    /// Stops accepting, closes the connected host's link (`bye` with `quit`, unless the guest closed it already) and
    /// removes the socket if it is still the one bound here.
    public func stop() {
        let (reader, fd, bound, session) = lock.withLock { () -> (DispatchSourceRead?, Int32, (dev: dev_t, ino: ino_t)?, DockSession?) in
            let result = (source, listenFD, boundFile, active)
            stopped = true
            source = nil
            listenFD = -1
            boundFile = nil
            active = nil
            pending = nil
            sessionHandler = nil
            refusalHandler = nil
            return result
        }
        session?.close(bye: .quit)
        if let reader {
            reader.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        if let bound {
            var info = stat()
            if lstat(socketPath, &info) == 0, info.st_dev == bound.dev, info.st_ino == bound.ino { unlink(socketPath) }
        }
        if fd >= 0 { Log.info("dock: stopped listening", "dock") }
    }
}
