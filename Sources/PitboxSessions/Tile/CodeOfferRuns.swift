import CryptoKit
import Foundation
import PitboxKit

/// What happened to the offers of each session, from the sheet's `CommandOfferEvent`s: memory only, until the app
/// restarts. A run record holds the first 16 hex characters of the text's SHA-256, never the text.
struct CodeOfferRunBook {
    struct Run: Equatable {
        enum State: Equatable {
            case running
            case finished(exitStatus: Int32, seconds: Double)
            case stopped(signal: Int32, seconds: Double)
            case fetched(FetchFileOutcome)
            case refused(String)
        }
        var offerID: CommandOffer.ID
        var textHash: String
        var runID: UUID?
        var state: State
        var at: Date
    }

    /// The latest run of each session (by session id).
    private(set) var latest: [String: Run] = [:]
    /// Finished runs by session id and text hash, for "ran 4 min ago · exit 0".
    private(set) var history: [String: [String: Run]] = [:]

    /// The text's identity in run records: the first 16 hex characters of its SHA-256.
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Records one event of the sheet for `offer` of session `sessionID`.
    mutating func record(_ event: CommandOfferEvent, offer: CommandOffer, sessionID: String, at now: Date) {
        let hash = Self.hash(offer.text)
        func set(_ state: Run.State, runID: UUID?) {
            let run = Run(offerID: offer.id, textHash: hash, runID: runID, state: state, at: now)
            latest[sessionID] = run
            if case .running = state { return }
            if case .refused = state { return }
            history[sessionID, default: [:]][hash] = run
        }
        switch event {
        case .started(let runID): set(.running, runID: runID)
        case .finished(let runID, let status, let seconds): set(.finished(exitStatus: status, seconds: seconds), runID: runID)
        case .stopped(let runID, let signal, let seconds): set(.stopped(signal: signal, seconds: seconds), runID: runID)
        case .fetched(let outcome): set(.fetched(outcome), runID: nil)
        case .refused(let reason): set(.refused(reason), runID: nil)
        case .copied, .typed, .cancelled: break
        }
    }

    func ran(sessionID: String, text: String) -> Run? { history[sessionID]?[Self.hash(text)] }
}

/// The words of the offer line and the peek's list. Pure.
enum CodeOfferWords {
    /// How long a refusal stays on the line, and a result once its offer went stale.
    static let refusalShown: TimeInterval = 30
    static let staleResultShown: TimeInterval = 30 * 60

    /// The monitor's offer line: a running command first, then the result of a run of one of the current offers (or a
    /// recent one whose offer went stale), then the offers themselves.
    static func line(offers: [CodeOfferEntry], run: CodeOfferRunBook.Run?, now: Date) -> CodeOfferLine? {
        let currentIDs = Set(offers.map(\.id))
        let currentHashes = Set(offers.map { CodeOfferRunBook.hash($0.offer.text) })
        if let run {
            let belongs = currentIDs.contains(run.offerID) || currentHashes.contains(run.textHash)
            let age = now.timeIntervalSince(run.at)
            switch run.state {
            case .running:
                return CodeOfferLine(text: "running…", detail: nil, tone: .running,
                                     action: run.runID.map { .revealRun($0) } ?? .none, count: 0)
            case .refused(let reason) where age < refusalShown:
                return CodeOfferLine(text: "✕ not started: " + (CodePlainText.line(reason, limit: 80) ?? "refused"),
                                     detail: nil, tone: .failed, action: offers.isEmpty ? .none : offerAction(offers), count: offers.count)
            case .finished, .stopped, .fetched:
                if belongs || (offers.isEmpty && age < staleResultShown) {
                    var line = result(run)
                    let others = offers.filter { $0.id != run.offerID && CodeOfferRunBook.hash($0.offer.text) != run.textHash }.count
                    if others > 0 { line.text += " · \(others) more" }
                    return line
                }
            default: break
            }
        }
        guard !offers.isEmpty else { return nil }
        return summary(offers)
    }

