import Foundation
import os

/// Logging to the unified log and to `Paths.logsDir/pitbox.log` (rotated at ~2 MB). Labels and numbers only: never
/// session text, commands, paths, hosts, titles or secrets (docs/THREAT_MODEL.md, "The run path as built").
public enum Log {
    private static let logger = Logger(subsystem: AppIdentity.defaultBundleID, category: "app")
    private static let queue = DispatchQueue(label: "pitbox.log")
    private static let maxBytes = 2_000_000

    public static func info(_ message: @autoclosure () -> String, _ category: String = "app") { write("INFO", category, message()) }
    public static func warn(_ message: @autoclosure () -> String, _ category: String = "app") { write("WARN", category, message()) }
    public static func error(_ message: @autoclosure () -> String, _ category: String = "app") { write("ERROR", category, message()) }

    private static func write(_ level: String, _ category: String, _ message: String) {
        switch level {
        case "ERROR": logger.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        case "WARN": logger.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        default: logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) [\(category)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            let dir = Paths.logsDir
            let url = dir.appendingPathComponent("pitbox.log")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }
}
