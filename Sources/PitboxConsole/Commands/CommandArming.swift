import Foundation

/// The sheet's arming: a delay after every change before a press counts, and the pointer rule.
///
/// - A press counts only if it *began* at least the delay after the sheet last armed: 0.8 s, or 2 s for Run (and Fetch
///   file) when the command has a red line. Every red line's tick re-arms, so it is 2 s after the last tick.
/// - Arming starts again on every change that matters (content, move, resize, cover, displays, wake, unlock, the
///   block's window, ticks); a press in progress at that moment is dropped by the buttons.
/// - Run, Type, Fetch file, the fetched file's Open and "Open a terminal" are never armed under the pointer: a press
///   counts only if the pointer entered the button after it armed. A pointer already resting on it must leave and come
///   back.
/// - The choices (the ticks, This Mac / The server, the login user) arm 0.8 s after the sheet was shown or changed,
///   but not again after each other: ticking two red lines in a row works, while each tick still re-arms Run.
/// All times are `MonotonicClock` seconds.
struct CommandArming: Equatable {
    static let delay: TimeInterval = 0.8
    static let riskyDelay: TimeInterval = 2.0

    /// How a button arms.
    enum Rule: Equatable {
        /// Cancel, ✕ and the disclosures: at once.
        case immediate
        /// Copy, Copy cleaned, Run in terminal instead, Show in Finder: the 0.8 s.
        case normal
        /// A tick, a machine or user choice: the 0.8 s, from the last change that was not itself a choice.
        case choice
        /// Run, Type, Fetch file (the delay, 2 s when `risky`), the fetched file's Open and "Open a terminal" (0.8 s):
        /// the delay and the pointer rule.
        case action(risky: Bool)
    }

    /// When the sheet last armed; infinity until it is first on screen.
    private(set) var armedFrom: TimeInterval = .infinity
    /// When the sheet last armed for a reason other than a tick or a choice.
    private(set) var choicesFrom: TimeInterval = .infinity

    /// Arming starts again now. `byChoice`: a tick or a choice did it (the other choices stay armed).
    mutating func rearm(now: TimeInterval, byChoice: Bool = false) {
        armedFrom = now
        if !byChoice || !choicesFrom.isFinite { choicesFrom = now }
    }

    /// When presses on a button with `rule` start counting.
    func armsAt(_ rule: Rule) -> TimeInterval {
        switch rule {
        case .immediate: return -.infinity
        case .normal: return armedFrom + Self.delay
        case .choice: return choicesFrom + Self.delay
        case .action(let risky): return armedFrom + (risky ? Self.riskyDelay : Self.delay)
        }
    }

    /// Whether a press that began at `pressBegan` counts. `pointerEnteredAt` is when the pointer last entered the
    /// button (nil when it is outside or never seen entering).
    func accepts(_ rule: Rule, pressBegan: TimeInterval, pointerEnteredAt: TimeInterval?) -> Bool {
        guard pressBegan.isFinite else { return false }
        let at = armsAt(rule)
        guard pressBegan >= at else { return false }
        if case .action = rule {
            guard let entered = pointerEnteredAt, entered >= at else { return false }
        }
        return true
    }

    /// For drawing: a press starting now would count (dimmed until then, no hover state). `pointerInside` is whether
    /// the pointer is over the button now.
    func isArmed(_ rule: Rule, now: TimeInterval, pointerEnteredAt: TimeInterval?, pointerInside: Bool) -> Bool {
        guard now >= armsAt(rule) else { return false }
        if case .action = rule, pointerInside {
            // Under a pointer that rested there since before it armed, it stays inert until the pointer left and came back.
            guard let entered = pointerEnteredAt else { return false }
            return entered >= armsAt(rule)
        }
        return true
    }
}