    /// "✓ exit 0 · 3 s", "✕ exit 1 · 12 s", "stopped", "✓ In Downloads", …
    static func result(_ run: CodeOfferRunBook.Run) -> CodeOfferLine {
        let reveal: CodeOfferLine.Action = run.runID.map { .revealRun($0) } ?? .none
        switch run.state {
        case .finished(let status, let seconds):
            let time = duration(seconds)
            return status == 0
                ? CodeOfferLine(text: "✓ exit 0 · \(time)", detail: nil, tone: .ok, action: reveal, count: 0)
                : CodeOfferLine(text: "✕ exit \(status) · \(time)", detail: nil, tone: .failed, action: reveal, count: 0)
        case .stopped:
            return CodeOfferLine(text: "stopped", detail: nil, tone: .failed, action: reveal, count: 0)
        case .fetched(let outcome):
            switch outcome {
            case .saved(let name, _):
                return CodeOfferLine(text: "✓ In Downloads: " + (CodePlainText.line(name, limit: 60) ?? "file"), detail: nil,
                                     tone: .ok, action: .none, count: 0)
            case .failed(let reason):
                return CodeOfferLine(text: "✕ fetch failed: " + (CodePlainText.line(reason, limit: 60) ?? "error"), detail: nil,
                                     tone: .failed, action: .none, count: 0)
            case .cancelled:
                return CodeOfferLine(text: "fetch cancelled", detail: nil, tone: .neutral, action: .none, count: 0)
            }
        case .running:
            return CodeOfferLine(text: "running…", detail: nil, tone: .running, action: reveal, count: 0)
        case .refused(let reason):
            return CodeOfferLine(text: "✕ not started: " + (CodePlainText.line(reason, limit: 80) ?? "refused"), detail: nil,
                                 tone: .failed, action: .none, count: 0)
        }
    }

    /// "▶ 1 command", "▶ 3 commands · 1 risky", "▶ Fetch release-notes.md", "▶ 1 command · for the server",
    /// "▶ 1 command · blocked: hidden characters", "▶ 1 command · partly read".
    static func summary(_ offers: [CodeOfferEntry]) -> CodeOfferLine {
        let count = offers.count
        if count == 1, let only = offers.first {
            let assessment = only.assessment
            if assessment.commandClass == .fetchFile, let fetch = assessment.fetch {
                let name = fetch.destinationName ?? (fetch.remotePath as NSString).lastPathComponent
                return CodeOfferLine(text: "▶ Fetch " + (CodePlainText.line(name, limit: 48) ?? "file"), detail: nil,
                                     tone: .offer, action: .openSheet(only.id), count: 1)
            }
            var text = "▶ 1 command"
            if let qualifier = qualifier(assessment) { text += " · " + qualifier }
            return CodeOfferLine(text: text, detail: firstLine(of: only.offer), tone: .offer, action: .openSheet(only.id), count: 1)
        }
        var text = "▶ \(count) commands"
        var parts: [String] = []
        func add(_ number: Int, _ word: String) { if number > 0, parts.count < 2 { parts.append("\(number) \(word)") } }
        let classes = offers.map(\.assessment.commandClass)
        add(classes.filter { $0 == .blocked }.count, "blocked")
        if classes.contains(.partlyRead), parts.count < 2 { parts.append("partly read") }
        add(classes.filter { $0 == .risky }.count, "risky")
        add(classes.filter { $0 == .forServer || $0 == .otherMachine }.count, "for the server")
        add(classes.filter { $0 == .fetchFile }.count, "fetch")
        add(classes.filter { $0 == .needsEditing }.count, "to fill in")
        if !parts.isEmpty { text += " · " + parts.joined(separator: " · ") }
        return CodeOfferLine(text: text, detail: nil, tone: .offer, action: .openPeek, count: count)
    }

    private static func offerAction(_ offers: [CodeOfferEntry]) -> CodeOfferLine.Action {
        offers.count == 1 ? .openSheet(offers[0].id) : .openPeek
    }

