import Darwin
import Foundation
import Testing
@testable import PitboxConsole

/// The descriptor steps of saving into Downloads, one by one: the staged file must be a plain file, the move never
/// replaces anything, the staging folder always goes.
struct FetchFoldersTests {
    @Test func onlyAPlainFileOfOursWithOneLinkLeavesStaging() throws {
        let sandbox = FetchSandbox()
        let stage = sandbox.root + "/stage"
        FetchSandbox.makeFolder(stage)
        sandbox.write(stage + "/plain.md", "plain")
        sandbox.write(stage + "/linked.md", "linked")
        _ = link(stage + "/linked.md", stage + "/second-link.md")
        _ = symlink(stage + "/plain.md", stage + "/symlink.md")
        FetchSandbox.makeFolder(stage + "/folder.app")
        _ = mkfifo(stage + "/fifo.md", 0o600)
        let folder = FetchFolders.openFolder(stage)
        defer { close(folder) }
        try #require(folder >= 0)

        guard case .success(let file) = FetchFolders.openStagedFile(in: folder, name: "plain.md") else {
            Issue.record("a plain file is accepted"); return
        }
        #expect(file.size == 5)
        close(file.fd)
        for name in ["symlink.md", "folder.app", "fifo.md", "linked.md"] {
            guard case .failure(let reason) = FetchFolders.openStagedFile(in: folder, name: name) else {
                Issue.record("\(name) must be refused"); continue
            }
            #expect(reason == .notPlainFile, "\(name)")
        }
        guard case .failure(.noSuchFile) = FetchFolders.openStagedFile(in: folder, name: "missing.md") else {
            Issue.record("a missing file reads as no such file"); return
        }
    }

    @Test func theMoveNeverReplacesAFileALinkOrAFolder() throws {
        let sandbox = FetchSandbox()
        let stage = sandbox.root + "/stage"
        FetchSandbox.makeFolder(stage)
        sandbox.write(stage + "/a.md", "new")
        sandbox.write(sandbox.downloads + "/a.md", "old file")
        _ = symlink("/etc/hosts", sandbox.downloads + "/a 2.md")
        FetchSandbox.makeFolder(sandbox.downloads + "/a 3.md")
        let staging = FetchFolders.openFolder(stage)
        let downloads = FetchFolders.openFolder(sandbox.downloads)
        defer { close(staging); close(downloads) }

        let moved = FetchFolders.moveExclusive(name: "a.md", from: staging, to: downloads,
                                               candidates: FetchNames.candidates(for: "a.md"))
        #expect(moved == .success("a 4.md"))
        #expect(sandbox.data(sandbox.downloads + "/a.md") == Data("old file".utf8))
        var info = stat()
        #expect(lstat(sandbox.downloads + "/a 2.md", &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK)
        #expect(lstat(sandbox.downloads + "/a 3.md", &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR)
        #expect(sandbox.data(sandbox.downloads + "/a 4.md") == Data("new".utf8))
    }

    @Test func ninetyNineTakenNamesLeaveTheFileInStaging() throws {
        let sandbox = FetchSandbox()
        let stage = sandbox.root + "/stage"
        FetchSandbox.makeFolder(stage)
        sandbox.write(stage + "/b.md", "new")
        for name in FetchNames.candidates(for: "b.md") { sandbox.write(sandbox.downloads + "/" + name, "taken") }
        let staging = FetchFolders.openFolder(stage)
        let downloads = FetchFolders.openFolder(sandbox.downloads)
        defer { close(staging); close(downloads) }
        #expect(FetchFolders.firstFreeName(in: downloads, candidates: FetchNames.candidates(for: "b.md")) == nil)
        #expect(FetchFolders.moveExclusive(name: "b.md", from: staging, to: downloads,
                                           candidates: FetchNames.candidates(for: "b.md")) == .failure(.noFreeName))
        #expect(sandbox.data(stage + "/b.md") == Data("new".utf8))
        #expect(FetchFailure.noFreeName.words(alias: "c", user: "u", fileName: "b.md", limits: FetchLimits())
                == "Downloads already has 99 files named b.md")
    }

    @Test func stagingFoldersArePrivateAndRemovedWithTheirContents() throws {
        let sandbox = FetchSandbox()
        let parent = FetchFolders.openStagingParent(sandbox.stagingParent)
        defer { close(parent) }
        try #require(parent >= 0)
        let staging = try #require(FetchFolders.makeStagingFolder(in: parent))
        #expect(staging.name.hasPrefix("fetch-") && staging.name.count == 38)
        var info = stat()
        #expect(fstat(staging.fd, &info) == 0 && info.st_mode & 0o777 == 0o700)
        let partial = openat(staging.fd, "partial.bin", O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        #expect(partial >= 0)
        close(partial)
        _ = mkdirat(staging.fd, "nested", 0o700)
        _ = symlinkat("/etc", staging.fd, "nested/link")
        _ = fchmodat(staging.fd, "nested", 0o500, 0)   // read-only: still emptied and removed
        close(staging.fd)
        FetchFolders.removeTree(named: staging.name, in: parent)
        #expect(sandbox.entries(sandbox.stagingParent).isEmpty)
        #expect(FileManager.default.fileExists(atPath: "/etc/hosts"), "links are removed, never followed")
    }

    @Test func aStagingParentThatIsALinkIsRefused() {
        let sandbox = FetchSandbox()
        FetchSandbox.makeFolder(sandbox.root + "/elsewhere")
        FetchSandbox.makeFolder(sandbox.home + "/Library/Caches/Pitbox")
        _ = symlink(sandbox.root + "/elsewhere", sandbox.stagingParent)
        #expect(FetchFolders.openStagingParent(sandbox.stagingParent) == -1)
    }
}
