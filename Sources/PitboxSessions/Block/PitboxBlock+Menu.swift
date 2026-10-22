import Foundation
import PitboxKit

// The status menu's block actions: Hide text, Pit all done and All back on track, with the counts the menu shows. They
// reach the block's own paths (the header's buttons), so the menu and the header can never disagree.

extension PitboxBlock {
    /// Hide text, as the header's button: monitors, Ready cards and desk tags show headlines and state only.
    public var hideText: Bool { model.hideText }

    /// Turns Hide text on or off (the header's button and `onHideTextChanged` follow).
    public func setHideText(_ hidden: Bool) {
        guard model.hideText != hidden else { return }
        model.toggleHideText()
    }

    /// How many windows "Pit all done" would send into the pit now: finished sessions under the focus whose window is
    /// on the desk with nothing in flight (the header's "Pit all done (N)").
    public var pitAllDoneCount: Int { model.snapshot.header.parkAllDone }

    /// "Pit all done": the header's button (its note says how many went into the pit and which were skipped).
    public func pitAllDone() { model.parkAllDone() }

    /// How many windows are in the pit now (all copies, any focus), each of which "All back on track" can bring back.
    public var inThePitCount: Int { Self.restorable(model.parker.statuses).count }

    /// "All back on track" (needed before an uninstall or a rollback): every window in the pit, under any
    /// focus, goes back to its old place and size. Windows not matched since a restart cannot be brought back and stay.
    /// Returns how many were asked to come back.
    @discardableResult
    public func allBackOnTrack() -> Int {
        let ids = Self.restorable(model.parker.statuses)
        for id in ids { model.parker.perform(.restore, sessionID: id) }
        CodeTileLog.info("all back on track count=\(ids.count)")
        return ids.count
    }

    /// The sessions whose window is in the pit and can be restored now (sorted, so the order is stable).
    static func restorable(_ statuses: [String: CodeWindowStatus]) -> [String] {
        statuses.filter { _, status in
            guard case .parked = status.place else { return false }
            return status.click == .restore
        }.map(\.key).sorted()
    }
}
