import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The string rules, the roots and the careful real path.
@Suite("Result paths")
struct ResultPathTests {
    @Test func normalizingIsStringWorkOnly() throws {
        #expect(try ResultPaths.normalize("~/a/./b/../c.md", home: "/Users/p", folder: nil).get() == "/Users/p/a/c.md")
        #expect(try ResultPaths.normalize("~", home: "/Users/p", folder: nil).get() == "/Users/p")
        #expect(try ResultPaths.normalize("docs//x.md/", home: "/Users/p", folder: "/Users/p/repo").get() == "/Users/p/repo/docs/x.md")
        #expect(try ResultPaths.normalize("/../../etc", home: "/Users/p", folder: nil).get() == "/etc")
        #expect(ResultPaths.normalize("x.md", home: "/Users/p", folder: nil) == .failure(.relative))
        #expect(ResultPaths.normalize("~root/x", home: "/Users/p", folder: nil) == .failure(.otherUsersHome))
        #expect(ResultPaths.normalize("", home: "/Users/p", folder: nil) == .failure(.empty))
        #expect(ResultPaths.normalize("/a/b\u{0}c", home: "/Users/p", folder: nil) == .failure(.hiddenCharacter))
        #expect(ResultPaths.normalize("/a/\u{202E}gpj.exe", home: "/Users/p", folder: nil) == .failure(.notASCII))
        #expect(ResultPaths.normalize("/a/r\u{0435}port.pdf", home: "/Users/p", folder: nil) == .failure(.notASCII), "Cyrillic е")
        #expect(ResultPaths.normalize("/a/\tb", home: "/Users/p", folder: nil) == .failure(.hiddenCharacter))
        #expect(ResultPaths.normalize("/" + String(repeating: "a", count: 1100), home: "/Users/p", folder: nil) == .failure(.tooLong))
    }

