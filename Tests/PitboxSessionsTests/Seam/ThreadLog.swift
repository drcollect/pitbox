import Darwin
import Foundation
@testable import PitboxSessions

/// `CodeLog` lines written on the thread that made this watcher, so a test can also check that a line did not come:
/// suites run in parallel, and other tests' lines arrive on other threads. Only for synchronous test bodies (they stay
/// on one thread); `stop()` when done.
final class ThisThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    private var token: UUID?

    init() {
        let thread = Self.threadID()
        token = CodeLog.observe { [weak self] line in
            guard Self.threadID() == thread else { return }
            self?.append(line)
        }
    }

    var lines: [String] { lock.withLock { collected } }

    func stop() {
        if let token { CodeLog.stopObserving(token) }
        token = nil
    }

    private func append(_ line: String) { lock.withLock { collected.append(line) } }

    private static func threadID() -> UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }
}
