import CoreGraphics
import Foundation

/// A session's window, held once matched: it is joined again only when it is gone.
struct CodeWindowMatch: Equatable, @unchecked Sendable {
    var pid: pid_t
    var number: CGWindowID
    var element: CodeAXElement
}

/// What the parker publishes after a pass or an operation.
struct CodeParkerSnapshot: Equatable, Sendable {
    var statuses: [String: CodeWindowStatus]
    var parkedSessionIDs: Set<String>
    /// Matched pop-outs on the desk (for desk tags and drag-to-park).
    var deskWindows: [String: CodeDeskWindow] = [:]
}

/// The window join and the parker's state. Confined to `queue`: every method runs there, so the state needs
/// no locks; `onPublish` is called there too. All system calls go through the seams.
///
/// Rules, tightened after watching real Claude windows: a window is joined
/// only when it is on screen or minimized and its AX title is a session's title (never empty, never "Claude"); there is
/// no match by position; a held window that leaves the screen is minimized, Claude hidden, another Space, or closed,
/// where "closed" also covers a pop-out Claude closed but kept alive as a hidden window (its record left
/// `session-popouts.json`).
final class CodeParkerCore: @unchecked Sendable {
    let server: CodeWindowServer
    let ax: CodeAccessibility
    let workspace: CodeWorkspace
    let store: CodeParkedRecordStore
    let queue: CodeWorkQueue
    /// Wall time, for `parkedAt`.
    let clock: () -> Date
    /// Monotonic seconds, for timeouts and caches.
    let uptime: () -> TimeInterval
    /// Called on the queue after the published state changed.
    var onPublish: ((CodeParkerSnapshot) -> Void)?

    /// How long a confirmation waits for the window server.
    static let confirmTimeout: TimeInterval = 1.5
    static let confirmPoll: TimeInterval = 0.1
    /// An unchanged process is joined again at most this often (a pop-out that cannot be matched is retried slowly).
    static let rejoinInterval: TimeInterval = 10
    /// An off-screen window's kind is read again after this long.
    static let offscreenRecheck: TimeInterval = 5
    /// How long a failure stays on the chip.
    static let problemDuration: TimeInterval = 15

    /// Why a held window is off screen.
    enum OffscreenKind: Equatable { case minimized, appHidden, hiddenByClaude, otherSpace }

    struct OffscreenEntry: Equatable {
        var kind: OffscreenKind
        var at: TimeInterval
        /// Whether Claude listed the pop-out when the kind was read: a change reads it again.
        var hasPopout: Bool
    }

    var sessions: [CodeWindowSessionInput] = []
    var running: [CodeClaudeProcess] = []
    var matches: [String: CodeWindowMatch] = [:]
    var records: [String: CodeParkedRecord] = [:]
    var operations: [String: CodeWindowBusy] = [:]
    var problems: [String: (text: String, until: TimeInterval)] = [:]
    /// Sessions whose window was closed while parked, with the pid they belonged to (memory only).
    var closed: [String: pid_t] = [:]
    var offscreen: [CGWindowID: OffscreenEntry] = [:]
    var lastJoin: [pid_t: (signature: Int, at: TimeInterval)] = [:]
    var serverWindows: [CGWindowID: CodeServerWindow] = [:]
    /// Parked sessions whose window Claude hid instead of minimizing (memory only, until the record goes).
    var hiddenAfterPark: Set<String> = []
    var trusted = true
    var recordsLoaded = false
    private var published: CodeParkerSnapshot?

    init(server: CodeWindowServer, ax: CodeAccessibility, workspace: CodeWorkspace, store: CodeParkedRecordStore,
         queue: CodeWorkQueue, clock: @escaping () -> Date, uptime: @escaping () -> TimeInterval) {
        self.server = server; self.ax = ax; self.workspace = workspace; self.store = store; self.queue = queue
        self.clock = clock; self.uptime = uptime
    }

    // MARK: Inputs

    /// The sessions the block shows (titles, the pop-out file's hint, whether Claude lists the pop-out).
    func setSessions(_ list: [CodeWindowSessionInput]) {
        sessions = list
    }

    func loadRecordsIfNeeded() {
        guard !recordsLoaded else { return }
        recordsLoaded = true
        for record in store.load() { records[record.sessionID] = record }
        if !records.isEmpty { CodeTileLog.info("parked records loaded count=\(records.count)") }
    }

    func saveRecords() {
        store.save(records.values.sorted { $0.parkedAt < $1.parkedAt })
    }

    // MARK: The pass