    @Test func networkPathsAreKnownWithoutTheDisk() {
        for path in ["/net/x/y.pdf", "/home/x/y.md", "/Volumes/x/y.md", "/NET/x", "/volumes/share", "/Network/Servers/x",
                     "/private/var/automount/x", "/var/automount/x", "/System/Volumes/Data/home/x", "/home"] {
            #expect(ResultPaths.isNetwork(path), "\(path)")
        }
        for path in ["/Users/p/net/x", "/networks/x", "/homes/x", "/tmp/x"] { #expect(!ResultPaths.isNetwork(path), "\(path)") }
    }

    @Test func insideIsByWholeParts() {
        #expect(ResultPaths.isInside("/tmp/x", "/tmp") && ResultPaths.isInside("/tmp", "/tmp"))
        #expect(!ResultPaths.isInside("/tmpx/y", "/tmp"))
        #expect(ResultPaths.remainder("/Users/p/a/b", below: "/Users/p") == ["a", "b"])
    }

    func roots(cwd: String? = "/Users/p/code/toy", toplevel: String? = "/Users/p/code/toy") -> ResultPathRoots {
        ResultPathRoots(home: .init(lexical: "/Users/p", real: "/Users/p"),
                        temporary: [.init(lexical: "/var/folders/x/T", real: "/private/var/folders/x/T"),
                                    .init(lexical: "/tmp", real: "/private/tmp"), .init(lexical: "/private/tmp", real: "/private/tmp")],
                        cwd: cwd.map { .init(lexical: $0, real: $0) }, toplevel: toplevel.map { .init(lexical: $0, real: $0) },
                        cwdIsNetwork: false)
    }

    @Test func handedOverFilesMayBeAnywhereInHomeOrTemporaryFoldersButNotLibraryOrDotFolders() {
        let r = roots()
        #expect(ResultPathRules.allowsLexically("/Users/p/Desktop/x.md", origin: .handedOver, roots: r))
        #expect(ResultPathRules.allowsLexically("/tmp/report.html", origin: .handedOver, roots: r))
        #expect(ResultPathRules.allowsLexically("/private/var/folders/x/T/a.png", origin: .handedOver, roots: r), "the real form of TMPDIR")
        #expect(!ResultPathRules.allowsLexically("/Users/p/Library/Keychains/x.md", origin: .handedOver, roots: r))
        #expect(!ResultPathRules.allowsLexically("/Users/p/.ssh/id_rsa", origin: .handedOver, roots: r))
        #expect(!ResultPathRules.allowsLexically("/Users/p/code/toy/.claude/x.md", origin: .handedOver, roots: r))
        #expect(!ResultPathRules.allowsLexically("/Users/other/x.md", origin: .handedOver, roots: r))
        #expect(!ResultPathRules.allowsLexically("/etc/passwd", origin: .handedOver, roots: r))
        #expect(ResultPathRules.allowsLexically("/Users/p/.env.md", origin: .handedOver, roots: r), "a dot-file is the name rule's")
    }

    @Test func writtenFilesOnlyInsideTheFolderOrItsRepository() {
        let r = roots(cwd: "/Users/p/code/toy/web", toplevel: "/Users/p/code/toy")
        #expect(ResultPathRules.allowsLexically("/Users/p/code/toy/web/report.md", origin: .written, roots: r))
        #expect(ResultPathRules.allowsLexically("/Users/p/code/toy/docs/report.md", origin: .written, roots: r), "the toplevel")
        #expect(!ResultPathRules.allowsLexically("/Users/p/Desktop/report.md", origin: .written, roots: r))
        #expect(!ResultPathRules.allowsLexically("/tmp/report.md", origin: .written, roots: r))
        var network = r
        network.cwdIsNetwork = true
        #expect(!ResultPathRules.allowsLexically("/Users/p/code/toy/web/report.md", origin: .written, roots: network))
    }

    @Test func theRealPathNeverFollowsALinkIntoANetworkPath() throws {
        let tree = ResultTree("realpath")
        let target = tree.write("ok", "home/code/toy-cube/docs/real.md")
        let link = tree.repo.appendingPathComponent("docs/link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real.md")
        let fs = RecordingFileSystem()
        let resolved = try ResultRealPath.resolve(link.path, fs: fs, budget: .unlimited()).get()
        #expect(resolved.path == realPath(target) && resolved.stat.kind == .regular)

        let away = tree.repo.appendingPathComponent("docs/away.md")
        try FileManager.default.createSymbolicLink(atPath: away.path, withDestinationPath: "/net/attacker.example/x.pdf")
        fs.reset()
        #expect(ResultRealPath.resolve(away.path, fs: fs, budget: .unlimited()).failureValue == .network)
        #expect(!fs.touched("/net"), "the link's target is checked as a string before anything is looked at")

        let loop = tree.repo.appendingPathComponent("docs/loop.md")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop.md")
        #expect(ResultRealPath.resolve(loop.path, fs: fs, budget: .unlimited()).failureValue == .loop)
        #expect(ResultRealPath.resolve(tree.repo.appendingPathComponent("docs/none.md").path, fs: fs, budget: .unlimited()).failureValue == .missing)
        #expect(ResultRealPath.resolve(target.path + "/x", fs: fs, budget: .unlimited()).failureValue == .notFolder)
    }

    /// L3 of the security review: the result walks use the mount table too, not only the fixed roots. A folder the
    /// table lists as an automount or network point (here one the test makes up inside its own tree) is never looked up,
    /// nor anything below it, nor its `.git`.
    @Test func resultWalksNeverLookUpAMountTableNetworkPoint() throws {
        let tree = ResultTree("mounts")
        let mounted = realPath(tree.home) + "/nfs"
        try FileManager.default.createDirectory(atPath: mounted + "/project", withIntermediateDirectories: true)
        let fs = RecordingFileSystem(guard: NetworkPathGuard(mountRoots: [mounted]))
        #expect(ResultRealPath.resolve(mounted + "/project/report.md", fs: fs, budget: .unlimited()).failureValue == .network)
        #expect(ResultRepoRoot.find(from: mounted + "/project", home: realPath(tree.home), tops: [], fs: fs,
                                    budget: .unlimited()) == nil)
        let link = tree.home.appendingPathComponent("to-nfs")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: mounted)
        #expect(ResultRealPath.resolve(link.path + "/project", fs: fs, budget: .unlimited()).failureValue == .network)
        let roots = ResultRootsMaker(home: realPath(tree.home), temporaryDirectory: NSTemporaryDirectory(), fs: fs)
            .make(cwd: mounted + "/project", budget: .unlimited())
        #expect(roots.cwdIsNetwork && roots.cwd == nil && roots.toplevel == nil)
        #expect(!fs.touched(mounted), "a lookup reached the mount point: \(fs.calls.filter { $0.hasPrefix(mounted) })")
    }

    @Test func theToplevelIsFoundByWalkingUpButNeverAboveHome() throws {
        let tree = ResultTree("toplevel")
        let deep = tree.repo.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let fs = RecordingFileSystem()
        let home = realPath(tree.home)
        #expect(ResultRepoRoot.find(from: realPath(deep), home: home, tops: [], fs: fs, budget: .unlimited()) == realPath(tree.repo))
        // A worktree's `.git` is a file.
        let worktree = tree.home.appendingPathComponent("code/toy-cube-wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        tree.write("gitdir: ../toy-cube/.git/worktrees/wt", "home/code/toy-cube-wt/.git")
        #expect(ResultRepoRoot.find(from: realPath(worktree), home: home, tops: [], fs: fs, budget: .unlimited()) == realPath(worktree))
        // No repository: the walk stops at home and never looks above it.
        let plain = tree.home.appendingPathComponent("notes/x")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        fs.reset()
        #expect(ResultRepoRoot.find(from: realPath(plain), home: home, tops: [], fs: fs, budget: .unlimited()) == nil)
        #expect(fs.calls.last == home + "/.git" && !fs.calls.contains { !$0.hasPrefix(home) })
        // At most 12 levels.
        let far = tree.home.appendingPathComponent((1...14).map { "d\($0)" }.joined(separator: "/"))
        try FileManager.default.createDirectory(at: far, withIntermediateDirectories: true)
        fs.reset()
        #expect(ResultRepoRoot.find(from: realPath(far), home: home, tops: [], fs: fs, budget: .unlimited()) == nil)
        #expect(fs.calls.count == CodeTuning.repoSearchDepth)
    }
}
