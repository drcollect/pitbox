import Foundation

/// Which Claude copies the block shows while more than one copy runs: every copy (`all`), or the copies whose profile
/// letters a focus lists. With one copy running every focus shows every session (a profile no longer says which kind of
/// work a session is for). A dock host switches it by a focus name (`focus` message, docs/DOCK_PROTOCOL.md); the
/// settings file's `focusProfiles` maps the name to letters (`named(_:in:)`).
public struct MonitorFocus: Equatable, Sendable, CustomStringConvertible {
    /// The focus's name, as a person sees it in "Nothing for <name>" ("All" for every copy).
    public let name: String
    /// The profile letters shown; nil shows every copy.
    public let letters: Set<String>?

    /// Every copy.
    public static let all = MonitorFocus(name: "All", letters: nil)

    /// A focus showing only the copies with `letters` (profile letters such as "A" or "B").
    public init(name: String, letters: Set<String>) {
        self.init(name: name, letters: Optional(letters))
    }

    private init(name: String, letters: Set<String>?) {
        self.name = name
        self.letters = letters
    }

    /// Whether every copy shows.
    public var isAll: Bool { letters == nil }

    public var description: String { isAll ? "all" : "letters=\(letters?.sorted().joined() ?? "")" }

    /// The focus a dock host names: `all` (any case) or an unknown name shows every copy; a name listed in
    /// `focusProfiles` shows its letters.
    public static func named(_ name: String, in settings: CodeSettings) -> MonitorFocus {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.lowercased() != "all", let letters = settings.focusProfiles[key] else { return .all }
        return MonitorFocus(name: key, letters: Set(letters))
    }

    /// Whether `session` shows under this focus; `severalCopies` false shows everything.
    func passes(_ session: CodeSessionSnapshot, severalCopies: Bool) -> Bool {
        guard severalCopies, let letters else { return true }
        return letters.contains(session.profile.letter)
    }
}
