import Foundation

// The classifier's pattern tables (red lines, notes, block reasons and the machine rules) as data, so the block's
// chips and the sheet use the same words and the classifier the same lists. Pitbox's own words: none of them ever
// says "safe". docs/SHELL_LANGUAGE.md is the reading these tables follow.

/// The words and lists the command classifier uses. Pure data.
public enum CommandPatterns {
    // MARK: Words

    /// A short name for each rule, for chips and lists ("blocked: hidden characters").
    public static let ruleTitles: [CommandRule: String] = [
        .r1: "administrator rights", .r2: "deletes for good", .r3: "downloaded code run at once",
        .r4: "permissions and Gatekeeper", .r5: "startup and settings files", .r6: "rewrites git history",
        .r7: "Keychain and credentials", .r8: "background services", .r9: "system settings",
        .r10: "SSH keys and host trust", .r11: "hidden or built command", .r12: "uploads or sends",
        .r13: "stops things", .r14: "disks", .r15: "a secret in the text", .r16: "installs software",
        .r17: "an unusual host", .r18: "runs code not shown", .r19: "controls other apps", .r20: "not your request",
        .r21: "replaces a file", .r22: "the session replied again",
        .b1: "hidden characters", .b2: "look-alike characters", .b3: "can't read", .b4: "too long",
        .b5: "decodes and runs hidden text", .b6: "known destroyer",
    ]

    /// The sheet's words for each red line, `<…>` filled in by the classifier. Several rules have more than one
    /// form; this is the main one.
    public static let ruleWords: [CommandRule: String] = [
        .r1: "Runs with administrator rights (<program>)",
        .r2: "Deletes files and folders; not to the Trash: <targets>",
        .r3: "Runs code it downloads from <host> without showing it",
        .r4: "Changes permissions of <path>",
        .r5: "Changes a startup or settings file: <path>",
        .r6: "Rewrites or deletes history on <remote>",
        .r7: "Shows a secret on screen; it stays in the tab until you close it",
        .r8: "Starts or changes a background service",
        .r9: "Changes a macOS setting",
        .r10: "Replaces an SSH key",
        .r11: "Builds the command at run time; what runs is not what you see",
        .r12: "Uploads <file or folder> to <host>",
        .r13: "Stops <process or app>",
        .r14: "Works on disks or volumes",
        .r15: "Contains what looks like a secret. Your rule: secrets go into the Keychain with hidden input.",
        .r16: "Installs software that runs with your rights",
        .r17: "Connects to an unusual host: <host>",
        .r18: "Runs code from <folder or package> that is not shown here",
        .r19: "Controls other apps (AppleScript or Shortcuts)",
        .r20: "No message from you started this turn: <who> did",
        .r21: "Replaces <file>",
        .r22: "The session has replied since this command (latest reply <time>). Read its newest reply first.",
        .b1: "Hidden or deceptive character <code point> <name>",
        .b2: "Look-alike character <character> (<code point>) in <where>",
        .b3: "\(AppIdentity.displayName) can't read this shell syntax (<what>); use Copy",
        .b4: "Too long to review here: <limit>",
        .b5: "Decodes hidden text and runs it as a command",
        .b6: "Known destroyer: <what>",
    ]

    /// The sheet's fixed second forms.
    public enum Words {
        public static let deletesKeychainItem = "Deletes a Keychain item"
        public static let showsSecret = "Shows a secret on screen; it stays in the tab until you close it"
        public static let keepsRunningAfterTab = "Keeps running after the tab closes"
        public static let backgroundService = "Starts or changes a background service"
        public static let turnsOffHostKeys = "Turns off host-key checking"
        public static let replacesSSHKey = "Replaces an SSH key"
        public static let removesQuarantine = "Removes the download check (quarantine)"
        public static let notFlagged = "No known risky pattern. \(AppIdentity.displayName) cannot tell what a program does: this runs with your rights."
        public static let copyCleaned = "Copy cleaned"
        public static let notYourRequestTask = "No message from you started this turn: a background task did"
        public static let notYourRequestPeer = "No message from you started this turn: another session did"
    }

