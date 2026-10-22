import AppKit
import Foundation

/// What the lab mode measures for the attended checks of desk tags. Numbers only.
struct DeskTagLabState: Equatable {
    var notes = 0
    var noteLines = 0
    var noteWindowStart: TimeInterval = 0
    var lastNoteAt: [pid_t: TimeInterval] = [:]
    var placements = 0
    var latencyCount = 0
    var latencySum: TimeInterval = 0
    var latencyMax: TimeInterval = 0
    var mainSeconds: TimeInterval = 0
    var readsAtLastCost = 0
    var notificationsAtLastCost = 0
    /// The last order verdict per session index, logged on change only.
    var order: [Int: Bool] = [:]

    mutating func noteLatency(_ seconds: TimeInterval) {
        let value = max(0, seconds)
        latencyCount += 1
        latencySum += value
        latencyMax = max(latencyMax, value)
    }
}

// Lab lines (`[code] desktag lab …`): every raw notification with its button state and gap, the minute's cost with
// tags shown (the idle cost), the order check of the first cover mode (above its Claude window and under windows
// covering it), and the click check (the app not active, Claude still frontmost with the same focused window).
extension DeskTagController {
    func labNote(pid: pid_t, _ note: CodeWindowNotification, buttonDown: Bool, at: TimeInterval) {
        guard lab.enabled else { return }
        labState.notes += 1
        if at - labState.noteWindowStart >= 60 {
            labState.noteWindowStart = at
            labState.noteLines = 0
        }
        let gap = labState.lastNoteAt[pid].map { Int(((at - $0) * 1000).rounded()) }
        labState.lastNoteAt[pid] = at
        guard labState.noteLines < DeskTagTuning.labNoteLinesPerMinute else { return }
        labState.noteLines += 1
        let button = note == .moved || note == .resized ? (buttonDown ? " button=down" : " button=up") : ""
        DeskTagLog.info("desktag lab note kind=\(note.rawValue)\(button) gap_ms=\(gap.map(String.init) ?? "-")")
    }

    func scheduleLabCost() {
        guard lab.enabled else { return }
        _ = scheduler.after(DeskTagTuning.labCostInterval) { [weak self] in
            guard let self, self.started else { return }
            self.logLabCost()
            self.scheduleLabCost()
        }
    }

    func logLabCost() {
        let core = observer.core
        // The core's counters are written on its thread; a racy read is fine for a minute's rough numbers.
        let reads = core.reads - labState.readsAtLastCost
        let notifications = core.notifications - labState.notificationsAtLastCost
        labState.readsAtLastCost = core.reads
        labState.notificationsAtLastCost = core.notifications
        let average = labState.latencyCount > 0 ? labState.latencySum / Double(labState.latencyCount) : 0
        DeskTagLog.info("desktag lab cost per_min tags=\(shownCount) notes=\(notifications) reads=\(reads) "
                     + "places=\(labState.placements) main_ms=\(Int((labState.mainSeconds * 1000).rounded())) "
                     + "latency_ms_avg=\(Int((average * 1000).rounded())) latency_ms_max=\(Int((labState.latencyMax * 1000).rounded()))")
        labState.placements = 0
        labState.mainSeconds = 0
        labState.latencyCount = 0
        labState.latencySum = 0
        labState.latencyMax = 0
    }

    /// First cover mode: each shown tag's panel lies directly in front of its Claude window, and other apps' windows that
    /// cover the tag lie in front of the panel too. Logged when the verdict changes.
    func labCheckOrder() {
        guard coverMode == .orderedAbove else { return }
        for tag in tags.values {
            guard let layout = tag.shownLayout, let panel = tag.panel, panel.panel.windowNumber > 0,
                  let holds = DeskTagVisibility.orderHolds(panel: CGWindowID(panel.panel.windowNumber),
                                                        claude: tag.desk.windowNumber, tag: layout.frame,
                                                        frontToBack: frontToBack, ownPID: ownPID) else { continue }
            guard labState.order[tag.index] != holds else { continue }
            labState.order[tag.index] = holds
            DeskTagLog.info("desktag lab order \(DeskTagLog.tag(tag.index)) holds=\(holds ? 1 : 0)")
        }
    }

    /// After a click on a tag: the app must not be active, Claude must still be frontmost, and Claude's focused
    /// window must be the one it was at the click.
    func labCheckClick(pid: pid_t, index: Int) {
        observer.focusedWindowNumber(pid: pid) { [weak self] before in
            guard let self else { return }
            _ = self.scheduler.after(DeskTagTuning.labClickCheckDelay) { [weak self] in
                guard let self else { return }
                let ownActive = self.system.isOwnAppActive()
                let claudeFront = self.system.frontmostPID() == pid
                self.observer.focusedWindowNumber(pid: pid) { after in
                    let kept = before != nil && before == after
                    DeskTagLog.info("desktag lab click \(DeskTagLog.tag(index)) own_active=\(ownActive ? 1 : 0) "
                                 + "claude_front=\(claudeFront ? 1 : 0) focus_kept=\(kept ? 1 : 0)")
                }
            }
        }
    }
}
