import Darwin
import Foundation
import PitboxKit

/// One verified connection to a dock host (docs/DOCK_PROTOCOL.md): framing and strict parsing, the handshake with
/// version and feature negotiation, typed messages in and out, ping and pong, `bye`, and liveness (the host's process
/// exit through kqueue `NOTE_EXIT`, end of file on the socket).
///
/// Everything runs on the session's own serial queue with dispatch sources on a non-blocking socket: no call ever
/// blocks a thread (a host that stops reading only grows a bounded output buffer). A violation of the rules closes the
/// link with a label in the log; nothing a peer sends can crash the app. Events go to the owner in order, on the
/// session's queue; events from before the owner attached are held and handed over when it does.
final class DockSession: @unchecked Sendable {
    /// The guest's own output pace: a bucket of 25 lines refilled at 25 a second, half the receiver's limit, so a
    /// receiver that reads late still never sees more than 50 a second. Only the newest unsent `area`, `attention`,
    /// `ping` and `pong` is kept.
    static let sendBurst = 25
    static let sendRate = 25
    /// Unsent messages held at most (beyond: dropped and counted).
    static let maxPaced = 64
    /// Bytes waiting for a host that does not read, at most (beyond: new messages dropped and counted).
    static let maxOutputBytes = 256 * 1024
    /// Slack for comparing times that were computed from each other.
    static let epsilon: TimeInterval = 0.001

    let id: Int
    let host: VerifiedHost
    let queue: DispatchQueue
    private let fd: Int32
    private let clock: DockClock
    private let ourHello: DockGuestHello
    private let folderRule: DockFolderRule

    // Everything below is used on `queue` only.
    private var framer = DockLineFramer()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceRunning = false
    private var exitSource: DispatchSourceProcess?
    private var openSources = 0
    private var fdClosed = false
    private var output: [UInt8] = []
    private var pacer = TokenBucket(capacity: DockSession.sendBurst, perSecond: DockSession.sendRate)
    private var paced: [(key: String?, data: Data)] = []
    private var flushTimer: DockTimer?
    private var handshakeTimer: DockTimer?
    private var livenessTimer: DockTimer?
    private var negotiated: DockHandshake?
    private var started = false
    private var endReason: DockEndReason?
    private var lastReceived: TimeInterval = 0
    private var firstUnansweredPing: TimeInterval?
    private var lastPingSent: TimeInterval?
    private var livenessDeadline: TimeInterval?
    private var unresponsive = false
    private var handler: (@Sendable (DockSessionEvent) -> Void)?
    private var held: [DockSessionEvent] = []
    private var stats = DockSessionStats()
    private var logged: Set<String> = []
    private var readBuffer = [UInt8](repeating: 0, count: 8192)
    private var endedCallback: (@Sendable (DockSession) -> Void)?

    /// A session over an accepted, verified socket. It owns `fd` from now on and closes it when it ends.
    init(id: Int, fd: Int32, host: VerifiedHost, hello: DockGuestHello, clock: DockClock,
         folderRule: DockFolderRule = DockFolderRule()) {
        self.id = id
        self.fd = fd
        self.host = host
        self.ourHello = hello
        self.clock = clock
        self.folderRule = folderRule
        queue = DispatchQueue(label: "pitbox.dock.session")
    }

    /// Called once, on the session's queue, after the session ended (the listener frees its one-host slot).
    func setEndedCallback(_ callback: @escaping @Sendable (DockSession) -> Void) {
        queue.async { self.endedCallback = callback }
    }

    /// Starts reading, watches the host's process, sends the guest's `hello` and starts the 2 s handshake timer.
    func start() {
        queue.async { self.startOnQueue() }
    }

    /// Where the events go (on the session's queue). Events from before are handed over at once, in order.
    func setEventHandler(_ handler: @escaping @Sendable (DockSessionEvent) -> Void) {
        queue.async {
            self.handler = handler
            let earlier = self.held
            self.held.removeAll()
            for event in earlier { handler(event) }
        }
    }

    /// Sends a message (paced; feature messages only when both sides listed the feature; nothing before the
    /// handshake).
    func send(_ message: GuestMessage) {
        queue.async { self.enqueue(message) }
    }

