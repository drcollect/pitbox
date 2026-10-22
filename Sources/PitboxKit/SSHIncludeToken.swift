/// The `Include` arguments of an SSH configuration that only ssh can turn into a file name.
public enum SSHIncludeToken {
    /// ssh expands `%` tokens (`%l`, `%h`, …), environment variables (`${HOME}`) and `~user` in an `Include`
    /// (`man ssh_config`); Pitbox does not, so it cannot know which file ssh would read there. Every reader treats
    /// such an argument as a file it could not read (a problem: no `ssh -G`, no alias counts), as Fetch file does.
    /// `~` and `~/…` (your own home folder) are expanded by the readers themselves.
    public static func needsSSH(_ token: String) -> Bool {
        token.isEmpty || token.contains("%") || token.contains("$")
            || (token.hasPrefix("~") && token != "~" && !token.hasPrefix("~/"))
    }
}
