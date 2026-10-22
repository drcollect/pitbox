import Darwin
import Foundation
import PitboxKit

/// Files on the server: what an SSH session's work handed over (`SendUserFile`) or wrote (Write,
/// Edit) and its final reply names becomes "⤓ Fetch <file>…", which opens the Fetch file sheet for
/// `<alias>:<path>` with every protection of Fetch file. Nothing connects before the user's click on Fetch file, and no
/// synthetic `scp` offer is ever made: the sheet gets a `FetchFileRequest` whose `sourceToolUseID` names the tool_use,
/// which the click-time check finds again (`CodeResultFetchChecker`).
enum ResultServerFiles {
    /// The `.serverFile` results for `candidates` of a session on `alias`: paths as written that pass Fetch file's path
    /// rules (absolute or `~/…`), a file name that passes its name rules, and a type that may be fetched.
    static func results(for candidates: [ResultFileCandidate], alias: String?) -> [CodeResult] {
        guard let alias, isValidAlias(alias) else { return [] }
        return candidates.compactMap { candidate in
            guard let toolUseID = candidate.toolUseID, ResultFileTypes.isAcceptableRemotePath(candidate.path),
                  let name = ResultPaths.lastComponent(candidate.path), ResultFileTypes.isFetchable(name) else { return nil }
            return CodeResult(kind: .serverFile, origin: candidate.origin, path: candidate.path, label: name,
                              toolUseID: toolUseID, at: candidate.at)
        }
    }

    /// An SSH alias the app may connect through: `^[A-Za-z0-9._-]{1,64}$`, no leading `-`.
    static func isValidAlias(_ alias: String) -> Bool {
        guard (1...64).contains(alias.utf8.count), !alias.hasPrefix("-") else { return false }
        return alias.utf8.allSatisfy { CodeIDs.isAlphanumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
    }

    /// What "⤓ Fetch <file>…" hands to `CommandOfferPresenting.presentFetch`: the request (the session's alias, the
    /// configured login user, the path as the tool_use wrote it, the remote base name in Downloads, the tool_use) and the
    /// "From" facts of the session. Nil for anything but a server file of an SSH session with a valid alias.
    static func request(for result: CodeResult, session: CodeSessionSnapshot,
                        severalCopies: Bool) -> (request: FetchFileRequest, source: CommandOffer.Source)? {
        guard result.kind == .serverFile, session.place == .ssh, let alias = session.sshHost, isValidAlias(alias),
              let path = result.path, let toolUseID = result.toolUseID, ResultFileTypes.isAcceptableRemotePath(path) else {
            return nil
        }
        let request = FetchFileRequest(alias: alias, replyUser: nil, remotePath: path, destinationName: nil,
                                       sourceToolUseID: toolUseID)
        let source = CommandOffer.Source(profileLetter: severalCopies ? session.profile.letter : nil,
                                         profileName: severalCopies ? session.profile.name : nil, sessionID: session.id,
                                         headline: session.headline, nickname: session.nickname, youAsked: nil,
                                         replyTime: result.at ?? session.turnFinishedAt ?? session.lastActivity ?? Date())
        return (request, source)
    }

    /// The sheet's line in place of "From the reply, command 1": host words, then the path (session text,
    /// shown through the plain-text renderer).
    static func sourceLine(for origin: CodeResult.Origin) -> String {
        origin == .written ? "A file the session wrote:" : "A file the session handed you:"
    }
}

/// The session side of the result fetches' click-time check, wrapped around
/// the engine's offer checker: `freshness(of:)` goes to it unchanged, `freshness(ofResultFetch:toolUseID:path:)`
/// re-reads the session file and a fresh transcript tail (up to 2 MB) on its own queue within
/// `CommandOfferFreshness.checkTimeout` and answers `fresh` only when the `SendUserFile`, Write or Edit tool_use is
/// still there naming exactly that path; `stale` when it is gone, names another path, the session is archived, its
/// file fails its checks or the session is not followed; `unknown` when the check takes too long. The composition
/// root hands it to the block as `freshness`.
public final class CodeResultFetchChecker: CommandOfferFreshnessChecking, @unchecked Sendable {
    /// Where one followed SSH session's files are, registered by the results deriver.
    struct Session: Equatable, Sendable {
        var transcript: CarefulPath
        var sessionFile: CarefulPath
        var owner: uid_t
    }

