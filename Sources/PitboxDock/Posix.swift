import Foundation

/// Failures of the socket layer, before any protocol is spoken.
enum SocketFailure: Error, Equatable {
    case pathTooLong(String)
    case invalidPath(String)
    case syscall(String, Int32)
}

/// Thin, EINTR-safe wrappers over the POSIX calls the dock link needs (docs/DOCK_PROTOCOL.md). Everything here works on
/// plain file descriptors, so the listener and its tests share one implementation.
enum POSIX {
    static func errorText(_ code: Int32) -> String { String(cString: strerror(code)) }

    static func fileType(_ mode: mode_t) -> mode_t { mode & mode_t(S_IFMT) }

    /// A duration made safe to convert to integer nanoseconds or seconds: finite, not negative, at most ~11 days.
    /// (Converting infinity or NaN to an integer type traps, and a timeout is caller-supplied configuration.)
    static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? min(max(seconds, 0), 1_000_000) : 1_000_000
    }

    /// Monotonic clock in nanoseconds (not affected by wall-clock changes).
    static func monotonicNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

    // MARK: Addresses and sockets

    /// A `sockaddr_un` for `path`. `sun_path` holds 104 bytes on macOS, including the terminating NUL.
    static func makeUnixAddress(_ path: String) throws -> sockaddr_un {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw SocketFailure.invalidPath(path) }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw SocketFailure.pathTooLong(path) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// A new AF_UNIX stream socket that is close-on-exec (children such as the console's commands must never inherit
    /// it) and never raises SIGPIPE (a peer that vanished mid-write must not kill the app).
    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketFailure.syscall("socket", errno) }
        setCloseOnExec(fd)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func bind(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var copy = address
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func connect(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var copy = address
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }

    static func setNonBlocking(_ fd: Int32, _ enabled: Bool = true) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, enabled ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }

    /// Bounds how long a blocking `write` may wait for a peer that does not read (`SO_SNDTIMEO`).
    static func setSendTimeout(_ fd: Int32, seconds: TimeInterval) {
        let seconds = clamp(seconds)
        guard seconds > 0 else { return }
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// True when the peer of a connected stream socket is gone for good (closed, not just done sending): a zero-length
    /// send fails with EPIPE then, and succeeds after a mere half-close (`shutdown(SHUT_WR)`), which `poll` cannot tell
    /// apart (both report POLLIN|POLLHUP on macOS). The socket must have `SO_NOSIGPIPE`.
    static func peerHasClosed(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        guard Darwin.send(fd, &byte, 0, 0) < 0 else { return false }
        return errno == EPIPE || errno == ENOTCONN || errno == ECONNRESET || errno == EBADF
    }

    /// The effective uid of the process on the other end of a connected Unix socket (`getpeereid`).
    static func peerUID(of fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    // MARK: Waiting, reading, writing

    /// Waits until one of `fds` is ready. Returns the number of ready descriptors, 0 on timeout, -1 on error.
    /// `timeout == nil` waits forever. Retries after signals without stretching the deadline.
    static func wait(_ fds: inout [pollfd], timeout: TimeInterval?) -> Int32 {
        let deadline = timeout.map { monotonicNanos() &+ UInt64(clamp($0) * 1_000_000_000) }
        while true {
            var milliseconds: Int32 = -1
            if let deadline {
                let now = monotonicNanos()
                milliseconds = now >= deadline ? 0 : Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            }
            let ready = fds.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, nfds_t($0.count), milliseconds) }
            if ready >= 0 { return ready }
            if errno != EINTR { return -1 }
        }
    }

    /// `read(2)` that retries after signals. Returns bytes read, 0 at end of stream, -1 on error.
    static func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        while true {
            let count = Darwin.read(fd, buffer.baseAddress, buffer.count)
            if count < 0, errno == EINTR { continue }
            return count
        }
    }

    /// Writes all of `data`. False if the peer is gone or stopped reading (send timeout).
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base + offset, raw.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }
}
