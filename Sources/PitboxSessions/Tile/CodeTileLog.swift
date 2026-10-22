import Foundation
import PitboxKit

/// Log lines of the Code monitors block and its window side, under `[code]` (docs/THREAT_MODEL.md): labels and
/// numbers only, for example `park ok session=#3 attempt=1` or `sheet opened offer=#3.1 class=risky`. Never a title,
/// TL;DR, nickname, command, path or host: callers pass only the app's own words and numbers.
enum CodeTileLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var writes = true
    nonisolated(unsafe) private static var recording = false
    nonisolated(unsafe) private static var lines: [String] = []

    /// Tests: false keeps lines out of the log file.
    static var enabled: Bool {
        get { lock.withLock { writes } }
        set { lock.withLock { writes = newValue } }
    }

    /// Tests: keep every line in memory too (`recorded`), from any thread.
    static func startRecording() {
        lock.withLock { recording = true }
    }

    /// The lines kept since `startRecording()` (all tests' lines: tests check for strings that must never appear).
    static var recorded: [String] { lock.withLock { lines } }

    static func info(_ message: String) { write(message, warn: false) }
    static func warn(_ message: String) { write(message, warn: true) }

    private static func write(_ message: String, warn: Bool) {
        let (enabled, keep) = lock.withLock { (writes, recording) }
        if keep { lock.withLock { lines.append(message) } }
        guard enabled else { return }
        if warn { Log.warn(message, "code") } else { Log.info(message, "code") }
    }
}
