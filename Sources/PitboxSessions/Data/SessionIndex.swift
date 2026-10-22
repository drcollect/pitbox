import Darwin
import Foundation

/// Where the session files of one copy are: `<profile>/claude-code-sessions/<account>/<org>/local_<id>.json`.
/// Built by listing those folders (names checked, links never followed); the path of a session file is then made only
/// from checked parts.
struct SessionIndex: Equatable, Sendable {
    struct Location: Equatable, Sendable {
        var account: String
        var org: String
    }

    static let folderName = "claude-code-sessions"
    static let maxFolders = 64
    static let maxFiles = 10_000

    private(set) var locations: [String: Location] = [:]
    /// Why the sessions folder could not be listed (missing for a copy that never used Claude Code).
    private(set) var failure: CarefulReadFailure?
    /// Session ids found more than once (another account or org): the newest file wins.
    private(set) var duplicates = 0
    /// An account or org folder could not be listed, or a listing reached its limit: some sessions may be missing, so
    /// nothing is taken as gone from this index (`code-memory.json` is pruned by it).
    private(set) var incomplete = false

    init() {}

    /// The session file of `id`, or nil when the index does not know it.
    func path(of id: String, profileFolder: CarefulPath) -> CarefulPath? {
        guard let location = locations[id] else { return nil }
        return CarefulPath(root: profileFolder.root,
                           components: profileFolder.components + [Self.folderName, location.account, location.org, "\(id).json"])
    }

    /// Records a session file seen in a file event (its path parts checked by the caller).
    mutating func note(id: String, account: String, org: String) {
        guard CodeIDs.isSessionID(id), Self.isFolderName(account), Self.isFolderName(org) else { return }
        locations[id] = Location(account: account, org: org)
    }

    static func build(profileFolder: CarefulPath, owner: uid_t) -> SessionIndex {
        var index = SessionIndex()
        guard let sessions = profileFolder.appending(folderName) else { return index }
        let accounts: [DirectoryEntry]
        switch CarefulFiles.list(sessions, owner: owner, limit: maxFolders) {
        case .failure(let failure):
            index.failure = failure
            return index
        case .success(let entries):
            accounts = entries
        }
        var modified: [String: TimeInterval] = [:]
        if accounts.count >= maxFolders { index.incomplete = true }
        for account in accounts where account.kind == .directory && isFolderName(account.name) {
            guard let accountPath = sessions.appending(account.name),
                  case .success(let orgs) = CarefulFiles.list(accountPath, owner: owner, limit: maxFolders) else {
                index.incomplete = true
                continue
            }
            if orgs.count >= maxFolders { index.incomplete = true }
            for org in orgs where org.kind == .directory && isFolderName(org.name) {
                guard let orgPath = accountPath.appending(org.name),
                      case .success(let files) = CarefulFiles.list(orgPath, owner: owner, limit: maxFiles) else {
                    index.incomplete = true
                    continue
                }
                if files.count >= maxFiles { index.incomplete = true }
                for file in files where file.kind == .file && file.name.hasSuffix(".json") {
                    let id = String(file.name.dropLast(5))
                    guard CodeIDs.isSessionID(id) else { continue }
                    let location = Location(account: account.name, org: org.name)
                    guard index.locations[id] != nil else {
                        index.locations[id] = location
                        continue
                    }
                    // The same id twice: keep the newer file.
                    index.duplicates += 1
                    let previous = index.locations[id]
                    func time(_ location: Location?) -> TimeInterval {
                        guard let location, let path = sessions.appending(location.account)?.appending(location.org)?.appending(file.name),
                              case .success(let identity) = CarefulFiles.identity(path, owner: owner) else { return 0 }
                        return identity.modified
                    }
                    let previousTime = modified[id] ?? time(previous)
                    let newTime = time(location)
                    if newTime > previousTime {
                        index.locations[id] = location
                        modified[id] = newTime
                    } else {
                        modified[id] = previousTime
                    }
                }
            }
        }
        return index
    }

    /// An account or org folder name: letters, digits, `-`, `_` and `.`, not starting with `.`, at most 128.
    static func isFolderName(_ name: String) -> Bool {
        guard (1...128).contains(name.utf8.count), !name.hasPrefix(".") else { return false }
        return name.utf8.allSatisfy { CodeIDs.isAlphanumeric($0) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E }
    }
}