    /// Closes the link: `bye` with `why` (best effort, never waiting), then the socket.
    func close(bye why: DockByeReason) {
        queue.async {
            guard self.endReason == nil else { return }
            self.writeAtOnce(.bye(why))
            self.end(.closed(why))
        }
    }

    /// Closes a link that cannot be served because another host holds the slot: `busy` (after the `hello` already sent),
    /// then the socket. The host retries at its own pace.
    func closeBusy() {
        queue.async {
            guard self.endReason == nil else { return }
            self.writeAtOnce(.busy)
            self.end(.closed(.other))
        }
    }

    /// The counters now (not from the session's queue).
    func currentStats() -> DockSessionStats { queue.sync { stats } }

    // MARK: Start

    private func startOnQueue() {
        guard !started, endReason == nil else { return }
        started = true
        POSIX.setNonBlocking(fd)
        lastReceived = clock.now()

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        reader.setCancelHandler { self.sourceCancelled() }
        openSources += 1
        readSource = reader
        reader.resume()

        let exit = DispatchSource.makeProcessSource(identifier: host.pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.end(.processExited) }
        exitSource = exit
        exit.resume()
        // The process may have exited before the watch began (or its pid was recycled): then no event would come.
        if hostProcessIsGone() {
            end(.processExited)
            return
        }

        enqueue(ourHello.message)
        handshakeTimer = clock.after(DockProtocol.handshakeTimeout, on: queue) { [weak self] in
            guard let self, self.negotiated == nil, self.endReason == nil else { return }
            self.writeAtOnce(.bye(.timeout))
            self.end(.handshakeTimeout)
        }
        Log.info("dock: link open pid=\(host.pid)", "dock")
    }

    private func hostProcessIsGone() -> Bool {
        if kill(host.pid, 0) != 0, errno == ESRCH { return true }
        return ProcessAncestry.identity(of: host.pid)?.started != host.started
    }

    // MARK: Reading

    private func readAvailable() {
        var total = 0
        while endReason == nil {
            let count = readBuffer.withUnsafeMutableBytes { POSIX.read(fd, into: $0) }
            if count > 0 {
                total += count
                let outputs = readBuffer.withUnsafeBytes { raw in
                    framer.feed(UnsafeRawBufferPointer(rebasing: raw[0..<count]), at: clock.now())
                }
                for output in outputs {
                    switch output {
                    case .line(let line): handleLine(line)
                    case .violation(let what): fail(what)
                    }
                    if endReason != nil { return }
                }
                stats.blankLines = framer.blankLines
                if total >= 64 * 1024 { return }  // the source fires again for the rest
                continue
            }
            if count == 0 {
                end(.endOfFile)
                return
            }
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK { return }
            end(code == ECONNRESET ? .endOfFile : .readFailed(code))
            return
        }
    }

    private func handleLine(_ bytes: [UInt8]) {
        stats.linesIn += 1
        noteTraffic()
        let value: JSONValue
        do {
            value = try StrictJSON.parse(bytes)
        } catch StrictJSON.Failure.duplicateKey {
            stats.duplicateKeys += 1
            logOnce("dock: line with a duplicated key dropped")
            return
        } catch let failure as StrictJSON.Failure {
            fail(failure == .tooDeep ? "nesting" : failure == .notUTF8 ? "not UTF-8" : "malformed")
            return
        } catch {
            fail("malformed")
            return
        }
        switch DockWire.decodeHost(value) {
        case .notAMessage:
            fail("not a message")
        case .unknownType:
            guard negotiated != nil else { return fail("hello expected") }
            stats.unknownTypes += 1
            logOnce("dock: unknown message type ignored")
        case .badFields(let label):
            guard negotiated != nil else { return fail("bad hello") }
            stats.badFields += 1
            logOnce("dock: line with bad fields dropped (\(label))")
        case let .message(message, unknownFields):
            if unknownFields > 0 {
                stats.unknownFields += unknownFields
                logOnce("dock: unknown fields ignored")
            }
            handle(message)
        }
    }

