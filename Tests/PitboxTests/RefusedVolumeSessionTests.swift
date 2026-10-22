import AppKit
import Foundation
import Testing
@testable import PitboxConsole
import PitboxKit
@testable import PitboxSessions

/// The terminal side of the sheet, faked: records every Run or Type it is asked to start.
@MainActor
private final class RecordingTabHost: CommandTabHost {
    private(set) var started: [CommandTabRequest] = []
    let homeFolder: String

    init(home: String) { homeFolder = home }

    func commandBlocker(role: CommandTabRole) -> String? { nil }

    func startCommandTab(_ request: CommandTabRequest, events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        started.append(request)
        request.folder.close()
        events(.started(runID: request.runID))
    }

    func openServerTab(alias: String, completion: @escaping @MainActor (String?) -> Void) { completion("not in this test") }

    func revealRun(_ runID: UUID) -> Bool { false }
}

/// A local session whose folder is on an external or network volume, from its session file to the sheet: the session
/// side reads it without looking the folder up, and the sheet runs and types none of its commands, whatever machine
/// is picked; Copy stays (docs/THREAT_MODEL.md, T33). Invented data only; `/Volumes/pitbox-test-volume` does not exist and
/// is never looked up.
@Suite("Session on an external volume", .serialized)
@MainActor
struct RefusedVolumeSessionTests {
    static let sessionID = "local_0eeeeeee-5555-4555-8555-000000000005"
    static let cli = "2f3c2a9e-1111-2222-3333-444455556666"
    static let words = "This session works on an external or network volume: Pitbox does not run its commands. Copy them instead."

    /// The session's files as Claude writes them, below `root`: a finished turn whose reply offers `echo done`.
    static func writeSession(root: URL, cwd: String, now: Date) throws {
        let support = root.appendingPathComponent("Application Support/\(CodeProfile.a.folderName)", isDirectory: true)
        let at = now.addingTimeInterval(-120)
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        func write(_ text: String, _ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try write(json(["title": "Tidy the tests (calm otter)", "cwd": cwd, "cliSessionId": cli, "model": "claude-opus-5-5",
                        "isArchived": false, "lastActivityAt": Int(at.timeIntervalSince1970 * 1000), "completedTurns": 1,
                        "postTurnSummary": ["status_category": "review_ready", "status_detail": "Tidied", "needs_action": "",
                                            "summarizes_uuid": "a-final"],
                        "postTurnSummaryFor": "a-final"]),
                  support.appendingPathComponent("claude-code-sessions/acct-1/org-1/\(sessionID).json"))
        try write(json(["version": 1, "popouts": [["sessionId": sessionID, "sessionType": "code", "isSsh": false,
                                                   "title": "Tidy the tests",
                                                   "bounds": ["x": 100, "y": 80, "width": 900, "height": 700]]]]),
                  support.appendingPathComponent("session-popouts.json"))
        let user = try json(["type": "user", "uuid": "u1", "timestamp": stamp.string(from: at), "isSidechain": false,
                             "userType": "external", "turnOrigin": "human",
                             "message": ["role": "user", "content": "Tidy up the tests"]])
        let reply = try json(["type": "assistant", "uuid": "a-final", "timestamp": stamp.string(from: at), "isSidechain": false,
                              "requestId": "req_a", "message": ["role": "assistant", "id": "msg_a", "type": "message",
                                                                "model": "claude-opus-5-5", "stop_reason": "end_turn",
                                                                "content": [["type": "text", "text": "Run this:\n\n```bash\necho done\n```"]],
                                                                "usage": ["input_tokens": 3, "output_tokens": 10]]])
        let folder = SessionRecord.projectFolderName(cwd) ?? "bad"
        try write(user + "\n" + reply + "\n", root.appendingPathComponent(".claude/projects/\(folder)/\(cli).jsonl"))
    }

    @Test func noCommandOfASessionOnAnExternalVolumeRunsOrIsTyped() async throws {
        let root = ScratchFolder("refused-volume")
        let home = root.url.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let now = Date()
        let cwd = "/Volumes/pitbox-test-volume/my project"
        try Self.writeSession(root: root.url, cwd: cwd, now: now)
        let environment = CodeSessionsEnvironment(
            applicationSupport: root.url.appendingPathComponent("Application Support", isDirectory: true),
            claudeProjects: root.url.appendingPathComponent(".claude/projects", isDirectory: true),
            sshConfig: root.url.appendingPathComponent(".ssh/config"), homeDirectory: home.path, userName: "alex",
            userID: getuid(), clock: { now },
            processes: { [ClaudeProcessCandidate(pid: 4242, arguments: ["/Applications/Claude.app/Contents/MacOS/Claude"],
                                                 bundlePath: "/Applications/Claude.app", version: "2.42304.0")] },
            programsOnCleanPath: { _ in ["echo"] }, watchesFiles: false, parseInterval: 0)
        let engine = CodeSessionsEngine(environment: environment)
        engine.start()
        await engine.waitUntilIdle()
        defer { engine.stop() }
        let session = try #require(engine.sessions.first { $0.id == Self.sessionID })
        #expect(session.place == .unknown && session.cwd == cwd, "never looked up: an unknown place")
        let offer = try #require(session.offers.first?.offer)
        #expect(offer.text == "echo done")

        let host = RecordingTabHost(home: home.path)
        var clockNow: TimeInterval = 1_000
        let sheet = CommandSheetController(host: host, classify: { CommandClassifier.assess(text: $0, context: $1, options: $2) },
                                           fetchRunner: nil, commandShell: { .clean }, extraPath: { [] }, clock: { clockNow },
                                           pasteboard: NSPasteboard(name: NSPasteboard.Name("pitbox-refused-volume-\(UUID().uuidString)")),
                                           home: home.path, userName: "alex")
        sheet.present = { _ in }
        sheet.hide = { _ in }
        sheet.isFullyVisible = { _ in true }
        sheet.runPolicy = { .run }
        sheet.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        sheet.lookUpFacts = { _ in [:] }
        sheet.setuidPrograms = { _, _ in [] }
        sheet.isExactAlias = { _ in false }
        sheet.screenFrame = { CGRect(x: 0, y: 0, width: 2_560, height: 1_400) }
        sheet.present(offer, anchor: CGRect(x: 1_200, y: 400, width: 300, height: 200), freshness: FreshFreshness()) { _ in }
        #expect(await eventually(5) { sheet.sheet?.state.assessmentReady == true })
        clockNow += 3
        // The user picks This Mac where the sheet offers a pick, and presses Run and Type.
        if sheet.sheet?.model?.showsMachinePicker == true { sheet.pickMachine(.thisMac) }
        clockNow += 3
        let model = try #require(sheet.sheet?.model)
        #expect(model.run.state == .off(Self.words), "Run is off, saying why")
        #expect(model.type.state == .off(Self.words), "Type is off, saying why")
        #expect(model.checkText == Self.words)
        #expect(model.copy.state == .on, "Copy stays")
        #expect(sheet.sheet?.frozen?.folder == nil, "no folder is bound, so nothing can start anywhere")
        sheet.runOrType(.run)
        sheet.runOrType(.typeIntoTerminal)
        _ = await eventually(1) { !host.started.isEmpty }
        #expect(host.started.isEmpty, "nothing started")
        sheet.dismissSheet()
    }
}
