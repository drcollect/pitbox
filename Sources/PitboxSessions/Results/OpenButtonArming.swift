import CoreGraphics
import Foundation

/// The arming of buttons that open something (↗, ▤, ▦, Preview, Open after a fetch), so none opens under a click meant
/// for what was there before (docs/THREAT_MODEL.md). A press counts only when the left button goes down and comes up on
/// the button, the press starting at least `CodeTuning.openButtonArmDelay` (0.8 s) after the button appeared or last
/// moved (a layout change re-arms every button it moved), and never while the pointer was already over the button's
/// place when it appeared or moved: such a button stays inert until the pointer has left it once. Buttons that open
/// nothing (Copy link, ⤓ Fetch…, which opens a sheet with its own arming) act at once. Pure: times and points come in,
/// so tests drive it.
struct OpenButtonArming: Equatable {
    struct Slot: Equatable {
        var rect: CGRect
        var placedAt: TimeInterval
        /// The pointer was over the place when the button appeared or moved, and has not left it since.
        var waitsForPointerToLeave: Bool
    }

    let delay: TimeInterval
    private(set) var slots: [String: Slot] = [:]

    init(delay: TimeInterval = CodeTuning.openButtonArmDelay) { self.delay = delay }

    /// The buttons laid out now, by key and frame (in one coordinate space with `pointer`). A new button, or one whose
    /// frame changed, is placed now; a button gone is forgotten.
    mutating func layout(_ rects: [String: CGRect], now: TimeInterval, pointer: CGPoint?) {
        var next: [String: Slot] = [:]
        for (key, rect) in rects {
            if let slot = slots[key], slot.rect == rect {
                next[key] = slot
            } else {
                next[key] = Slot(rect: rect, placedAt: now, waitsForPointerToLeave: pointer.map(rect.contains) ?? false)
            }
        }
        slots = next
    }

    /// Re-arms every button, as if it had just appeared (the window or the content behind it moved).
    mutating func rearmAll(now: TimeInterval, pointer: CGPoint?) {
        var next = slots
        for (key, slot) in slots {
            next[key] = Slot(rect: slot.rect, placedAt: now, waitsForPointerToLeave: pointer.map(slot.rect.contains) ?? false)
        }
        slots = next
    }

    /// The pointer moved (nil: it left the view): a button it is no longer over stops waiting.
    mutating func pointerMoved(to point: CGPoint?) {
        for (key, slot) in slots where slot.waitsForPointerToLeave {
            if point.map({ !slot.rect.contains($0) }) ?? true { slots[key]?.waitsForPointerToLeave = false }
        }
    }

    /// The button may be pressed now.
    func isArmed(_ key: String, now: TimeInterval) -> Bool {
        guard let slot = slots[key] else { return false }
        return !slot.waitsForPointerToLeave && now - slot.placedAt >= delay
    }

    /// A left-button press that went down at `downAt` on `downPoint` and came up on `upPoint` counts for `key`.
    func accepts(_ key: String, downAt: TimeInterval, downPoint: CGPoint, upPoint: CGPoint) -> Bool {
        guard let slot = slots[key], slot.rect.contains(downPoint), slot.rect.contains(upPoint) else { return false }
        return isArmed(key, now: downAt)
    }
}