    private func handle(_ message: HostMessage) {
        guard let negotiated else {
            guard case .hello(let hello) = message else { return fail("hello expected") }
            return handshake(with: hello)
        }
        switch message {
        case .hello:
            fail("second hello")
        case .ping:
            enqueue(.pong)
        case .pong:
            break
        case .bye(let why):
            end(.bye(why))
        default:
            if let feature = message.feature, !negotiated.features.contains(feature) {
                stats.featureOff += 1
                logOnce("dock: message of a feature not in use ignored")
                return
            }
            emit(.message(message))
        }
    }

    private func handshake(with hello: DockHello) {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        let low = max(ourHello.proto.lowerBound, hello.proto.lowerBound)
        let high = min(ourHello.proto.upperBound, hello.proto.upperBound)
        guard low <= high else {
            writeAtOnce(.bye(.version))
            end(.version(ours: ourHello.proto, theirs: hello.proto, hostApp: hello.app))
            return
        }
        // Only specific app-private folders pass; refused entries are dropped and counted.
        let folders = folderRule.filter(hello.privateFolders.folders)
        let socketFolders = folderRule.filter(hello.privateFolders.socketFolders)
        stats.refusedFolders += folders.refused + socketFolders.refused
        if folders.refused + socketFolders.refused > 0 {
            Log.warn("dock: announced folders refused (too broad or unresolvable) count=\(folders.refused + socketFolders.refused)", "dock")
        }
        let result = DockHandshake(major: high, features: ourHello.features.intersection(hello.features),
                                   hostName: hello.app, hostBuild: hello.build, wakeWords: hello.wakeWords,
                                   privateFolders: HostPrivateFolders(folders: folders.kept, socketFolders: socketFolders.kept),
                                   host: host)
        negotiated = result
        Log.info("dock: handshake done major=\(high) features=\(result.features.count)", "dock")
        emit(.handshake(result))
        armLiveness()
    }

    // MARK: Liveness

    private func noteTraffic() {
        lastReceived = clock.now()
        firstUnansweredPing = nil
        lastPingSent = nil
        if unresponsive {
            unresponsive = false
            Log.info("dock: host responding again", "dock")
            emit(.responsive(true))
        }
    }

    /// One timer at a time; it re-arms itself when it fires (no work per received line).
    private func armLiveness() {
        guard livenessTimer == nil, endReason == nil, negotiated != nil else { return }
        let now = clock.now()
        var deadline = lastReceived + DockProtocol.pingAfter
        if let first = firstUnansweredPing, let last = lastPingSent {
            deadline = last + DockProtocol.pingAfter
            if !unresponsive {
                deadline = min(deadline, first + DockProtocol.notRespondingAfter - DockProtocol.pingAfter)
            }
        }
        livenessDeadline = max(deadline, now)
        livenessTimer = clock.after(max(deadline - now, Self.epsilon), on: queue) { [weak self] in self?.livenessFired() }
    }

    /// A check that fires this much later than planned means the Mac slept (timers stop during sleep).
    static let wakeGap: TimeInterval = 2

    private func livenessFired() {
        livenessTimer = nil
        guard endReason == nil, negotiated != nil else { return }
        let now = clock.now() + Self.epsilon
        if let planned = livenessDeadline, now - planned > Self.wakeGap, !unresponsive {
            // After a sleep the host had no chance to answer: start over with a fresh ping, never "not responding" yet.
            firstUnansweredPing = clock.now()
            sendPing()
            armLiveness()
            return
        }
        if let first = firstUnansweredPing {
            if let last = lastPingSent, now - last >= DockProtocol.pingAfter { sendPing() }
            if !unresponsive, now - first >= DockProtocol.notRespondingAfter - DockProtocol.pingAfter {
                unresponsive = true
                Log.warn("dock: host not responding (no line for 15 s)", "dock")
                emit(.responsive(false))
            }
        } else if now - lastReceived >= DockProtocol.pingAfter {
            firstUnansweredPing = clock.now()
            sendPing()
        }
        armLiveness()
    }

    private func sendPing() {
        lastPingSent = clock.now()
        stats.pingsSent += 1
        enqueue(.ping)
    }

    // MARK: Writing