    private let base: CommandOfferFreshnessChecking
    private let lock = NSLock()
    private var sessions: [Int: Session] = [:]
    private let queue = DispatchQueue(label: "pitbox.code.result-fetch", qos: .userInitiated)
    private let timerQueue = DispatchQueue(label: "pitbox.code.result-fetch.timer", qos: .userInitiated)
    private let timeout: TimeInterval

    /// Wraps the engine's checker (`CodeSessionsEngine.freshnessChecker`).
    public convenience init(base: CommandOfferFreshnessChecking) {
        self.init(base: base, timeout: CommandOfferFreshness.checkTimeout)
    }

    init(base: CommandOfferFreshnessChecking, timeout: TimeInterval) {
        self.base = base
        self.timeout = timeout
    }

    public func freshness(of offer: CommandOffer.ID) async -> CommandOfferFreshness {
        await base.freshness(of: offer)
    }

    public func freshness(ofResultFetch sessionIndex: Int, toolUseID: String, path: String) async -> CommandOfferFreshness {
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            let once = ResultFetchResume(continuation)
            queue.async { [self] in once.resume(check(sessionIndex: sessionIndex, toolUseID: toolUseID, path: path)) }
            timerQueue.asyncAfter(deadline: .now() + timeout) { once.resume(.unknown) }
        }
    }

    // MARK: Registry (the results deriver, on the engine's queue)

    func register(_ session: Session, sessionIndex: Int) { lock.withLock { sessions[sessionIndex] = session } }

    func unregister(sessionIndex: Int) { _ = lock.withLock { sessions.removeValue(forKey: sessionIndex) } }

    /// Tests.
    func registered(sessionIndex: Int) -> Session? { lock.withLock { sessions[sessionIndex] } }

    /// Tests: hold back the reading queue (a check then runs into its timeout) and let it go again.
    func suspendChecks() { queue.suspend() }
    func resumeChecks() { queue.resume() }

    /// The check itself, synchronous.
    func check(sessionIndex: Int, toolUseID: String, path: String) -> CommandOfferFreshness {
        guard let session = lock.withLock({ sessions[sessionIndex] }) else { return .stale }
        switch CarefulFiles.read(session.sessionFile, owner: session.owner, maxBytes: ClaudeSessionFile.maxBytes) {
        case .failure:
            return .stale
        case .success(let (data, _)):
            guard case .success(let file) = ClaudeSessionFile.parse(data), !file.isArchived, let cli = file.cliSessionID,
                  session.transcript.name == cli + ".jsonl" else { return .stale }
        }
        var verdict: CommandOfferFreshness = .stale
        let read = TranscriptReader.read(session.transcript, owner: session.owner, cursor: nil, digestFacts: true) { lines in
            lines.contains { Self.toolUse(in: $0.entry, id: toolUseID) != nil }
        }
        guard case .success(let window) = read else { return .stale }
        var found = false
        for line in window.lines {
            guard let tool = Self.toolUse(in: line.entry, id: toolUseID) else { continue }
            guard Self.names(tool, path: path) else { return .stale }
            found = true
        }
        if found { verdict = .fresh }
        return verdict
    }

    /// The tool_use with `id` in `entry` (an assistant entry of the session itself, not a subagent's side chain).
    private static func toolUse(in entry: TranscriptEntry?, id: String) -> TranscriptToolUse? {
        guard let entry, entry.kind == .assistant, !entry.isSidechain else { return nil }
        for case .toolUse(let tool) in entry.blocks where tool.id == id { return tool }
        return nil
    }

    /// The tool_use hands over or writes exactly `path`.
    private static func names(_ tool: TranscriptToolUse, path: String) -> Bool {
        switch tool.name {
        case "SendUserFile": return tool.input.files?.contains(path) == true
        case "Write", "Edit", "MultiEdit": return tool.input.filePath == path
        case "NotebookEdit": return tool.input.notebookPath == path || tool.input.filePath == path
        default: return false
        }
    }
}

/// Resumes a continuation once: whichever of the check and the timeout comes first.
private final class ResultFetchResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandOfferFreshness, Never>?

    init(_ continuation: CheckedContinuation<CommandOfferFreshness, Never>) { self.continuation = continuation }

    func resume(_ value: CommandOfferFreshness) {
        let pending = lock.withLock { () -> CheckedContinuation<CommandOfferFreshness, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
