import Foundation

/// The arming of a button that opens something outside the app: ▦ on a tag and ↗ ▤ ▦ in the desk peek count only a
/// left press that begins and ends on them, at least `DeskTagTuning.armDelay` (0.8 s) after the button appeared or
/// moved, and never while the pointer was already over its place when it appeared or moved, until the pointer has left
/// it once. Tags reappear under the pointer after a drag, so this matters most here. Pure; times are monotonic seconds.
struct DeskTagArming: Equatable {
    private(set) var since: TimeInterval
    private(set) var blockedUntilExit: Bool

    /// A button that appeared at `time`, with the pointer over its place or not.
    init(appearedAt time: TimeInterval, pointerInside: Bool) {
        since = time
        blockedUntilExit = pointerInside
    }

    /// The button moved (a layout change, or its panel followed the window): armed again from `time`, and blocked again
    /// when its new place is under the pointer.
    mutating func moved(at time: TimeInterval, pointerInside: Bool) {
        since = time
        blockedUntilExit = pointerInside
    }

    /// The pointer left the button.
    mutating func pointerExited() {
        blockedUntilExit = false
    }

    /// Whether a press beginning at `time` counts.
    func allowsPress(at time: TimeInterval) -> Bool {
        !blockedUntilExit && time - since >= DeskTagTuning.armDelay
    }
}
