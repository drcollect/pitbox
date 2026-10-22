import Foundation

/// Whether the command sheet may run a command (the settings key `commands`). The key is file-only: no window, link
/// or message changes it.
public enum CommandRunPolicy: String, CaseIterable, Sendable {
    /// Copy and Type into console only: the sheet shows no Run button and starts no Run tab; it says in one line that
    /// Run is off and how to turn it on. Fetch file stays (Pitbox's own fixed scp argument list, never the reply's text).
    /// New installs start here, and a settings file without the key (or with any other value) means this.
    case copyOnly
    /// Run after the sheet's review and the user's click, as the sheet has always allowed.
    case run

    /// The policy of a settings file's `commands` value: `run` only for exactly "run", else `copyOnly`.
    public init(settingsValue: String?) {
        self = settingsValue == CommandRunPolicy.run.rawValue ? .run : .copyOnly
    }
}
