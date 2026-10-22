import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// "Same file": two working sessions, one file of one repository; forks, worktrees,
/// machines and network paths; clearing; OK for 2 hours.
@Suite("Same file")
struct SameFileTests {
    let tree = ResultTree("same-file")
    let folder = SeamFolder("same-file-memory")
    let clock = ManualClock(resultNow)

    func store() -> CodeMemoryStore {
        let clock = self.clock
        return CodeMemoryStore(url: folder.file("code-memory.json"), owner: getuid(), clock: { clock.now }, writeInterval: 0.05,
                               writeMax: CodeTuning.memoryWriteMax)
    }

    func input(_ id: String, index: Int, edits: [(path: String, id: String, minutesAgo: Double)], state: CodeSessionState = .working,
               place: CommandSessionFacts.Place = .local, cwd: String? = nil, sshHost: String? = nil,
               copied: Set<String> = []) -> CodeCrossSessionInput {
        var lines = [Line.user("Edit the \(secretWord) checkout", uuid: "u-\(id)", at: ago(40))]
        for edit in edits {
            lines.append(SeamLine.edit(edit.path, id: edit.id, uuid: "e-\(edit.id)", at: ago(edit.minutesAgo)))
            lines.append(SeamLine.result(edit.id, uuid: "r-\(edit.id)", at: ago(edit.minutesAgo), content: "ok"))
        }
        let snapshot = resultSession(id, index: index, place: place, cwd: cwd ?? tree.repo.path, sshHost: sshHost, state: state,
                                     headline: "Session \(index) \(secretWord)")
        return CodeCrossSessionInput(snapshot: snapshot, digest: resultDigest(lines, copied: copied), digestVersion: 1)
    }

    func derive(_ sessions: [CodeCrossSessionInput], fs: ResultFileSystem = RecordingFileSystem(), memory: CodeMemoryStore? = nil,
                settings: CodeSettings = CodeSettings(), now: Date = resultNow) -> [String: CodeDerivedFields] {
        let deriver = SameFileDeriver(environment: environment(fs))
        var fields: [String: CodeDerivedFields] = [:]
        deriver.derive(sessions, context: CodeCrossDeriveContext(now: now, memory: memory ?? store(), settings: settings, owner: getuid()),
                       into: &fields)
        return fields
    }

    /// The tree's environment with a clock that stands still: the 50 ms file-check budget of a pass is real time, and a
    /// busy machine once spent it before both sessions' files were resolved (no key, so no warning). The budget itself
    /// is tested elsewhere; here it never runs out.
    func environment(_ fs: ResultFileSystem) -> ResultEnvironment {
        var environment = tree.environment(fs)
        environment.clock = { 0 }
        return environment
    }

    var checkout: String { tree.write("x", "home/code/toy-cube/src/checkout.tsx").path }

    @Test func twoLocalSessionsEditingOneFileAreBothWarned() throws {
        let file = checkout
        let fields = derive([input("local_a", index: 1, edits: [(file, "toolu_a1", 10)]),
                             input("local_b", index: 2, edits: [(file, "toolu_b1", 3)])])
        let a = try #require(fields["local_a"]?.warnings.first)
        let b = try #require(fields["local_b"]?.warnings.first)
        #expect(a.kind == .sameFile && a.otherSessionID == "local_b" && a.otherHeadline == "Session 2 \(secretWord)")
        #expect(a.path == "src/checkout.tsx" && b.path == "src/checkout.tsx" && b.otherSessionID == "local_a")
        #expect(a.since == ago(3), "since both had edited it")
        #expect(fields["local_a"]?.deadlines.first == ago(3).addingTimeInterval(CodeTuning.sameFileWindow), "it ends by itself")
        #expect(fields["local_a"]?.finished == nil && fields["local_a"]?.unread == false, "a display only")
        #expect(CodeWarningWords.line(a, now: resultNow) == "⚠ Also edited by “Session 2 \(secretWord)”: src/checkout.tsx")
    }

    @Test func aForkAndItsParentNeverCollide() {
        let file = checkout
        let fields = derive([input("local_p", index: 1, edits: [(file, "toolu_shared", 10)], copied: ["toolu_shared"]),
                             input("local_f", index: 2, edits: [(file, "toolu_shared", 10)], copied: ["toolu_shared"])])
        #expect(fields.values.allSatisfy { $0.warnings.isEmpty })
    }

