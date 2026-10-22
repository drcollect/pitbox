import Darwin
import Foundation
import Testing
import PitboxKit

/// This Mac's filesystem, recording every path the walk asks about.
final class RecordingLiveFileSystem: LocalPathFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let live = LiveLocalPathFileSystem()

    var calls: [String] { lock.withLock { recorded } }

    func lstat(_ path: String) -> LocalPathLookup {
        lock.withLock { recorded.append(path) }
        return live.lstat(path)
    }

    func readlink(_ path: String) -> String? {
        lock.withLock { recorded.append(path) }
        return live.readlink(path)
    }
}

/// An `Include` of the SSH configuration is expanded as glob expands it, under the network check of every other lookup:
/// a pattern that reaches a refused root is never looked up there (docs/THREAT_MODEL.md, T33).
struct CheckedGlobTests {
    /// A temporary folder by its real path (so `/var` and `/private/var` cannot differ), removed afterwards.
    final class Tree {
        let root: String

        init() throws {
            let raw = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pitbox-glob-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            guard Darwin.realpath(raw.path, &buffer) != nil else { throw CocoaError(.fileNoSuchFile) }
            root = String(cString: buffer)
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }

        func write(_ relative: String) throws {
            let url = URL(fileURLWithPath: root + "/" + relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Host x\n".utf8).write(to: url)
        }

        func link(_ relative: String, to target: String) throws {
            try FileManager.default.createSymbolicLink(atPath: root + "/" + relative, withDestinationPath: target)
        }
    }

    /// What plain glob(3) answers (only for local test folders).
    private func plainGlob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
    }

    @Test func itMatchesWhatGlobMatches() throws {
        let tree = try Tree()
        for file in ["conf.d/b.conf", "conf.d/a.conf", "conf.d/.hidden.conf", "conf.d/notes.txt", "hosts/x/config", "hosts/y/config",
                     "with space/a b.conf"] {
            try tree.write(file)
        }
        try tree.link("linked.d", to: "conf.d")
        for pattern in ["conf.d/*.conf", "conf.d/*", "conf.d/.*", "hosts/*/config", "conf.d/a.conf", "conf.d/none.conf",
                        "c?nf.d/[ab].conf", "nothing/*", "with space/*", "linked.d/*.conf", "conf.d/\\a.conf", "*"] {
            let full = tree.root + "/" + pattern
            let expected = plainGlob(full)
            #expect(CheckedGlob.expand(full, guard: .fixed) == .matches(expected), "\(pattern)")
            #expect(!expected.isEmpty || ["conf.d/none.conf", "nothing/*"].contains(pattern), "\(pattern): the fixture matches")
        }
        #expect(CheckedGlob.expand("relative/*", guard: .fixed) == .failed)
    }

    @Test func aPatternThatReachesARefusedRootIsNeverLookedUp() throws {
        let tree = try Tree()
        // A folder of the test's own standing in for an automount point the mount table lists.
        let mount = tree.root + "/automounted"
        try tree.write("automounted/ssh/x.conf")
        try tree.write("local/ok.conf")
        try tree.link("to-mount", to: mount + "/ssh")
        try tree.link("local/up", to: "../automounted")
        let pathGuard = NetworkPathGuard(mountRoots: [mount])
        for pattern in [mount + "/ssh/x.conf", mount + "/ssh/*.conf", tree.root + "/to-mount/x.conf", tree.root + "/to-mount/*",
                        tree.root + "/*/ssh/x.conf", tree.root + "/auto*/ssh/x.conf", tree.root + "/local/*/ssh/*",
                        tree.root + "/AUTOMOUNTED/ssh/x.conf", "/Volumes/pitbox-test-volume/config", "/Volumes/*/config",
                        "/Vol*/pitbox-test-volume/config", "/V?lumes/pitbox-test-volume/*.conf"] {
            let fs = RecordingLiveFileSystem()
            #expect(CheckedGlob.expand(pattern, guard: pathGuard, fs: fs) == .refused, "\(pattern)")
            let reached = fs.calls.filter { pathGuard.refuses($0) }
            #expect(reached.isEmpty, "\(pattern): a lookup reached a refused root: \(reached)")
        }
        // The rest of the tree is still read.
        let fs = RecordingLiveFileSystem()
        #expect(CheckedGlob.expand(tree.root + "/local/*.conf", guard: pathGuard, fs: fs) == .matches([tree.root + "/local/ok.conf"]))
        #expect(!fs.calls.isEmpty, "the walk asked about the local folders")
        #expect(CheckedGlob.expand(tree.root + "/local/none-*", guard: pathGuard) == .matches([]))
    }
}
