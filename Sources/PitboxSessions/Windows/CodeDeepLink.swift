import Foundation

/// The two links Code monitors build from a session id. The id must match
/// `^local_[A-Za-z0-9-]{1,64}$` before anything is built or sent; nothing else from a session ever goes into a link.
public enum CodeDeepLink {
    /// `local_` plus 1 to 64 ASCII letters, digits or `-`.
    public static func isValidSessionID(_ id: String) -> Bool {
        let prefix = "local_"
        guard id.hasPrefix(prefix) else { return false }
        let rest = id.utf8.dropFirst(prefix.utf8.count)
        guard (1...64).contains(rest.count) else { return false }
        return rest.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
        }
    }

    /// `claude://code/continue?session=local_<id>`: opens the session in that copy's **main** window (no route opens a
    /// pop-out). Nil when the id fails the check.
    public static func continueURL(sessionID: String) -> URL? {
        guard isValidSessionID(sessionID) else { return nil }
        return URL(string: "claude://code/continue?session=\(sessionID)")
    }

    /// `claude://claude.ai/epitaxy/local_<id>`: the link Claude itself hands out (the peek's Copy link). Nil when
    /// the id fails the check.
    public static func shareLink(sessionID: String) -> String? {
        guard isValidSessionID(sessionID) else { return nil }
        return "claude://claude.ai/epitaxy/\(sessionID)"
    }
}
