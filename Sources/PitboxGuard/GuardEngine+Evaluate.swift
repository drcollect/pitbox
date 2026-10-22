import CoreGraphics
import Foundation

extension GuardEngine {
    /// Looks at one window and corrects it if it overlaps a strip. `known` skips the attribute round trip when the
    /// caller already read it. Cheap checks come first: a window that overlaps nothing costs one round trip.
    @discardableResult
    func evaluate(_ window: Window, now: TimeInterval, userInitiated: Bool, known: WindowInfo? = nil) -> EvalOutcome {
        // Every look ends the window's claim wait; a claimed look below continues it (GuardEngine+Claims.swift).
        let claimWait = claimWaits.removeValue(forKey: window)
        let owner = known?.pid ?? provider.pid(of: window) ?? windowPIDs[window]
        if let owner, isBackedOff(owner, now: now) {
            keepClaimWait(window, claimWait, pid: owner, now: now)
            return .backoff
        }
        let info: WindowInfo
        if let known {
            info = known
        } else {
            switch provider.info(of: window) {
            case .success(let value): info = value
            case .failure(let failure):
                let outcome = handle(failure, window: window, pid: owner, now: now)
                if case .backoff = outcome { keepClaimWait(window, claimWait, pid: owner, now: now) }
                return outcome
            }
        }
        answered(info.pid)
        guard info.pid != ownPID, isManaged(pid: info.pid) else { return .notManaged }
        if let learned = learnedMinWidth[window], info.frame.width < learned - options.tolerance {
            // The window has since become narrower than the width it seemed to refuse (the app applied the write
            // late, or animated it): that was no minimum.
            learnedMinWidth[window] = nil
            settled.removeAll()
        }
        learnGrowBack(window, pid: info.pid, frame: info.frame, now: now)
        if let reason = WindowPolicy.ineligibility(of: info, options: options, displays: displays) {
            forgetMarks(window)
            return .ignored(reason)
        }
        guard overlapsRegion(info.frame) else {
            forgetMarks(window)
            return .clear
        }
        if let until = fights.cooldownEnd(window, now: now) { return .coolingDown(until: until) }
        if isMouseDownNow(now) {
            deferForDrag(window, now: now)
            return .deferred
        }
        // Drag-to-park: a window the block's drop claimed is left alone until the claim ends.
        if let until = claimEnd(of: window, pid: info.pid, now: now) {
            return holdForClaim(window, pid: info.pid, until: until, previous: claimWait, now: now)
        }
        // Only normal-level windows in the active Space: floating ("always on top") windows are left alone, and a
        // window on another Space is corrected when that Space becomes active.
        if let state = serverState(of: window, info: info) {
            if state.layer != 0 { return .skipped("window level \(state.layer)") }
            if !state.onScreen { return .skipped("not on screen in the active Space") }
        }
        // A timeout here is not a verdict about the window (it would read as "neither movable nor resizable").
        let caps: WindowCapabilities
        switch provider.capabilities(of: window) {
        case .success(let value): caps = value
        case .failure(let failure): return handle(failure, window: window, pid: info.pid, now: now)
        }
        guard let plan = plan(for: window, frame: info.frame, caps: caps) else {
            forgetMarks(window)
            return .clear
        }
        guard plan.action != .none else { return markCannotFit(window, pid: info.pid, frame: info.frame) }
        if options.dryRun { return noteDryRun(window, info: info, plan: plan) }
        return apply(plan, to: window, info: info, caps: caps, now: now, userInitiated: userInitiated)
    }

    /// Level and visibility from the window server, by window number; without one (private symbol missing or
    /// failing), by the app's on-screen window with the same frame, and "not on screen" when there is none.
    func serverState(of window: Window, info: WindowInfo) -> ServerWindowState? {
        if let id = provider.windowID(of: window) { return provider.serverState(ofWindowID: id) }
        let match = provider.onScreenWindows().first { $0.pid == info.pid && Placement.sameFrame($0.bounds, info.frame) }
        return ServerWindowState(layer: match?.layer ?? 0, onScreen: match != nil)
    }

