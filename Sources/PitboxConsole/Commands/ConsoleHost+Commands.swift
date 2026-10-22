import AppKit
import Foundation
import PitboxKit

/// One approved Run or Type, as the sheet hands it to the console: the consumed descriptor, the folder bound when the
/// sheet opened, and the words for the tab's bar.
struct CommandTabRequest {
    var role: CommandTabRole
    var descriptor: CommandExecutionDescriptor
    /// The folder by descriptor; closed by the spawn, or here when nothing starts.
    var folder: FolderBinding
    var origin: CommandTabOrigin
    var runID: UUID
    /// Type only: the text to paste (the descriptor's text; the login shell leaves out full-line comments).
    var typedText: String?
    /// Run only: the sheet's run policy, asked once more after the console's reveal, right before the spawn; a
    /// policy switched to `copyOnly` during the wait starts nothing. The sheet passes its own reading.
    var runAllowed: @MainActor () -> Bool = { false }
}

/// What the command sheet needs from the console. Internal: no public method starts a command tab or
/// types into a session; only `CommandSheetController`'s click handlers call these.
protocol CommandTabHost: AnyObject {
    /// Nil when a tab of `role` could open now; else the reason in the app's words (the console can't be shown, the
    /// console's limits, the spawn path unavailable).
    @MainActor func commandBlocker(role: CommandTabRole) -> String?
    /// Starts a Run or Type tab: reveal and hold the console, then the tab and its shell at the held size.
    /// `events` gets `started`/`finished`/`stopped` (Run), `typed` (Type) or `refused`.
    @MainActor func startCommandTab(_ request: CommandTabRequest, events: @escaping @MainActor (CommandOfferEvent) -> Void)
    /// "Open a terminal on <alias>": `completion` gets nil when the tab opened, else why not. The SSH config is read
    /// off the main thread; `completion` runs on the main thread.
    @MainActor func openServerTab(alias: String, completion: @escaping @MainActor (String?) -> Void)
    /// Selects the tab of a Run and reveals the console; never focuses, runs or types anything.
    @MainActor func revealRun(_ runID: UUID) -> Bool
    /// The user's home folder (to check `~/.ssh/config`).
    @MainActor var homeFolder: String { get }
}

extension ConsoleHost: CommandTabHost {
    /// The console can't be shown now, so nothing can run in it.
    static let consoleHiddenReason = "Show \(AppIdentity.displayName) to run commands here."
    /// How long the composition root may take to reveal and hold the console before nothing starts.
    static let revealTimeout: TimeInterval = 2
    /// The console's linger: the hold ends this long after the last Run finished.
    static let holdLinger: TimeInterval = 25

    @MainActor var homeFolder: String { (environment ?? .live).home }

    @MainActor func commandBlocker(role: CommandTabRole) -> String? {
        guard commandHooks.consoleVisible(), let manager else { return Self.consoleHiddenReason }
        if role != .server, let problem = commandPathProblem() { return problem }
        return manager.commandBlocker(role: role)
    }

    @MainActor func startCommandTab(_ request: CommandTabRequest, events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        let refuse: @MainActor (String) -> Void = { reason in
            request.folder.close()
            CommandLog.code("run refused", ["kind": .label(request.role), "offer": .offer(request.descriptor.offerID)])
            events(.refused(reason: reason))
        }
        guard request.role != .server else { return refuse("this isn't a command tab") }
        if let reason = commandBlocker(role: request.role) { return refuse(reason) }
        guard commandHooks.consoleVisible() else { return refuse(Self.consoleHiddenReason) }
        let spec: CommandLaunchSpec
        do {
            spec = try CommandLaunchSpec(descriptor: request.descriptor, environment: environment ?? .live)
        } catch {
            return refuse((error as? CommandLaunchSpec.BuildProblem)?.words ?? "the command can't be run")
        }
        if let problem = request.folder.verify() { return refuse(problem.words) }

        var answered = false
        let runID = request.runID
        let proceed: @MainActor (Bool) -> Void = { [weak self] shown in
            guard !answered else { return }
            answered = true
            guard let self else { request.folder.close(); return }
            self.revealTimeouts[runID] = nil
            self.openRequestedTab(request, spec: spec, shown: shown, events: events, refuse: refuse)
        }
        beginHold(ready: proceed)
        if !answered {
            revealTimeouts[runID] = clock.schedule(after: Self.revealTimeout) { MainActor.assumeIsolated { proceed(false) } }
        }
    }

