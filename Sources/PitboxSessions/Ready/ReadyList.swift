import Foundation
import PitboxKit

/// The Ready list as drawn.
struct CodeReadySnapshot: Equatable {
    /// "Ready for you · 4", the followed note and the 5 s "Dismissed · Undo".
    struct Header: Equatable {
        var count: Int
        var followNote: String?
        var undoShown: Bool
    }

    /// A run, a typed text or a fetch from an item: a 28 pt row for 10 minutes or until OK.
    struct ResultRow: Equatable {
        enum State: Equatable {
            case running
            case finished(exitStatus: Int32, seconds: Double)
            case stopped(seconds: Double)
            case typed
            case fetched(fileName: String, bytes: Int64)
            case fetchFailed(reason: String)
        }
        var state: State
        var runID: UUID?
        var at: Date
    }

    /// One drawn entry: a card, a folded Later row or a result row.
    struct Entry: Equatable {
        enum Style: Equatable { case card, later, result(ResultRow) }
        var item: CodeReadyItem
        var style: Style
    }

    /// Counts for the summary line and the bucket badges.
    struct Counts: Equatable {
        /// Command and file items, Later ones included.
        var commands = 0
        var files = 0
        /// Open Finished items, active warnings.
        var finished = 0
        var warnings = 0
    }

    var header: Header?
    var recap: CodeAwayRecap.Recap?
    /// Cards and result rows shown, in order.
    var entries: [Entry] = []
    /// Cards behind "N more ▾" (0: none; with the list expanded the line reads "Show fewer").
    var more = 0
    var expanded = false
    /// Later rows, in the order they were folded.
    var later: [Entry] = []
    /// Items of recent sessions the user used least recently, hidden by the 40-item cap (never dismissed).
    var hiddenRecent = 0
    var counts = Counts()
    var countsBySession: [String: Counts] = [:]
    /// Offers the list no longer shows (dismissed; run, typed or fetched) and, per session, the warnings the user OK'd:
    /// desk tags drop them too (`DeskTagSuppressed`). Later keeps an item, and so its tag.
    var suppressedOffers: Set<CommandOffer.ID> = []
    var okWarnings: [String: Set<String>] = [:]

    /// No list at all (heading included).
    var isEmpty: Bool { header == nil && recap == nil }
}

