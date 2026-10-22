import Darwin
import Foundation
import Testing
@testable import PitboxSessions

/// Report files on this Mac (docs/THREAT_MODEL.md), in made-up folders with a recording filesystem: no filesystem call
/// before the string checks, the roots again on the real path, regular files with one link, type and name by the
/// resolved name, and every rule again at the click.
@Suite("Local report files")
struct LocalReportCheckTests {
    let tree = ResultTree("local-files")

    /// `realBudget`: the 50 ms wall-clock budget of the app; otherwise unlimited, so a busy machine (the whole suite
    /// running in parallel) cannot cut a check short and misalign the results with the names (seen once).
    func check(_ candidates: [ResultFileCandidate], fs: RecordingFileSystem = RecordingFileSystem(), cwd: String? = nil,
               webPreview: Bool = true, realBudget: Bool = false) -> [CodeResult] {
        let environment = tree.environment(fs, webPreview: webPreview)
        return LocalReportCheck(environment: environment).results(for: candidates, cwd: cwd ?? tree.repo.path,
                                                                    budget: realBudget ? environment.budget() : .unlimited())
    }

    func handed(_ path: String) -> ResultFileCandidate {
        ResultFileCandidate(path: path, origin: .handedOver, toolUseID: "toolu_send", at: ago(5))
    }

    func written(_ path: String) -> ResultFileCandidate {
        ResultFileCandidate(path: path, origin: .written, toolUseID: "toolu_write", at: ago(5))
    }

    @Test func networkPathsMakeNoFilesystemCallAtAll() {
        let fs = RecordingFileSystem()
        let up = String(repeating: "../", count: 40)
        let results = check([handed("/net/x/y.pdf"), handed("/home/x/y.md"), handed("/Volumes/x/y.md"), handed(up + "net/x.pdf")], fs: fs)
        #expect(fs.calls.isEmpty, "\(fs.calls.count) calls")
        #expect(results.count == 4 && results.allSatisfy { $0.kind == .mentionedPath && $0.note == "not checked: network path" })
    }

    @Test func aSessionWorkingUnderVolumesGetsNoCheckAtAll() {
        let fs = RecordingFileSystem()
        let results = check([written("/Volumes/x/proj/report.md"), handed(tree.tmp.appendingPathComponent("a.md").path)], fs: fs,
                            cwd: "/Volumes/x/proj")
        #expect(fs.calls.isEmpty)
        #expect(results.map(\.note) == ["not checked: network path", "not checked: network path"])
    }

    @Test func sevenCandidatesCheckSix() {
        let files = (1...7).map { tree.write("x", "tmp/report\($0).md") }
        let fs = RecordingFileSystem()
        let results = check(files.map { handed($0.path) }, fs: fs)
        #expect(results.count == 6 && results.allSatisfy { $0.kind == .document })
        #expect(!fs.touched(files[6].path) && !fs.touched(realPath(files[6])), "the seventh is never looked at")
    }

    @Test func aSlowFilesystemIsGivenUpAfter50ms() {
        let files = (1...6).map { tree.write("x", "tmp/slow\($0).md") }
        let fs = RecordingFileSystem(delay: 0.012)
        let started = Date()
        let results = check(files.map { handed($0.path) }, fs: fs, realBudget: true)
        #expect(Date().timeIntervalSince(started) < 0.25)
        #expect(results.count < 6, "the budget ends the checks")
        #expect(fs.calls.count <= Int(CodeTuning.fileCheckBudget / 0.012) + 2)
    }

    @Test func pathsOutsideTheRootsGetNoButtonAndNoLook() {
        let key = tree.write("PRIVATE", "home/.ssh/id_rsa")
        let fs = RecordingFileSystem()
        let results = check([handed("../../.ssh/id_rsa"), written("../../.ssh/id_rsa"), handed("/etc/hosts")], fs: fs)
        #expect(results.allSatisfy { $0.kind == .mentionedPath })
        #expect(!fs.touched(key.path) && !fs.touched(realPath(key)) && !fs.touched("/etc/hosts"))
    }

    @Test func handedOverMayBeInTheTemporaryFolderButNeverInADotFolder() throws {
        let report = tree.write("ok", "tmp/report.md")
        let secret = tree.write("PRIVATE", "home/.ssh/notes.md")
        let results = check([handed(report.path), handed(secret.path), handed("~/Desktop/missing.md")])
        let first = try #require(results.first)
        #expect(first.kind == .document && first.path == realPath(report) && first.label == "report.md")
        #expect(first.device != nil && first.inode != nil && first.toolUseID == "toolu_send")
        #expect(results[1].kind == .mentionedPath, "~/.ssh is a dot-folder")
        #expect(results[2].kind == .mentionedPath, "missing")
    }

