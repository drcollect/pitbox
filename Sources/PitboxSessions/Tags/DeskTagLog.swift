import Foundation
import PitboxKit

/// Log lines of desk tags and the window observer, category "code" (docs/THREAT_MODEL.md): labels and
/// numbers only, for example `tag shown session=#3 kind=offer` or `desktag lab note kind=moved button=down gap_ms=16`.
/// Never a headline, title, nickname, path, URL, handle, ETA time, command or session id: `#3` is the session's local
/// index in this run. Tests switch the app log off and watch every line (`observe`).
enum DeskTagLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var writesToLog = true
    nonisolated(unsafe) private static var observers: [UUID: @Sendable (String) -> Void] = [:]

    /// Whether lines go to `Log` (the app's log file). Observers get them either way.
    static var enabled: Bool {
        get { lock.withLock { writesToLog } }
        set { lock.withLock { writesToLog = newValue } }
    }

    /// Calls `handler` with every line until `stopObserving` is called with the returned token. Any thread.
    static func observe(_ handler: @escaping @Sendable (String) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = handler }
        return token
    }

    static func stopObserving(_ token: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: token) }
    }

    static func info(_ message: @autoclosure () -> String) { write(false, message()) }
    static func warn(_ message: @autoclosure () -> String) { write(true, message()) }

    private static func write(_ warn: Bool, _ message: String) {
        let (enabled, handlers) = lock.withLock { (writesToLog, Array(observers.values)) }
        for handler in handlers { handler(message) }
        guard enabled else { return }
        if warn { Log.warn(message, "code") } else { Log.info(message, "code") }
    }

    /// `session=#3`: the session's local index, never its id.
    static func tag(_ index: Int?) -> String { "session=#\(index.map(String.init) ?? "?")" }
}
