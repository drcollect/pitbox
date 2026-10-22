import Darwin
import Foundation
import PitboxKit

/// The file lookups the sheet makes for its own reading of a command (docs/SHELL_LANGUAGE.md §8, rulings A5 and A6).
/// `lstat` and `readlink` only: nothing is read, nothing is followed, nothing runs. Off the main thread, bounded in
/// time; whatever is not known in time counts as an existing file (fail toward the tick).
///
/// The paths come from a reply, so no lookup may reach the network (docs/THREAT_MODEL.md, T33): each path is walked one
/// part at a time (`LocalPathWalk`) under `NetworkPathGuard` (`/net`, `/home`, `/Volumes`, `/Network`, automount
/// points, the mount table's network and automounted filesystems), links on the way included. A path the guard refuses
/// is never looked up and counts as an existing file, so a write to it keeps its red-line tick.
enum CommandFiles {
    static let maxPaths = 64
    static let timeout: TimeInterval = 0.3

    /// What is at each absolute path, for `CommandContext.pathFacts`. `fs` and `pathGuard` are for tests (nil: this
    /// Mac's mount table, read on the lookup's own queue).
    static func lookUp(_ paths: [String], fs: LocalPathFileSystem = LiveLocalPathFileSystem(),
                       guard pathGuard: NetworkPathGuard? = nil) async -> [String: CommandPathFact] {
        let wanted = Array(Set(paths.filter { $0.hasPrefix("/") && !$0.contains("\0") })).sorted().prefix(maxPaths)
        guard !wanted.isEmpty else { return [:] }
        let fallback = Dictionary(uniqueKeysWithValues: wanted.map { ($0, CommandPathFact.file) })
        return await bounded(fallback: fallback) {
            let checked = pathGuard ?? .current()
            return Dictionary(uniqueKeysWithValues: wanted.map { ($0, fact(for: $0, guard: checked, fs: fs)) })
        }
    }

    /// `lstat` of one path (its folders resolved part by part, checked): a link with what it points to, a folder, a file,
    /// or nothing there. A failed lookup is a file; so is a path the guard refuses (never looked up).
    static func fact(for path: String, guard pathGuard: NetworkPathGuard, fs: LocalPathFileSystem) -> CommandPathFact {
        switch LocalPathWalk.resolve(path, followLastLink: false, guard: pathGuard, fs: fs) {
        case .missing:
            return .missing
        case .network, .link, .failed:
            return .file
        case .found(let real, let info):
            switch info.kind {
            case .link:
                guard let target = fs.readlink(real) else { return .link(target: "?") }
                return .link(target: String(decoding: Array(target.utf8).prefix(1_024), as: UTF8.self))
            case .directory:
                return .directory
            case .regular, .other:
                return .file
            }
        }
    }

    /// The programs among `programs` that macOS will not start inside the command sandbox: setuid or setgid files
    /// found on `path` (measured: `ps`, `sudo`, `top`, `crontab`, `at`, `su`, `login`, `traceroute`).
    static func setuidPrograms(_ programs: [String], path: String) async -> [String] {
        let names = Array(Set(programs.filter { !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") })).sorted()
        guard !names.isEmpty else { return [] }
        let folders = path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return await bounded(fallback: []) {
            names.filter { name in
                for folder in folders {
                    var info = stat()
                    guard stat(folder + "/" + name, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                    return info.st_mode & (S_ISUID | S_ISGID) != 0
                }
                return false
            }
        }
    }

    /// Runs `work` on a background queue and returns its result, or `fallback` after `timeout` (the work is then left
    /// to finish on its own; nobody waits for it).
    private static func bounded<T: Sendable>(fallback: T, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let once = CommandOnce()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                if once.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: fallback) }
            }
        }
    }
}

/// A flag that can be claimed once, from any thread.
final class CommandOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

/// The click-time freshness check, bounded by `CommandOfferFreshness.checkTimeout`: slower counts as `unknown`, and the
/// session side's task is never waited for after that.
enum CommandFreshnessCheck {
    /// An offer's check (`freshness(of:)`).
    static func check(_ checker: CommandOfferFreshnessChecking, offer: CommandOffer.ID,
                      timeout: TimeInterval = CommandOfferFreshness.checkTimeout) async -> CommandOfferFreshness {
        await bounded(timeout) { await checker.freshness(of: offer) }
    }

    /// A result fetch's check: the tool_use is still in the session's tail and still names `path`.
    static func check(_ checker: CommandOfferFreshnessChecking, resultFetch sessionIndex: Int, toolUseID: String, path: String,
                      timeout: TimeInterval = CommandOfferFreshness.checkTimeout) async -> CommandOfferFreshness {
        await bounded(timeout) { await checker.freshness(ofResultFetch: sessionIndex, toolUseID: toolUseID, path: path) }
    }