    private func enqueue(_ message: GuestMessage) {
        guard endReason == nil, started else { return }
        if case .hello = message {} else if negotiated == nil { return }
        if let feature = message.feature, negotiated?.features.contains(feature) != true {
            stats.featureOff += 1
            return
        }
        let data = DockWire.encode(message)
        let now = clock.now()
        if paced.isEmpty, pacer.take(at: now) {
            write(data)
            return
        }
        if let key = message.coalesceKey, let index = paced.firstIndex(where: { $0.key == key }) {
            paced[index].data = data
        } else if paced.count < Self.maxPaced {
            paced.append((key: message.coalesceKey, data: data))
        } else {
            stats.sendDropped += 1
            logOnce("dock: output held too long, a message dropped")
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTimer == nil, !paced.isEmpty, endReason == nil else { return }
        let now = clock.now()
        let at = pacer.nextToken(after: now)
        flushTimer = clock.after(max(at - now, Self.epsilon), on: queue) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushTimer = nil
        guard endReason == nil else { return }
        let now = clock.now()
        while !paced.isEmpty, pacer.take(at: now) { write(paced.removeFirst().data) }
        scheduleFlush()
    }

    private func write(_ data: Data) {
        guard output.count + data.count <= Self.maxOutputBytes else {
            stats.sendDropped += 1
            logOnce("dock: host is not reading, a message dropped")
            return
        }
        stats.linesOut += 1
        output.append(contentsOf: data)
        drain()
    }

    /// Writes what the socket takes now; the rest waits for the write source.
    private func drain() {
        guard !fdClosed else { return }
        while !output.isEmpty {
            let count = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                output.removeFirst(count)
                continue
            }
            let code = errno
            if count < 0, code == EINTR { continue }
            if count < 0, code == EAGAIN || code == EWOULDBLOCK {
                runWriteSource(true)
                return
            }
            // The host is gone (EPIPE, reset): reading reports the end.
            output.removeAll()
            break
        }
        runWriteSource(false)
    }

    private func runWriteSource(_ run: Bool) {
        if run, writeSource == nil, endReason == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            source.setCancelHandler { self.sourceCancelled() }
            openSources += 1
            writeSource = source
        }
        guard let source = writeSource, run != writeSourceRunning else { return }
        writeSourceRunning = run
        if run { source.resume() } else { source.suspend() }
    }

    /// A last line before closing: written now if the socket takes it, else lost (never waited for).
    private func writeAtOnce(_ message: GuestMessage) {
        guard !fdClosed else { return }
        output.append(contentsOf: DockWire.encode(message))
        stats.linesOut += 1
        while !output.isEmpty {
            let count = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 { output.removeFirst(count); continue }
            if count < 0, errno == EINTR { continue }
            break
        }
        output.removeAll()
    }

    // MARK: Ending

    private func fail(_ what: String) {
        guard endReason == nil else { return }
        writeAtOnce(.bye(.protocol))
        end(.violation(what))
    }

    private func end(_ reason: DockEndReason) {
        guard endReason == nil else { return }
        endReason = reason
        handshakeTimer?.cancel()
        livenessTimer?.cancel()
        flushTimer?.cancel()
        handshakeTimer = nil
        livenessTimer = nil
        flushTimer = nil
        paced.removeAll()
        exitSource?.cancel()
        exitSource = nil
        if let source = writeSource {
            if !writeSourceRunning { source.resume() }
            source.cancel()
            writeSource = nil
        }
        if let source = readSource {
            source.cancel()
            readSource = nil
        }
        if openSources == 0 { closeSocket() }
        stats.blankLines = framer.blankLines
        let line = "dock: link ended (\(reason.label)) \(stats.logText)"
        if case .violation = reason { Log.warn(line, "dock") } else { Log.info(line, "dock") }
        emit(.ended(reason))
        endedCallback?(self)
        endedCallback = nil
    }

    private func sourceCancelled() {
        openSources -= 1
        if openSources == 0, endReason != nil { closeSocket() }
    }

    private func closeSocket() {
        guard !fdClosed else { return }
        fdClosed = true
        Darwin.close(fd)
    }

    // MARK: Events and log

    private func emit(_ event: DockSessionEvent) {
        if let handler { handler(event) } else { held.append(event) }
    }

    private func logOnce(_ line: String) {
        guard logged.insert(line).inserted else { return }
        Log.info(line, "dock")
    }
}
