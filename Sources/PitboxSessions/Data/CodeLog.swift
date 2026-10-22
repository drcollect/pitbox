import Foundation
import PitboxKit

/// The data side's log lines, category "code" (docs/THREAT_MODEL.md): labels and numbers only, for example
/// `offers session=#3 profile=B count=2 classes=unflagged,risky flags=3`. Never a title, nickname, path, host, cwd,
/// command, TL;DR, Ask line, reply text or session id: `#3` is the session's local index in this run. Tests switch the
/// app log off and watch every line (`observe`).
enum CodeLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var writesToLog = true
    nonisolated(unsafe) private static var observers: [UUID: @Sendable (String) -> Void] = [:]

    /// Whether lines go to `Log` (the app's log file). Observers get them either way.
    static var enabled: Bool {
        get { lock.withLock { writesToLog } }
        set { lock.withLock { writesToLog = newValue } }
    }

    /// Calls `handler` with every line ("INFO …", "WARN …") until `stopObserving` is called with the returned token.
    static func observe(_ handler: @escaping @Sendable (String) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = handler }
        return token
    }

    static func stopObserving(_ token: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: token) }
    }

    static func info(_ message: @autoclosure () -> String) { write("INFO", message()) }
    static func warn(_ message: @autoclosure () -> String) { write("WARN", message()) }

    private static func write(_ level: String, _ message: String) {
        let (enabled, handlers) = lock.withLock { (writesToLog, Array(observers.values)) }
        for handler in handlers { handler("\(level) \(message)") }
        guard enabled else { return }
        if level == "WARN" { Log.warn(message, "code") } else { Log.info(message, "code") }
    }
}
