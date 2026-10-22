import Foundation
import PitboxKit

/// What the Ready list is built from at each rebuild of the block (main thread).
struct CodeReadyInput {
    /// `CodeSessionsSource.sessions`: pop-outs and the followed sessions, in the block's fixed order.
    var sessions: [CodeSessionSnapshot]
    var followed: CodeFollowedSet
    /// The window side's statuses (`CodeWindowParking.statuses`).
    var statuses: [String: CodeWindowStatus]
    /// The bucket a parked session sits in, for "in the pit (Toy Cube)".
    var bucketName: (String) -> String? = { _ in nil }
    /// Hide text in the block's header, and `showText` per copy letter.
    var hideText = false
    var showText: [String: Bool] = [:]
    /// The block's focus filter, applied only while more than one copy runs.
    var passesFilter: (CodeSessionSnapshot) -> Bool = { _ in true }
    /// The block has 12 rows or more: 6 cards show instead of 3.
    var tallTile = false
    var now: Date
    /// `CodeSettings.commands`: with Run off (`copyOnly`, the default) a command card's button says "Review…".
    var commands: CodeSettings.Commands = .copyOnly
}

/// Builds one session's items. Pure; session text passes the plain-text renderer here.
enum CodeReadyItemBuilder {
    /// The items of `session`, followed as `follow`, before Later, Dismiss and OK are applied.
    static func items(for session: CodeSessionSnapshot, follow: CodeFollowedSet.Kind, input: CodeReadyInput,
                      clock: CodeReadyClock) -> [CodeReadyItem] {
        let id = session.id
        let hidden = input.hideText || input.showText[session.profile.letter] == false
        let headline = "“" + (CodePlainText.line(session.headline, limit: 80) ?? "Untitled session") + "”"
        let status = input.statuses[id]
        let whereText = CodeReadyWords.whereText(follow, status: status, bucket: input.bucketName(id), now: input.now)
        let showButton = CodeReadyWords.showButton(follow, status: status, session: id)
        let ownOnly = !follow.getsOffers
        let dashboard = session.dashboard != nil && !ownOnly
            ? CodeReadyButton(.openDashboard(sessionID: id), "▦ Dashboard", opens: true) : nil
        var out: [CodeReadyItem] = []

        // Warnings.
        for warning in session.warnings {
            var buttons: [CodeReadyButton]
            if follow.isRecent {
                buttons = [CodeReadyButton(.openInClaude(sessionID: id), "Open in Claude")]
            } else {
                buttons = [CodeReadyWords.windowButton(follow, session: id, primary: false), showButton]
            }
            if let dashboard { buttons.append(dashboard) }
            buttons.append(CodeReadyButton(.ok(CodeReadyKey.warning(warning.kind, session: id)), "OK"))
            out.append(CodeReadyItem(
                id: CodeReadyKey.warning(warning.kind, session: id), kind: .warning, sessionID: id,
                sessionIndex: session.index, follow: follow, headline: headline, whereText: whereText, time: warning.since,
                title: CodeReadyWords.warningTitle(warning.kind), titleNote: nil, detail: "\(headline) · \(whereText)",
                line: hidden ? CodeReadyWords.hidden : CodeReadyWords.reason(warning, now: input.now), buttons: buttons,
                warningID: warning.id))
        }

        // Commands and files: offers of the latest reply and earlier ones, never from own-activity sessions.
        if follow.getsOffers {
            for entry in session.offers + session.earlierOffers {
                guard let key = CodeReadyKey.command(entry.offer, session: id) else { continue }
                out.append(offerItem(entry, key: key, session: session, follow: follow, headline: headline,
                                     whereText: whereText, showButton: showButton, hidden: hidden,
                                     commands: input.commands, clock: clock))
            }
            if let reply = session.replyUUID ?? session.finished?.replyUUID {
                for result in session.results where result.kind == .serverFile {
                    guard let path = result.path, let key = CodeReadyKey.file(path: path, reply: reply, session: id) else { continue }
                    let buttons = [CodeReadyButton(.fetchResult(sessionID: id, result: result), "⤓ Fetch…", primary: true),
                                   showButton, CodeReadyButton(.later(key), "Later"), CodeReadyButton(.dismiss(key), "Dismiss")]
                    out.append(CodeReadyItem(
                        id: key, kind: .file, sessionID: id, sessionIndex: session.index, follow: follow, headline: headline,
                        whereText: whereText, time: result.at ?? session.turnFinishedAt ?? input.now, title: "⤓ File ready",
                        titleNote: nil, detail: "from \(headline) · \(whereText)",
                        line: hidden ? CodeReadyWords.hidden : CodeReadyWords.fileLine(name: result.label, alias: session.sshHost),
                        buttons: buttons, result: result))
                }
            }
        }

        // Finished.
        if let mark = session.finished, mark.isOpen, mark.hasItem,
           let key = CodeReadyKey.finished(reply: mark.replyUUID, session: id) {
            var buttons: [CodeReadyButton]
            if ownOnly {
                buttons = [CodeReadyButton(.ok(key), "OK"), CodeReadyButton(.openInClaude(sessionID: id), "Open in Claude")]
            } else {
                buttons = [CodeReadyWords.windowButton(follow, session: id, primary: true)]
                if let first = firstResult(session.results, session: id) { buttons.append(first) }
                if let dashboard { buttons.append(dashboard) }
                buttons.append(CodeReadyButton(.ok(key), "OK"))
            }
            let tldr = hidden ? CodeReadyWords.hidden : session.tldr.flatMap { CodeText.firstLines($0, count: 1, limit: 400) }
                .flatMap { CodePlainText.line($0, limit: 200) }
            out.append(CodeReadyItem(
                id: key, kind: .finished, sessionID: id, sessionIndex: session.index, follow: follow, headline: headline,
                whereText: whereText, time: mark.at, title: CodeReadyWords.finishedTitle(mark, clock: clock), titleNote: nil,
                detail: CodeReadyWords.finishedDetail(mark, headline: headline, whereText: whereText, clock: clock),
                line: tldr, buttons: buttons))
        }
        return out
    }