    /// One pass: the processes, the window-server list, held windows, the join, the records.
    func pass(processes: [CodeClaudeProcess]) {
        loadRecordsIfNeeded()
        updateProcesses(processes)
        trusted = ax.isTrusted()
        refreshServerWindows()
        var memo = AXMemo()
        if trusted {
            checkHeldWindows(&memo)
            for process in running { join(process, memo: &memo, force: false) }
            // Windows joined just now that are minimized get their kind read too.
            checkHeldWindows(&memo)
        }
        cleanRecords(memo: memo)
        let now = uptime()
        problems = problems.filter { $0.value.until > now }
        publish()
    }

    /// The process list changed: everything of a process that ended goes (Claude quit or relaunched). A record
    /// goes only when its process is really gone (`isClaudeRunning`), never because the list is empty or not there yet.
    func updateProcesses(_ processes: [CodeClaudeProcess]) {
        let listed = Set(processes.map(\.pid))
        for pid in Set(running.map(\.pid)).subtracting(listed) { ax.forget(pid: pid); lastJoin[pid] = nil }
        let letters = processes.map(\.profile.letter).filter { $0 != "?" }
        if Set(letters).count != letters.count { CodeTileLog.warn("two Claude processes claim one copy; the first is used") }
        running = processes
        var gone: [pid_t: Bool] = [:]
        func ended(_ pid: pid_t) -> Bool {
            if listed.contains(pid) { return false }
            if let known = gone[pid] { return known }
            let value = !workspace.isClaudeRunning(pid: pid)
            gone[pid] = value
            return value
        }
        matches = matches.filter { listed.contains($0.value.pid) || operations[$0.key] != nil }
        closed = closed.filter { !ended($0.value) }
        let before = records.count
        records = records.filter { !ended($0.value.pid) || operations[$0.key] != nil }
        if records.count != before {
            CodeTileLog.info("parked records dropped count=\(before - records.count) reason=process-ended")
            saveRecords()
        }
    }

