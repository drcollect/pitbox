import CoreGraphics
import Foundation

extension GuardEngine {
    /// The safety net for missed notifications. One window-server call lists the on-screen windows of the active
    /// Space; only normal-level windows of managed apps that overlap a strip (and were not already judged at the same
    /// bounds) cost Accessibility round trips. With nothing over the strips, a pass makes no Accessibility call.
    func reconcile(now: TimeInterval) {
        lastReconcile = now
        reconcileAt = nil
        guard isActive else { return }
        if isMouseDownNow(now) {
            // Never correct under a held button: finish right after the release instead.
            reconcileAfterRelease = true
            if dragSince == nil { dragSince = now }
            return
        }
        let listing = provider.onScreenWindows()
        pruneMarks(onScreen: listing, now: now)
        var live = Set<SettleKey>()
        var suspects: [pid_t: [OnScreenWindow]] = [:]
        for entry in listing where isCandidate(entry) {
            let key = SettleKey(entry)
            live.insert(key)
            if let until = settled[key], until > now { continue }
            if isBackedOff(entry.pid, now: now) { continue }
            suspects[entry.pid, default: []].append(entry)
        }
        settled = settled.filter { live.contains($0.key) && $0.value > now }
        for pid in suspects.keys.sorted() {
            guard let entries = suspects[pid] else { continue }
            reconcile(pid: pid, entries: entries, now: now)
            if apiDisabled { return }
        }
    }

    /// A window-server window that might need a correction.
    func isCandidate(_ window: OnScreenWindow) -> Bool {
        guard window.layer == 0, window.alpha > 0, window.pid != ownPID, isManaged(pid: window.pid) else { return false }
        guard window.bounds.width >= 40, window.bounds.height >= 40, overlapsRegion(window.bounds) else { return false }
        if let home = Placement.homeDisplay(for: window.bounds, displays: displays),
           Placement.coversDisplay(window.bounds, home) {
            return false
        }
        return true
    }

    /// Matches one app's suspect windows to its Accessibility windows (by window number when available, else by
    /// frame) and evaluates each match. Outcomes that cannot change while the bounds stay the same are remembered.
    private func reconcile(pid: pid_t, entries: [OnScreenWindow], now: TimeInterval) {
        let windows: [Window]
        switch provider.windows(ofPID: pid) {
        case .success(let list): windows = list
        case .failure(let failure):
            _ = handle(failure, window: nil, pid: pid, now: now)
            return
        }
        answered(pid)
        var remaining = entries
        for window in windows where !remaining.isEmpty {
            let id = provider.windowID(of: window)
            var index = id.flatMap { id in remaining.firstIndex { $0.windowID == id } }
            if id != nil, index == nil { continue }
            // A window still settling after a notification (mid-drag, mid-zoom animation) is left to that path, so
            // the pass never corrects a half-animated frame.
            if let known = index, pending[window] != nil || deferred.contains(window) {
                remaining.remove(at: known)
                continue
            }
            let info: WindowInfo
            switch provider.info(of: window) {
            case .success(let value): info = value
            case .failure(let failure):
                if handle(failure, window: window, pid: pid, now: now) == .backoff { return }
                continue
            }
            if index == nil { index = remaining.firstIndex { Placement.sameFrame($0.bounds, info.frame) } }
            guard let found = index else { continue }
            let entry = remaining.remove(at: found)
            if pending[window] != nil || deferred.contains(window) { continue }
            let outcome = evaluate(window, now: now, userInitiated: causedByUser(now), known: info)
            if let until = settleUntil(outcome, now: now) { settled[SettleKey(entry)] = until }
            if apiDisabled { return }
        }
        if !remaining.isEmpty { unexposed(pid: pid, entries: remaining, exposedCount: windows.count, now: now) }
    }

    /// How long an outcome stays true while the window keeps its bounds; nil means "look again next pass".
    func settleUntil(_ outcome: EvalOutcome, now: TimeInterval) -> TimeInterval? {
        switch outcome {
        case .ignored, .notManaged, .cannotFit, .wouldCorrect: return .infinity
        case .coolingDown(let until): return until
        case .clear: return now + 30
        case .skipped: return now + 5
        // A claimed window waits for its claim's end, not for its bounds to change.
        case .corrected, .deferred, .gone, .backoff, .claimed: return nil
        }
    }

    /// On-screen windows over a strip that Accessibility does not list. If the app lists no windows at all (the
    /// Electron symptom) and policy allows, ask it once for `AXManualAccessibility` and look again; otherwise leave
    /// them and look again in 30 s.
    private func unexposed(pid: pid_t, entries: [OnScreenWindow], exposedCount: Int, now: TimeInterval) {
        if exposedCount == 0, options.manualAccessibility == .whenWindowsMissing,
           !manualAccessibilityTried.contains(pid),
           entries.contains(where: { $0.bounds.width >= 100 && $0.bounds.height >= 100 }) {
            manualAccessibilityTried.insert(pid)
            if options.dryRun {
                // A dry run changes nothing in other apps (the flag can switch VS Code to screen-reader mode).
                log(.info, "dry run: would set AXManualAccessibility on \(appName(pid)), which lists no windows to "
                    + "Accessibility")
            } else if provider.enableManualAccessibility(pid: pid) {
                log(.info, "\(appName(pid)) lists no windows to Accessibility; set AXManualAccessibility, looking again")
                requestReconcile(at: now + 0.5)
                return
            }
        }
        if !unexposedLogged.contains(pid) {
            unexposedLogged.insert(pid)
            log(.info, "\(appName(pid)) has \(entries.count) window(s) over the block that Accessibility does not "
                + "list; leaving them")
        }
        for entry in entries { settled[SettleKey(entry)] = now + 30 }
    }

    /// Drops "cannot fit" and dry-run marks of windows that are no longer on screen at the marked frame, so the
    /// status counts stay true, and forgets old fight history.
    private func pruneMarks(onScreen listing: [OnScreenWindow], now: TimeInterval) {
        fights.prune(now: now)
        guard !cannotFit.isEmpty || !dryRunNoted.isEmpty else { return }
        let live = Set(listing.map { FrameKey(pid: $0.pid, frame: $0.bounds) })
        cannotFit = cannotFit.filter { live.contains(FrameKey(pid: $0.value.pid, frame: $0.value.frame)) }
        dryRunNoted = dryRunNoted.filter { live.contains(FrameKey(pid: $0.value.pid, frame: $0.value.frame)) }
    }
}
