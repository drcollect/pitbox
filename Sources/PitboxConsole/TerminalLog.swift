import Foundation
import PitboxKit

/// The terminal's log lines (category `terminal` in the app's log). They go through here so tests can keep their
/// deliberate warnings ("terminal state ignored", ...) out of the real log file, and record every line
/// (`addRecorder`) to prove what it holds. Never log output, input, arguments or paths.
enum TerminalLog {
    /// Off in tests (`TempDir` switches it off), on in the app.
    nonisolated(unsafe) static var enabled = true
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorders: [UUID: (String) -> Void] = [:]

    static func info(_ message: @autoclosure () -> String) { write(message, warn: false) }

    static func warn(_ message: @autoclosure () -> String) { write(message, warn: true) }

    /// Tests: `recorder` receives every line, also while `enabled` is off, until `removeRecorder`.
    static func addRecorder(_ recorder: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { recorders[id] = recorder }
        return id
    }

    static func removeRecorder(_ id: UUID) {
        _ = lock.withLock { recorders.removeValue(forKey: id) }
    }

    private static func write(_ message: () -> String, warn: Bool) {
        let current = lock.withLock { Array(recorders.values) }
        guard enabled || !current.isEmpty else { return }
        let text = message()
        for recorder in current { recorder(text) }
        guard enabled else { return }
        if warn { Log.warn(text, "terminal") } else { Log.info(text, "terminal") }
    }
}
