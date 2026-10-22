import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

@Suite("Session files")
struct SessionFileTests {
    func parse(_ text: String) -> Result<ClaudeSessionFile, ClaudeFileFailure> { ClaudeSessionFile.parse(Data(text.utf8)) }

    @Test func readsTheFieldsOfSection5_3() throws {
        var fixture = SessionFixture()
        fixture.summary = ("blocked", "Waiting for the \(secretWord) key", "Paste the key", "u-9")
        fixture.midTurn = true
        fixture.extra = ["turnWrapUp": ["needsUser": true], "errorCategory": "api_error",
                         "lastFocusedAt": "2026-10-01T14:00:00.000Z", "lastAssistantUuid": "u-9"]
        let file = try parse(fixture.json).get()
        #expect(file.title == fixture.title)
        #expect(file.previousTitles == ["Earlier \(secretWord) title"])
        #expect(file.cwd == "/home/someone/project")
        #expect(file.cliSessionID == fixture.cli && !file.cliSessionIDRejected)
        #expect(file.model == "claude-opus-5-5" && file.effort == "high" && file.permissionMode == "default")
        #expect(file.hasSSHConfig && file.sshHost == "buildbox")
        #expect(file.midTurn && file.wrapUpNeedsUser)
        #expect(file.summary?.category == "blocked" && file.summary?.needsAction == "Paste the key")
        #expect(file.summary?.summarizesUUID == "u-9" && file.summaryFor == "u-9" && file.lastAssistantUUID == "u-9")
        #expect(file.errorCategory == "api_error" && !file.hasError)
        #expect(!file.interruptedAwaitingPerson && !file.stoppedUntilPersonSends)
        #expect(file.lastActivityAt.map { abs($0.timeIntervalSince(fixture.lastActivity)) < 0.01 } == true)
        #expect(file.lastFocusedAt == CodeDates.parse("2026-10-01T14:00:00.000Z"))
        #expect(file.completedTurns == 4)
    }