    private static func offerItem(_ entry: CodeOfferEntry, key: String, session: CodeSessionSnapshot,
                                  follow: CodeFollowedSet.Kind, headline: String, whereText: String,
                                  showButton: CodeReadyButton, hidden: Bool, commands: CodeSettings.Commands,
                                  clock: CodeReadyClock) -> CodeReadyItem {
        let offer = entry.offer
        let isFile = entry.assessment.commandClass == .fetchFile
        var notes: [String] = []
        if offer.supersession != nil { notes.append("from an earlier reply (\(clock.time(offer.source.replyTime)))") }
        if offer.supersession != nil, !offer.replyReadCompletely { notes.append(CodeReadyWords.tooFarBack) }
        let line: String?
        if hidden {
            line = CodeReadyWords.hidden
        } else if isFile, let fetch = entry.assessment.fetch {
            let name = fetch.destinationName ?? (fetch.remotePath as NSString).lastPathComponent
            line = CodeReadyWords.fileLine(name: name, alias: fetch.alias)
        } else {
            line = CodeOfferWords.firstLine(of: offer)
        }
        let title = CodeOfferWords.reviewTitle(entry.assessment, commands: commands)
        let buttons = [CodeReadyButton(.openSheet(offer.id, sessionID: session.id), title, primary: true),
                       showButton, CodeReadyButton(.later(key), "Later"), CodeReadyButton(.dismiss(key), "Dismiss")]
        return CodeReadyItem(
            id: key, kind: isFile ? .file : .command, sessionID: session.id, sessionIndex: session.index, follow: follow,
            headline: headline, whereText: whereText, time: offer.source.replyTime,
            title: isFile ? "⤓ File ready" : "▶ Command ready", titleNote: notes.isEmpty ? nil : notes.joined(separator: " · "),
            detail: "from \(headline) · \(whereText)", line: line, lineIsCommand: !isFile && !hidden,
            chip: isFile || hidden ? nil : CodeReadyWords.chip(entry.assessment), buttons: buttons, offerID: offer.id)
    }

    /// The Finished card's result button (the first result), in host words; nil when the first one has none.
    static func firstResult(_ results: [CodeResult], session: String) -> CodeReadyButton? {
        for result in results {
            let name = CodePlainText.line((result.path as NSString?)?.lastPathComponent ?? result.label, limit: 32) ?? "file"
            switch result.kind {
            case .preview:
                let label = CodePlainText.line(result.label, limit: 40).map { "↗ Open preview · \($0)" } ?? "↗ Open preview"
                return CodeReadyButton(.openResult(sessionID: session, result: result), label, opens: true)
            case .artifact:
                return CodeReadyButton(.openResult(sessionID: session, result: result), "↗ Open artifact", opens: true)
            case .document:
                return CodeReadyButton(.openResult(sessionID: session, result: result), "▤ Open \(name)", opens: true)
            case .webDocument:
                return CodeReadyButton(.openResult(sessionID: session, result: result), "▤ Preview \(name)", opens: true)
            case .otherFile:
                return CodeReadyButton(.openResult(sessionID: session, result: result), "▤ Show \(name) in Finder", opens: true)
            case .serverFile:
                return CodeReadyButton(.fetchResult(sessionID: session, result: result), "⤓ Fetch \(name)…")
            case .serverPreview, .mentionedPath, .earlierArtifact:
                continue
            }
        }
        return nil
    }
}
