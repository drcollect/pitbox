import Darwin
import Foundation
import PitboxKit

/// The private folders and socket folders verified dock hosts announced (`hello.private`,
/// docs/DOCK_PROTOCOL.md §5.3), remembered so the command sandbox keeps denying them after the host quits, and after
/// Pitbox restarts.
///
/// Append-only: entries are only ever added, never removed by Pitbox. The file is `<appSupport>/sandbox-memory.json`
/// (mode 0600, in the private 0700 folder that commands cannot read or write). It is read carefully: a file that is a
/// symlink, belongs to someone else, is writable by group or others, or is not the expected JSON is not used. Whatever
/// happens to the file (deleted by hand, broken, replaced), the process keeps denying every entry it already knows and
/// logs a label; the next `remember` writes the file again with everything known (a broken file is first moved aside
/// to `sandbox-memory.json.broken`, never lost).
///
/// The store does not decide whom to believe: the dock link calls `remember` only for a host it verified. It checks
/// every entry itself all the same (defense in depth, docs/DOCK_PROTOCOL.md §5.3): an absolute path without control
/// characters, `"` or `\`, whose canonical form (`realpath(3)` of the part that exists) is a specific app-private
/// folder, at least 3 components below the home folder or at least 1 below `/private/tmp`; never `/`, the home folder or
/// one of its ancestors, the system's top folders, `~/Library` or `~/Library/Application Support` (`too-broad`). Others
/// are refused and a label is logged. The same rule applies to the file's entries at every read (so a file written by an
/// older build heals) and again whenever the lists are read: an entry that now resolves to a broad folder (a link
/// swapped in later) is left out of the lists, logged once, and kept in memory.
///
/// A total cap on the file: at most `maxEntries` per list, across all hosts, reconnects and restarts. A new entry beyond
/// it is not written (`sandbox memory full`, logged) but kept and denied for the rest of the process's life, so a full
/// memory never leaves a verified host's folders open (it never fails open); nothing known is ever dropped to make room.
/// The sandbox policy also adds the folders the dock link holds for the hosts it verified in this process
/// (`folders(adding:)`).
///
/// Thread-safe: the dock link may call `remember` from its own queue while a spawn reads the lists.
public final class SandboxMemory: @unchecked Sendable {
    /// At most this many entries per list (a host announces one or two; the dock guest passes at most 64 in all).
    static let maxEntries = 64
    /// The file is not read when it is larger than this.
    static let maxFileBytes = 1_000_000

    private let file: URL
    private let uid: uid_t
    /// The canonical home folder the breadth rule measures from.
    private let home: String
    /// The cap per list (`maxEntries`; tests use a small one).
    let limit: Int
    private let lock = NSLock()
    private var knownFolders: [String] = []
    private var knownSocketFolders: [String] = []
    /// Valid entries announced past the cap: denied for the process's life, never written to the file.
    private var runOnlyFolders: [String] = []
    private var runOnlySocketFolders: [String] = []
    /// Entries left out of the lists because they now resolve to a broad folder (logged once each).
    private var reportedBroad: Set<String> = []

    /// The store in Pitbox's folder (`Paths.appSupport/sandbox-memory.json`), read now.
    public convenience init() {
        self.init(file: Paths.appSupport.appendingPathComponent("sandbox-memory.json"))
    }

    /// The store at `file`, read now (tests use a scratch folder and an invented home).
    init(file: URL, uid: uid_t = getuid(), home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         limit: Int = SandboxMemory.maxEntries) {
        self.file = file
        self.uid = uid
        self.home = CommandSandbox.canonicalPath(home) ?? home
        self.limit = limit
        reload()
    }

    /// Every private folder a verified host announced (files and sockets denied), in the order first seen, those past
    /// the cap included; entries that now resolve to a broad folder are left out.
    public var folders: [String] { folders(adding: []) }

    /// Every socket folder a verified host announced (socket connects denied), in the order first seen, those past the
    /// cap included; entries that now resolve to a broad folder are left out.
    public var socketFolders: [String] { socketFolders(adding: []) }

    /// `folders` and then the entries of `live` it does not hold (the dock link's announcements of this process), each
    /// once, under the same rule: what the sandbox denies for one spawn.
    public func folders(adding live: [String]) -> [String] {
        lock.withLock { stillSpecific(Self.unique(knownFolders + runOnlyFolders + live)) }
    }

    /// `socketFolders` and then the entries of `live` it does not hold, each once, under the same rule.
    public func socketFolders(adding live: [String]) -> [String] {
        lock.withLock { stillSpecific(Self.unique(knownSocketFolders + runOnlySocketFolders + live)) }
    }

