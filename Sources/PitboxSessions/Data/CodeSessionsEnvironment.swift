import Darwin
import Foundation
import PitboxKit

/// Everything the data side takes from the outside world, so tests run on invented folders, processes and clocks only.
/// `live()` is the user's Mac.
public struct CodeSessionsEnvironment: Sendable {
    /// `~/Library/Application Support`: the profile folders (`Claude` and the ones `profiles` lists) are in it.
    public var applicationSupport: URL
    /// `~/.claude/projects`: Claude Code's transcripts and the SSH mirrors.
    public var claudeProjects: URL
    /// `~/.ssh/config`; relative `Include` paths are taken from its folder.
    public var sshConfig: URL
    /// The user's home folder (the folder an SSH session's Mac commands run in).
    public var homeDirectory: String
    /// The user's user name (for the classifier's facts).
    public var userName: String
    /// Files and folders below the roots must belong to this user.
    public var userID: uid_t
    /// The wall clock the state rules and the 24-hour limit use.
    public var clock: @Sendable () -> Date
    /// The running processes with Claude's bundle id.
    public var processes: @Sendable () -> [ClaudeProcessCandidate]
    /// The HostName of an SSH alias (`ssh -G`, never connecting); called only when the config has no `Match` block.
    public var hostName: @Sendable (_ alias: String) -> String?
    /// The program names on the clean PATH plus the given `extraPath` folders; nil when not looked up.
    public var programsOnCleanPath: @Sendable (_ extraPath: [String]) -> Set<String>?
    /// The settings file (`settings.json`; the app passes `CodeSettingsWatcher.current`).
    public var settings: @Sendable () -> CodeSettings
    /// FSEvents and kernel file events (tests switch them off and call `refresh`).
    public var watchesFiles: Bool
    /// Follow Claude launching and quitting through NSWorkspace notifications.
    public var observesApplications: Bool
    /// At most one parse per session per this many seconds (2 s).
    public var parseInterval: TimeInterval
    /// FSEvents latency.
    public var watchLatency: TimeInterval
    /// At most this many sessions get their transcripts read and watched (24).
    public var maxWatchedSessions: Int

    /// An environment from its parts; the defaults switch off what tests usually do not need.
    public init(applicationSupport: URL, claudeProjects: URL, sshConfig: URL, homeDirectory: String, userName: String,
                userID: uid_t, clock: @escaping @Sendable () -> Date = { Date() },
                processes: @escaping @Sendable () -> [ClaudeProcessCandidate],
                hostName: @escaping @Sendable (String) -> String? = { _ in nil },
                programsOnCleanPath: @escaping @Sendable ([String]) -> Set<String>? = { _ in nil },
                settings: @escaping @Sendable () -> CodeSettings = { CodeSettings() }, watchesFiles: Bool = true,
                observesApplications: Bool = false, parseInterval: TimeInterval = 2, watchLatency: TimeInterval = 0.5,
                maxWatchedSessions: Int = 24) {
        self.applicationSupport = applicationSupport
        self.claudeProjects = claudeProjects
        self.sshConfig = sshConfig
        self.homeDirectory = homeDirectory
        self.userName = userName
        self.userID = userID
        self.clock = clock
        self.processes = processes
        self.hostName = hostName
        self.programsOnCleanPath = programsOnCleanPath
        self.settings = settings
        self.watchesFiles = watchesFiles
        self.observesApplications = observesApplications
        self.parseInterval = parseInterval
        self.watchLatency = watchLatency
        self.maxWatchedSessions = maxWatchedSessions
    }

    /// The user's Mac: the real folders, `NSRunningApplication` and `sysctl` for processes, `ssh -G` for HostNames,
    /// the clean PATH's folders for programs, and the settings file (written with defaults once when missing; pass the watcher's `current` instead in the app).
    public static func live(settings: @escaping @Sendable () -> CodeSettings = { CodeSettings.loadOrCreate() }) -> CodeSessionsEnvironment {
        let home = NSHomeDirectory()
        let user = NSUserName()
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        let programs = CleanPathPrograms()
        return CodeSessionsEnvironment(
            applicationSupport: support,
            claudeProjects: homeURL.appendingPathComponent(".claude/projects", isDirectory: true),
            sshConfig: homeURL.appendingPathComponent(".ssh/config"),
            homeDirectory: home, userName: user, userID: getuid(),
            processes: { ClaudeProcessDiscovery.liveCandidates() },
            hostName: { alias in SSHHostNameLookup.hostName(alias: alias, home: home, user: user) },
            programsOnCleanPath: { extra in programs.programs(extraPath: extra) },
            settings: settings, watchesFiles: true, observesApplications: true)
    }
}