    /// The word after "▶ 1 command · ", nil for Not flagged.
    static func qualifier(_ assessment: CommandAssessment) -> String? {
        switch assessment.commandClass {
        case .notFlagged: return nil
        case .risky: return "risky"
        case .needsEditing: return "needs editing"
        case .otherMachine:
            if case .remote(let host) = assessment.machine, let host = CodePlainText.line(host, limit: 32) { return "runs on " + host }
            return "runs on another machine"
        case .forServer: return "for the server"
        case .unclearMachine: return "machine unclear"
        case .fetchFile: return "fetch"
        case .partlyRead: return "partly read"
        case .blocked: return "blocked: " + blockWords(assessment.blockReason)
        }
    }

    static func blockWords(_ rule: CommandRule?) -> String {
        switch rule {
        case .b1?: return "hidden characters"
        case .b2?: return "look-alike characters"
        case .b3?: return "syntax not readable"
        case .b4?: return "too long to review"
        case .b5?: return "decoded text run"
        case .b6?: return "known destroyer"
        default: return "not runnable"
        }
    }

    /// The words of the button that opens the sheet: "▶ Run…" for classes that can run after
    /// review while Run is on (`commands` run), "⤓ Fetch…" for Fetch file, "Review…" for the others, and for every
    /// command while Run is off (`copyOnly`, the default: the sheet offers Copy and Type, no Run). A click only opens
    /// the sheet.
    static func reviewTitle(_ assessment: CommandAssessment, commands: CodeSettings.Commands) -> String {
        switch assessment.commandClass {
        case .notFlagged, .risky, .unclearMachine: return commands == .run ? "▶ Run…" : "Review…"
        case .fetchFile: return "⤓ Fetch…"
        case .needsEditing, .otherMachine, .forServer, .partlyRead, .blocked: return "Review…"
        }
    }

    /// The peek's class chip.
    static func classChip(_ assessment: CommandAssessment) -> (String, CodeOfferLine.Tone) {
        switch assessment.commandClass {
        case .notFlagged: return ("Not flagged", .neutral)
        case .risky: return ("Risky", .failed)
        case .needsEditing: return ("Needs editing", .neutral)
        case .forServer: return ("For the server", .neutral)
        case .otherMachine: return ("Other machine", .neutral)
        case .unclearMachine: return ("Unclear", .neutral)
        case .partlyRead: return ("Partly read", .neutral)
        case .blocked: return ("Blocked", .failed)
        case .fetchFile: return ("Fetch file", .offer)
        }
    }

    /// The peek's machine chip: "This Mac", the server alias, the remote host, or "?".
    static func machineChip(_ assessment: CommandAssessment, alias: String?) -> String {
        switch assessment.machine {
        case .thisMac: return "This Mac"
        case .server: return CodePlainText.line(alias, limit: 24) ?? "server"
        case .remote(let host): return CodePlainText.line(host, limit: 24) ?? "?"
        case .unclear: return "?"
        }
    }

    /// Copy is off for B1 (Copy cleaned is on the sheet), B2 and B5.
    static func canCopy(_ assessment: CommandAssessment) -> Bool {
        guard assessment.commandClass == .blocked else { return true }
        let rules = Set(assessment.flags.filter { $0.rule.blocks }.map(\.rule))
        return rules.isDisjoint(with: [.b1, .b2, .b5])
    }

    /// The first command line of an offer, plain text (B1 escaped), for previews.
    static func firstLine(of offer: CommandOffer) -> String? {
        let first = offer.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let line = CodePlainText.command(first, limit: 160)
        return line.isEmpty ? nil : line
    }

    /// "ran 4 min ago · exit 0".
    static func ranNote(_ run: CodeOfferRunBook.Run, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(run.at) / 60)
        let ago = minutes < 1 ? "just now" : "\(CodeWindowStatus.duration(minutes: minutes)) ago"
        switch run.state {
        case .finished(let status, _): return "ran \(ago) · exit \(status)"
        case .stopped: return "ran \(ago) · stopped"
        case .fetched(.saved): return "fetched \(ago)"
        case .fetched: return "fetch tried \(ago)"
        default: return "ran \(ago)"
        }
    }

    /// "3 s", "12 s", "2 min 5 s", "1 h 4 min".
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return total % 60 == 0 ? "\(total / 60) min" : "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \((total % 3600) / 60) min"
    }
}
