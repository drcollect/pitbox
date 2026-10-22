import Foundation
import PitboxKit

/// The private folders and socket folders the dock link's verified hosts announced in this process: each host's whole
/// announcement, uncapped by the guest (the wire keeps at most 16 per kind per `hello`). The command sandbox denies them
/// together with `SandboxMemory`'s, so a connected host's folders are denied even when every cap is reached
/// (docs/THREAT_MODEL.md). Bounded at `limit` entries per kind, the newest kept: an entry announced again moves to the
/// newest place, so the current host's announcement is always held; older ones beyond the bound are dropped and logged
/// (the memory still holds what it remembered). Thread-safe: the dock link adds on the main thread, a spawn reads from
/// the console's queue.
final class AnnouncedFolders: @unchecked Sendable {
    /// The two lists, oldest first.
    struct Lists: Equatable, Sendable {
        var folders: [String] = []
        var socketFolders: [String] = []
    }

    /// At most this many entries per kind.
    static let defaultLimit = 256
    let limit: Int
    private let lock = NSLock()
    private var stored = Lists()

    init(limit: Int = AnnouncedFolders.defaultLimit) { self.limit = max(16, limit) }

    /// Everything held now.
    var lists: Lists { lock.withLock { stored } }

    /// Adds a verified host's announcement: each entry goes to the newest place (moved there when already held), and
    /// the oldest beyond `limit` go.
    func add(folders: [String], socketFolders: [String]) {
        let dropped = lock.withLock {
            Self.add(folders, to: &stored.folders, limit: limit) + Self.add(socketFolders, to: &stored.socketFolders, limit: limit)
        }
        if dropped > 0 { Log.warn("dock: announced folders over the bound max=\(limit) dropped=\(dropped)", "dock") }
    }

    private static func add(_ entries: [String], to list: inout [String], limit: Int) -> Int {
        for entry in entries {
            list.removeAll { $0 == entry }
            list.append(entry)
        }
        let over = max(0, list.count - limit)
        list.removeFirst(over)
        return over
    }
}
