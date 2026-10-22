import Darwin
import Foundation

/// Reads facts about other processes of the same user with libproc and sysctl: their name, folder and arguments. Used to
/// label tabs and to remember each shell's last folder. Nothing here changes a process.
enum ProcessInspector {
    /// The process name (the executable's file name, at most 32 characters).
    static func name(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    /// The process's current working directory.
    static func currentDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// The process's arguments (`argv`), or nil when they cannot be read.
    static func arguments(of pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// Whether a process with this id exists (a zombie still counts).
    static func exists(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Parses the `KERN_PROCARGS2` layout: `int32 argc`, the executable path, padding NULs, then `argc` NUL-terminated
    /// arguments (the environment follows and is ignored on purpose).
    static func parseProcessArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { raw in for i in 0..<4 { raw[i] = bytes[i] } }
        guard argc > 0, argc < 4096 else { return nil }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }      // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }      // padding
        var out: [String] = []
        while out.count < Int(argc), index < bytes.count {
            var end = index
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            out.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end + 1
        }
        return out.isEmpty ? nil : out
    }
}