    private static func unique(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }
    }

    /// Under `lock`: the entries that still pass the rule now.
    private func stillSpecific(_ entries: [String]) -> [String] {
        entries.filter { entry in
            guard let refusal = Self.refusal(of: entry, home: home) else { return true }
            if reportedBroad.insert(entry).inserted {
                CommandLog.terminal("sandbox memory entry left out", ["reason": .label(refusal)])
            }
            return false
        }
    }

    /// Adds what a verified dock host announced in `hello.private`. Entries already known are skipped; nothing is ever
    /// removed. Writes the file when something new was added.
    public func remember(folders newFolders: [String], socketFolders newSocketFolders: [String]) {
        lock.withLock {
            let addedFolders = merge(newFolders, into: &knownFolders, pastCap: &runOnlyFolders)
            let addedSockets = merge(newSocketFolders, into: &knownSocketFolders, pastCap: &runOnlySocketFolders)
            guard addedFolders + addedSockets > 0 else { return }
            writeLocked()
            CommandLog.terminal("sandbox memory added", ["folders": .number(addedFolders), "socketFolders": .number(addedSockets)])
        }
    }

    /// Reads the file again and adds what it holds to what the process knows. A missing, broken or untrusted file
    /// changes nothing the process knows (a label is logged).
    public func reload() {
        lock.withLock {
            switch readFile() {
            case .success(let stored):
                _ = merge(stored.folders, into: &knownFolders, pastCap: &runOnlyFolders)
                _ = merge(stored.socketFolders, into: &knownSocketFolders, pastCap: &runOnlySocketFolders)
            case .failure(let problem):
                guard problem != .missing || !knownFolders.isEmpty || !knownSocketFolders.isEmpty else { return }
                CommandLog.terminal("sandbox memory not read", ["reason": .label(problem),
                                                                 "kept": .number(knownFolders.count + knownSocketFolders.count)])
            }
        }
    }

    // MARK: The file

    struct Stored: Codable, Equatable {
        var version = 1
        var folders: [String] = []
        var socketFolders: [String] = []
    }

    enum Problem: String, Error, CommandLogLabel {
        case missing, untrusted, unreadable, broken
        var logLabel: String { rawValue }
    }

    private func readFile() -> Result<Stored, Problem> {
        let (data, trust) = SecureFile.read(file, uid: uid)
        switch trust {
        case .missing: return .failure(.missing)
        case .untrusted: return .failure(.untrusted)
        case .trusted: break
        }
        guard let data else { return .failure(.unreadable) }
        guard data.count <= Self.maxFileBytes, let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == 1 else { return .failure(.broken) }
        return .success(stored)
    }

    /// Writes everything known. A file that is there but not usable is moved aside first, so nothing in it is lost.
    private func writeLocked() {
        if case .failure(let problem) = readFile(), problem != .missing {
            let aside = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".broken")
            unlink(aside.path)
            rename(file.path, aside.path)
            CommandLog.terminal("sandbox memory moved aside", ["reason": .label(problem)])
        }
        let stored = Stored(folders: knownFolders, socketFolders: knownSocketFolders)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored),
              SecureFile.write(data, to: file) else {
            CommandLog.terminal("sandbox memory not written")
            return
        }
    }

    /// Under `lock`: adds the valid entries of `entries` that `known` does not hold yet, up to `limit` in all, and keeps
    /// the valid ones beyond the cap in `pastCap` (denied for the process's life, never written); returns how many were
    /// added to `known`. Refused entries and entries beyond the cap are logged (labels only).
    private func merge(_ entries: [String], into known: inout [String], pastCap: inout [String]) -> Int {
        var added = 0
        var overCap = 0
        for entry in entries where !known.contains(entry) {
            if let refusal = Self.refusal(of: entry, home: home) {
                CommandLog.terminal("sandbox memory entry refused", ["reason": .label(refusal)])
                continue
            }
            guard known.count < limit else {
                if !pastCap.contains(entry) {
                    pastCap.append(entry)
                    overCap += 1
                }
                continue
            }
            known.append(entry)
            pastCap.removeAll { $0 == entry }
            added += 1
        }
        if overCap > 0 {
            CommandLog.terminal("sandbox memory full", ["max": .number(limit), "runOnly": .number(overCap)])
        }
        return added
    }

    /// Why an announced entry cannot be remembered: it must be absolute (no `~`), without control characters, `"` or
    /// `\`, resolvable (no `..` after the part that exists), and specific (`tooBroad` otherwise): its canonical form at
    /// least 3 components below `home` or at least 1 below `/private/tmp`, and never `/`, `home` or one of its
    /// ancestors, a system top folder, `~/Library` or `~/Library/Application Support`.
    static func refusal(of entry: String, home: String) -> CommandSandbox.Refusal? {
        guard !entry.isEmpty else { return .empty }
        for scalar in entry.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f { return .controlCharacter }
            if scalar == "\"" || scalar == "\\" { return .quote }
        }
        guard entry.hasPrefix("/") else { return .notAbsolute }
        let canonical: String
        switch CommandSandbox.canonicalEntry(entry, home: home) {
        case .success(let path): canonical = path
        case .failure(let refusal): return refusal
        }
        return isSpecific(canonical, home: CommandSandbox.canonicalPath(home) ?? home) ? nil : .tooBroad
    }

    /// Folders never remembered (each also in its canonical spelling).
    static let systemFolders = ["/", "/Users", "/System", "/Library", "/Applications", "/private", "/var", "/tmp",
                                "/private/tmp", "/private/var", "/Volumes", "/opt", "/usr", "/bin", "/sbin", "/etc",
                                "/private/etc", "/dev", "/cores", "/Network", "/System/Volumes", "/System/Volumes/Data"]

    /// Whether the canonical `path` is a specific app-private folder (the rule of docs/DOCK_PROTOCOL.md §5.3).
    static func isSpecific(_ path: String, home: String) -> Bool {
        var broad = Set(systemFolders)
        for folder in systemFolders + [home + "/Library", home + "/Library/Application Support"] {
            broad.insert(folder)
            if let canonical = CommandSandbox.canonicalPath(folder) { broad.insert(canonical) }
        }
        if broad.contains(path) || CommandSandbox.isInside(home, folder: path) { return false }
        func depth(below folder: String) -> Int {
            path.split(separator: "/").count - folder.split(separator: "/").count
        }
        if CommandSandbox.isInside(path, folder: home), depth(below: home) >= 3 { return true }
        return CommandSandbox.isInside(path, folder: "/private/tmp") && depth(below: "/private/tmp") >= 1
    }
}