    /// After the reveal: the console must still be visible and within its limits; then the tab opens and its shell
    /// starts at the size the console has now.
    @MainActor private func openRequestedTab(_ request: CommandTabRequest, spec: CommandLaunchSpec, shown: Bool,
                                             events: @escaping @MainActor (CommandOfferEvent) -> Void,
                                             refuse: @MainActor (String) -> Void) {
        guard shown, commandHooks.consoleVisible(), let manager else {
            endHold(after: 0)
            return refuse("the console couldn't be shown")
        }
        if request.role == .run, !request.runAllowed() {
            endHold(after: 0)
            return refuse(CommandSheetModel.runOffWords)
        }
        if let reason = manager.commandBlocker(role: request.role) {
            endHold(after: 0)
            return refuse(reason)
        }
        // Size first: the console is held open; lay it out so the shell starts with those rows and columns.
        consoleView()?.layoutSubtreeIfNeeded()
        let role = request.role
        let wrapped: @MainActor (CommandOfferEvent) -> Void = { [weak self] event in
            events(event)
            switch event {
            case .finished, .stopped, .refused, .typed:
                // One hold for all Run tabs: it ends the console's linger after none runs any more.
                self?.endHold(after: Self.holdLinger)
            default:
                break
            }
        }
        let text = role == .typeIntoTerminal ? (request.typedText ?? request.descriptor.text) : request.descriptor.text
        let command = CommandTab(role: role, runID: request.runID, origin: request.origin, text: text, spec: spec,
                                 folder: request.folder, events: wrapped)
        guard manager.openCommandTab(command) != nil else {
            endHold(after: 0)
            return refuse(manager.commandBlocker(role: role) ?? "the console couldn't open a tab")
        }
        let lines = request.descriptor.text.split(separator: "\n", omittingEmptySubsequences: false).count
        if role == .run {
            CommandLog.code("run started", ["offer": .offer(request.descriptor.offerID), "lines": .number(lines)])
        } else {
            CommandLog.code("type started", ["offer": .offer(request.descriptor.offerID), "lines": .number(lines)])
        }
    }

    /// Reads the SSH config here, never on the main thread (up to 64 files of 256 KB, and `glob`).
    static let sshConfigQueue = DispatchQueue(label: "pitbox.console.ssh-config", qos: .userInitiated)

    @MainActor func openServerTab(alias: String, completion: @escaping @MainActor (String?) -> Void) {
        guard commandHooks.consoleVisible(), manager != nil else { return completion(Self.consoleHiddenReason) }
        let home = homeFolder
        let check = exactAliasCheck
        Task { @MainActor [weak self] in
            let exact = await withCheckedContinuation { continuation in
                Self.sshConfigQueue.async { continuation.resume(returning: check(alias, home)) }
            }
            guard let self else { return completion(Self.consoleHiddenReason) }
            completion(self.finishServerTab(alias: alias, exact: exact))
        }
    }

    /// After the off-main check: the console is asked again (it may have hidden meanwhile), then the tab opens.
    @MainActor private func finishServerTab(alias: String, exact: Bool) -> String? {
        guard commandHooks.consoleVisible(), let manager else { return Self.consoleHiddenReason }
        guard exact else { return "that server isn't an exact entry in your SSH config" }
        if let reason = manager.commandBlocker(role: .server) { return reason }
        beginHold { [weak self] _ in self?.endHold(after: Self.holdLinger) }
        guard manager.openServerTab(alias: alias) != nil else { return "the console couldn't open a tab" }
        CommandLog.code("server tab opened")
        return nil
    }

    @MainActor func revealRun(_ runID: UUID) -> Bool {
        guard let manager, let session = manager.commandSession(runID: runID) else { return false }
        manager.select(id: session.id, userInitiated: false)
        if commandHooks.consoleVisible() {
            beginHold { [weak self] _ in self?.endHold(after: Self.holdLinger) }
        }
        CommandLog.code("run revealed")
        return true
    }

    // MARK: The hold

    /// Reveals and holds the console; a pending end of the hold is cancelled (the hold goes on).
    @MainActor private func beginHold(ready: @escaping @MainActor (Bool) -> Void) {
        holdRelease = nil
        commandHooks.revealAndHoldConsole(ready)
    }

    /// Ends the hold `delay` seconds from now, unless a Run still runs then or a new hold came first.
    @MainActor private func endHold(after delay: TimeInterval) {
        guard (manager?.runningCommandCount ?? 0) == 0 else { return }
        if delay <= 0 {
            holdRelease = nil
            commandHooks.releaseConsoleHold()
            return
        }
        holdRelease = clock.schedule(after: delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, (self.manager?.runningCommandCount ?? 0) == 0 else { return }
                self.holdRelease = nil
                self.commandHooks.releaseConsoleHold()
            }
        }
    }

    // MARK: Public, for the composition root (selection and counts only)

    /// Selects the tab of a Run (the monitor's result line, "Show output") and reveals the console through the
    /// hooks. Selecting never gives it the keyboard. False when the tab is gone.
    @discardableResult
    public func selectCommandTab(runID: UUID) -> Bool {
        onMain { revealRun(runID) }
    }

    /// How many Run tabs are running now (for a status display: a count, nothing else).
    public var runningCommandCount: Int {
        onMain { manager?.runningCommandCount ?? 0 }
    }
}
