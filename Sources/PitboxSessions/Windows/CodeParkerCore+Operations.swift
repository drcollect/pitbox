import CoreGraphics
import Foundation

/// How one window operation ended.
enum CodeWindowOutcome: Equatable, Sendable {
    case parked, restored, alreadyOnScreen, activated, opened
    /// The window is not in a state for it (another Space for Park, not matched, …).
    case notPossible
    /// Another operation of the same session is in flight.
    case busy
    case noAccessibility
    /// The reason in the app's words.
    case failed(String)
}

/// Park, restore and the fallbacks. On the parker's queue, like the rest of the
/// core; waits are `queue.after` polls, never sleeps.
extension CodeParkerCore {
    static let parkFailure = "couldn't pit (Claude didn't answer)"
    static let restoreFailure = "couldn't restore (Claude didn't answer)"

    // MARK: Park

    /// `frame` (drag-to-park): the window's bounds before the drag, recorded instead of the frame it has now, so a
    /// restore brings it back where it was and not onto the block.
    func park(_ id: String, displays: [CodeDisplay], frame override: CGRect? = nil,
              done: @escaping (CodeWindowOutcome) -> Void) {
        guard operations[id] == nil else { return done(.busy) }
        guard trusted else { return done(.noAccessibility) }
        if let match = matches[id] { refreshWindow(match.number) }
        guard let session = session(id), case .onDesk = place(of: session), let match = matches[id] else {
            return done(.notPossible)
        }
        let element = match.element
        operations[id] = .parking
        problems[id] = nil
        publish()
        // 1. The record first, with the frame AX reports (the window server's bounds if AX did not answer).
        let axFrame: CGRect? = { if case .success(let info) = ax.info(of: element) { return info.frame } else { return nil } }()
        guard let frame = override ?? axFrame ?? serverWindows[match.number]?.bounds else {
            return finishPark(id, success: false, attempt: 1, done: done)
        }
        records[id] = CodeParkedRecord(profile: session.profile.letter, sessionID: id, pid: match.pid,
                                       windowNumber: match.number, frame: frame,
                                       displayID: CodeRestoreGeometry.displayID(for: frame, displays: displays),
                                       parkedAt: clock())
        saveRecords()
        attemptPark(id, element: element, number: match.number, attempt: 1, done: done)
    }

    private func attemptPark(_ id: String, element: CodeAXElement, number: CGWindowID, attempt: Int,
                             done: @escaping (CodeWindowOutcome) -> Void) {
        // 2. Minimize.
        switch ax.setMinimized(true, of: element) {
        case .invalidElement?:
            return finishPark(id, success: false, attempt: attempt, done: done, problem: "couldn't pit (the window is gone)")
        case .apiDisabled?:
            trusted = false
            return finishPark(id, success: false, attempt: attempt, done: done, problem: "couldn't pit (Accessibility is off)")
        default: break
        }
        // 3. Confirm through the window server: no longer on screen within 1.5 s.
        confirm(number: number, onScreen: false, deadline: uptime() + Self.confirmTimeout) { [self] confirmed in
            if confirmed {
                // Off screen is not always minimized: Claude may hide the window instead, and then
                // `AXMinimized = false` cannot bring it back. The monitor says so instead of "parked".
                if case .success(false) = ax.isMinimized(element) {
                    hiddenAfterPark.insert(id)
                    CodeTileLog.warn("park left the window hidden, not minimized \(tag(id))")
                }
                return finishPark(id, success: true, attempt: attempt, done: done)
            }
            // 4. One retry.
            if attempt == 1 { return attemptPark(id, element: element, number: number, attempt: 2, done: done) }
            finishPark(id, success: false, attempt: attempt, done: done)
        }
    }

    private func finishPark(_ id: String, success: Bool, attempt: Int, done: @escaping (CodeWindowOutcome) -> Void,
                            problem: String = CodeParkerCore.parkFailure) {
        operations[id] = nil
        if success {
            if let number = records[id]?.windowNumber {
                offscreen[number] = nil
                if var window = serverWindows[number] { window.isOnScreen = false; serverWindows[number] = window }
            }
            CodeTileLog.info("park ok \(tag(id)) attempt=\(attempt)")
            publish()
            return done(.parked)
        }
        records[id] = nil
        saveRecords()
        setProblem(id, problem)
        CodeTileLog.warn("park failed \(tag(id)) attempts=\(attempt)")
        publish()
        done(.failed(problem))
    }

    // MARK: Restore

