import Foundation

/// The running words on the block's monitors and slim rows, through the model's item decorators
/// (`CodeMonitorsModel.itemDecorators`). The app's own words only (times, counts), no session text. For a running
/// session it sets:
///
/// - `runText`: a slim row's right-hand words ("ETA 23:24 · 4/6 agents", "≈ 9 min left", "Running 12 min") in place
///   of "state · age";
/// - `progress`: the 3 pt bar of medium and small monitors, from background tasks or todos (no source, no bar);
/// - `compactLine`: a small monitor's "≈ 9 min" when no offer, file or run result comes first (its state word else).
///
/// The run line of large and medium monitors has a field (`runLine`) and a place of its own on the item and layout;
/// `line(for:now:clock:)` gives it.
enum CodeRunDecoration {
    /// Decorates `item` of `session` for `now`.
    static func decorate(_ session: CodeSessionSnapshot, _ item: inout CodeMonitorItem, now: Date, clock: CodeClockFormat) {
        guard let line = line(for: session, now: now, clock: clock) else { return }
        item.runText = line.row
        item.runLine = line
        if let fraction = line.fraction { item.progress = fraction }
        if item.compactTone == nil, let small = line.small {
            item.compactLine = small
            item.compactTone = .running
        }
    }

    /// The run line of `session` (all sizes), nil while it is not running.
    static func line(for session: CodeSessionSnapshot, now: Date, clock: CodeClockFormat) -> CodeRunLine? {
        CodeRunLine.make(session, now: now, clock: clock)
    }
}

extension CodeMonitorsModel {
    /// The running words on every monitor and slim row (`CodeRunDecoration`), with the model's clock and this Mac's
    /// zone and hour cycle (read once here; the zone follows the system's by itself). Call once, before `start()` or
    /// after it (the next rebuild picks it up; the block rebuilds every 30 s while shown, so "Running 34 min" stays
    /// current).
    func installRunWords(clock: CodeClockFormat = .system) {
        itemDecorators.append { [weak self] session, item in
            CodeRunDecoration.decorate(session, &item, now: self?.now() ?? Date(), clock: clock)
        }
    }
}