    /// An app that grows a window back shortly after a correction, keeping its left edge, top and height but not its
    /// old width, is enforcing a minimum width after the fact (auto layout, SwiftUI): learn it instead of fighting.
    /// A full revert, or anything after a click, is left to the fight detector.
    func learnGrowBack(_ window: Window, pid: pid_t, frame: CGRect, now: TimeInterval) {
        guard let last = lastCorrection.removeValue(forKey: window), now - last.at <= options.maxSettleDelay,
              lastMouseUp < last.at else { return }
        let t = options.tolerance
        guard abs(frame.minX - last.after.minX) <= t, abs(frame.minY - last.after.minY) <= t,
              abs(frame.height - last.after.height) <= t, frame.width > last.after.width + t,
              frame.width < last.before.width - t else { return }
        learnedMinWidth[window] = max(learnedMinWidth[window] ?? 0, frame.width)
        log(.info, "\(appName(pid)) window grew back to \(FrameKey.whole(frame.width)) pt after a correction; "
            + "treating that as its minimum width")
    }

    func plan(for window: Window, frame: CGRect, caps: WindowCapabilities) -> Placement.Correction? {
        let minWidth = max(options.minimumWindowSize.width, learnedMinWidth[window] ?? 0)
        return Placement.resolve(windowFrame: frame, regions: regions, displays: displays,
                                 minSize: CGSize(width: minWidth, height: options.minimumWindowSize.height),
                                 resizable: caps.resizable, movable: caps.movable,
                                 minShrinkFraction: CGFloat(options.minimumShrinkFraction),
                                 tolerance: options.tolerance)
    }

    private func apply(_ plan: Placement.Correction, to window: Window, info: WindowInfo, caps: WindowCapabilities,
                       now: TimeInterval, userInitiated: Bool) -> EvalOutcome {
        var result: CGRect
        switch provider.setFrame(plan.frame, of: window, from: info.frame) {
        case .success(let frame): result = frame
        case .failure(let failure): return handle(failure, window: window, pid: info.pid, now: now)
        }
        // An app may refuse to get narrower than its own minimum: remember it and move the window instead.
        if overlapsRegion(result), caps.resizable, result.width > plan.frame.width + options.tolerance {
            learnedMinWidth[window] = result.width
            if let retry = self.plan(for: window, frame: result, caps: caps), retry.action != .none,
               case .success(let frame) = provider.setFrame(retry.frame, of: window, from: result) {
                result = frame
            }
        }
        windowPIDs[window] = info.pid
        // Nothing changed at all: the app ignored the write. That is no correction and no fight; leave the window
        // alone at these bounds instead of writing again every verification.
        if Placement.sameFrame(result, info.frame, tolerance: 0.5) {
            return markCannotFit(window, pid: info.pid, frame: result, refused: true)
        }
        correctedCount += 1
        lastCorrection[window] = LastCorrection(before: info.frame, after: result, at: now)
        let name = appName(info.pid)
        log(.info, "\(verb(plan.action)) \(name) window \(describe(info.frame)) -> \(describe(result))"
            + (userInitiated ? " (after user action)" : ""))
        if let until = fights.record(window, now: now, countsAsFight: !userInitiated) {
            fightWake = min(fightWake ?? until, until)
            log(.warn, "\(name) window keeps ending up over the block; leaving it alone for \(Int(until - now)) s")
        }
        // Look again shortly: apps sometimes re-apply their own frame, or finish an animation, right after a change.
        pending[window] = Pending(due: max(pending[window]?.due ?? 0, now + options.verifyDelay), fromDrag: false,
                                  since: pending[window]?.since ?? now)
        if overlapsRegion(result) { return markCannotFit(window, pid: info.pid, frame: result) }
        forgetMarks(window)
        return .corrected(result)
    }