    func restore(_ id: String, displays: [CodeDisplay], stripRects: [CGRect], done: @escaping (CodeWindowOutcome) -> Void) {
        guard operations[id] == nil else { return done(.busy) }
        guard trusted else { return done(.noAccessibility) }
        guard let session = session(id), let match = matches[id] else { return done(.notPossible) }
        // The live state, not the last pass's: a window the user brought back a moment ago is never moved.
        refreshWindow(match.number)
        let element = match.element
        switch place(of: session) {
        case .onDesk:
            // 1. Already on screen (the user restored it themselves): raise and activate only, never move it.
            _ = ax.raise(element)
            activate(pid: match.pid)
            if records[id] != nil { records[id] = nil; saveRecords() }
            publish()
            return done(.alreadyOnScreen)
        case .parked, .minimized, .hidden, .hiddenByClaude:
            break
        default:
            return done(.notPossible)
        }
        operations[id] = .restoring
        problems[id] = nil
        publish()
        attemptRestore(id, match: match, element: element, displays: displays, stripRects: stripRects, attempt: 1, done: done)
    }

    private func attemptRestore(_ id: String, match: CodeWindowMatch, element: CodeAXElement, displays: [CodeDisplay],
                                stripRects: [CGRect], attempt: Int, done: @escaping (CodeWindowOutcome) -> Void) {
        // 2. Un-minimize.
        if ax.setMinimized(false, of: element) == .invalidElement {
            return finishRestore(id, success: false, attempt: attempt, done: done)
        }
        // 3. The saved frame, clamped to the screen's visible frame minus the strip (only for windows the app
        //    parked: a window the user minimized themselves comes back where macOS puts it).
        if let record = records[id], record.windowNumber == match.number,
           let display = CodeRestoreGeometry.display(for: record.frame, preferredID: record.displayID, displays: displays) {
            let area = CodeRestoreGeometry.usableArea(of: display, stripRects: stripRects)
            _ = ax.setFrame(CodeRestoreGeometry.clamp(record.frame, into: area), of: element)
        }
        // 4. Raise, activate that process (never by bundle id: all copies share one), make it the main window.
        _ = ax.raise(element)
        activate(pid: match.pid)
        _ = ax.setMain(element)
        // 5. Confirm on screen within 1.5 s, else one retry.
        confirm(number: match.number, onScreen: true, deadline: uptime() + Self.confirmTimeout) { [self] confirmed in
            if confirmed { return finishRestore(id, success: true, attempt: attempt, done: done) }
            if attempt == 1 {
                return attemptRestore(id, match: match, element: element, displays: displays, stripRects: stripRects,
                                      attempt: 2, done: done)
            }
            finishRestore(id, success: false, attempt: attempt, done: done)
        }
    }

    private func finishRestore(_ id: String, success: Bool, attempt: Int, done: @escaping (CodeWindowOutcome) -> Void) {
        operations[id] = nil
        if success {
            if let number = matches[id]?.number {
                offscreen[number] = nil
                if var window = serverWindows[number] { window.isOnScreen = true; serverWindows[number] = window }
            }
            // The record goes only after a confirmed restore.
            if records[id] != nil { records[id] = nil; saveRecords() }
            hiddenAfterPark.remove(id)
            CodeTileLog.info("restore ok \(tag(id)) attempt=\(attempt)")
            publish()
            return done(.restored)
        }
        setProblem(id, Self.restoreFailure)
        CodeTileLog.warn("restore failed \(tag(id)) attempts=\(attempt)")
        publish()
        done(.failed(Self.restoreFailure))
    }

    // MARK: Fallbacks

    /// Another Space (or Claude hidden): activate that process; macOS switches to the Space by its own setting.
    /// The app never switches Spaces itself.
    func activateWindow(_ id: String, done: @escaping (CodeWindowOutcome) -> Void) {
        guard operations[id] == nil else { return done(.busy) }
        guard let session = session(id), let process = process(of: session.profile) else { return done(.notPossible) }
        switch place(of: session) {
        case .otherSpace, .hidden: break
        default: return done(.notPossible)
        }
        activate(pid: process.pid)
        CodeTileLog.info("activate \(tag(id))")
        done(.activated)
    }