    /// `ask`'s answer, or `unknown` once `timeout` has passed (whichever comes first).
    private static func bounded(_ timeout: TimeInterval,
                                _ ask: @escaping @Sendable () async -> CommandOfferFreshness) async -> CommandOfferFreshness {
        await withCheckedContinuation { continuation in
            let once = CommandOnce()
            Task.detached {
                let answer = await ask()
                if once.claim() { continuation.resume(returning: answer) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.claim() { continuation.resume(returning: .unknown) }
            }
        }
    }
}

/// The sheet's own copy of what one approval covers: the text, the shell and its options,
/// the PATH, the environment names and the folder by descriptor, taken when the sheet opened. The run uses this copy,
/// never a fresh read, and consumes it once: one approval, one run.
@MainActor
final class FrozenCommand {
    let offerID: CommandOffer.ID
    let text: String
    let shell: CommandExecutionDescriptor.Shell
    let path: String
    let environmentNames: [String]
    /// What Type types: the text, or for the login shell the text without full-line comments; nil when Type must not
    /// type it there (a comment after a command, which an interactive-comments-off zsh would run as words).
    let typedText: String?
    private(set) var folder: FolderBinding?
    private(set) var consumed = false

    init(offerID: CommandOffer.ID, text: String, shell: CommandExecutionDescriptor.Shell, path: String,
         environmentNames: [String], folder: FolderBinding?) {
        self.offerID = offerID
        self.text = text
        self.shell = shell
        self.path = path
        self.environmentNames = environmentNames
        self.folder = folder
        typedText = shell == .clean ? text : Self.loginTypedText(text)
    }

    /// The descriptor for one Run or Type, with the folder; nil once consumed, without a folder, or for a Type this
    /// shell must not type.
    /// `machine` is what the sheet showed at the click (the reader's machine, or the user's pick when it was Unclear), so
    /// the launch spec's `.thisMac` guard can refuse a mismatch.
    func consume(kind: CommandExecutionDescriptor.Kind, machine: CommandMachine)
        -> (descriptor: CommandExecutionDescriptor, folder: FolderBinding)? {
        guard !consumed, let folder else { return nil }
        let sent: String
        if kind == .typeIntoTerminal {
            guard let typedText else { return nil }
            sent = typedText
        } else {
            sent = text
        }
        consumed = true
        self.folder = nil
        let descriptor = CommandExecutionDescriptor(
            offerID: offerID, kind: kind, text: sent, shell: shell,
            shellPath: CommandLaunchSpec.shellPath, shellArguments: CommandEnvironmentRules.arguments(kind: kind, shell: shell),
            path: path, environmentNames: environmentNames, folderPath: folder.path, folderDevice: folder.device,
            folderInode: folder.inode, machine: machine)
        return (descriptor, folder)
    }

    /// Closes the folder when the sheet goes without a run.
    func discard() {
        folder?.close()
        folder = nil
    }

    /// `commandShell: login`, Type: the user's zsh has interactive comments off, so the full-line comments are left out
    /// (whole lines, as the scanner reads them). Type is refused (nil) for a comment after a command (that zsh would
    /// type it as words), for a comment line that a `\` at the end of the line before joins onto that line (leaving
    /// it out would join the lines around it), and for a text the scanner cannot read. A `#` line inside quotes or a
    /// here-doc body is not a comment and stays exactly as it is.
    static func loginTypedText(_ text: String) -> String? {
        let scan = ShellCommandScanner.scan(text)
        guard scan.isReadable else { return nil }
        guard !scan.comments.isEmpty else { return text }
        let units = Array(text.utf16)
        var lineStarts = [0]
        for (index, unit) in units.enumerated() where unit == 0x0A { lineStarts.append(index + 1) }
        var leftOut = Set<Int>()
        for comment in scan.comments {
            guard let line = lineStarts.lastIndex(where: { $0 <= comment.lowerBound }) else { return nil }
            let start = lineStarts[line]
            guard comment.lowerBound <= units.count,
                  units[start..<comment.lowerBound].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return nil }
            if line > 0 {
                var backslashes = 0
                var index = start - 2
                while index >= lineStarts[line - 1], units[index] == 0x5C {
                    backslashes += 1
                    index -= 1
                }
                if backslashes % 2 == 1 { return nil }
            }
            leftOut.insert(line)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .filter { !leftOut.contains($0.offset) }.map(\.element).joined(separator: "\n")
    }
}
