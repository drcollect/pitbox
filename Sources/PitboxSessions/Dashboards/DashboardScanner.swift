import Darwin
import Foundation
import PitboxKit

/// A running one-time scan: cancelled when its session stops being followed. Thread-safe.
final class DashboardScanTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false
    private var finishedFlag = false

    var isCancelled: Bool { lock.withLock { cancelledFlag } }
    /// The scan ended (whatever its outcome).
    var isFinished: Bool { lock.withLock { finishedFlag } }

    func cancel() { lock.withLock { cancelledFlag = true } }
    func finish() { lock.withLock { finishedFlag = true } }
}

/// Starts one-time scans; the deriver holds one. A protocol so tests can run scans in place.
protocol DashboardScanning: AnyObject {
    /// Scans `transcript` of session `sessionID` (`#index` in logs) once, writing the mark (`dashboardScan`) to
    /// `memory` when it ran to an end; a cancelled or unreadable scan writes nothing (it runs again when the session
    /// is followed again).
    func start(sessionID: String, index: Int, transcript: CarefulPath, owner: uid_t, memory: CodeMemoryStore,
               sites: CodeDashboardSites) -> DashboardScanTicket
}

/// The production scanner: its own serial queue at utility priority, never the engine's parse queue,
/// so no monitor waits on it. The file is opened through `CarefulFiles` (no link followed, a regular file of the user's)
/// and read with `pread`; nothing is written but the mark, and nothing leaves the Mac.
final class DashboardScanner: DashboardScanning {
    private let queue = DispatchQueue(label: "pitbox.code.dashboard-scan", qos: .utility)
    private let limits: TranscriptMarkerScan.Limits
    private let wallClock: @Sendable () -> Date

    /// A scanner with the default limits; `wallClock` dates the mark.
    init(limits: TranscriptMarkerScan.Limits = TranscriptMarkerScan.Limits(),
         wallClock: @escaping @Sendable () -> Date = { Date() }) {
        self.limits = limits
        self.wallClock = wallClock
    }

    func start(sessionID: String, index: Int, transcript: CarefulPath, owner: uid_t,
               memory: CodeMemoryStore, sites: CodeDashboardSites) -> DashboardScanTicket {
        let ticket = DashboardScanTicket()
        let limits = self.limits
        let wallClock = self.wallClock
        queue.async {
            Self.scan(sessionID: sessionID, index: index, transcript: transcript, owner: owner, memory: memory,
                      sites: sites, ticket: ticket, limits: limits, wallClock: wallClock)
        }
        return ticket
    }

    /// One scan, on the caller's thread (the scanner's queue; tests call it directly).
    static func scan(sessionID: String, index: Int, transcript: CarefulPath, owner: uid_t, memory: CodeMemoryStore,
                     sites: CodeDashboardSites, ticket: DashboardScanTicket, limits: TranscriptMarkerScan.Limits,
                     wallClock: @Sendable () -> Date) {
        defer { ticket.finish() }
        guard !ticket.isCancelled else { return }
        let begun = MonotonicClock.now()
        let outcome = CarefulFiles.withFile(transcript, owner: owner) { fd, identity in
            TranscriptMarkerScan.run(size: identity.size, sites: sites, limits: limits,
                                     read: { offset, count in CarefulFiles.readRange(fd: fd, from: offset, count: count) },
                                     clock: { MonotonicClock.now() }, isCancelled: { ticket.isCancelled })
        }
        let milliseconds = Int(((MonotonicClock.now() - begun) * 1000).rounded())
        switch outcome {
        case .failure(let failure):
            CodeLog.warn("dashboard scan session=#\(index) failed reason=\(failure.label)")
        case .success(let result):
            let found = result.link != nil
            CodeLog.info("dashboard scan session=#\(index) bytes=\(result.bytesRead) ms=\(milliseconds) "
                + "found=\(found ? "yes" : "no") stop=\(result.stop.rawValue)")
            guard result.stop != .cancelled, result.stop != .unreadable else { return }
            let mark = DashboardScanRecord(at: wallClock(), found: found, bytes: result.bytesRead,
                                           handle: result.link?.handle, site: result.link?.site, linkAt: result.link?.at,
                                           builderAt: result.builderAt)
            memory.write(.dashboardScan, session: sessionID, value: mark)
        }
    }
}
