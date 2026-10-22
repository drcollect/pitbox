import Foundation
import PitboxKit

/// What building a snapshot needs besides the session's record.
struct SnapshotContext {
    var now: Date
    var sshFacts: SSHConfigFacts
    var settings: CodeSettings
    var homeDirectory: String
    var userName: String
    /// More than one copy runs: offers then name their copy.
    var multipleProfiles: Bool
    /// The programs on the clean PATH; asked only when a reply's offers are (re)built.
    var programs: () -> Set<String>?
    /// The HostName of an exact alias (`ssh -G`, only without `Match` blocks); asked only when offers are built.
    var hostName: (String) -> String?
}

/// Builds one session's snapshot and the offers of its latest finished reply.
enum SessionSnapshotBuilder {
    struct Output {
        var snapshot: CodeSessionSnapshot
        /// The latest finished reply's offers (possibly none), nil when there is no such reply.
        var latest: ReplyOffers?
        /// Times at which the snapshot changes without a file changing.
        var deadlines: [Date]
    }

    static func build(_ record: inout SessionRecord, context: SnapshotContext) -> Output {
        let now = context.now
        let file = record.file
        let title = file?.title ?? record.popout?.title ?? ""
        let hosts: [String]
        if let host = file?.sshHost {
            hosts = [host]
        } else if file == nil, record.popout?.isSSH == true {
            hosts = context.sshFacts.exactHosts
        } else {
            hosts = []
        }
        let (headline, nickname) = TitleRules.split(title: title, hosts: hosts)
        let place = record.place
        let readable = record.transcriptReadable
        let input = SessionStateInput(file: file, tracker: readable ? record.tracker : nil,
                                      transcriptModified: readable ? record.cursor?.identity.modifiedDate : nil,
                                      sessionFileModified: record.fileIdentity?.modifiedDate, now: now)
        let result = SessionStateRules.evaluate(input)
        var deadlines = [result.nextChange, readable ? record.activity.nextChange(now: now) : nil].compactMap { $0 }

        var latest: ReplyOffers?
        if readable, result.finished, let file {
            latest = latestReply(record, file: file, place: place, headline: headline, nickname: nickname, context: context)
        }
        if let latest { deadlines.append(latest.replyTime.addingTimeInterval(CommandOffer.maxAge)) }
        record.replies = latest.map { [$0] } ?? []
        let working = result.state == .working || result.state == .maybeNeedsYou
        let snapshot = CodeSessionSnapshot(
            id: record.id, index: record.index, profile: record.profile, headline: headline, nickname: nickname,
            title: title, previousTitles: file?.previousTitles ?? [], place: place,
            sshHost: file?.sshHost.flatMap { SSHConfigReader.isValidAlias($0) ? $0 : nil }, cwd: file?.cwd,
            cwdOnRefusedRoot: record.cwdOnRefusedRoot && place != .ssh,
            model: file?.model, effort: file?.effort, permissionMode: file?.permissionMode, state: result.state,
            stateWord: result.word, lastActivity: result.lastActivity, quietSince: result.quietSince, tldr: result.tldr,
            askLine: result.askLine, now: working ? result.nowLine : nil, todos: readable ? record.tracker.todos : nil,
            steps: readable ? record.tracker.steps : [], sparkline: readable ? record.activity.sparkline(now: now) : [],
            offers: latest?.entries ?? [], offersNotShown: latest?.notShown ?? 0,
            popout: record.popout.map { CodePopoutHint(bounds: $0.bounds) }, isArchived: file?.isArchived ?? false,
            turnFinishedAt: result.turnFinishedAt,
            replyUUID: readable && result.finished ? record.tracker.turn?.lastAssistantUUID : nil)
        return Output(snapshot: snapshot, latest: latest, deadlines: deadlines)
    }

