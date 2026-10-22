import CoreGraphics
import Foundation

/// The arming of buttons that open something: ↗, ▤, ▦,
/// Preview, Open after a fetch. A press counts only when it is a left press that begins and ends on the button (the
/// view checks that), begins at least `CodeTuning.openButtonArmDelay` after the button appeared or last moved (a layout
/// change re-arms every button it moved), and never while the pointer was already over the button's place when it
/// appeared: the pointer must leave it and come back. Buttons that open nothing (Later, Dismiss, OK, Show, Open window,
/// ▶ Run…, …) are not armed: they act at once. Pure; the clock comes in with every call.
struct CodeReadyArming: Equatable {
    struct Button: Equatable {
        var rect: CGRect
        /// When it appeared or last moved.
        var shownAt: Date
        /// The pointer was over its place when it appeared and has not left since.
        var pointerWasOver: Bool
    }

    private(set) var buttons: [String: Button] = [:]

    /// The armed buttons as now laid out (id → frame), with the pointer where it is (nil: not over the view): a new or
    /// moved button arms from `now`; buttons not listed are forgotten.
    mutating func layout(_ rects: [String: CGRect], pointer: CGPoint?, now: Date) {
        var next: [String: Button] = [:]
        for (id, rect) in rects {
            if let old = buttons[id], old.rect == rect {
                next[id] = old
            } else {
                next[id] = Button(rect: rect, shownAt: now, pointerWasOver: pointer.map(rect.contains) ?? false)
            }
        }
        buttons = next
    }

    /// The pointer moved to `point` (nil: it left the view): a button it is no longer over may arm again.
    mutating func pointerMoved(to point: CGPoint?) {
        for (id, button) in buttons where button.pointerWasOver {
            if point.map({ !button.rect.contains($0) }) ?? true { buttons[id]?.pointerWasOver = false }
        }
    }

    /// Whether a press on `id` that began at `downAt` counts.
    func counts(_ id: String, downAt: Date) -> Bool {
        guard let button = buttons[id], !button.pointerWasOver else { return false }
        return downAt.timeIntervalSince(button.shownAt) >= CodeTuning.openButtonArmDelay
    }

    /// Whether `id` is armed at `now` (drawn at full strength).
    func isArmed(_ id: String, now: Date) -> Bool { counts(id, downAt: now) }

    /// When the next button arms (for one redraw), nil when every one is armed or waits for the pointer.
    func nextArming(after now: Date) -> Date? {
        buttons.values.filter { !$0.pointerWasOver }
            .map { $0.shownAt.addingTimeInterval(CodeTuning.openButtonArmDelay) }
            .filter { $0 > now }.min()
    }
}