    @Test func missingAndMistypedKeysMeanUnknown() throws {
        let file = try parse(#"{"title": 42, "isArchived": "yes", "sshConfig": null, "postTurnSummary": "x", "cwd": ""}"#).get()
        #expect(file.title == nil && !file.isArchived && !file.hasSSHConfig && file.summary == nil && file.cwd == nil)
        #expect(file.cliSessionID == nil && !file.cliSessionIDRejected)
    }

    @Test func aBadCLISessionIDNeverBecomesAPath() throws {
        for bad in ["../../etc/passwd-00000000000000000000", "0f3c2a9e-1111-2222-3333-44445555666", "zzzzzzzz-1111-2222-3333-444455556666"] {
            var fixture = SessionFixture()
            fixture.cli = bad
            let file = try parse(fixture.json).get()
            #expect(file.cliSessionID == nil && file.cliSessionIDRejected, "\(bad)")
        }
    }

    @Test func titlesAndSummariesAreCutWhileParsing() throws {
        var fixture = SessionFixture()
        fixture.title = String(repeating: "t", count: 5000)
        fixture.summary = ("completed", String(repeating: "d", count: 5000), "", "u")
        let file = try parse(fixture.json).get()
        #expect(file.title?.count == ClaudeSessionFile.titleScalars)
        #expect(file.summary?.detail?.count == ClaudeSessionFile.summaryScalars)
        #expect(file.summary?.needsAction == nil)
    }

    @Test func aLargeKeyThatIsNotReadIsSkippedButStillChecked() throws {
        // Real files reach 1.02 MB through `remoteMcpServersConfig` (measured): above an old 1 MB limit, below 4 MB.
        let servers = (0..<3000).map { ["name": "server-\($0)", "url": "https://mcp.example/\($0)/" + String(repeating: "p", count: 400)] }
        var fixture = SessionFixture()
        fixture.extra = ["remoteMcpServersConfig": ["servers": servers]]
        let text = fixture.json
        #expect(text.utf8.count > 1 << 20 && text.utf8.count < ClaudeSessionFile.maxBytes)
        let file = try parse(text).get()
        #expect(file.title == fixture.title && file.cliSessionID == fixture.cli)
        // A duplicated key inside a skipped value still fails the file.
        let bad = #"{"title":"x","remoteMcpServersConfig":{"servers":[{"name":"a","name":"b"}]}}"#
        #expect(parse(bad).failure == .json(.duplicateKey))
    }

    @Test func aTenMegabyteTitleIsRefusedBeforeParsing() throws {
        let tree = FixtureTree()
        var fixture = SessionFixture()
        fixture.title = String(repeating: "t", count: 10 * 1024 * 1024)
        try tree.writeSession(sessionA, fixture)
        var record = SessionRecord(id: sessionA, index: 1, firstSeen: 0, profile: .a, popout: nil)
        let folder = try #require(CarefulPath(root: tree.appSupport.path, components: ["Claude"]))
        let index = SessionIndex.build(profileFolder: folder, owner: getuid())
        record.refreshFile(path: index.path(of: sessionA, profileFolder: folder), owner: getuid())
        #expect(record.file == nil && record.fileFailure == .read(.tooLarge) && record.fileFailure?.isContentFailure == true)
    }

    /// C1: an SSH session's `cwd` is a path on the server and is never looked up here; a local session's is walked
    /// under the network check, so `/Volumes`, `/net`, `/home`, `/Network` and automount points are never touched.
    @Test func theSessionFolderIsNeverLookedUpOnTheNetworkOrForAServer() throws {
        let tree = FixtureTree()
        let folder = try #require(CarefulPath(root: tree.appSupport.path, components: ["Claude"]))
        let pathGuard = NetworkPathGuard(mountRoots: ["/Users/alex/automounted"])
        func cwdExists(_ cwd: String, ssh: Bool, fs: RecordingFolders) throws -> Bool {
            var fixture = SessionFixture()
            fixture.cwd = cwd
            fixture.sshHost = ssh ? "buildbox" : nil
            try tree.writeSession(sessionA, fixture)
            var record = SessionRecord(id: sessionA, index: 1, firstSeen: 0, profile: .a, popout: nil)
            let index = SessionIndex.build(profileFolder: folder, owner: getuid())
            record.refreshFile(path: index.path(of: sessionA, profileFolder: folder), owner: getuid(), folders: fs,
                               pathGuard: { pathGuard })
            #expect(record.file?.cwd == cwd)
            return record.cwdExists
        }
        let fs = RecordingFolders(["/Users/alex/project", "/home/someone/project"])
        #expect(try !cwdExists("/home/someone/project", ssh: true, fs: fs))
        #expect(try !cwdExists("/Users/alex/project", ssh: true, fs: fs), "a server's folder, even one that exists here")
        #expect(fs.calls.isEmpty, "no lookup for an SSH session's folder: \(fs.calls)")
        for cwd in ["/Volumes/x/project", "/net/host/p", "/home/u/p", "/Network/Servers/box/p", "/Users/alex/automounted/p"] {
            #expect(try !cwdExists(cwd, ssh: false, fs: fs), "\(cwd)")
        }
        #expect(fs.calls.isEmpty, "no lookup on a network root: \(fs.calls)")
        #expect(try cwdExists("/Users/alex/project", ssh: false, fs: fs), "a local folder is still found")
        #expect(!fs.calls.isEmpty)
    }

    /// A local session working on an external or network volume, its folder itself or through a link of the user's, is
    /// marked so that none of its commands runs (its place stays unknown); an SSH session never is.
    @Test func aSessionOnARefusedRootIsMarkedAndNeverLookedUpThere() throws {
        let tree = FixtureTree()
        let folder = try #require(CarefulPath(root: tree.appSupport.path, components: ["Claude"]))
        let pathGuard = NetworkPathGuard(mountRoots: ["/Users/alex/automounted"])
        let fs = RecordingFolders(["/Users/alex/project"], links: ["/Users/alex/to-volume": "/Volumes/x"])
        func record(_ cwd: String, ssh: Bool) throws -> SessionRecord {
            var fixture = SessionFixture()
            fixture.cwd = cwd
            fixture.sshHost = ssh ? "buildbox" : nil
            try tree.writeSession(sessionA, fixture)
            var record = SessionRecord(id: sessionA, index: 1, firstSeen: 0, profile: .a, popout: nil)
            let index = SessionIndex.build(profileFolder: folder, owner: getuid())
            record.refreshFile(path: index.path(of: sessionA, profileFolder: folder), owner: getuid(), folders: fs,
                               pathGuard: { pathGuard })
            return record
        }
        for cwd in ["/Volumes/x/project", "/net/host/p", "/Network/Servers/box/p", "/Users/alex/automounted/p",
                    "/Users/alex/to-volume/project"] {
            let marked = try record(cwd, ssh: false)
            #expect(marked.cwdOnRefusedRoot && !marked.cwdExists, "\(cwd)")
        }
        let reached = fs.calls.filter { pathGuard.refuses($0) }
        #expect(reached.isEmpty, "a lookup reached a refused root: \(reached)")
        #expect(fs.calls.contains("/Users/alex/to-volume"), "a link of the user's is read, its target checked")
        let ssh = try record("/Volumes/x/project", ssh: true)
        #expect(!ssh.cwdOnRefusedRoot && !ssh.cwdExists, "an SSH session's folder is the server's")
        let local = try record("/Users/alex/project", ssh: false)
        #expect(local.cwdExists && !local.cwdOnRefusedRoot)
        let gone = try record("/Users/alex/gone", ssh: false)
        #expect(!gone.cwdExists && !gone.cwdOnRefusedRoot, "a missing folder is no refused root: today's unknown place")
    }

    @Test func failuresAreLabelled() {
        #expect(parse(#"{"title":"a","title":"b"}"#).failure == .json(.duplicateKey))
        #expect(parse("[1,2]").failure == .notObject)
        #expect(parse("{").failure == .json(.syntax))
        let deep = "{\"a\":" + String(repeating: "[", count: 64) + String(repeating: "]", count: 64) + "}"
        #expect(parse(deep).failure == .json(.tooDeep))
        #expect(ClaudeFileFailure.json(.duplicateKey).isContentFailure)
        #expect(!ClaudeFileFailure.read(.missing).isContentFailure)
    }

    @Test func popoutsKeepOnlyCheckedSessionIDs() throws {
        let text = jsonLine(["version": 1, "popouts": [
            ["sessionId": sessionA, "sessionType": "code", "isSsh": true, "title": "One", "bounds": ["x": 1, "y": 2, "width": 3, "height": 4]],
            ["sessionId": "local_../../x", "title": "Bad"],
            ["sessionId": "chat-1234", "title": "Not code"],
            ["sessionId": sessionB, "bounds": ["x": "a"]],
            ["sessionId": sessionA, "title": "Twice"],
            "not an object",
        ]])
        let popouts = try ClaudePopouts.parse(Data(text.utf8)).get()
        #expect(popouts.entries.map(\.sessionID) == [sessionA, sessionB])
        #expect(popouts.entries[0].bounds == CGRect(x: 1, y: 2, width: 3, height: 4) && popouts.entries[0].isSSH == true)
        #expect(popouts.entries[1].bounds == nil)
        #expect(popouts.rejected == 3)
    }

    @Test func identifiersAreChecked() {
        #expect(CodeIDs.isSessionID(sessionA))
        #expect(!CodeIDs.isSessionID("local_"))
        #expect(!CodeIDs.isSessionID("local_" + String(repeating: "a", count: 65)))
        #expect(!CodeIDs.isSessionID("local_a/b"))
        #expect(CodeText.identifier("claude-opus-5-5[1m]") == "claude-opus-5-5[1m]")
        #expect(CodeText.identifier("two words") == nil)
    }

    @Test func datesFromNumbersAndStrings() {
        #expect(CodeDates.fromNumber(1_790_865_420_000) == fixtureNow)
        #expect(CodeDates.fromNumber(1_790_865_420) == fixtureNow)
        #expect(CodeDates.fromNumber(12) == nil)
        #expect(CodeDates.parse("2026-10-01T14:37:00Z") == fixtureNow)
        #expect(CodeDates.parse("2026-10-01T15:37:00+01:00") == fixtureNow)
        #expect(CodeDates.parse("yesterday") == nil)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

/// Invented folders that record every lookup (the session folder check's filesystem).
final class RecordingFolders: LocalPathFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var folders: Set<String> = ["/"]
    private let links: [String: String]
    private var recorded: [String] = []

    /// Folders (and their parents), and links of the user's with their targets (their parents are folders).
    init(_ list: [String], links: [String: String] = [:]) {
        self.links = links
        for path in list + links.keys.map({ ($0 as NSString).deletingLastPathComponent }) {
            var current = path
            while current != "/", !current.isEmpty {
                folders.insert(current)
                current = (current as NSString).deletingLastPathComponent
            }
        }
    }

    var calls: [String] { lock.withLock { recorded } }

    func lstat(_ path: String) -> LocalPathLookup {
        lock.withLock {
            recorded.append(path)
            if links[path] != nil { return .found(LocalPathStat(kind: .link, device: 1, inode: 3)) }
            return folders.contains(path) ? .found(LocalPathStat(kind: .directory, device: 1, inode: 2)) : .missing
        }
    }

    func readlink(_ path: String) -> String? {
        lock.withLock {
            recorded.append(path)
            return links[path]
        }
    }
}
