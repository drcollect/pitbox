import Darwin
import Foundation
import Testing
@testable import PitboxDock

/// A connected AF_UNIX stream pair in this process, closed by `close()`.
private struct SocketPair {
    var a: Int32
    var b: Int32

    init() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw SocketFailure.syscall("socketpair", errno) }
        a = fds[0]
        b = fds[1]
    }

    func close() {
        if a >= 0 { Darwin.close(a) }
        if b >= 0 { Darwin.close(b) }
    }
}

/// A short private folder for socket files (`sun_path` holds 104 bytes), removed by `remove()` in a `defer`; under
/// the test run's app-support folder when scripts/test.sh set one (`DockTestFolder.parent`), else under /tmp.
private struct SocketFolder {
    let path: String

    init() throws {
        var template = Array((DockTestFolder.parent + "/pitbox-dock.XXXXXX").utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw SocketFailure.syscall("mkdtemp", errno)
        }
        path = String(cString: made)
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

private func hasFlag(_ fd: Int32, getter: Int32, _ flag: Int32) -> Bool {
    let flags = fcntl(fd, getter)
    return flags >= 0 && flags & flag != 0
}

@Suite struct PosixAddressTests {
    @Test func aPathThatFitsBecomesAUnixAddress() throws {
        let path = "/tmp/pitbox-dock/dock.sock"
        let address = try POSIX.makeUnixAddress(path)
        #expect(Int32(address.sun_family) == AF_UNIX)
        #expect(Int(address.sun_len) == MemoryLayout<sockaddr_un>.size)
        let stored = withUnsafeBytes(of: address.sun_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #expect(stored == path)
    }

    @Test func theLongestPathThatFitsLeavesRoomForTheTerminator() throws {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        #expect(capacity == 104)
        let longest = "/" + String(repeating: "a", count: capacity - 2)
        #expect(longest.utf8.count == 103)
        _ = try POSIX.makeUnixAddress(longest)
        #expect(throws: SocketFailure.pathTooLong(longest + "a")) { try POSIX.makeUnixAddress(longest + "a") }
    }

    @Test func aTooLongSocketPathFailsCleanly() throws {
        let folder = try SocketFolder()
        defer { folder.remove() }
        let long = folder.path + "/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: SocketFailure.pathTooLong(long)) { try POSIX.makeUnixAddress(long) }
        // Multibyte characters count as their UTF-8 bytes.
        let wide = "/tmp/" + String(repeating: "é", count: 50)
        #expect(throws: SocketFailure.pathTooLong(wide)) { try POSIX.makeUnixAddress(wide) }
        #expect(!FileManager.default.fileExists(atPath: long), "nothing was created")
    }

    @Test func emptyPathsAndPathsWithNULAreRefused() {
        #expect(throws: SocketFailure.invalidPath("")) { try POSIX.makeUnixAddress("") }
        #expect(throws: SocketFailure.invalidPath("/tmp/a\u{0}b")) { try POSIX.makeUnixAddress("/tmp/a\u{0}b") }
    }

    @Test func clampKeepsTimeoutsConvertible() {
        #expect(POSIX.clamp(1.5) == 1.5)
        #expect(POSIX.clamp(-3) == 0)
        #expect(POSIX.clamp(.infinity) == 1_000_000)
        #expect(POSIX.clamp(.nan) == 1_000_000)
        #expect(POSIX.clamp(5_000_000) == 1_000_000)
    }

    @Test func socketErrorsReadAsText() {
        #expect(!POSIX.errorText(EACCES).isEmpty)
        #expect(POSIX.fileType(mode_t(S_IFSOCK) | 0o600) == mode_t(S_IFSOCK))
    }
}

@Suite struct PosixSocketTests {
    @Test func newSocketsAreCloseOnExecAndNeverRaiseSIGPIPE() throws {
        let fd = try POSIX.makeSocket()
        defer { close(fd) }
        #expect(hasFlag(fd, getter: F_GETFD, FD_CLOEXEC))
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &length) == 0)
        #expect(value != 0)
        #expect(!hasFlag(fd, getter: F_GETFL, O_NONBLOCK), "blocking until asked")
    }

    @Test func closeOnExecAndNonBlockingCanBeSet() throws {
        let pair = try SocketPair()
        defer { pair.close() }
        #expect(!hasFlag(pair.a, getter: F_GETFD, FD_CLOEXEC))
        POSIX.setCloseOnExec(pair.a)
        #expect(hasFlag(pair.a, getter: F_GETFD, FD_CLOEXEC))

        POSIX.setNonBlocking(pair.a)
        #expect(hasFlag(pair.a, getter: F_GETFL, O_NONBLOCK))
        var byte: UInt8 = 0
        let count = withUnsafeMutableBytes(of: &byte) { POSIX.read(pair.a, into: $0) }
        let code = errno
        #expect(count == -1 && code == EAGAIN, "nothing to read: a non-blocking read returns at once")
        POSIX.setNonBlocking(pair.a, false)
        #expect(!hasFlag(pair.a, getter: F_GETFL, O_NONBLOCK))
    }

    @Test func peerIsThisProcessForAnInProcessPair() throws {
        let pair = try SocketPair()
        defer { pair.close() }
        #expect(POSIX.peerUID(of: pair.a) == getuid())
        #expect(POSIX.peerUID(of: pair.b) == getuid())
        #expect(ProcessAncestry.peerPID(of: pair.a) == getpid())
        #expect(ProcessAncestry.peerPID(of: pair.b) == getpid())
    }

    @Test func peerChecksOnABoundSocketInATempFolder() throws {
        let folder = try SocketFolder()
        defer { folder.remove() }
        let address = try POSIX.makeUnixAddress(folder.path + "/dock.sock")
        let listener = try POSIX.makeSocket()
        defer { close(listener) }
        #expect(POSIX.bind(listener, to: address) == 0)
        #expect(listen(listener, 4) == 0)

        let client = try POSIX.makeSocket()
        defer { close(client) }
        #expect(POSIX.connect(client, to: address) == 0, "a Unix connect completes into the backlog")
        let accepted = accept(listener, nil, nil)
        #expect(accepted >= 0)
        defer { if accepted >= 0 { close(accepted) } }

        #expect(POSIX.peerUID(of: accepted) == getuid())
        #expect(ProcessAncestry.peerPID(of: accepted) == getpid())
        #expect(POSIX.peerUID(of: client) == getuid())
        #expect(ProcessAncestry.peerPID(of: client) == getpid())

        var info = stat()
        #expect(lstat(folder.path + "/dock.sock", &info) == 0)
        #expect(POSIX.fileType(info.st_mode) == mode_t(S_IFSOCK))
    }

    @Test func connectingWithoutAListenerFails() throws {
        let folder = try SocketFolder()
        defer { folder.remove() }
        let client = try POSIX.makeSocket()
        defer { close(client) }
        let address = try POSIX.makeUnixAddress(folder.path + "/none.sock")
        let result = POSIX.connect(client, to: address)
        let code = errno
        #expect(result == -1)
        #expect(code == ENOENT)
    }

    @Test func notASocketHasNoPeer() throws {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        #expect(POSIX.peerUID(of: fds[0]) == nil)
        #expect(ProcessAncestry.peerPID(of: fds[0]) == nil)
        #expect(POSIX.peerUID(of: -1) == nil)
        #expect(ProcessAncestry.peerPID(of: -1) == nil)
    }

    @Test func writeAllReadAndWait() throws {
        let pair = try SocketPair()
        defer { pair.close() }
        var poll = [pollfd(fd: pair.b, events: Int16(POLLIN), revents: 0)]
        #expect(POSIX.wait(&poll, timeout: 0.01) == 0, "nothing sent yet: times out")

        let message = Data("{\"type\":\"hello\"}\n".utf8)
        #expect(POSIX.writeAll(pair.a, message))
        #expect(POSIX.wait(&poll, timeout: 1) == 1)
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = buffer.withUnsafeMutableBytes { POSIX.read(pair.b, into: $0) }
        #expect(count == message.count)
        #expect(Data(buffer.prefix(max(count, 0))) == message)
    }

    @Test func aClosedPeerIsToldApartFromAHalfClose() throws {
        var pair = try SocketPair()
        defer { pair.close() }
        var one: Int32 = 1
        setsockopt(pair.a, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #expect(!POSIX.peerHasClosed(pair.a))
        shutdown(pair.b, SHUT_WR)
        #expect(!POSIX.peerHasClosed(pair.a), "a half-close is not gone")
        close(pair.b)
        pair.b = -1
        #expect(POSIX.peerHasClosed(pair.a))
        #expect(!POSIX.writeAll(pair.a, Data("x".utf8)), "writing to a gone peer fails instead of raising SIGPIPE")
    }
}

@Suite struct ProcessAncestryTests {
    @Test(.enabled(if: getppid() > 1, "the test host still has its parent")) func thisProcessIsKnownWithItsParentAndOwner() throws {
        let me = try #require(ProcessAncestry.identity(of: getpid()))
        #expect(me.pid == getpid())
        #expect(me.parent == getppid())
        #expect(me.uid == getuid())
        #expect(me.started > 0)
        #expect(ProcessAncestry.identity(of: getpid()) == me, "stable while the process lives")
    }

    @Test func noProcessForInvalidPids() {
        #expect(ProcessAncestry.identity(of: 0) == nil)
        #expect(ProcessAncestry.identity(of: -1) == nil)
    }

    @Test(.enabled(if: getppid() > 1, "the test host still has its parent")) func descentFollowsTheParentChain() throws {
        let me = try #require(ProcessAncestry.identity(of: getpid()))
        let parent = try #require(ProcessAncestry.identity(of: getppid()))
        #expect(ProcessAncestry.descends(getpid(), from: me), "a process counts as its own descendant")
        #expect(ProcessAncestry.descends(getpid(), from: parent))
        #expect(!ProcessAncestry.descends(getppid(), from: me), "a parent never descends from its child")
        #expect(!ProcessAncestry.descends(0, from: me))
    }

    @Test(.enabled(if: getppid() > 1, "the test host still has its parent")) func aRecycledAncestorPidDoesNotCount() throws {
        let parent = try #require(ProcessAncestry.identity(of: getppid()))
        let impostor = ProcessAncestry.Identity(pid: parent.pid, parent: parent.parent, uid: parent.uid,
                                                started: parent.started + 1)
        #expect(!ProcessAncestry.descends(getpid(), from: impostor), "same pid, other start time: another process")
    }
}
