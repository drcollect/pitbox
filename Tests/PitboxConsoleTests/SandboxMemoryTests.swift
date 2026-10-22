import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// The append-only store of what verified dock hosts announced: entries are only ever added, the file is private and
/// read carefully, and whatever happens to it the process keeps denying what it already knows.
@MainActor
struct SandboxMemoryTests {
    private func store(_ dir: TempDir) -> SandboxMemory {
        SandboxMemory(file: dir.url.appendingPathComponent("sandbox-memory.json"), home: "/Users/alex")
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    @Test func entriesAreRememberedInAPrivateFileAndReadBackAfterARestart() throws {
        let dir = TempDir()
        let memory = store(dir)
        #expect(memory.folders.isEmpty && memory.socketFolders.isEmpty)
        memory.remember(folders: ["/Users/alex/Library/Application Support/Host"], socketFolders: ["/private/tmp/host-runner-501"])
        let file = dir.url.appendingPathComponent("sandbox-memory.json")
        #expect(mode(file) == 0o600)
        let again = store(dir)
        #expect(again.folders == ["/Users/alex/Library/Application Support/Host"])
        #expect(again.socketFolders == ["/private/tmp/host-runner-501"])
    }

    @Test func entriesAreOnlyEverAdded() {
        let dir = TempDir()
        let memory = store(dir)
        memory.remember(folders: ["/private/tmp/pbx-a", "/private/tmp/pbx-b"], socketFolders: ["/private/tmp/pbx-s"])
        memory.remember(folders: ["/private/tmp/pbx-b"], socketFolders: [])
        memory.remember(folders: ["/private/tmp/pbx-c", "/private/tmp/pbx-a"], socketFolders: ["/private/tmp/pbx-t"])
        #expect(memory.folders == ["/private/tmp/pbx-a", "/private/tmp/pbx-b", "/private/tmp/pbx-c"], "a host announcing less removes nothing; duplicates are skipped")
        #expect(memory.socketFolders == ["/private/tmp/pbx-s", "/private/tmp/pbx-t"])
        #expect(store(dir).folders == ["/private/tmp/pbx-a", "/private/tmp/pbx-b", "/private/tmp/pbx-c"])
    }

    @Test func badEntriesAreRefusedWithALabel() {
        let dir = TempDir()
        var lines: [String] = []
        let lock = NSLock()
        let recorder = CommandLog.addRecorder { _, line in lock.withLock { lines.append(line) } }
        defer { CommandLog.removeRecorder(recorder) }
        let memory = store(dir)
        memory.remember(folders: ["relative/x", "~/x", "/a\"b", "/a\\b", "/new\nline", "/nul\0x", "", "/private/tmp/pbx-ok"], socketFolders: [])
        #expect(memory.folders == ["/private/tmp/pbx-ok"])
        let refused = lock.withLock { lines.filter { $0.hasPrefix("sandbox memory entry refused") } }
        #expect(refused.count == 7)
        #expect(!lock.withLock { lines }.contains { $0.contains("/private/tmp/pbx-a") || $0.contains("relative") }, "labels only, never the entry")
    }

    @Test func aHandDeletedFileChangesNothingTheProcessKnowsAndComesBackOnTheNextAdd() throws {
        let dir = TempDir()
        let memory = store(dir)
        memory.remember(folders: ["/private/tmp/pbx-host"], socketFolders: ["/private/tmp/pbx-run"])
        let file = dir.url.appendingPathComponent("sandbox-memory.json")
        try FileManager.default.removeItem(at: file)
        memory.reload()
        #expect(memory.folders == ["/private/tmp/pbx-host"] && memory.socketFolders == ["/private/tmp/pbx-run"], "fail safe: still denied")
        let policy = CommandSandbox.Policy.testPolicy(ownFolder: dir.url, announcedFolders: memory.folders,
                                                      announcedSocketFolders: memory.socketFolders)
        let profile = try #require(CommandSandbox.profile(policy))
        #expect(profile.contains(#"(deny file-read* file-write* (subpath "/private/tmp/pbx-host"))"#))
        #expect(profile.contains(#"(deny network-outbound (remote unix-socket (subpath "/private/tmp/pbx-run")))"#))
        memory.remember(folders: ["/private/tmp/pbx-other"], socketFolders: [])
        let restarted = store(dir)
        #expect(restarted.folders == ["/private/tmp/pbx-host", "/private/tmp/pbx-other"] && restarted.socketFolders == ["/private/tmp/pbx-run"], "everything known is written again")
    }

    @Test func aBrokenFileIsNotUsedAndIsMovedAsideBeforeTheNextWrite() throws {
        let dir = TempDir()
        let memory = store(dir)
        memory.remember(folders: ["/private/tmp/pbx-host"], socketFolders: [])
        let file = dir.write("sandbox-memory.json", "{ not json")
        memory.reload()
        #expect(memory.folders == ["/private/tmp/pbx-host"], "the process keeps what it knows")
        #expect(store(dir).folders.isEmpty, "a new process cannot read the broken file")
        memory.remember(folders: ["/private/tmp/pbx-next"], socketFolders: [])
        let aside = dir.url.appendingPathComponent("sandbox-memory.json.broken")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json", "nothing in it is lost")
        #expect(store(dir).folders == ["/private/tmp/pbx-host", "/private/tmp/pbx-next"])
        #expect(mode(file) == 0o600)
    }

    @Test func anUntrustedFileIsNotRead() throws {
        let dir = TempDir()
        store(dir).remember(folders: ["/private/tmp/pbx-host"], socketFolders: [])
        let file = dir.url.appendingPathComponent("sandbox-memory.json")
        chmod(file.path, 0o666)
        #expect(store(dir).folders.isEmpty, "writable by others: not used")
        chmod(file.path, 0o600)
        #expect(store(dir).folders == ["/private/tmp/pbx-host"])
        // A symlink in its place is not followed.
        let elsewhere = dir.write("elsewhere.json", #"{"version":1,"folders":["/private/tmp/pbx-planted"],"socketFolders":[]}"#)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        #expect(store(dir).folders.isEmpty)
    }

    /// A total cap per list on the file, across hosts, reconnects and restarts. A new entry beyond it is not written
    /// (a label is logged) but stays denied for the process's life: a full memory never fails open. Nothing known is
    /// dropped to make room.
    @Test func pastTheCapNewEntriesStayDeniedForTheRunButAreNotWritten() throws {
        let dir = TempDir()
        var lines: [String] = []
        let lock = NSLock()
        let recorder = CommandLog.addRecorder { _, line in lock.withLock { lines.append(line) } }
        defer { CommandLog.removeRecorder(recorder) }
        let file = dir.url.appendingPathComponent("sandbox-memory.json")
        let memory = SandboxMemory(file: file, home: "/Users/alex", limit: 3)
        memory.remember(folders: ["/private/tmp/pbx-f0", "/private/tmp/pbx-f1"], socketFolders: [])
        memory.remember(folders: ["/private/tmp/pbx-f2", "/private/tmp/pbx-f3", "/private/tmp/pbx-f4"],
                        socketFolders: ["/private/tmp/pbx-s0"])
        let all = ["/private/tmp/pbx-f0", "/private/tmp/pbx-f1", "/private/tmp/pbx-f2", "/private/tmp/pbx-f3",
                   "/private/tmp/pbx-f4"]
        #expect(memory.folders == all, "past the cap: denied for this run")
        #expect(memory.socketFolders == ["/private/tmp/pbx-s0"], "each list has its own cap")
        memory.remember(folders: ["/private/tmp/pbx-f1", "/private/tmp/pbx-f4"], socketFolders: [])
        #expect(memory.folders == all, "a known entry announced again is fine")
        memory.reload()
        #expect(memory.folders == all, "a reload drops nothing")
        let profile = try #require(CommandSandbox.profile(.testPolicy(ownFolder: dir.url, announcedFolders: memory.folders)))
        #expect(profile.contains(#"(deny file-read* file-write* (subpath "/private/tmp/pbx-f2"))"#))
        #expect(profile.contains(#"(deny file-read* file-write* (subpath "/private/tmp/pbx-f4"))"#), "never fails open")
        #expect(lock.withLock { lines }.filter { $0.hasPrefix("sandbox memory full") } == ["sandbox memory full max=3 runOnly=2"])
        #expect(SandboxMemory(file: file, home: "/Users/alex", limit: 3).folders.count == 3, "the file holds the cap")
        #expect(SandboxMemory.maxEntries == 64, "the dock guest passes at most 64 per kind in all")
    }

    /// The spawn's lists: what the memory denies, then the dock link's live announcements it does not hold, each once
    /// and under the same breadth rule.
    @Test func theSpawnsListsAddTheLiveAnnouncements() {
        let dir = TempDir()
        let memory = SandboxMemory(file: dir.url.appendingPathComponent("sandbox-memory.json"), home: "/Users/alex", limit: 1)
        memory.remember(folders: ["/private/tmp/pbx-a"], socketFolders: ["/private/tmp/pbx-sa"])
        #expect(memory.folders(adding: ["/private/tmp/pbx-a", "/private/tmp/pbx-live", "/Users/alex"])
            == ["/private/tmp/pbx-a", "/private/tmp/pbx-live"], "each once; a broad one left out")
        #expect(memory.socketFolders(adding: ["/private/tmp/pbx-slive"]) == ["/private/tmp/pbx-sa", "/private/tmp/pbx-slive"])
        #expect(memory.folders == ["/private/tmp/pbx-a"], "the live ones are not remembered by reading")
    }
}

/// A short folder under /private/tmp (the only temp location an announced folder may lie in), removed at the end.
private final class PrivateTmpFolder {
    let path: String

