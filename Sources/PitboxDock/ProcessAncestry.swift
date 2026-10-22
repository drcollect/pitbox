import Darwin
import Foundation

/// Who is on the other end of a Unix socket, and whether that process descends from a given one. The dock link uses it
/// to check the process that connected (docs/DOCK_PROTOCOL.md).
enum ProcessAncestry {
    /// A live process, identified by its pid AND its start time, so a pid the system recycled never counts as the same
    /// process.
    struct Identity: Equatable, Sendable {
        let pid: pid_t
        let parent: pid_t
        let uid: uid_t
        /// Microseconds since the epoch.
        let started: UInt64
    }

    /// `pid` as the kernel reports it now, or nil when it does not exist (or cannot be inspected).
    static func identity(of pid: pid_t) -> Identity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let started = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        return Identity(pid: pid, parent: pid_t(info.pbi_ppid), uid: info.pbi_uid, started: started)
    }

    /// The pid of the process at the other end of a connected Unix socket (`LOCAL_PEERPID`: the last process that
    /// used the peer's socket, normally the one that connected).
    static func peerPID(of fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// True when `pid` is `ancestor` itself or one of its descendants. Walks the parent chain (at most `maxDepth`
    /// links) and requires every parent to have started no later than its child, so a pid recycled while the chain
    /// was read breaks the chain instead of extending it; `ancestor` must still be the very process recorded (same
    /// start time).
    static func descends(_ pid: pid_t, from ancestor: Identity, maxDepth: Int = 64) -> Bool {
        guard var current = identity(of: pid) else { return false }
        for _ in 0...maxDepth {
            if current.pid == ancestor.pid { return current.started == ancestor.started }
            guard current.parent > 1, current.parent != current.pid, let parent = identity(of: current.parent),
                  parent.started <= current.started else { return false }
            current = parent
        }
        return false
    }
}