    /// `refused`: the app ignored the write altogether (as opposed to getting as close as it could).
    func markCannotFit(_ window: Window, pid: pid_t, frame: CGRect, refused: Bool = false) -> EvalOutcome {
        if cannotFit[window]?.frame != frame {
            let why = refused ? "refused to move or resize" : "cannot fit next to the block"
            log(.info, "\(appName(pid)) window \(describe(frame)) \(why); leaving it there")
        }
        cannotFit[window] = Mark(pid: pid, frame: frame, target: nil)
        return .cannotFit(frame)
    }

    private func noteDryRun(_ window: Window, info: WindowInfo, plan: Placement.Correction) -> EvalOutcome {
        if dryRunNoted[window]?.target != plan.frame {
            correctedCount += 1
            log(.info, "dry run: would \(verb(plan.action, past: false)) \(appName(info.pid)) window \(describe(info.frame)) -> "
                + "\(describe(plan.frame))" + (plan.fits ? "" : " (still overlapping: cannot fit)"))
        }
        dryRunNoted[window] = Mark(pid: info.pid, frame: info.frame, target: plan.frame)
        return .wouldCorrect(plan.frame)
    }

    /// A look that ended in a backoff keeps a live claim wait and re-pends the window for the backoff's end, so the look
    /// after it still corrects as the user's and a slide-back after a park attempt never counts as a fight.
    func keepClaimWait(_ window: Window, _ wait: ClaimWait?, pid: pid_t?, now: TimeInterval) {
        guard let wait, wait.isLive(at: now) else { return }
        claimWaits[window] = wait
        let due = pid.flatMap { backoff[$0]?.until } ?? now + 2
        pending[window] = Pending(due: due, fromDrag: true, since: wait.since)
    }

    /// Turns an Accessibility failure into state: forget vanished windows, back off from unresponsive apps, flag a
    /// revoked permission.
    func handle(_ failure: AXFailure, window: Window?, pid: pid_t?, now: TimeInterval) -> EvalOutcome {
        switch failure {
        case .invalidElement:
            if let window { forget(window) }
            return .gone
        case .cannotComplete:
            if let pid { backOff(pid, now: now) }
            return .backoff
        case .apiDisabled:
            apiDisabled = true
            lastError = "Accessibility permission is off"
            lastErrorPID = nil
            return .backoff
        case .unsupported, .other:
            return .skipped("accessibility error \(failure)")
        }
    }

    /// 2, 4, 8 ... 60 s while the app keeps failing; back to 2 s once it has behaved for a minute. (An app that
    /// answers one call and then times out on the next must still escalate, so an answer does not reset the delay.)
    func backOff(_ pid: pid_t, now: TimeInterval) {
        let recent = backoff[pid].flatMap { now - $0.until < 60 ? $0.delay : nil } ?? 1
        let delay = min(max(recent * 2, 2), 60)
        backoff[pid] = Backoff(until: now + delay, delay: delay)
        lastError = "\(appName(pid)) does not answer Accessibility requests"
        lastErrorPID = pid
        log(.warn, "\(appName(pid)) did not answer Accessibility in time; trying again in \(Int(delay)) s")
    }

    /// The app answered: the error message about it goes (its backoff has already run out).
    func answered(_ pid: pid_t) {
        guard lastErrorPID == pid else { return }
        lastError = nil
        lastErrorPID = nil
    }

    func isBackedOff(_ pid: pid_t, now: TimeInterval) -> Bool {
        (backoff[pid]?.until ?? -.infinity) > now
    }

    private func verb(_ action: Placement.Correction.Action, past: Bool = true) -> String {
        switch action {
        case .shrink: return past ? "shrank" : "shrink"
        case .move: return past ? "moved" : "move"
        case .moveAndShrink: return past ? "moved and shrank" : "move and shrink"
        case .none: return past ? "left" : "leave"
        }
    }
}