    /// The offers of the latest finished reply: the final reply's shell blocks, with the session facts, the
    /// folder, "You asked", the caption and the classifier's result. Nil when there is no reply to offer from (archived,
    /// no text, burned after a replaced or cut transcript, older than 24 hours).
    static func latestReply(_ record: SessionRecord, file: ClaudeSessionFile, place: CommandSessionFacts.Place,
                            headline: String, nickname: String?, context: SnapshotContext) -> ReplyOffers? {
        guard !file.isArchived, let turn = record.tracker.turn, let replyUUID = turn.lastAssistantUUID,
              !record.burnedReplies.contains(replyUUID), !turn.run.isEmpty, let cursor = record.cursor,
              let transcript = record.transcript, let sessionFile = record.sessionFile, let cli = file.cliSessionID else { return nil }
        let replyTime = turn.lastAssistantAt ?? cursor.identity.modifiedDate
        guard context.now.timeIntervalSince(replyTime) < CommandOffer.maxAge else { return nil }
        let complete = turn.isReadCompletely
        let profileName = record.profile.name.replacingOccurrences(of: TitleRules.separator, with: " ")
        let source = CommandOffer.Source(profileLetter: context.multipleProfiles ? record.profile.letter : nil,
                                         profileName: context.multipleProfiles ? profileName : nil, sessionID: record.id,
                                         headline: headline, nickname: nickname, youAsked: turn.youAsked, replyTime: replyTime)
        let folder = offerFolder(record, file: file, place: place, home: context.homeDirectory)
        let registration = CodeOfferFreshnessChecker.Reply(
            sessionIndex: record.index, replyUUID: replyUUID, texts: [:], sessionFile: sessionFile, transcript: transcript,
            cliSessionID: cli, identity: cursor.identity, replyEnd: turn.lastAssistantEnd ?? cursor.nextOffset, replyTime: replyTime)

        // Reuse what was built for this reply while nothing it depends on changed (the classifier runs once).
        if let cached = record.replies.last, cached.replyUUID == replyUUID, cached.key.readCompletely == complete,
           cached.key.source == source, cached.key.folder == folder,
           cached.key.facts == facts(record, file: file, place: place, turn: turn, context: context, resolveHost: false,
                                     previous: cached.key.facts) {
            return cached
        }
        let programs = context.programs()
        let sessionFacts = facts(record, file: file, place: place, turn: turn, context: context, resolveHost: true, previous: nil)
        let key = ReplyOffers.Key(replyUUID: replyUUID, readCompletely: complete, facts: sessionFacts,
                                  programs: programs?.count ?? -1, source: source, folder: folder)
        if let cached = record.replies.last, cached.key == key { return cached }

        let extraction = OfferExtraction.extract(from: turn.run, programs: programs)
        let replyText = turn.run.joined(separator: "\n\n")
        var entries: [CodeOfferEntry] = []
        var texts: [Int: String] = [:]
        for (position, block) in extraction.blocks.enumerated() {
            let number = position + 1
            // `pathFacts` stays empty: only the sheet looks up files (docs/SHELL_LANGUAGE.md §8).
            let commandContext = CommandContext(facts: sessionFacts, caption: block.caption, programsOnCleanPath: programs,
                                                runFolder: folder.path)
            let offer = CommandOffer(id: CommandOffer.ID(sessionIndex: record.index, replyUUID: replyUUID, number: number),
                                     text: block.text, total: extraction.blocks.count, blockKind: block.kind,
                                     displayLines: block.displayLines, caption: block.caption, source: source,
                                     replyReadCompletely: complete, folder: folder, context: commandContext, replyText: replyText)
            var assessment = CommandClassifier.assess(text: block.text, context: commandContext)
            // The classifier cannot know how much of the reply was read: a partly read reply is Copy only.
            if !complete, assessment.commandClass != .blocked { assessment.commandClass = .partlyRead }
            entries.append(CodeOfferEntry(offer: offer, assessment: assessment))
            texts[number] = block.text
        }
        var registered = registration
        registered.texts = texts
        return ReplyOffers(key: key, replyUUID: replyUUID, replyTime: replyTime, entries: entries,
                           notShown: extraction.notShown, readCompletely: complete, registration: registered)
    }

    /// The session facts for the classifier and the sheet, from the session file and the user's own SSH config
    /// and settings, never from the reply. With `resolveHost: false` the HostName is taken from `previous` (no lookup).
    static func facts(_ record: SessionRecord, file: ClaudeSessionFile, place: CommandSessionFacts.Place,
                      turn: TranscriptTurn, context: SnapshotContext, resolveHost: Bool,
                      previous: CommandSessionFacts?) -> CommandSessionFacts {
        var alias: String?
        if place == .ssh, let host = file.sshHost, SSHConfigReader.isValidAlias(host), context.sshFacts.isExactHost(host) {
            alias = host
        }
        let hostName: String?
        if let alias, context.sshFacts.allowsHostLookup {
            hostName = resolveHost ? context.hostName(alias) : (previous?.sshAlias == alias ? previous?.resolvedHostName : nil)
        } else {
            hostName = nil
        }
        // A session working on an external or network volume: its folder is named so that the sheet can say why
        // nothing of it runs (an SSH session never is one).
        let refused = place != .ssh && !file.hasSSHConfig && record.cwdOnRefusedRoot ? file.cwd : nil
        // The folder the sheet decides again when it opens and at the click (never an SSH session's: a server path).
        let workFolder = place != .ssh && !file.hasSSHConfig ? file.cwd : nil
        return CommandSessionFacts(place: place, sshAlias: alias, resolvedHostName: hostName,
                                   serverNames: alias.flatMap { context.settings.serverNames[$0] } ?? [],
                                   knownSSHHosts: context.sshFacts.exactHosts,
                                   remoteCwd: place == .ssh ? file.cwd : nil, localCwd: place == .local ? file.cwd : nil,
                                   refusedLocalCwd: refused, localWorkFolder: workFolder,
                                   homeDirectory: context.homeDirectory, userName: context.userName,
                                   turnOrigin: turn.origin, turnReadWeb: turn.readWeb)
    }

    /// The working folder: a local session runs in its folder (it exists, or the place would not be local); a command
    /// an SSH session hands to the Mac runs in the home folder; an unknown place uses the session's folder when it
    /// exists here and the file names no SSH host, else the home folder, said beforehand.
    static func offerFolder(_ record: SessionRecord, file: ClaudeSessionFile, place: CommandSessionFacts.Place,
                            home: String) -> CommandOffer.Folder {
        switch place {
        case .local:
            return CommandOffer.Folder(path: file.cwd ?? home, isHomeFallback: file.cwd == nil)
        case .ssh:
            return CommandOffer.Folder(path: home, isHomeFallback: false)
        case .unknown:
            if !file.hasSSHConfig, let cwd = file.cwd, record.cwdExists { return CommandOffer.Folder(path: cwd, isHomeFallback: false) }
            return CommandOffer.Folder(path: home, isHomeFallback: true)
        }
    }

    /// A short label of an offer's class for the log.
    static func label(_ value: CommandAssessment.Class) -> String {
        switch value {
        case .notFlagged: return "unflagged"
        case .risky: return "risky"
        case .needsEditing: return "needs-editing"
        case .otherMachine: return "other-machine"
        case .forServer: return "server"
        case .unclearMachine: return "unclear"
        case .fetchFile: return "fetch"
        case .partlyRead: return "partly-read"
        case .blocked: return "blocked"
        }
    }
}