    @Test func twoWorktreesNeverCollide() throws {
        let worktree = tree.home.appendingPathComponent("code/toy-cube-wt")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("src"), withIntermediateDirectories: true)
        tree.write("gitdir: ../toy-cube/.git/worktrees/wt", "home/code/toy-cube-wt/.git")
        let other = tree.write("x", "home/code/toy-cube-wt/src/checkout.tsx").path
        let fields = derive([input("local_a", index: 1, edits: [(checkout, "toolu_a1", 5)]),
                             input("local_b", index: 2, edits: [(other, "toolu_b1", 4)], cwd: worktree.path)])
        #expect(fields.values.allSatisfy { $0.warnings.isEmpty })
    }

    @Test func sshSessionsCollideByAliasAndPathOnly() {
        let path = "/home/buildbox/toy/src/./checkout.tsx"
        let fs = RecordingFileSystem()
        let same = derive([input("local_a", index: 1, edits: [(path, "toolu_a1", 5)], place: .ssh, cwd: "/home/buildbox/toy", sshHost: "buildbox"),
                           input("local_b", index: 2, edits: [("/home/buildbox/toy/src/checkout.tsx", "toolu_b1", 4)], place: .ssh,
                                 cwd: "/home/buildbox/toy", sshHost: "buildbox")], fs: fs)
        #expect(same["local_a"]?.warnings.first?.path == "src/checkout.tsx")
        #expect(fs.calls.allSatisfy { !$0.hasPrefix("/home") }, "no filesystem call for a server path")
        let twoMachines = derive([input("local_a", index: 1, edits: [(path, "toolu_a1", 5)], place: .ssh, sshHost: "buildbox"),
                                  input("local_b", index: 2, edits: [(path, "toolu_b1", 4)], place: .ssh, sshHost: "builder")])
        #expect(twoMachines.values.allSatisfy { $0.warnings.isEmpty })
        // The same path text on the Mac and on a server is never the same file.
        let mixed = derive([input("local_a", index: 1, edits: [(checkout, "toolu_a1", 5)]),
                            input("local_b", index: 2, edits: [(checkout, "toolu_b1", 4)], place: .ssh, sshHost: "buildbox")])
        #expect(mixed.values.allSatisfy { $0.warnings.isEmpty })
    }

    @Test func aNetworkPathMakesNoFilesystemCallAndNoKey() {
        let fs = RecordingFileSystem()
        let fields = derive([input("local_a", index: 1, edits: [("/net/host/share/x.swift", "toolu_a1", 5)]),
                             input("local_b", index: 2, edits: [("/net/host/share/x.swift", "toolu_b1", 4)])], fs: fs)
        #expect(fields.values.allSatisfy { $0.warnings.isEmpty })
        #expect(!fs.touched("/net"))
    }

    @Test func itClearsWhenASessionStopsRunningOrTheEditsGrowOld() {
        let file = checkout
        let finished = derive([input("local_a", index: 1, edits: [(file, "toolu_a1", 10)], state: .reviewReady),
                               input("local_b", index: 2, edits: [(file, "toolu_b1", 3)])])
        #expect(finished.values.allSatisfy { $0.warnings.isEmpty }, "one session finished")
        let needsYou = derive([input("local_a", index: 1, edits: [(file, "toolu_a1", 10)], state: .needsYou),
                               input("local_b", index: 2, edits: [(file, "toolu_b1", 3)])])
        #expect(needsYou["local_a"]?.warnings.count == 1, "Needs you still counts")
        let old = derive([input("local_a", index: 1, edits: [(file, "toolu_a1", 50)]), input("local_b", index: 2, edits: [(file, "toolu_b1", 31)])])
        #expect(old.values.allSatisfy { $0.warnings.isEmpty }, "neither edited it in the last 30 minutes")
        let apart = derive([input("local_a", index: 1, edits: [(file, "toolu_a1", 45)]), input("local_b", index: 2, edits: [(file, "toolu_b1", 5)])])
        #expect(apart.values.allSatisfy { $0.warnings.isEmpty }, "their edits lie 40 minutes apart")
        let off = derive([input("local_a", index: 1, edits: [(file, "toolu_a1", 10)]), input("local_b", index: 2, edits: [(file, "toolu_b1", 3)])],
                         settings: { var s = CodeSettings(); s.warnings.sameFile = false; return s }())
        #expect(off.values.allSatisfy { $0.warnings.isEmpty }, "switched off")
    }

    @Test func okSilencesThePairAndFileForTwoHours() throws {
        let file = checkout
        let memory = store()
        let sessions = [input("local_a", index: 1, edits: [(file, "toolu_a1", 10)]), input("local_b", index: 2, edits: [(file, "toolu_b1", 3)])]
        let warning = try #require(derive(sessions, memory: memory)["local_a"]?.warnings.first)
        CodeWarningSilencer.silence(warning, of: "local_a", memory: memory, now: resultNow)
        #expect(derive(sessions, memory: memory).values.allSatisfy { $0.warnings.isEmpty }, "both sessions")
        let records: [WarningSilenceRecord] = memory.read(.silenced, session: "local_b") ?? []
        #expect(records.count == 1 && records[0].rule.hasPrefix("same_file:") && records[0].rule.count == "same_file:".count + 16)
        #expect(!records[0].rule.contains("checkout"), "no path is stored")
        // Two hours later it is back (the edits being recent again).
        clock.set(resultNow.addingTimeInterval(2 * 3600 + 60))
        let later = sessions.map { session -> CodeCrossSessionInput in
            var lines = [Line.user("x", uuid: "u-\(session.sessionID)", at: clock.now.addingTimeInterval(-600))]
            lines.append(SeamLine.edit(file, id: "toolu_late_\(session.sessionID)", uuid: "e-\(session.sessionID)", at: clock.now.addingTimeInterval(-120)))
            return CodeCrossSessionInput(snapshot: session.snapshot, digest: resultDigest(lines), digestVersion: 2)
        }
        #expect(derive(later, memory: memory, now: clock.now)["local_a"]?.warnings.count == 1)
    }
}