    @Test func aLinkInsideTheRepositoryPointingOutsideIsRefused() throws {
        tree.write("PRIVATE", "home/.ssh/id_rsa")
        let link = tree.repo.appendingPathComponent("docs/key.md")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: tree.home.appendingPathComponent(".ssh/id_rsa").path)
        let results = check([written(link.path), handed(link.path)])
        #expect(results.map(\.kind) == [.mentionedPath, .mentionedPath])
    }

    @Test func aHardLinkIsRefused() throws {
        let first = tree.write("x", "tmp/a.md")
        let second = tree.tmp.appendingPathComponent("b.md")
        #expect(Darwin.link(first.path, second.path) == 0)
        #expect(check([handed(second.path)]).first?.kind == .mentionedPath, "st_nlink 2")
    }

    @Test func aLinkIsJudgedByItsResolvedName() throws {
        tree.write("SECRET=1", "home/code/toy-cube/.env")
        let link = tree.repo.appendingPathComponent("report.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: ".env")
        let result = try #require(check([written(link.path)]).first)
        #expect(result.kind == .otherFile && result.label == ".env", "never ▤ Open report.txt")
    }

    @Test func aFolderNamedLikeADocumentIsRefused() throws {
        try FileManager.default.createDirectory(at: tree.repo.appendingPathComponent("report.md"), withIntermediateDirectories: true)
        #expect(check([written(tree.repo.appendingPathComponent("report.md").path)]).first?.kind == .mentionedPath)
    }

    @Test func typesDecideTheButton() {
        let names = ["report.md.command", "script.sh", "notes.md", "demo.mp4", "index.html", "chart.svg", "page.xhtml",
                     "site.webarchive", "archive.zip", "noext"]
        let files = names.map { tree.write("x", "home/code/toy-cube/out/\($0)") }
        let kinds = Dictionary(uniqueKeysWithValues: zip(names, check(files.prefix(6).map { written($0.path) }).map(\.kind)))
        #expect(kinds["report.md.command"] == .otherFile && kinds["script.sh"] == .otherFile)
        #expect(kinds["notes.md"] == .document && kinds["demo.mp4"] == .document)
        #expect(kinds["index.html"] == .webDocument && kinds["chart.svg"] == .webDocument)
        let rest = check(files.suffix(4).map { written($0.path) })
        #expect(rest.map(\.kind) == [.webDocument, .webDocument, .otherFile, .otherFile])
        // Without the web preview (`webPreview: false`): web documents are Show in Finder only.
        let off = check([written(files[4].path), written(files[5].path), written(files[6].path), written(files[7].path)], webPreview: false)
        #expect(off.allSatisfy { $0.kind == .otherFile })
    }

    @Test func aFileReplacedAfterTheCardFailsTheClickCheck() throws {
        let file = tree.write("first", "home/code/toy-cube/notes.md")
        let environment = tree.environment()
        let result = try #require(check([written(file.path)]).first)
        let checker = LocalReportCheck(environment: environment)
        #expect(try checker.recheck(result, cwd: tree.repo.path).get().path == realPath(file))
        try FileManager.default.removeItem(at: file)
        tree.write("second", "home/code/toy-cube/notes.md")
        #expect(checker.recheck(result, cwd: tree.repo.path) == .failure(.changed))
        #expect(ResultRecheckFailure.changed.words == "the file changed after you looked")
        // A result whose path is a link now (swapped for one) fails too.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: tree.tmp.path)
        #expect(checker.recheck(result, cwd: tree.repo.path) == .failure(.changed))
    }

    @Test func afterAFetchDocumentsOpenAndWebDocumentsPreview() {
        #expect(CodeResultFiles.fetchedOpening(fileName: "release-notes 2.md") == .open)
        #expect(CodeResultFiles.fetchedOpening(fileName: "demo.mp4") == .open)
        #expect(CodeResultFiles.fetchedOpening(fileName: "report.html") == .preview)
        #expect(CodeResultFiles.fetchedOpening(fileName: "eval-tables.zip") == .showInFinderOnly)
        #expect(CodeResultFiles.fetchedOpening(fileName: "run.sh") == .showInFinderOnly)
        #expect(CodeResultFiles.fetchedOpening(fileName: "notes.md.app") == .showInFinderOnly)
        #expect(CodeResultFiles.fetchedOpening(fileName: "archive.tar.gz") == .showInFinderOnly)
    }

    @Test func aFIFOIsRefusedWithoutWaiting() {
        let pipe = tree.tmp.appendingPathComponent("pipe.md")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let started = Date()
        #expect(check([handed(pipe.path)]).first?.kind == .mentionedPath)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