    /// The class chips of the peek list.
    public static let classWords: [CommandAssessment.Class: String] = [
        .notFlagged: "Not flagged", .risky: "Risky", .needsEditing: "Needs editing", .otherMachine: "Other machine",
        .forServer: "For the server", .unclearMachine: "Unclear", .fetchFile: "Fetch file", .partlyRead: "Partly read",
        .blocked: "Blocked",
    ]

    /// Fixed note texts; the others are built with their target.
    public enum NoteWords {
        public static let readWeb = "This reply came after the session read web pages"
        public static let untaggedBlock = "Untagged block, read as a command"
        public static let cleanShell = "Runs in the clean shell: your aliases and `~/.zshrc` are not used"
        public static let usesSSHAgent = "Uses your ssh-agent"
        public static let notQuarantined = "Not quarantined: files copied by scp, rsync or curl get no download check"
        public static let homebrew = "Installs software with Homebrew"
        public static let keepsRunning = "Keeps running until you stop it (Ctrl-C)"
        public static let asksValue = "Asks you for a value"
        public static let asksSecret = "Asks for a secret with hidden input"
        public static let laterLinesRun = "later lines run even if one fails"
    }

    // MARK: Programs

    /// Wrappers looked through to find the program (docs/SHELL_LANGUAGE.md §3.2), plus a few more that
    /// only start their command (`timeout`, `stdbuf`, `arch`, `chronic`, `unbuffer`).
    public static let wrappers: Set<String> = [
        "sudo", "doas", "env", "command", "builtin", "exec", "nohup", "time", "nice", "xargs", "caffeinate", "watch",
        "setsid", "timeout", "gtimeout", "stdbuf", "gstdbuf", "arch", "chronic", "unbuffer", "busybox",
    ]

