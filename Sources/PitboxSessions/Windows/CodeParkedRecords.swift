import CoreGraphics
import Darwin
import Foundation
import PitboxKit

/// One window the app parked: ids, numbers and a frame only. No title, no text, no
/// command ever goes into the file.
struct CodeParkedRecord: Equatable, Sendable {
    /// The copy's letter ("A").
    var profile: String
    /// `local_<id>`, checked against `CodeDeepLink.isValidSessionID`.
    var sessionID: String
    var pid: pid_t
    var windowNumber: CGWindowID
    /// The window's frame before parking, Quartz global coordinates.
    var frame: CGRect
    var displayID: UInt32
    var parkedAt: Date
}

/// `~/Library/Application Support/Pitbox/code-monitors.json`: `{"version":1,"parked":[{profile, sessionId, pid,
/// windowNumber, frame{x,y,w,h}, displayID, parkedAt}]}`. Written atomically with mode 0600 (a private temporary file
/// renamed over the old one); read tolerantly: a broken file is no records, a bad entry is skipped, unknown keys are
/// ignored, and a session id that appears twice keeps its latest entry.
final class CodeParkedRecordStore: @unchecked Sendable {
    let url: URL
    /// Larger files are refused unread (a real one is well under 10 KB).
    static let maxBytes = 256 * 1024
    /// More records than this are never kept.
    static let maxRecords = 64

    init(url: URL = Paths.appSupport.appendingPathComponent("code-monitors.json")) {
        self.url = url
    }

    /// The records in the file; empty when it is missing, too large or unreadable.
    func load() -> [CodeParkedRecord] {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return [] }
        // A link or anything but a regular file is never followed (only the app writes this file).
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= Self.maxBytes,
              let data = FileManager.default.contents(atPath: url.path) else {
            CodeTileLog.warn("parked records: file unusable, starting empty")
            return []
        }
        return Self.decode(data)
    }

    /// Replaces the file with `records` (atomic, 0600). Returns false (and logs) when it could not be written.
    @discardableResult
    func save(_ records: [CodeParkedRecord]) -> Bool {
        let data = Self.encode(Array(records.prefix(Self.maxRecords)))
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            CodeTileLog.warn("parked records: folder unavailable")
            return false
        }
        let temporary = folder.appendingPathComponent(".code-monitors.\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            CodeTileLog.warn("parked records: could not write (errno \(errno))")
            return false
        }
        var ok = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return buffer.count == 0 }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            CodeTileLog.warn("parked records: could not replace the file")
            return false
        }
        return true
    }

    // MARK: Format

    static func encode(_ records: [CodeParkedRecord]) -> Data {
        let entries: [[String: Any]] = records.map { record in
            ["profile": record.profile, "sessionId": record.sessionID, "pid": Int(record.pid),
             "windowNumber": Int(record.windowNumber),
             "frame": ["x": Double(record.frame.minX), "y": Double(record.frame.minY),
                       "w": Double(record.frame.width), "h": Double(record.frame.height)],
             "displayID": Int(record.displayID), "parkedAt": record.parkedAt.timeIntervalSince1970]
        }
        let object: [String: Any] = ["version": 1, "parked": entries]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func decode(_ data: Data) -> [CodeParkedRecord] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["parked"] as? [Any] else { return [] }
        var byID: [String: CodeParkedRecord] = [:]
        var order: [String] = []
        for case let entry as [String: Any] in list.prefix(maxRecords * 4) {
            guard let record = record(from: entry) else { continue }
            if byID[record.sessionID] == nil { order.append(record.sessionID) }
            if let existing = byID[record.sessionID], existing.parkedAt > record.parkedAt { continue }
            byID[record.sessionID] = record
        }
        return order.compactMap { byID[$0] }.prefix(maxRecords).map { $0 }
    }

    private static func record(from entry: [String: Any]) -> CodeParkedRecord? {
        guard let profile = entry["profile"] as? String, profile.count <= 8,
              let sessionID = entry["sessionId"] as? String, CodeDeepLink.isValidSessionID(sessionID),
              let pid = (entry["pid"] as? NSNumber)?.int32Value, pid > 0,
              let number = (entry["windowNumber"] as? NSNumber)?.uint32Value, number > 0,
              let frame = entry["frame"] as? [String: Any],
              let x = (frame["x"] as? NSNumber)?.doubleValue, let y = (frame["y"] as? NSNumber)?.doubleValue,
              let w = (frame["w"] as? NSNumber)?.doubleValue, let h = (frame["h"] as? NSNumber)?.doubleValue,
              [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0,
              let parkedAt = (entry["parkedAt"] as? NSNumber)?.doubleValue, parkedAt.isFinite else { return nil }
        let display = (entry["displayID"] as? NSNumber)?.uint32Value ?? 0
        return CodeParkedRecord(profile: profile, sessionID: sessionID, pid: pid, windowNumber: number,
                                frame: CGRect(x: x, y: y, width: w, height: h), displayID: display,
                                parkedAt: Date(timeIntervalSince1970: parkedAt))
    }
}
