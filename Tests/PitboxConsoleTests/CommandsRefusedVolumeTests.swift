import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// A session that works on an external or network volume runs and types none of its commands (Copy stays); for every
/// other session the sheet names the folder a command would start in (docs/THREAT_MODEL.md, T33).
@MainActor
struct CommandsRefusedVolumeTests {
    static let words = "This session works on an external or network volume: Pitbox does not run its commands. Copy them instead."
    static let cwd = "/Volumes/pitbox-test-volume/my project"

    /// What the session side hands over for such a session: an unknown place, and its folder named as refused.
    static func refusedFacts() -> CommandSessionFacts {
        var facts = SheetFixtures.facts(place: .unknown)
        facts.refusedLocalCwd = cwd
        return facts
    }

    @Test func runAndTypeAreOffWithTheReasonAndCopyStays() async throws {
        let fs = RecordingPathFileSystem()
        let h = SheetHarness(realClassifier: ())
        h.controller.pathFileSystem = fs
        h.controller.pathGuard = { NetworkLookupTests.pathGuard }
        await h.present(SheetFixtures.offer("echo done > notes.txt", facts: Self.refusedFacts()))
        h.advance(3)
        let model = try #require(h.model)
        #expect(!model.showsMachinePicker, "no pick: no machine makes it run")
        #expect(model.run.state == .off(Self.words) && model.type.state == .off(Self.words))
        #expect(model.checkText == Self.words && model.message?.text == Self.words)
        #expect(model.copy.state == .on && model.redLines.isEmpty && model.footer == nil)
        #expect(model.rows.first { $0.label == "Session" }?.lines == [[.host("works on an external or network volume")]])
        #expect(model.rows.first { $0.label == "Runs on" }?.lines == [[.warning("nowhere: Pitbox does not run this session's commands")]])
        let folder = try #require(model.rows.first { $0.label == "Folder" })
        #expect(folder.lines == [[.host("/Volumes/pitbox-test-volume/my project"), .dim("   (\(Self.cwd))")],
                                 [.warning("an external or network volume: nothing runs here")]], "its own folder, shown")
        let sheet = try #require(h.sheet)
        #expect(sheet.frozen?.folder == nil, "nothing is bound, so nothing can start")
        #expect(sheet.state.howItRuns.contains { $0.contains(.dim("  (not bound: nothing runs from this sheet)")) })
        #expect(fs.calls.isEmpty, "the folder is never looked up: \(fs.calls)")

        // Run, Type and a pick of This Mac start nothing; Copy copies.
        let view = try #require(h.view)
        h.click(view.runButton)
        h.click(view.typeButton)
        h.controller.pickMachine(.thisMac)
        h.controller.runOrType(.run)
        h.controller.runOrType(.typeIntoTerminal)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(h.host.requests.isEmpty && h.model?.machinePick == nil)
        h.click(view.copyButton)
        #expect(h.pasteboard.string(forType: .string) == "echo done > notes.txt")
    }

    /// With Run off in the settings, Type is still off for such a session, and the footer does not suggest turning Run on.
    @Test func runOffInTheSettingsChangesNothingForIt() async throws {
        let h = SheetHarness(realClassifier: ())
        h.runPolicy = .copyOnly
        await h.present(SheetFixtures.offer("ls", facts: Self.refusedFacts()))
        let model = try #require(h.model)
        #expect(!model.run.state.isShown && model.type.state == .off(Self.words) && model.footer == nil)
        #expect(model.message?.text == Self.words)
    }

    /// The rule is the session's, not the command's: a blocked or partly read command keeps its own words, and still
    /// offers no pick and binds nothing.
    @Test func otherClassesKeepTheirWordsAndStillBindNothing() async throws {
        let h = SheetHarness(realClassifier: ())
        await h.present(SheetFixtures.offer("ls", facts: Self.refusedFacts(), complete: false))
        let model = try #require(h.model)
        #expect(model.checkText == "Pitbox couldn't read the whole reply. Copy only.")
        #expect(!model.run.state.isOn && !model.type.state.isOn && !model.showsMachinePicker)
        #expect(h.sheet?.frozen?.folder == nil)
    }

    /// L2 of the p8 review: an offer made while the session's folder was an ordinary one (kept behind R22, or the latest
    /// one before a parse) is decided again when the sheet opens: a folder that is now a mount-table point counts as on
    /// a refused root, never looked up there.
    @Test func aFolderThatBecameARefusedRootIsCaughtWhenTheSheetOpens() async throws {
        let fs = RecordingPathFileSystem(["/Users/alex/automounted/p": .folder])
        let h = SheetHarness(realClassifier: ())
        h.controller.pathFileSystem = fs
        h.controller.pathGuard = { NetworkLookupTests.pathGuard }
        await h.present(SheetFixtures.offer("ls", facts: SheetFixtures.facts(cwd: "/Users/alex/automounted/p")))
        h.advance(3)
        let model = try #require(h.model)
        #expect(model.run.state == .off(Self.words) && model.type.state == .off(Self.words) && model.checkText == Self.words)
        #expect(h.sheet?.state.folder.path == "/Users/alex/automounted/p" && h.sheet?.frozen?.folder == nil)
        #expect(NetworkLookupTests.reachedNetwork(fs.calls).isEmpty, "\(fs.calls)")
    }

    /// The same for an unknown place, whose folder the session side names as written (`localWorkFolder`).
    @Test func anUnknownPlacesFolderThatBecameARefusedRootIsCaughtWhenTheSheetOpens() async throws {
        let fs = RecordingPathFileSystem()
        let h = SheetHarness(realClassifier: ())
        h.controller.pathFileSystem = fs
        h.controller.pathGuard = { NetworkLookupTests.pathGuard }
        var facts = SheetFixtures.facts(place: .unknown)
        facts.localWorkFolder = "/Users/alex/automounted/p"
        await h.present(SheetFixtures.offer("ls", facts: facts))
        let model = try #require(h.model)
        #expect(!model.showsMachinePicker && model.run.state == .off(Self.words) && model.type.state == .off(Self.words))
        #expect(model.rows.first { $0.label == "Session" }?.lines == [[.host("works on an external or network volume")]])
        #expect(fs.calls.isEmpty, "\(fs.calls)")
        // An SSH session's folder is a server path: never walked here.
        let ssh = SheetHarness(realClassifier: ())
        ssh.controller.pathFileSystem = fs
        ssh.controller.pathGuard = { NetworkLookupTests.pathGuard }
        var server = SheetFixtures.facts(place: .ssh, alias: "buildbox")
        server.localWorkFolder = "/Users/alex/automounted/p"
        await ssh.present(SheetFixtures.offer("ls", facts: server))
        #expect(ssh.sheet?.state.workFolderRefused == false)
    }

    /// A mount that appears at the session's folder while the sheet is open is caught at the click: nothing starts, the
    /// sheet says why, and Run and Type stay off.
    @Test func aRefusedRootThatAppearsWhileTheSheetIsOpenIsCaughtAtTheClick() async throws {
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text)
            a.commandClass = .unclearMachine
            a.machine = .unclear
            return a
        })
        let folder = h.folder.path + "/nfs/project"
        var facts = SheetFixtures.facts(place: .unknown)
        facts.localWorkFolder = folder
        await h.present(SheetFixtures.offer("echo hi", facts: facts))
        h.advance(1)
        let view = try #require(h.view)
        h.click(view.thisMacChip)
        h.advance(1)
        #expect(h.model?.run.state == .on, "an ordinary unknown place, as before")
        h.controller.pathGuard = { NetworkPathGuard(mountRoots: [h.folder.path + "/nfs"]) }
        h.click(view.runButton)
        #expect(await waitUntil(5) { h.sheet?.state.workFolderRefused == true })
        #expect(h.host.requests.isEmpty, "nothing started")
        let model = try #require(h.model)
        #expect(model.run.state == .off(Self.words) && model.type.state == .off(Self.words))
        #expect(model.message?.text == Self.words && h.sheet?.frozen?.folder == nil && h.sheet?.state.folder.path == folder)
        h.advance(3)
        h.click(view.typeButton)
        h.controller.runOrType(.typeIntoTerminal)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(h.host.requests.isEmpty)
    }

    /// SSH sessions are unchanged: the fact is never theirs, and the sheet ignores it there.
    @Test func anSSHSessionIsUnchanged() async throws {
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text)
            a.commandClass = .unclearMachine
            a.machine = .unclear
            return a
        })
        var facts = SheetFixtures.facts(place: .ssh, alias: "buildbox")
        facts.refusedLocalCwd = Self.cwd
        await h.present(SheetFixtures.offer("tail -n 5 /var/log/x", facts: facts))
        h.advance(1)
        let view = try #require(h.view)
        #expect(h.model?.showsMachinePicker == true)
        h.click(view.thisMacChip)
        #expect(h.model?.run.state == .on && h.sheet?.state.folder.path == h.folder.path)
    }

    /// Every sheet names the folder its command would start in, the folder that is bound; for an unknown place it says
    /// that this is not a folder of the session's. Run and Type behave as before for these places.
    @Test func theSheetAlwaysNamesTheFolderACommandStartsIn() async throws {
        for place: CommandSessionFacts.Place in [.local, .ssh, .unknown] {
            let h = SheetHarness(assess: { text, context in
                var a = SheetFixtures.notFlagged(text)
                if context.facts.place == .unknown {
                    a.commandClass = .unclearMachine
                    a.machine = .unclear
                }
                return a
            })
            let facts: CommandSessionFacts
            let expected: String
            var note: String?
            switch place {
            case .local:
                expected = h.folder.subfolder("project").path
                facts = SheetFixtures.facts(cwd: expected)
            case .ssh:
                expected = h.folder.path
                facts = SheetFixtures.facts(place: .ssh, alias: "buildbox")
            case .unknown:
                expected = h.folder.path
                facts = SheetFixtures.facts(place: .unknown)
                note = "Pitbox couldn't tell where this session works: runs in ~"
            }
            await h.present(SheetFixtures.offer("echo hi", facts: facts))
            h.advance(1)
            let view = try #require(h.view)
            if h.model?.showsMachinePicker == true {
                h.click(view.thisMacChip)
                h.advance(1)
            }
            let model = try #require(h.model)
            let state = try #require(h.sheet?.state.folder)
            #expect(state.path == expected, "\(place)")
            let row = try #require(model.rows.first { $0.label == "Folder" })
            #expect(row.lines.first == [.host(state.shortPath), .dim("   (\(expected))")], "\(place)")
            #expect(Array(row.lines.dropFirst()) == (note.map { [[CommandSheetModel.Part.warning($0)]] } ?? []), "\(place)")
            #expect(h.sheet?.frozen?.folder?.path == expected, "\(place): the folder named is the folder bound")
            #expect(model.run.state == .on, "\(place): as before")
            h.click(view.runButton)
            #expect(await waitUntil(5) { h.host.requests.count == 1 }, "\(place)")
            #expect(h.host.requests.first?.folder.path == expected, "\(place): it starts where the sheet said")
        }
    }
}