/// Ready for you: one list of commands, files, finished work and warnings from every followed session.
/// Main thread. It keeps Later and Dismiss in `CodeMemoryStore` (key `ready`), closes Finished items through the
/// finished records and hands everything that opens a sheet, a window or a link to the block (`onAction`). It never
/// runs anything: ▶ Run…, Review… and ⤓ Fetch… only ask the block to open the sheet.
@MainActor
final class CodeReadyList {
    let memory: CodeMemoryStore
    /// The list as drawn.
    private(set) var snapshot = CodeReadySnapshot()
    /// Presses the block handles (a sheet, a window, a monitor, a link, a fetched file), with the pressed card's frame
    /// in screen coordinates (the sheet opens beside the block, next to it; `.zero` when unknown).
    var onAction: ((CodeReadyAction, CGRect) -> Void)?
    /// Got it on the recap card.
    var onGotIt: (() -> Void)?
    /// Called after `snapshot` changed.
    var onChange: (() -> Void)?
    /// OK on a warning (Warnings silence it for the rest of the work, or the pair and file for 2 hours).
    var onWarningOK: ((_ sessionID: String, _ warning: CodeWarning) -> Void)?
    /// Whether a fetched file gets Open next to Show in Finder (documents only); default: Finder only.
    var fetchedFileOpens: (String) -> Bool = { _ in false }
    /// Runs `work` after `seconds` on the main thread (the 5 s Undo); tests replace it.
    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }
    var clock = CodeReadyClock()
    /// The wall clock for presses (Later's order, "You dismissed this at 14:05"); `CodeReadyForYou` passes its own.
    var now: @MainActor () -> Date = { Date() }

    /// Every item now in the list (cards, rows behind "more", Later rows and items hidden by the cap), for the recap.
    private(set) var allItems: [CodeReadyItem] = []

    /// The recap card, set by `CodeReadyForYou`.
    var recap: CodeAwayRecap.Recap? {
        didSet { if recap != oldValue { rebuild() } }
    }

    private var input: CodeReadyInput?
    /// Item keys that were run, typed or fetched: they leave as items (a result row follows).
    private var ran: Set<String> = []
    private var results: [String: (row: CodeReadySnapshot.ResultRow, item: CodeReadyItem)] = [:]
    /// Finished items OK'd here, until the engine's next publication says so too.
    private var closed: Set<String> = []
    private var undo: (key: String, session: String, until: Date, generation: Int)?
    private var undoGeneration = 0
    private var expanded = false
    private var showsHidden = false

    init(memory: CodeMemoryStore) {
        self.memory = memory
    }

    // MARK: Input

    /// A new block rebuild: sessions, followed set, windows, the clock.
    func update(_ input: CodeReadyInput) {
        self.input = input
        rebuild()
    }

    /// The block's sheet reported `event` for `offer` (from the list, a monitor or a tag: every run counts).
    func record(_ event: CommandOfferEvent, offer: CommandOffer, sessionID: String, now: Date) {
        guard let key = CodeReadyKey.command(offer, session: sessionID) else { return }
        let state: CodeReadySnapshot.ResultRow.State
        var runID: UUID?
        var leaves = true
        switch event {
        case .started(let id): state = .running; runID = id
        case .finished(let id, let status, let seconds): state = .finished(exitStatus: status, seconds: seconds); runID = id
        case .stopped(let id, _, let seconds): state = .stopped(seconds: seconds); runID = id
        case .typed: state = .typed
        case .fetched(.saved(let name, let bytes)): state = .fetched(fileName: name, bytes: bytes)
        case .fetched(.failed(let reason)): state = .fetchFailed(reason: reason); leaves = false
        case .fetched(.cancelled), .copied, .cancelled, .refused: return
        }
        guard let item = currentItem(key) ?? results[key]?.item else { return }
        if leaves { ran.insert(key) }
        results[key] = (CodeReadySnapshot.ResultRow(state: state, runID: runID ?? results[key]?.row.runID, at: now), item)
        CodeTileLog.info("ready result session=#\(item.sessionIndex) kind=\(Self.label(state))")
        rebuild()
    }

    /// When the user dismissed this offer, for the peek's greyed "dismissed" and the sheet's "You dismissed this at …".
    func dismissedAt(_ offerID: CommandOffer.ID, in session: CodeSessionSnapshot) -> Date? {
        guard let entry = (session.offers + session.earlierOffers).first(where: { $0.id == offerID }),
              let key = CodeReadyKey.command(entry.offer, session: session.id),
              let state = states(session.id)[key], state.state == CodeReadyStateRecord.dismissed else { return nil }
        return state.at
    }

    // MARK: Presses

    /// A press on a list button (the view calls it; arming was checked there). `anchor`: the card's screen frame.
    func press(_ action: CodeReadyAction, anchor: CGRect = .zero) {
        let now = self.now()
        switch action {
        case .later(let key):
            setState(key, CodeReadyStateRecord(state: CodeReadyStateRecord.later, at: now))
            CodeTileLog.info("ready item later \(tag(key))")
        case .unfold(let key):
            setState(key, nil)
        case .dismiss(let key):
            setState(key, CodeReadyStateRecord(state: CodeReadyStateRecord.dismissed, at: now))
            undoGeneration += 1
            let generation = undoGeneration
            undo = (key, session(of: key), now.addingTimeInterval(CodeTuning.dismissUndo), generation)
            CodeTileLog.info("ready item dismissed \(tag(key))")
            schedule(CodeTuning.dismissUndo) { [weak self] in self?.undoExpired(generation) }
        case .undoDismiss:
            guard let undo else { return }
            self.undo = nil
            setState(undo.key, nil)
            CodeTileLog.info("ready item restored \(tag(undo.key))")
        case .ok(let key):
            ok(key, now: now)
        case .openWindow(let id):
            closeFinished(of: id, now: now)
            onAction?(action, anchor)
        case .showMore:
            expanded.toggle()
        case .showHidden:
            showsHidden = true
        case .gotIt:
            onGotIt?()
        default:
            onAction?(action, anchor)
        }
        rebuild()
    }

    private func ok(_ key: String, now: Date) {
        if results[key] != nil {
            results[key] = nil
            return
        }
        let id = session(of: key)
        if key.hasPrefix("fin:") {
            let reply = String(key.dropFirst("fin:".count + id.count + 1))
            CodeFinishedRecords.close(reply, session: id, memory: memory)
            CodeUnreadMarks.markSeen(id, memory: memory, now: now)
            closed.insert(key)
            CodeTileLog.info("ready item ok \(tag(key)) kind=finished")
        } else if key.hasPrefix("warn:") {
            setState(key, CodeReadyStateRecord(state: CodeReadyStateRecord.dismissed, at: now))
            let rule = String(key.dropFirst("warn:".count + id.count + 1))
            if let warning = input?.sessions.first(where: { $0.id == id })?.warnings.first(where: { $0.kind.rawValue == rule }) {
                onWarningOK?(id, warning)
            }
            CodeTileLog.info("ready item ok \(tag(key)) kind=warning")
        }
    }

    /// Open window also clears the item and the unread dot.
    private func closeFinished(of id: String, now: Date) {
        guard let session = input?.sessions.first(where: { $0.id == id }) else { return }
        if let mark = session.finished, mark.isOpen, let key = CodeReadyKey.finished(reply: mark.replyUUID, session: id) {
            CodeFinishedRecords.close(mark.replyUUID, session: id, memory: memory)
            closed.insert(key)
        }
        CodeUnreadMarks.markSeen(id, memory: memory, now: now)
    }

    /// The 5 s of "Dismissed · Undo" are over (a newer Dismiss starts its own 5 s).
    private func undoExpired(_ generation: Int) {
        guard let undo, undo.generation == generation else { return }
        self.undo = nil
        rebuild()
    }

    // MARK: Building

    func rebuild() {
        guard let input else {
            publish(CodeReadySnapshot(recap: recap))
            return
        }
        let now = input.now
        if let undo, undo.until <= now { self.undo = nil }
        results = results.filter { $0.value.row.state == .running || now.timeIntervalSince($0.value.row.at) < CodeTuning.resultRowLife }

        var warnings: [CodeReadyItem] = []
        var offers: [CodeReadySnapshot.Entry] = []
        var finished: [CodeReadyItem] = []
        var later: [(entry: CodeReadySnapshot.Entry, at: Date)] = []
        var alive = Set<String>()
        var counts = CodeReadySnapshot.Counts()
        var bySession: [String: CodeReadySnapshot.Counts] = [:]
        var suppressedOffers = Set<CommandOffer.ID>()
        var okWarnings: [String: Set<String>] = [:]

        for session in input.sessions {
            guard !session.isArchived, let follow = input.followed.kind(of: session.id), input.passesFilter(session) else { continue }
            let stored = states(session.id)
            for item in CodeReadyItemBuilder.items(for: session, follow: follow, input: input, clock: clock) {
                alive.insert(item.id)
                if ran.contains(item.id), let offer = item.offerID { suppressedOffers.insert(offer) }
                guard results[item.id] == nil, !ran.contains(item.id), !closed.contains(item.id) else { continue }
                let state = stored[item.id]
                switch item.kind {
                case .warning:
                    if let state, state.state == CodeReadyStateRecord.dismissed, state.at >= item.time {
                        if let warning = item.warningID { okWarnings[item.sessionID, default: []].insert(warning) }
                        continue
                    }
                    warnings.append(item)
                    counts.warnings += 1
                    bySession[item.sessionID, default: .init()].warnings += 1
                case .command, .file:
                    if state?.state == CodeReadyStateRecord.dismissed {
                        if let offer = item.offerID { suppressedOffers.insert(offer) }
                        continue
                    }
                    if item.kind == .command { counts.commands += 1 } else { counts.files += 1 }
                    if item.kind == .command { bySession[item.sessionID, default: .init()].commands += 1 }
                    else { bySession[item.sessionID, default: .init()].files += 1 }
                    if let state, state.state == CodeReadyStateRecord.later {
                        later.append((laterRow(item), state.at))
                    } else {
                        offers.append(CodeReadySnapshot.Entry(item: item, style: .card))
                    }
                case .finished:
                    finished.append(item)
                    counts.finished += 1
                    bySession[item.sessionID, default: .init()].finished += 1
                }
            }
        }
        // Forget runs and local OKs whose items left the snapshot; keep result rows until their time is up.
        ran = ran.intersection(alive.union(results.keys))
        closed = closed.intersection(alive)
        for (_, value) in results { offers.append(CodeReadySnapshot.Entry(item: value.item, style: .result(value.row))) }

        // Order: warnings newest first; commands and files newest reply first, one reply's in reply order;
        // finished newest first; Later rows in the order they were folded.
        warnings.sort { $0.time != $1.time ? $0.time > $1.time : $0.id < $1.id }
        offers.sort(by: Self.offerOrder)
        finished.sort { $0.time != $1.time ? $0.time > $1.time : $0.id < $1.id }
        later.sort { $0.at != $1.at ? $0.at < $1.at : $0.entry.item.id < $1.entry.item.id }
        allItems = warnings + offers.filter { $0.style == .card }.map(\.item) + finished + later.map(\.entry.item)

        // At most 40 items: the oldest finished go first, then the oldest Later rows, then command and file items of the
        // recent sessions the user used least recently are hidden (never desk or parked ones, never a warning).
        var laterEntries = later.map(\.entry)
        var over = warnings.count + offers.count + finished.count + laterEntries.count - CodeTuning.readyMaxItems
        while over > 0, !finished.isEmpty { finished.removeLast(); over -= 1 }
        while over > 0, !laterEntries.isEmpty { laterEntries.removeFirst(); over -= 1 }
        var hidden = 0
        if over > 0, !showsHidden {
            let candidates = offers.enumerated().compactMap { index, entry -> (Int, Date)? in
                guard entry.style == .card, case .recentUsed(let at) = entry.item.follow else { return nil }
                return (index, at)
            }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 > $1.0 }  // least recently used first; a reply's last offers first
            let drop = Set(candidates.prefix(over).map(\.0))
            hidden = drop.count
            offers = offers.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }

        let all = warnings.map { CodeReadySnapshot.Entry(item: $0, style: .card) } + offers
            + finished.map { CodeReadySnapshot.Entry(item: $0, style: .card) }
        let visible = input.tallTile ? CodeTuning.readyVisibleCardsTall : CodeTuning.readyVisibleCards
        var next = CodeReadySnapshot()
        next.recap = recap
        next.entries = expanded ? all : Array(all.prefix(visible))
        next.more = max(0, all.count - visible)
        next.expanded = expanded && next.more > 0
        next.later = laterEntries
        next.hiddenRecent = hidden
        next.counts = counts
        next.countsBySession = bySession
        next.suppressedOffers = suppressedOffers
        next.okWarnings = okWarnings
        let count = all.filter { $0.style == .card }.count + laterEntries.count
        if count > 0 || undo != nil || recap != nil {
            next.header = CodeReadySnapshot.Header(count: count, followNote: input.followed.headerNote, undoShown: undo != nil)
        }
        if next.more == 0 { expanded = false }
        publish(next)
    }

    private func publish(_ next: CodeReadySnapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onChange?()
    }

    /// Newest reply first; one reply's offers in reply order; result rows with their item.
    private static func offerOrder(_ a: CodeReadySnapshot.Entry, _ b: CodeReadySnapshot.Entry) -> Bool {
        if a.item.time != b.item.time { return a.item.time > b.item.time }
        if a.item.sessionID != b.item.sessionID { return a.item.sessionID < b.item.sessionID }
        let na = a.item.offerID?.number ?? Int.max, nb = b.item.offerID?.number ?? Int.max
        return na != nb ? na < nb : a.item.id < b.item.id
    }

    /// The 28 pt Later row: "▶ “<headline>” · <where> [Run…]" (or "⤓ … [Fetch…]"); a click on its text unfolds it.
    private func laterRow(_ item: CodeReadyItem) -> CodeReadySnapshot.Entry {
        var row = item
        let main = item.buttons.first { $0.primary }.map { button -> CodeReadyButton in
            var short = button
            short.title = button.title.replacingOccurrences(of: "▶ ", with: "").replacingOccurrences(of: "⤓ ", with: "")
            return short
        }
        row.buttons = [CodeReadyButton(.unfold(item.id), "Unfold")] + (main.map { [$0] } ?? [])
        return CodeReadySnapshot.Entry(item: row, style: .later)
    }

    private func currentItem(_ key: String) -> CodeReadyItem? {
        for entry in snapshot.entries + snapshot.later where entry.item.id == key { return entry.item }
        guard let input else { return nil }
        let id = session(of: key)
        guard let session = input.sessions.first(where: { $0.id == id }), let follow = input.followed.kind(of: id) else { return nil }
        return CodeReadyItemBuilder.items(for: session, follow: follow, input: input, clock: clock).first { $0.id == key }
    }

    // MARK: Memory

    private func states(_ session: String) -> [String: CodeReadyStateRecord] {
        memory.read(.ready, session: session) ?? [:]
    }

    private func setState(_ key: String, _ value: CodeReadyStateRecord?) {
        let id = session(of: key)
        var all = states(id)
        all[key] = value
        memory.write(.ready, session: id, value: all.isEmpty ? nil : all)
    }

    /// The session id inside an item key (`kind:<session>:…`).
    private func session(of key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    /// "session=#3 kind=command": labels and numbers only (docs/THREAT_MODEL.md).
    private func tag(_ key: String) -> String {
        let index = input?.sessions.first { $0.id == session(of: key) }?.index
        let kind = key.split(separator: ":").first.map(String.init) ?? "item"
        let word = ["cmd": "command", "file": "file", "fin": "finished", "warn": "warning"][kind] ?? "item"
        return "session=#\(index.map(String.init) ?? "?") kind=\(word)"
    }

    private static func label(_ state: CodeReadySnapshot.ResultRow.State) -> String {
        switch state {
        case .running: return "running"
        case .finished(let status, _): return status == 0 ? "ok" : "failed"
        case .stopped: return "stopped"
        case .typed: return "typed"
        case .fetched: return "fetched"
        case .fetchFailed: return "fetch-failed"
        }
    }
}