    func refreshServerWindows() {
        let pids = Set(running.map(\.pid))
        let list = pids.isEmpty ? [] : server.windows(ofPIDs: pids).filter(CodeWindowJoin.isEligible)
        serverWindows = Dictionary(list.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The pid's AX window list, read at most once per pass.
    struct AXMemo {
        var windows: [pid_t: Result<[CodeAXElement], CodeAXFailure>] = [:]
        /// Processes the join read this pass, and the window numbers AX reported for them.
        var joined: Set<pid_t> = []
        var reportedNumbers: Set<CGWindowID> = []
    }

    func axWindows(_ pid: pid_t, _ memo: inout AXMemo) -> Result<[CodeAXElement], CodeAXFailure> {
        if let known = memo.windows[pid] { return known }
        let result = ax.windows(ofPID: pid)
        if case .failure(.apiDisabled) = result { trusted = false }
        memo.windows[pid] = result
        return result
    }

    func isVisibleToAX(_ match: CodeWindowMatch, _ memo: inout AXMemo) -> Bool? {
        switch axWindows(match.pid, &memo) {
        case .success(let list): return list.contains(match.element)
        case .failure: return nil
        }
    }

    // MARK: Held windows

    private enum Judgement { case kind(OffscreenKind), closed, unknown }

    /// Every held window that is not on screen: its kind, or closed. A closed window's match goes; when
    /// the app had parked it, its record goes too and the monitor says "window closed".
    func checkHeldWindows(_ memo: inout AXMemo) {
        let now = uptime()
        var offscreenNumbers = Set<CGWindowID>()
        for (id, match) in matches where operations[id] == nil {
            let window = serverWindows[match.number]
            if window?.isOnScreen == true { continue }
            offscreenNumbers.insert(match.number)
            let hasPopout = session(id)?.hasPopout ?? true
            if let known = offscreen[match.number], known.hasPopout == hasPopout, now - known.at < Self.offscreenRecheck { continue }
            switch judge(id, match, window: window, hasPopout: hasPopout, &memo) {
            case .kind(let kind):
                offscreen[match.number] = OffscreenEntry(kind: kind, at: now, hasPopout: hasPopout)
            case .closed:
                drop(id, match)
            case .unknown:
                break
            }
        }
        offscreen = offscreen.filter { offscreenNumbers.contains($0.key) }
    }

    private func judge(_ id: String, _ match: CodeWindowMatch, window: CodeServerWindow?, hasPopout: Bool,
                       _ memo: inout AXMemo) -> Judgement {
        let appHidden = running.first { $0.pid == match.pid }?.isHidden == true
        // A window the app parked, still listed by the server and by Claude's file: parked, no AX needed.
        if let record = records[id], record.windowNumber == match.number, window != nil, hasPopout { return .kind(.minimized) }
        guard let visible = isVisibleToAX(match, &memo) else { return .unknown }
        if visible {
            switch ax.isMinimized(match.element) {
            case .success(true): return .kind(.minimized)
            case .success(false):
                if appHidden { return .kind(.appHidden) }
                // Off screen, not minimized, Claude not hidden: Claude hid it. Without its record in Claude's file it is a
                // closed pop-out kept alive.
                return hasPopout ? .kind(.hiddenByClaude) : .closed
            case .failure(.invalidElement): return .closed
            case .failure: return .unknown
            }
        }
        if appHidden { return .kind(.appHidden) }
        if window == nil { return .closed }                     // gone from the server and from AX
        return hasPopout ? .kind(.otherSpace) : .closed
    }

    private func drop(_ id: String, _ match: CodeWindowMatch) {
        matches[id] = nil
        offscreen[match.number] = nil
        guard records[id] != nil else { return }
        records[id] = nil
        closed[id] = match.pid
        saveRecords()
        CodeTileLog.info("window closed while parked \(tag(id))")
    }

    // MARK: The join

    /// Joins the unmatched sessions of one process with its windows. Skipped while nothing about the process or its
    /// sessions changed since the last attempt, for at most `rejoinInterval`, unless `force`.
    func join(_ process: CodeClaudeProcess, memo: inout AXMemo, force: Bool) {
        let open = sessions
            .filter { $0.profile == process.profile && matches[$0.id] == nil && operations[$0.id] == nil }
            .map { session -> CodeWindowSessionInput in
                // A parked record's saved frame tells two equal titles apart better than the pop-out file.
                var session = session
                if let record = records[session.id], record.pid == process.pid { session.hint = record.frame }
                return session
            }
        guard !open.isEmpty else { return }
        let own = serverWindows.values.filter { $0.pid == process.pid }.sorted { $0.number < $1.number }
        var hasher = Hasher()
        hasher.combine(process.isHidden)
        for window in own {
            hasher.combine(window.number); hasher.combine(window.isOnScreen)
            hasher.combine(window.bounds.minX); hasher.combine(window.bounds.minY)
            hasher.combine(window.bounds.width); hasher.combine(window.bounds.height)
        }
        for session in open.sorted(by: { $0.id < $1.id }) {
            hasher.combine(session.id); hasher.combine(session.title); hasher.combine(session.previousTitles)
            hasher.combine(session.hint?.minX); hasher.combine(session.hint?.minY); hasher.combine(session.hasPopout)
        }
        let signature = hasher.finalize()
        let now = uptime()
        if !force, let last = lastJoin[process.pid], last.signature == signature, now - last.at < Self.rejoinInterval { return }
        lastJoin[process.pid] = (signature, now)

        guard case .success(let elements) = axWindows(process.pid, &memo) else { return }
        memo.joined.insert(process.pid)
        let held = Set(matches.values.map(\.element))
        let heldNumbers = Set(matches.values.map(\.number))
        var candidates: [CodeJoinWindow] = []
        for element in elements where !held.contains(element) {
            guard case .success(let info) = ax.info(of: element) else { continue }
            if let role = info.role, role != "AXWindow" { continue }
            let reported = ax.windowNumber(of: element)
            if let reported { memo.reportedNumbers.insert(reported) }
            // A minimized window may be missing from the server list: AX's own number then still counts.
            let number = CodeWindowJoin.resolveNumber(reported: reported, frame: info.frame, serverWindows: own)
                ?? (info.minimized ? reported : nil)
            // Only windows on screen or minimized: Claude keeps hidden windows (a 912 × 622 one was seen) that a
            // stale record could otherwise claim.
            let onScreen = number.flatMap { serverWindows[$0]?.isOnScreen } ?? false
            guard onScreen || info.minimized else { continue }
            candidates.append(CodeJoinWindow(element: element, title: info.title, frame: info.frame,
                                             minimized: info.minimized, number: number))
        }

        var matchedCount = 0
        var used = Set<Int>()
        var remaining = open
        // Records first: after a restart a parked window is found by its stored number when AX reports it.
        for session in open {
            guard let record = records[session.id], record.pid == process.pid,
                  let index = candidates.firstIndex(where: { $0.number == record.windowNumber }), !used.contains(index),
                  let title = candidates[index].title, !title.isEmpty, title != CodeWindowJoin.mainWindowTitle else { continue }
            hold(session.id, CodeWindowMatch(pid: process.pid, number: record.windowNumber, element: candidates[index].element))
            used.insert(index)
            remaining.removeAll { $0.id == session.id }
            matchedCount += 1
        }
        let pool = candidates.indices.filter { !used.contains($0) }
        let titled = CodeWindowJoin.matchTitles(sessions: remaining, windows: pool.map { candidates[$0] })
        for (id, poolIndex) in titled {
            let window = candidates[pool[poolIndex]]
            // After a restart a minimized window found by title and saved frame keeps its stored number when AX cannot
            // report one.
            let stored = window.minimized ? records[id].flatMap { $0.pid == process.pid ? $0.windowNumber : nil } : nil
            guard let number = window.number ?? stored, !heldNumbers.contains(number),
                  !matches.values.contains(where: { $0.number == number }) else { continue }
            hold(id, CodeWindowMatch(pid: process.pid, number: number, element: window.element))
            matchedCount += 1
        }
        if matchedCount > 0 {
            CodeTileLog.info("join pid=\(process.pid) windows=\(candidates.count) matched=\(matchedCount) open=\(open.count - matchedCount)")
        }
    }

    private func hold(_ id: String, _ match: CodeWindowMatch) {
        matches[id] = match
        closed[id] = nil   // the pop-out was opened again
    }

    /// Records whose process ended went with the process. Here: a window seen on screen again (the user restored it,
    /// the record goes, the window is never moved) and an unmatched record whose window is gone.
    func cleanRecords(memo: AXMemo) {
        var changed = false
        for (id, record) in records where operations[id] == nil {
            if let match = matches[id] {
                if match.number == record.windowNumber, serverWindows[match.number]?.isOnScreen == true {
                    records[id] = nil
                    changed = true
                    CodeTileLog.info("parked record dropped \(tag(id)) reason=back-on-screen")
                }
                continue
            }
            // Unmatched (after a restart): gone only when the server lost the number and AX, read this pass, did not
            // report it either.
            if serverWindows[record.windowNumber] == nil, memo.joined.contains(record.pid),
               !memo.reportedNumbers.contains(record.windowNumber) {
                records[id] = nil
                closed[id] = record.pid
                changed = true
                CodeTileLog.info("parked record dropped \(tag(id)) reason=window-gone")
            }
        }
        if changed { saveRecords() }
    }

    // MARK: Statuses

    func process(of profile: CodeProfile) -> CodeClaudeProcess? { running.first { $0.profile == profile } }

    func session(_ id: String) -> CodeWindowSessionInput? { sessions.first { $0.id == id } }

    func place(of session: CodeWindowSessionInput) -> CodeWindowPlace {
        guard process(of: session.profile) != nil else { return .profileNotRunning(letter: session.profile.letter) }
        guard trusted else { return .noAccessibility }
        if let match = matches[session.id] {
            let window = serverWindows[match.number]
            if window?.isOnScreen == true { return .onDesk }
            if let record = records[session.id], record.windowNumber == match.number {
                return hiddenAfterPark.contains(session.id) ? .hiddenByClaude : .parked(since: record.parkedAt)
            }
            switch offscreen[match.number]?.kind {
            case .minimized?: return .minimized
            case .appHidden?: return .hidden
            case .hiddenByClaude?: return .hiddenByClaude
            case .otherSpace?: return .otherSpace
            case nil: return window == nil ? .minimized : .otherSpace   // not read yet (Claude did not answer)
            }
        }
        if closed[session.id] != nil { return .closed }
        if records[session.id] != nil { return .parkedNotMatched }
        return .notMatched
    }

    func status(of session: CodeWindowSessionInput) -> CodeWindowStatus {
        let problem = problems[session.id].flatMap { $0.until > uptime() ? $0.text : nil }
        return CodeWindowStatus(place: place(of: session), busy: operations[session.id], problem: problem)
    }

    func snapshot() -> CodeParkerSnapshot {
        var statuses: [String: CodeWindowStatus] = [:]
        var desk: [String: CodeDeskWindow] = [:]
        for session in sessions {
            let status = status(of: session)
            statuses[session.id] = status
            if status.place == .onDesk, let match = matches[session.id] {
                desk[session.id] = CodeDeskWindow(pid: match.pid, windowNumber: match.number)
            }
        }
        hiddenAfterPark = hiddenAfterPark.filter { records[$0] != nil }
        return CodeParkerSnapshot(statuses: statuses, parkedSessionIDs: Set(records.keys).union(closed.keys),
                                  deskWindows: desk)
    }

    func publish() {
        let next = snapshot()
        guard next != published else { return }
        published = next
        onPublish?(next)
    }

    func setProblem(_ id: String, _ text: String) {
        problems[id] = (text, uptime() + Self.problemDuration)
    }

    /// `session=#3` for logs: the session's local index, never its id or title.
    func tag(_ id: String) -> String {
        guard let session = session(id) else { return "session=#?" }
        return "session=#\(session.index)"
    }
}