    init() throws {
        var template = Array("/private/tmp/pbxmem.XXXXXX".utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        path = String(cString: made)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// Defense in depth: the store refuses an announced folder that is not a specific app-private folder,
/// whatever the dock link let through, also through links and `..`, and heals a file that holds one.
@MainActor
struct SandboxMemoryBreadthTests {
    private let home = "/Users/alex"

    @Test(arguments: [
        "/", "/Users", "/Users/alex", "/Users/alex/Library", "/Users/alex/Library/Application Support",
        "/Users/alex/Documents", "/Users/alex/Documents/notes", "/System", "/Library", "/Applications", "/private",
        "/var", "/tmp", "/private/tmp", "/private/var", "/private/var/folders/xy/T/host", "/Volumes", "/Volumes/Disk/x/y/z",
        "/opt", "/opt/host/state/run", "/usr", "/usr/local/var/host", "/bin", "/sbin", "/etc", "/private/etc", "/dev",
        "/Users/alex/Library/Application Support/Host/../..", "/private/tmp/pbx-x/../..",
    ])
    func broadOrUnresolvableFoldersAreRefused(_ entry: String) {
        #expect(SandboxMemory.refusal(of: entry, home: home) != nil, "\(entry)")
    }

    @Test func specificAppPrivateFoldersPass() {
        for entry in ["/Users/alex/Library/Application Support/Host", "/Users/alex/Library/Caches/Host",
                      "/private/tmp/host-runner-501", "/tmp/host-runner-501", "/private/tmp/host-runner-501/sockets"] {
            #expect(SandboxMemory.refusal(of: entry, home: home) == nil, "\(entry)")
        }
        #expect(SandboxMemory.refusal(of: "/Users/alex/Library", home: home) == .tooBroad)
        #expect(SandboxMemory.refusal(of: "/private/tmp/x/../..", home: home) == .dotDot)
    }

    @Test func aLinkToABroadFolderIsRefusedAndOneSwappedInLaterIsLeftOut() throws {
        let tmp = try PrivateTmpFolder()
        let toRoot = tmp.path + "/to-root"
        #expect(symlink("/", toRoot) == 0)
        #expect(SandboxMemory.refusal(of: toRoot, home: home) == .tooBroad, "the link leads to /")
        #expect(SandboxMemory.refusal(of: toRoot + "/usr", home: home) == .tooBroad)

        let dir = TempDir()
        let memory = SandboxMemory(file: dir.url.appendingPathComponent("sandbox-memory.json"), home: home)
        let later = tmp.path + "/host-state"
        try FileManager.default.createDirectory(atPath: later, withIntermediateDirectories: false)
        memory.remember(folders: [later, toRoot], socketFolders: [])
        #expect(memory.folders == [later], "the link to / was refused")
        // The folder is replaced by a link to / after it was remembered: it is left out of what the sandbox denies.
        try FileManager.default.removeItem(atPath: later)
        #expect(symlink("/", later) == 0)
        #expect(memory.folders.isEmpty, "never a deny of the whole disk")
        try FileManager.default.removeItem(atPath: later)
        try FileManager.default.createDirectory(atPath: later, withIntermediateDirectories: false)
        #expect(memory.folders == [later], "kept in memory: denied again once it is specific again")
    }

    @Test func aFileWithABroadEntryHeals() throws {
        let dir = TempDir()
        let file = dir.write("sandbox-memory.json",
                             #"{"version":1,"folders":["/","/private/tmp/pbx-host"],"socketFolders":["/Users/alex"]}"#)
        let memory = SandboxMemory(file: file, home: home)
        #expect(memory.folders == ["/private/tmp/pbx-host"])
        #expect(memory.socketFolders.isEmpty)
        memory.remember(folders: ["/private/tmp/pbx-next"], socketFolders: [])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(#""/""#) && !text.contains("/Users/alex"), "the broad entries are gone from the file")
        #expect(SandboxMemory(file: file, home: home).folders == ["/private/tmp/pbx-host", "/private/tmp/pbx-next"])
    }
}

/// An entry that does not exist yet is resolved through the part that exists (links included, by
/// `realpath`), never lexically; a `..` after that part is refused.
@MainActor
struct SandboxEntryTests {
    @Test func aDotDotAfterALinkFollowsTheLinkAndAnUnresolvableOneIsRefused() throws {
        let dir = TempDir()
        let a = dir.url.appendingPathComponent("a"), deep = dir.url.appendingPathComponent("b/deep")
        for folder in [a, deep] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("link"), withDestinationURL: deep)
        let b = try #require(CommandSandbox.canonicalPath(dir.url.appendingPathComponent("b").path))
        let viaLink = a.path + "/link/../x"
        #expect(CommandSandbox.canonicalEntry(viaLink, home: "/Users/tester") == .success(b + "/x"),
                "the kernel's meaning: the link's parent, not a/x")
        #expect(CommandSandbox.canonicalEntry(a.path + "/missing/../x", home: "/Users/tester") == .failure(.dotDot))
        #expect(CommandSandbox.canonicalEntry(a.path + "/new/./x", home: "/Users/tester")
                == .success(try #require(CommandSandbox.canonicalPath(a.path)) + "/new/x"))
        #expect(CommandSandbox.canonicalPath("/tmp/x-\(UUID().uuidString)/../y") == nil)
    }
}
