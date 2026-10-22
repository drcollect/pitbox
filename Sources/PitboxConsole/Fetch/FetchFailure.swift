import Darwin
import Foundation
import PitboxKit

/// Why a Fetch file ended without a file. The raw value is the label the log may carry; `words(…)` is Pitbox's
/// sentence for the offer line. Words name the session's alias and the login user (both
/// checked against their grammars), never a host from the reply or from scp's output.
enum FetchFailure: String, Error, Equatable, Sendable, CaseIterable {
    // Before scp starts.
    case busySession, busyOverall, planInvalid, configChanged, downloadsUnavailable, otherVolume, notEnoughSpace
    case stagingFailed, spawnFailed
    // While it runs (Pitbox stopped it).
    case timedOut, tooLarge, spaceRanOut
    // scp or ssh failed.
    case hostKey, password, keyRejected, connectionRefused, nameLookup, unreachable, connectFailed
    case noSuchFile, notAFile, noPermission, localWrite, diskFull, scpFailed
    // After the copy.
    case notPlainFile, permissions, quarantine, downloadsChanged, noFreeName, moveFailed

    /// The sentence for the offer line.
    func words(alias: String, user: String, fileName: String, limits: FetchLimits) -> String {
        switch self {
        case .busySession: return "a fetch from \(alias) is already running"
        case .busyOverall: return "two fetches are already running; try again when one has finished"
        case .planInvalid: return "this fetch no longer matches what you reviewed; review again"
        case .configChanged: return "your SSH config changed; review again"
        case .downloadsUnavailable: return "Downloads isn't available"
        case .otherVolume: return "Downloads is on another volume"
        case .notEnoughSpace: return "not enough free space for a fetch"
        case .stagingFailed: return "couldn't prepare \(AppIdentity.displayName)'s staging folder"
        case .spawnFailed: return "couldn't start scp"
        case .timedOut: return "timed out"
        case .tooLarge: return "stopped: larger than \(limits.maxFileBytes / 1_048_576) MB"
        case .spaceRanOut: return "stopped: less than \(limits.freeSpaceReserve / 1_000_000_000) GB free"
        case .hostKey: return "the host key for \(alias) is unknown or changed: not fetched"
        case .password: return "\(alias) asked for a password (use Run in terminal)"
        case .keyRejected: return "\(alias) didn't accept your key for \(user)"
        case .connectionRefused: return "\(alias) refused the connection"
        case .nameLookup: return "couldn't look up \(alias)'s address"
        case .unreachable: return "couldn't reach \(alias)"
        case .connectFailed: return "couldn't connect to \(alias)"
        case .noSuchFile: return "no such file on \(alias)"
        case .notAFile: return "that's a folder or not a plain file on \(alias)"
        case .noPermission: return "no permission to read that file on \(alias)"
        case .localWrite: return "couldn't write the file on this Mac"
        case .diskFull: return "the disk is full"
        case .scpFailed: return "scp failed"
        case .notPlainFile: return "the fetched file isn't a plain file: not fetched"
        case .permissions: return "couldn't set the file's permissions: not fetched"
        case .quarantine: return "couldn't mark the file as downloaded: not fetched"
        case .downloadsChanged: return "Downloads changed"
        case .noFreeName: return "Downloads already has 99 files named \(fileName)"
        case .moveFailed: return "couldn't move the file into Downloads"
        }
    }

    /// Reads how scp ended. ssh writes its own lines (`alex@<ip>: Permission denied (publickey).`, `Host key
    /// verification failed.`; measured on OpenSSH 10.2p1 with `LogLevel=ERROR`); scp prefixes its lines with its
    /// program name (`/usr/bin/scp: <path>: No such file or directory`). Lines naming the remote file are only read as
    /// scp's, so a remote path cannot pose as an ssh line. A server can still print text that steers which of these
    /// fixed sentences is shown; it can never make a fetch succeed or put its text on screen.
    static func classify(exit: ProcessExit, stderr: String, stagingFolder: String) -> FetchFailure {
        if case .signaled(let signal) = exit, signal == SIGXFSZ { return .tooLarge }
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        let scpPrefixes = ["\(FetchCommand.scpPath): ", "scp: "]
        let scpLines = lines.filter { line in scpPrefixes.contains { line.hasPrefix($0) } }.map { $0.lowercased() }
        let sshLines = lines.filter { line in !scpPrefixes.contains { line.hasPrefix($0) } }.map { $0.lowercased() }
        func ssh(_ needles: String...) -> Bool { sshLines.contains { line in needles.contains { line.contains($0) } } }
        func scp(_ needles: String...) -> Bool { scpLines.contains { line in needles.contains { line.contains($0) } } }

        if ssh("host key verification failed", "remote host identification has changed")
            || sshLines.contains(where: { $0.contains("host key") && $0.contains("requested strict checking") }) {
            return .hostKey
        }
        if let methods = authenticationMethods(sshLines) {
            return methods.contains("password") || methods.contains("keyboard-interactive") ? .password : .keyRejected
        }
        if ssh("too many authentication failures") { return .keyRejected }
        if ssh("timed out") { return .timedOut }
        if ssh("connection refused") { return .connectionRefused }
        if ssh("could not resolve hostname", "nodename nor servname") { return .nameLookup }
        if ssh("no route to host", "network is unreachable", "host is down") { return .unreachable }
        let staging = stagingFolder.lowercased()
        if !staging.isEmpty, scpLines.contains(where: { $0.contains(staging) }) {
            if scp("no space left on device") { return .diskFull }
            if scp("file too large") { return .tooLarge }
            return .localWrite
        }
        if scp("no space left on device") { return .diskFull }
        if scp("no such file or directory") { return .noSuchFile }
        if scp("not a regular file", "is a directory") { return .notAFile }
        if scp("permission denied") { return .noPermission }
        if exit == .exited(255) || scp("connection closed") { return .connectFailed }
        return .scpFailed
    }

    /// The methods of ssh's `<user>@<host>: Permission denied (<methods>).`, nil when no line has that shape.
    private static func authenticationMethods(_ lines: [String]) -> Set<String>? {
        for line in lines {
            guard let range = line.range(of: "permission denied (", options: .backwards) else { continue }
            let rest = line[range.upperBound...]
            guard let close = rest.firstIndex(of: ")") else { continue }
            let methods = rest[rest.startIndex..<close].split(separator: ",").map { String($0) }
            if !methods.isEmpty { return Set(methods) }
        }
        return nil
    }
}
