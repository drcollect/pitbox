import Darwin
import Foundation
import PitboxKit

/// Why the guest does not dock with a peer (shown in the menu's dock line; protocol words, numbers and a bundle id).
public enum DockRefusal: Error, Equatable, Sendable {
    /// No common protocol major: the majors this build speaks, the majors the host speaks.
    case version(ours: ClosedRange<Int>, theirs: ClosedRange<Int>)
    /// The connecting app's bundle id is not in the settings file's `dock.hosts` (nil: it has none).
    case notListed(bundleID: String?)
    /// The connecting process is not an app: its executable is not in `<name>.app/Contents/MacOS/` of a bundle owned by
    /// you or root.
    case notAnApp
    /// A process of another user (impossible through the private folder; checked anyway).
    case otherUser

    /// The menu's dock line for this refusal. `hostName` is the host's cleaned name, when known.
    public func menuLine(hostName: String? = nil) -> String {
        let host = hostName ?? "the host app"
        switch self {
        case let .version(ours, theirs):
            return "Can't dock with \(host): \(AppIdentity.displayName) speaks protocol \(Self.words(ours)), "
                + "\(host) speaks \(Self.words(theirs))"
        case .notListed(let bundleID):
            let who = bundleID.map { "An app (\($0))" } ?? "An app"
            return "\(who) asked to dock but is not in dock.hosts in the settings file"
        case .notAnApp:
            return "Refused a dock connection: not an app of yours"
        case .otherUser:
            return "Refused a dock connection from another user"
        }
    }

    static func words(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
    }
}

/// What the guest knows about the process at the other end of an accepted connection.
struct DockPeerFacts: Equatable, Sendable {
    /// `getpeereid`.
    var uid: uid_t?
    /// `LOCAL_PEERPID`.
    var pid: pid_t?
    /// The process's start time (microseconds since the epoch), so a recycled pid is never taken for it.
    var started: UInt64?
    /// The app bundle its executable sits in, when it sits in one.
    var bundle: DockPeerBundle?
}

/// The app bundle of a peer's executable.
struct DockPeerBundle: Equatable, Sendable {
    /// `CFBundleIdentifier` of the bundle's `Info.plist` (nil when missing or unreadable).
    var bundleID: String?
    /// The owner of the `.app` folder.
    var bundleOwner: uid_t
    /// The owner of the executable file.
    var executableOwner: uid_t
}

/// A peer the guest accepted as its host.
struct VerifiedHost: Equatable, Sendable {
    var pid: pid_t
    /// The process's start time (microseconds since the epoch): a recycled pid is never taken for it.
    var started: UInt64
    var bundleID: String
}

/// Reads the facts about the peer of a connected socket. Injectable: a test cannot be another user or an app bundle.
protocol DockPeerInspecting: Sendable {
    func inspect(_ fd: Int32) -> DockPeerFacts
}

/// The real inspector: `getpeereid`, `LOCAL_PEERPID`, `proc_pidpath` and the bundle on disk.
struct SystemPeerInspector: DockPeerInspecting {
    func inspect(_ fd: Int32) -> DockPeerFacts {
        var facts = DockPeerFacts()
        facts.uid = POSIX.peerUID(of: fd)
        guard let pid = ProcessAncestry.peerPID(of: fd) else { return facts }
        facts.pid = pid
        facts.started = ProcessAncestry.identity(of: pid)?.started
        if let path = Self.executablePath(of: pid) { facts.bundle = Self.bundle(forExecutable: path) }
        return facts
    }

    /// The executable of a running process (`proc_pidpath`).
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The app bundle an executable belongs to: the executable must be `<name>.app/Contents/MacOS/<file>`, a regular
    /// file in a real folder (no symlinks for either). Nil otherwise.
    static func bundle(forExecutable path: String) -> DockPeerBundle? {
        let parts = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let count = parts.count
        guard count >= 4, parts[count - 2] == "MacOS", parts[count - 3] == "Contents",
              parts[count - 4].lowercased().hasSuffix(".app"), parts[count - 4].count > 4 else { return nil }
        let bundlePath = "/" + parts[0...(count - 4)].joined(separator: "/")
        let executable = "/" + parts.joined(separator: "/")
        var bundleInfo = stat()
        var executableInfo = stat()
        guard lstat(bundlePath, &bundleInfo) == 0, POSIX.fileType(bundleInfo.st_mode) == mode_t(S_IFDIR),
              lstat(executable, &executableInfo) == 0, POSIX.fileType(executableInfo.st_mode) == mode_t(S_IFREG) else {
            return nil
        }
        return DockPeerBundle(bundleID: bundleIdentifier(ofBundleAt: bundlePath), bundleOwner: bundleInfo.st_uid,
                              executableOwner: executableInfo.st_uid)
    }

    /// `CFBundleIdentifier` from `<bundle>/Contents/Info.plist` (a regular file of at most 1 MiB), when it is a valid
    /// bundle id.
    static func bundleIdentifier(ofBundleAt bundlePath: String) -> String? {
        let plist = bundlePath + "/Contents/Info.plist"
        var info = stat()
        guard lstat(plist, &info) == 0, POSIX.fileType(info.st_mode) == mode_t(S_IFREG), info.st_size <= 1 << 20,
              let data = FileManager.default.contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = object["CFBundleIdentifier"] as? String, DockPeerCheck.isBundleID(identifier) else {
            return nil
        }
        return identifier
    }
}

/// The guest's verdict on a peer (docs/DOCK_PROTOCOL.md "Who may connect"): same user, a pid with a readable start time,
/// an executable inside an app bundle owned by you or root (bundle folder and executable), and that bundle's id in
/// `dock.hosts`.
enum DockPeerCheck {
    static func verdict(_ facts: DockPeerFacts, allowedHosts: [String], ownUID: uid_t) -> Result<VerifiedHost, DockRefusal> {
        guard let uid = facts.uid, uid == ownUID else { return .failure(.otherUser) }
        // A process whose start time cannot be read cannot be bound to its pid: refused.
        guard let pid = facts.pid, pid > 0, let started = facts.started, let bundle = facts.bundle,
              [ownUID, 0].contains(bundle.bundleOwner), [ownUID, 0].contains(bundle.executableOwner) else {
            return .failure(.notAnApp)
        }
        guard let bundleID = bundle.bundleID, allowedHosts.contains(bundleID) else {
            return .failure(.notListed(bundleID: bundle.bundleID))
        }
        return .success(VerifiedHost(pid: pid, started: started, bundleID: bundleID))
    }

    /// A reverse-DNS bundle id: 3 to 255 characters of letters, digits, `-` and `.`, with a dot, no empty part.
    static func isBundleID(_ text: String) -> Bool {
        guard (3...255).contains(text.utf8.count), text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."),
              !text.contains("..") else { return false }
        return text.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2D || byte == 0x2E
        }
    }
}
