import AppKit
import Darwin
import Foundation

/// A running process with Claude's bundle id, before its copy is known.
public struct ClaudeProcessCandidate: Sendable, Equatable {
    /// The process id.
    public var pid: Int32
    /// Its arguments (`sysctl KERN_PROCARGS2`), nil when they could not be read.
    public var arguments: [String]?
    /// The `Claude.app` it runs from.
    public var bundlePath: String?
    /// The app's version (`CFBundleShortVersionString`).
    public var version: String?

    /// A candidate as found (tests build them by hand).
    public init(pid: Int32, arguments: [String]?, bundlePath: String? = nil, version: String? = nil) {
        self.pid = pid
        self.arguments = arguments
        self.bundlePath = bundlePath
        self.version = version
    }
}

/// Finds Claude's processes and tells their copies apart: `--user-data-dir=<folder>` names the profile folder,
/// no such argument means the default copy A (`~/Library/Application Support/Claude`). Only a folder the settings file
/// lists (`profiles`), directly in Application Support, is a known copy; anything else is "Claude ?" and never read.
enum ClaudeProcessDiscovery {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    /// The running processes with Claude's bundle id (main processes only: Electron helpers have their own ids).
    static func liveCandidates() -> [ClaudeProcessCandidate] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).compactMap { app in
            let pid = app.processIdentifier
            guard pid > 0, !app.isTerminated else { return nil }
            let bundle = app.bundleURL
            let version = bundle.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
            return ClaudeProcessCandidate(pid: pid, arguments: arguments(pid: pid), bundlePath: bundle?.path,
                                          version: CodeText.identifier(version))
        }
    }

    /// The copies of `candidates`, in profile order (A, the listed letters, then unknown ones). `profiles` are the
    /// copies the settings file lists (the default copy alone when it lists none).
    static func resolve(_ candidates: [ClaudeProcessCandidate], applicationSupport: URL,
                        profiles: CodeProfiles = .defaultOnly) -> [ClaudeProcessInfo] {
        let infos = candidates.map { candidate in
            ClaudeProcessInfo(pid: candidate.pid,
                              profile: profile(arguments: candidate.arguments, applicationSupport: applicationSupport,
                                               profiles: profiles),
                              bundlePath: candidate.bundlePath, version: candidate.version)
        }
        return infos.sorted { (order($0.profile), $0.pid) < (order($1.profile), $1.pid) }
    }

    /// The copy a process with `arguments` belongs to: no `--user-data-dir` is the default copy; a folder directly in
    /// Application Support that `profiles` lists is that copy; anything else is "Claude ?" (never read).
    static func profile(arguments: [String]?, applicationSupport: URL, profiles: CodeProfiles = .defaultOnly) -> CodeProfile {
        guard let arguments else { return .unknown(folderName: "?") }
        var folder: String?
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--user-data-dir=") {
                folder = String(argument.dropFirst("--user-data-dir=".count))
            } else if argument == "--user-data-dir", index + 1 < arguments.count {
                folder = arguments[index + 1]
            }
        }
        guard let folder else { return .a }
        let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
        let name = url.lastPathComponent
        guard let known = profiles.profile(folderName: name), sameFolder(url.deletingLastPathComponent(), applicationSupport)
        else {
            return .unknown(folderName: name.isEmpty ? "?" : name)
        }
        return known
    }

    /// Sort order of copies: A, the listed letters, then unknown ones.
    static func order(_ profile: CodeProfile) -> Int { profile.rank }

    /// A process's arguments (`argv`), read with `sysctl KERN_PROCARGS2` (same user, no permission needed).
    static func arguments(pid: Int32) -> [String]? {
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argmaxMIB, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Int(argmax)
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` layout: `argc` (32 bits), the executable path, NUL padding, then `argc` NUL-terminated strings
    /// (the environment follows and is never read).
    static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(Int32(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        guard argc > 0, argc <= 4096 else { return nil }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }

    private static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.path == b.standardizedFileURL.path { return true }
        return realPath(a.path) != nil && realPath(a.path) == realPath(b.path)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