    /// A window closed while parked: `claude://code/continue?session=local_<id>` in that copy's own app (it opens in
    /// Claude's main window). The id is checked before anything is sent.
    func openInMainWindow(_ id: String, done: @escaping (CodeWindowOutcome) -> Void) {
        guard operations[id] == nil else { return done(.busy) }
        guard let session = session(id), case .closed = place(of: session) else { return done(.notPossible) }
        guard let url = CodeDeepLink.continueURL(sessionID: id), let appURL = process(of: session.profile)?.appURL else {
            setProblem(id, "can't open this session")
            publish()
            return done(.failed("can't open this session"))
        }
        operations[id] = .opening
        publish()
        workspace.open(url, withApplicationAt: appURL) { [self] opened in
            queue.async { [self] in
                operations[id] = nil
                if opened {
                    closed[id] = nil
                    CodeTileLog.info("opened in main window \(tag(id))")
                } else {
                    setProblem(id, "couldn't open the session")
                    CodeTileLog.warn("open in main window failed \(tag(id))")
                }
                publish()
                done(opened ? .opened : .failed("couldn't open the session"))
            }
        }
    }

    /// `AXFrontmost` first (works from an accessory app), `NSRunningApplication.activate()` as the fallback.
    func activate(pid: pid_t) {
        if !ax.setFrontmost(pid: pid) { _ = workspace.activate(pid: pid) }
    }

    // MARK: Park all done and ⌃⌥P

    /// Parks each listed session whose window is on the desk, one after the other; windows on another Space are counted
    /// and skipped.
    func parkAll(_ ids: [String], displays: [CodeDisplay], done: @escaping (CodeParkAllResult) -> Void) {
        var result = CodeParkAllResult()
        var pending: [String] = []
        for id in ids {
            guard let session = session(id) else { continue }
            switch place(of: session) {
            case .onDesk: pending.append(id)
            case .otherSpace: result.skippedOtherSpace += 1
            default: break
            }
        }
        func next() {
            guard !pending.isEmpty else {
                CodeTileLog.info("park all done parked=\(result.parked) skipped=\(result.skippedOtherSpace) failed=\(result.failed)")
                return done(result)
            }
            let id = pending.removeFirst()
            park(id, displays: displays) { outcome in
                switch outcome {
                case .parked: result.parked += 1
                case .failed: result.failed += 1
                default: break
                }
                next()
            }
        }
        next()
    }

    /// ⌃⌥P: the focused window of the frontmost app, when that app is a Claude copy and the window is a matched pop-out
    /// (never the main window "Claude").
    func parkFrontmost(pid: pid_t?, processes: [CodeClaudeProcess], displays: [CodeDisplay],
                       done: @escaping (CodeParkFrontmostResult) -> Void) {
        updateProcesses(processes)
        trusted = ax.isTrusted()
        guard trusted else { return done(.noAccessibility) }
        guard let pid, let process = running.first(where: { $0.pid == pid }) else { return done(.notAPopout) }
        let focused: CodeAXElement
        switch ax.focusedWindow(ofPID: pid) {
        case .success(let element?): focused = element
        case .success(nil): return done(.notAPopout)
        case .failure(.apiDisabled): trusted = false; return done(.noAccessibility)
        case .failure: return done(.failed(reason: Self.parkFailure))
        }
        var id = matches.first(where: { $0.value.element == focused })?.key
        if id == nil {
            // Not held yet: join this process now, ignoring the "nothing changed" shortcut.
            refreshServerWindows()
            var memo = AXMemo()
            join(process, memo: &memo, force: true)
            id = matches.first(where: { $0.value.element == focused })?.key
        }
        guard let id, let session = session(id) else { return done(.notAPopout) }
        switch place(of: session) {
        case .parked, .minimized: return done(.alreadyParked)
        case .onDesk:
            park(id, displays: displays) { outcome in
                switch outcome {
                case .parked: done(.parked)
                case .failed(let reason): done(.failed(reason: reason))
                case .noAccessibility: done(.noAccessibility)
                default: done(.failed(reason: Self.parkFailure))
                }
            }
        default: done(.notAPopout)
        }
    }

    /// Reads one window's state from the window server now (the pass's list may be a second old).
    func refreshWindow(_ number: CGWindowID) {
        if let live = server.window(number: number), CodeWindowJoin.isEligible(live) {
            serverWindows[number] = live
        } else {
            serverWindows[number] = nil
        }
    }

    // MARK: Confirmation

    /// Polls the window server until the window's on-screen flag is `onScreen` (a window that is gone counts as off
    /// screen) or `deadline` passes.
    func confirm(number: CGWindowID, onScreen wanted: Bool, deadline: TimeInterval, done: @escaping (Bool) -> Void) {
        let current = server.window(number: number)?.isOnScreen ?? false
        if current == wanted { return done(true) }
        if uptime() >= deadline { return done(false) }
        queue.after(Self.confirmPoll) { [self] in confirm(number: number, onScreen: wanted, deadline: deadline, done: done) }
    }
}
