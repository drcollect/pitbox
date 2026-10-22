import Foundation
import PitboxKit

/// Command, Type and server tabs in the console. Internal: only the command
/// sheet's handlers reach these, through `ConsoleHost`'s `CommandTabHost` methods.
extension TerminalSessionManager {
    /// At most this many Run tabs run at once.
    static let maxRunningCommands = 3

    /// Run tabs whose shell is starting or running.
    var runningCommandCount: Int {
        sessions.filter { $0.command?.role == .run && $0.command?.isRunning == true }.count
    }

    /// Nil when a tab of `role` can open now; else the reason, in the app's words.
    func commandBlocker(role: CommandTabRole) -> String? {
        if sessions.count >= settings.maxSessions { return "The console has \(sessions.count) tabs. Close one." }
        if role == .run, runningCommandCount >= Self.maxRunningCommands {
            return "\(Self.maxRunningCommands) commands are running. Wait for one to finish, or stop one."
        }
        return nil
    }

    /// Opens a Run or Type tab at the end, selected but not focused, and starts its shell at the current size. Nil
    /// (nothing started) at a limit.
    @discardableResult
    func openCommandTab(_ command: CommandTab) -> TerminalSession? {
        guard command.role != .server, commandBlocker(role: command.role) == nil else { return nil }
        var preset = TerminalPreset(id: "command", name: command.origin.tabTitle, argv: nil, script: nil, cwd: nil, env: [:],
                                    enabled: true, restore: false)
        preset.commandRole = command.role
        return addSession(preset: preset, directory: nil, select: true, command: command)
    }

    /// "Open a terminal on <host>": a program tab running `ssh <alias>` through the login shell, like a preset;
    /// nothing is typed into it and it does not take the keyboard. The alias must already have passed
    /// `SSHConfigHosts.isExactAlias` (off the main thread: `ConsoleHost.openServerTab`).
    @discardableResult
    func openServerTab(alias: String) -> TerminalSession? {
        guard SSHConfigHosts.isWellFormedAlias(alias), commandBlocker(role: .server) == nil else { return nil }
        var preset = TerminalPreset(id: "server", name: alias, argv: ["ssh", alias], script: nil, cwd: nil, env: [:],
                                    enabled: true, restore: false)
        preset.commandRole = .server
        return addSession(preset: preset, directory: nil, select: true, command: nil)
    }

    /// The session of a Run tab, by its run id.
    func commandSession(runID: UUID) -> TerminalSession? {
        sessions.first { $0.command?.runID == runID }
    }

    // MARK: The bar's clock

    /// While a Run tab runs (running time, hidden input) or a Type tab waits for its shell, the bar is refreshed once a
    /// second, and only while the console is shown. No timer runs otherwise: an idle Type tab's bar changes only when
    /// the keyboard moves, which the console view pushes.
    func scheduleCommandTick() {
        guard commandTickToken == nil else { return }
        commandTickToken = clock.schedule(after: 1) { [weak self] in
            MainActor.assumeIsolated { self?.commandTick() }
        }
    }

    private func commandTick() {
        commandTickToken = nil
        let active = sessions.filter { session in
            guard let command = session.command else { return false }
            return (command.role == .run && !command.hasEnded) || command.typing == .waitingForShell
        }
        guard !active.isEmpty else { return }
        if isVisible {
            for session in active {
                guard let command = session.command, command.phase == .running else { continue }
                command.asksForHiddenInput = session.commandInputModes()?.asksForHiddenInput ?? false
            }
            onCommandTick?()
        }
        scheduleCommandTick()
    }
}
