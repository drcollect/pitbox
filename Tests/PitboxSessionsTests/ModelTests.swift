import Foundation
import Testing
@testable import PitboxSessions

@Suite struct ModelTests {
    @Test func knownProfilesMapTheirFolders() {
        #expect(CodeProfiles.test.profile(folderName: "Claude") == .a)
        #expect(CodeProfiles.test.profile(folderName: "Claude-Work")?.letter == "B")
        #expect(CodeProfiles.test.profile(folderName: "Claude-Work")?.name == "B · Acme")
        #expect(CodeProfiles.test.profile(folderName: "Claude-3p") == nil)
        #expect(!CodeProfile.unknown(folderName: "Claude-3p").isReadable)
        #expect(CodeProfile.a.isReadable && CodeProfile.a.name == "A · Claude")
        // Only the default copy is built in: a listed copy is known only while the settings list it.
        #expect(CodeProfiles.defaultOnly.known == [.a])
        #expect(CodeProfiles.defaultOnly.profile(folderName: "Claude-Work") == nil)
        // A, then the listed letters, then unknown copies.
        #expect(CodeProfile.a.rank < CodeProfile.b.rank && CodeProfile.c.rank < CodeProfile.unknown(folderName: "x").rank)
    }

    @Test func everyStateHasAWord() {
        for s in CodeSessionState.allCases { #expect(!s.word.isEmpty) }
        #expect(CodeSessionState.needsYou.asksForAttention && CodeSessionState.problem.asksForAttention)
        #expect(!CodeSessionState.working.asksForAttention)
        #expect(CodeSessionState.reviewReady.isDone && !CodeSessionState.quietUnfinished.isDone)
    }

    @Test func todosCountAndPickTheCurrentItem() {
        let t = CodeSessionTodos(items: [.init(text: "a", status: .completed), .init(text: "b", status: .pending),
                                         .init(text: "c", status: .inProgress)])
        #expect(t.done == 1 && t.total == 3 && t.current?.text == "c")
    }

    @Test func settingsReadTolerantly() {
        let s = CodeSettings.decode(Data(#"{"commandShell":"login","extraPath":["/opt/x",3],"serverNames":{"buildbox":["box.example"]},"showText":{"B":false},"unknown":1}"#.utf8))
        #expect(s.commandShell == .login)
        #expect(s.extraPath == ["/opt/x"])
        #expect(s.serverNames["buildbox"] == ["box.example"])
        #expect(s.showText["B"] == false && s.showText["A"] == nil, "a letter not listed shows its text")
        #expect(CodeSettings.decode(Data("not json".utf8)) == CodeSettings())
        #expect(CodeSettings.decode(Data(#"{"commandShell":"fish"}"#.utf8)).commandShell == .clean)
    }

    @Test func extraPathDropsUnsafeEntries() {
        var s = CodeSettings(); s.extraPath = ["/ok", "relative/bin", "/a:b", "/unsafe"]
        #expect(s.usableExtraPath(isSafeFolder: { $0 == "/ok" || $0 == "/a:b" }) == ["/ok"])
    }

    @Test func defaultsFileIsCreatedOnceWithPrivateMode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cm-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("code-settings.json")
        #expect(CodeSettings.loadOrCreate(at: url) == CodeSettings())
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try Data(#"{"commandShell":"login"}"#.utf8).write(to: url)
        #expect(CodeSettings.loadOrCreate(at: url).commandShell == .login)
    }
}