    /// Programs that send a command to another machine.
    public static let remoteShells: Set<String> = ["ssh", "mosh", "autossh", "et"]
    /// Transfers whose `host:path` operands are remote text.
    public static let transfers: Set<String> = ["scp", "rsync", "sftp", "sshfs", "rclone"]
    /// Mac-only programs: they point to the Mac.
    public static let macOnlyPrograms: Set<String> = [
        "open", "pbcopy", "pbpaste", "security", "defaults", "launchctl", "osascript", "brew", "mdfind", "mdls", "say",
        "caffeinate", "sw_vers", "xcode-select", "xcrun", "diskutil", "hdiutil", "plutil", "codesign", "spctl", "xattr",
        "tccutil", "sips",
    ]
    /// Linux-only programs: they point to the server.
    public static let linuxOnlyPrograms: Set<String> = [
        "systemctl", "journalctl", "apt", "apt-get", "dpkg", "snap", "ufw", "useradd", "loginctl",
    ]
    /// Programs that use the ssh-agent: the note "Uses your ssh-agent".
    public static let sshAgentPrograms: Set<String> = [
        "ssh", "scp", "sftp", "rsync", "mosh", "sshfs", "rclone", "git", "autossh", "ssh-add", "ssh-copy-id",
    ]
    /// Programs that download (R3).
    public static let downloaders: Set<String> = ["curl", "wget", "fetch", "http", "https", "xh", "aria2c"]
    /// Shells that read a script (R3, R18, nested scripts).
    public static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "csh", "tcsh", "yash"]
    /// Interpreters (R3, R18); `python3.12` and the like match by their family.
    public static let interpreterFamilies: [String] = [
        "python", "pypy", "perl", "ruby", "node", "nodejs", "php", "osascript", "deno", "bun", "lua", "luajit",
        "rscript", "tclsh", "expect", "pwsh", "swift", "tsx", "ts-node",
    ]
    /// Network programs (the note "Connects to <host>").
    public static let networkPrograms: Set<String> = [
        "ssh", "scp", "sftp", "rsync", "mosh", "autossh", "et", "sshfs", "rclone", "curl", "wget", "fetch", "http",
        "https", "xh", "aria2c", "nc", "ncat", "netcat", "socat", "telnet", "ftp", "git", "gh", "aws", "gsutil",
        "gcloud", "ping", "traceroute", "dig", "nslookup", "host", "whois", "ssh-copy-id", "ssh-keyscan", "openssl",
    ]
    /// Programs that keep running (the note "Keeps running until you stop it").
    public static let longRunning: Set<String> = ["top", "htop", "btop", "yes", "watch", "fswatch", "entr", "tcpdump"]
    /// Disk programs (R14) matched in any form.
    public static let diskPrograms: Set<String> = ["diskutil", "dd", "fdisk", "gpt", "asr", "hdiutil", "bless"]
    /// Programs that stop things (R13).
    public static let stopPrograms: Set<String> = ["kill", "killall", "pkill", "shutdown", "reboot", "halt"]
    /// System-setting programs (R9) matched in any form.
    public static let settingsPrograms: Set<String> = [
        "networksetup", "nvram", "csrutil", "tccutil", "dscl", "sysadminctl", "fdesetup", "profiles", "kextload",
        "kextunload", "systemextensionsctl",
    ]
    /// Programs that control other apps (R19).
    public static let appControlPrograms: Set<String> = ["osascript", "automator", "cliclick"]
    /// Builtins and keywords an untagged block may start a line with.
    public static let shellBuiltins: Set<String> = [
        "cd", "export", "read", "if", "for", "while", "until", "case", "echo", "printf", "source", ".", "set", "unset",
        "test", "[", "[[", "((", "{", "(", "pwd", "pushd", "popd", "exit", "return", "true", "false", ":", "local",
        "typeset", "declare", "readonly", "eval", "exec", "command", "builtin", "type", "which", "whence", "where",
        "wait", "kill", "jobs", "fg", "bg", "umask", "ulimit", "shift", "getopts", "let", "print", "time", "!",
    ]

    // MARK: Paths

    /// The folders of the clean PATH and the other system program folders: a program given by a path elsewhere is
    /// R18 (docs/SHELL_LANGUAGE.md §3.3).
    public static let systemProgramFolders: [String] = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        "/usr/libexec", "/System", "/Library/Apple",
    ]
    /// R4: permission changes on these (or below them) are red lines.
    public static let protectedSystemFolders: [String] = [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private", "/var", "/opt", "/Applications",
    ]
    /// R5: files in the home folder.
    public static let startupFiles: [String] = [
        ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".profile", ".inputrc",
        ".gitconfig", ".claude.json", ".npmrc", ".netrc", ".pypirc",
    ]
    /// R5: folders in the home folder, everything inside them included.
    public static let settingsFolders: [String] = [
        ".ssh", ".config", ".claude", ".aws", ".docker", ".kube", "Library/LaunchAgents", "Library/Preferences",
        "Library/Application Support/Pitbox",
    ]
    /// R5: folders of `~/Library/Application Support` that start with this (Claude, Claude-Work, …).
    public static let settingsFolderPrefixes: [String] = ["Library/Application Support/Claude"]
    /// R5: system folders, everything inside them included (temporary folders excepted).
    public static let settingsSystemFolders: [String] = [
        "/Library", "/etc", "/usr", "/opt", "/private", "/System", "/Applications",
    ]
    /// Not R5 although inside a settings system folder: temporary files.
    public static let temporaryFolders: [String] = ["/private/tmp", "/private/var/folders", "/private/var/tmp"]
    /// R10: SSH trust files.
    public static let sshTrustFiles: [String] = [".ssh/known_hosts", ".ssh/known_hosts2", ".ssh/authorized_keys",
                                                  ".ssh/authorized_keys2", ".ssh/config"]
    /// Local paths pointing to the Mac (`~` is the home folder) and to the server.
    public static let macPathHints: [String] = ["~/Downloads", "~/Desktop", "~/Documents", "~/Library", "/Users/",
                                                "/Applications", "/Volumes/", "/opt/homebrew"]
    /// Local paths that point to the server.
    public static let serverPathHints: [String] = ["/home/", "/root", "/srv/", "/etc/", "/var/", "/opt/"]
    /// Write targets that are devices, not files.
    public static let deviceTargets: [String] = ["/dev/null", "/dev/zero", "/dev/stdout", "/dev/stderr", "/dev/stdin",
                                                 "/dev/tty", "/dev/fd/"]
    /// B6: folders whose recursive deletion is a known destroyer (besides `/`, the home folder, `/Users`, `..` and a
    /// bare `*`): the top system folders and the home folder's own top folders.
    public static let destroyerSystemFolders: [String] = [
        "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/opt",
        "/Volumes", "/cores", "/private/var", "/private/etc",
    ]
    /// B6: the home folder's own top folders.
    public static let destroyerHomeFolders: [String] = ["Library", "Documents", "Desktop", "Downloads", "Pictures",
                                                        "Movies", "Music", "Applications", ".ssh", ".gnupg"]
    /// B6: disks taken as the internal one (docs/SHELL_LANGUAGE.md A11; on Apple silicon disk1-disk3 are its
    /// system containers).
    public static let internalDisks: [String] = ["disk0", "disk1", "disk2", "disk3"]

    // MARK: Hosts

    /// Well-known hosts whose near-misses are R17 too (registrable names), besides the session's own hosts.
    public static let wellKnownHosts: [String] = [
        "github.com", "githubusercontent.com", "gitlab.com", "bitbucket.org", "npmjs.com", "npmjs.org", "pypi.org",
        "pythonhosted.org", "brew.sh", "apple.com", "icloud.com", "anthropic.com", "claude.ai", "google.com",
        "googleapis.com", "amazonaws.com", "cloudflare.com", "docker.com", "docker.io", "slack.com",
        "microsoft.com",
    ]

    // MARK: The reply's claims

    /// Phrases in a caption or a comment that name this Mac.
    public static let macClaims: [String] = [
        "on your mac", "on this mac", "on the mac", "on your local machine", "on your machine", "on your laptop",
        "in your local terminal", "on your computer", "locally", "auf deinem mac", "auf dem mac", "lokal",
    ]
    /// Phrases that name the server ("on <alias>" is added from the session facts).
    public static let serverClaims: [String] = [
        "on the server", "on the remote server", "on the remote machine", "on the box", "on the vps", "on the host",
        "on your server", "remotely", "auf dem server",
    ]

    // MARK: Secrets (R15)

    /// Token prefixes and how many token characters must follow (docs/SHELL_LANGUAGE.md A14).
    public static let secretPrefixes: [(prefix: String, minimum: Int)] = [
        ("sk-", 20), ("ghp_", 20), ("gho_", 20), ("ghu_", 20), ("ghs_", 20), ("ghr_", 20), ("github_pat_", 20),
        ("xoxa-", 20), ("xoxb-", 20), ("xoxp-", 20), ("xoxr-", 20), ("glpat-", 20), ("sk_live_", 20),
        ("rk_live_", 20), ("AIza", 30),
    ]
    /// `AKIA` / `ASIA` and exactly 16 upper-case letters or digits.
    public static let awsKeyPrefixes: [String] = ["AKIA", "ASIA"]
    /// Assignment names that hold secrets when given a literal value.
    public static let secretNameSuffixes: [String] = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "_PASS", "_PWD",
                                                      "CREDENTIALS", "APIKEY"]

    // MARK: Placeholders (Needs editing)

    /// Words that are placeholders wherever they stand (outside comments).
    public static let placeholderWords: [String] = ["CHANGEME", "CHANGE_ME", "TODO", "REPLACE_ME", "REPLACEME", "FIXME"]
    /// HTML and XML tag names that are not `<…>` placeholders.
    public static let markupTags: Set<String> = [
        "a", "b", "i", "p", "u", "s", "br", "hr", "em", "div", "span", "html", "head", "body", "title", "script",
        "style", "ul", "ol", "li", "table", "tr", "td", "th", "img", "strong", "code", "pre", "h1", "h2", "h3", "h4",
        "h5", "h6", "key", "string", "dict", "array", "plist", "true", "false", "integer", "real", "data", "date",
    ]
}
