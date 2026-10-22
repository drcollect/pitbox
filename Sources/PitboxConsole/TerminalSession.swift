import AppKit
import PitboxKit
import SwiftTerm

/// What a session needs from its surroundings.
struct SessionContext {
    var settings: TerminalSettings
    var environment: TerminalEnvironment
    var launcher: ProcessLauncher
    /// Carries out what `LinkPolicy` decided for a Cmd-click.
    var performLink: (LinkPolicy.Action) -> Void
    /// Puts text on the clipboard (OSC 52, only when the settings allow it).
    var setClipboard: (String) -> Void
    /// Starts command and Type tabs (`Commands/CommandSpawner.swift`); never used for settings presets.
    var commandLauncher: CommandLauncher = CommandSpawner.live(policy: { .standard })
    /// Time for command tabs: durations and Type's wait for the shell.
    var clock: TerminalClock = SystemClock()
}

/// One tab: a terminal view and the process behind it.
///
/// Input reaches the process only through `send(source:data:)`, which the session's own view calls for keyboard, paste
/// and drop events (and for the emulator's own answers to a program's queries). The session has no method for anybody
/// else to type into it.
@MainActor
final class TerminalSession: @preconcurrency TerminalViewDelegate {
    enum State: Equatable {
        case notStarted
        case running
        case exited(ProcessExit)
        case failed(String)
    }

    let id = UUID()
    let preset: TerminalPreset
    let view: ConsoleTerminalView
    private(set) var state: State = .notStarted
    /// The first process's working directory, refreshed while the session runs.
    private(set) var directory: String?
    private(set) var foreground: ForegroundInfo?
    /// The title the program set with OSC 0/2 (cleaned). Shown in the tooltip only: it is program-controlled text.
    private(set) var oscTitle: String?
    private(set) var title: String
    /// Output arrived while the tab was in the background.
    private(set) var hasUnseenActivity = false
    /// The bell rang while the tab was in the background.
    private(set) var needsAttention = false
    var isSelected = false {
        didSet {
            guard isSelected, hasUnseenActivity || needsAttention else { return }
            hasUnseenActivity = false
            needsAttention = false
            onChange?()
        }
    }

    /// Something a tab shows changed (title, state, activity).
    var onChange: (() -> Void)?
    /// The process ended (after its last output).
    var onExit: ((TerminalSession, ProcessExit) -> Void)?
    /// The user typed, pasted or dropped something.
    var onUserInput: (() -> Void)?

    private var process: TerminalProcess?
    private let context: SessionContext
    private let startDirectory: String?
    /// File name of the login shell (`zsh`): a foreground process with this name means "the shell itself".
    private let shellName: String
    /// Set for command and Type tabs (`.command` kind): what was approved, how it went, the sheet's events.
    let command: CommandTab?
    /// The shell ended before the helper confirmed its start: held until the start result is known.
    private var pendingCommandExit: ProcessExit?
    private var typeTimeout: ClockToken?

    var pid: pid_t? { process?.pid }
    var isRunning: Bool { state == .running }
    var hasExited: Bool { if case .exited = state { return true }; if case .failed = state { return true }; return false }
    /// Restart (Return in an exited tab, the Restart menu item) exists for settings-preset tabs only: a command tab
    /// never runs its command again.
    var isRestartable: Bool { preset.kind != .command }

    /// The process ended with an error (a non-zero status, a signal) or could not start: the tab's dot says so.
    var exitFailed: Bool {
        switch state {
        case .exited(let status): return !status.isClean
        case .failed: return true
        default: return false
        }
    }

    /// True when closing the tab would end a running program: anything but an idle shell.
    var isBusy: Bool {
        guard state == .running else { return false }
        if preset.kind != .shell { return true }
        return !(foreground?.isSessionLeader ?? true)
    }

    init(preset: TerminalPreset, startDirectory: String?, context: SessionContext, palette: TerminalPalette, frame: CGRect,
         command: CommandTab? = nil) {
        self.preset = preset
        self.context = context
        self.startDirectory = startDirectory
        self.command = command
        self.shellName = URL(fileURLWithPath: context.environment.resolveShell(configured: context.settings.shell)).lastPathComponent
        let settings = context.settings
        var options = TerminalOptions.default
        options.termName = "xterm-256color"
        options.cursorStyle = settings.cursorStyle.swiftTerm
        options.scrollback = settings.scrollback
        options.ansi256PaletteStrategy = .xterm
        options.kittyImageCacheLimitBytes = 32 * 1024 * 1024
        view = ConsoleTerminalView(frame: frame, font: TerminalTheme.font(name: settings.fontName, size: settings.fontSize), options: options)
        title = preset.name
        view.terminalDelegate = self
        view.configure(palette: palette, settings: settings)
        view.onBell = { [weak self] in self?.bellRang() }
        directory = startDirectory
        recomputeTitle()
    }

    // MARK: Lifecycle

    /// Starts the process at the view's current size. The view must have been laid out first so the program starts with
    /// the right number of rows and columns.
    func start() {
        if let command {
            startCommand(command)
            return
        }
        guard state == .notStarted || hasExited else { return }
        let (spec, cwdFellBack) = context.environment.launchSpec(preset: preset, settings: context.settings, cwd: directory ?? startDirectory)
        if cwdFellBack { TerminalLog.info("session \(preset.id): folder not found, starting in the home folder") }
        do {
            let process = try context.launcher(spec, view.terminalSize)
            self.process = process
            process.onOutput = { [weak self] bytes in self?.receive(bytes) }
            process.onExit = { [weak self] status in self?.processEnded(status) }
            state = .running
            directory = spec.cwd
            TerminalLog.info("session \(preset.id) started (pid \(process.pid))")
        } catch {
            state = .failed("\(error)")
            view.feed(text: Self.hint("Could not start: \(error). Press Return to try again, \u{2318}W to close."))
            TerminalLog.warn("session \(preset.id) could not start: \(PTYError.logLabel(of: error))")
        }
        recomputeTitle()
        onChange?()
    }

    /// Starts the same preset again in an exited (or failed) tab, keeping the scrollback. Never for a command tab.
    func restart() {
        guard hasExited, isRestartable else { return }
        view.feed(text: "\r\n")
        view.terminal.softReset()
        process = nil
        state = .notStarted
        start()
    }

    /// SIGHUP now, then SIGKILL after a grace period. The exit is reported through `onExit`.
    func terminate() { process?.terminate() }

    /// For the app quitting: SIGHUP without waiting.
    func hangUp() { process?.hangUp() }

    // MARK: Output and exit

    private func receive(_ bytes: [UInt8]) {
        view.feed(byteArray: bytes[...])
        if command?.typing == .waitingForShell { typeOfferIfReady() }
        if !isSelected, !hasUnseenActivity {
            hasUnseenActivity = true
            onChange?()
        }
    }

    private func processEnded(_ status: ProcessExit) {
        if let command, command.phase == .starting {
            pendingCommandExit = status   // decided once the helper's start result arrives
            return
        }
        let wasFailed: Bool
        if case .failed = state { wasFailed = true } else { wasFailed = false }
        if !wasFailed { state = .exited(status) }
        process = nil
        foreground = nil
        typeTimeout?.cancel()
        typeTimeout = nil
        // Leave alternate screens and mouse or paste modes a crashed program may have left on, then say what happened.
        // `?1049l` also restores the saved cursor (SwiftTerm, like xterm), so it is sent only while the alternate screen
        // is up: otherwise the hint would land on an earlier line and overwrite the output.
        let leaveAlternate = view.terminal.isCurrentBufferAlternate ? "\u{1b}[?1049l" : ""
        let reset = leaveAlternate + "\u{1b}[?25h\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?1l\u{1b}>\u{1b}[0m"
        if let command {
            // No "press Return to restart": a command tab never runs again. The bar above says how it ended.
            if !wasFailed { view.feed(text: reset + Self.hint("\(status.summary)")) }
            command.ended(status, at: context.clock.now)
        } else {
            view.feed(text: reset + Self.hint("\(status.summary). Press Return to restart, \u{2318}W to close."))
        }
        recomputeTitle()
        onChange?()
        onExit?(self, status)
    }

    // MARK: Command and Type tabs

    /// Spawns the approved shell once: the dim echo first (Run only, written into the view, never sent to the
    /// process), then the command launcher with the bound folder. A failure starts nothing and says why.
    private func startCommand(_ command: CommandTab) {
        guard state == .notStarted, let launch = command.takeLaunch() else { return }
        if command.role == .run { view.feed(text: CommandEcho.text(for: command.text)) }
        do {
            let started = try context.commandLauncher(launch.spec, launch.folder, view.terminalSize)
            let process = started.process
            self.process = process
            process.onOutput = { [weak self] bytes in self?.receive(bytes) }
            process.onExit = { [weak self] status in self?.processEnded(status) }
            state = .running
            directory = launch.folder.path
            command.spawned()
            started.awaitStart { [weak self] result in self?.commandStartResolved(result) }
            if command.role == .typeIntoTerminal {
                typeTimeout = context.clock.schedule(after: CommandTab.typeReadyTimeout) { [weak self] in
                    MainActor.assumeIsolated { self?.typeTimedOut() }
                }
            }
            CommandLog.terminal("command tab spawned", ["kind": .label(command.role), "pid": .number(Int(process.pid))])
        } catch {
            let reason = (error as? CommandStartFailure)?.words ?? "the command's shell couldn't be started"
            state = .failed(reason)
            view.feed(text: Self.hint("Did not start: \(reason). Nothing ran."))
            command.didNotStart(reason, at: context.clock.now)
            CommandLog.terminal("command tab spawn failed", ["kind": .label(command.role),
                                                             "reason": .label(CommandStartLabel((error as? CommandStartFailure)))])
        }
        recomputeTitle()
        onChange?()
    }

    private func commandStartResolved(_ result: CommandStartResult) {
        guard let command, command.phase == .starting else { return }
        switch result {
        case .started:
            command.started(at: context.clock.now)
            if command.typing == .waitingForShell { typeOfferIfReady() }
        case .failed(let failure):
            process?.killSession()
            state = .failed(failure.words)
            view.feed(text: Self.hint("Did not start: \(failure.words)"))
            command.didNotStart(failure.words, at: context.clock.now)
            CommandLog.terminal("command tab did not start", ["kind": .label(command.role), "reason": .label(CommandStartLabel(failure))])
        }
        onChange?()
        if let exit = pendingCommandExit {
            pendingCommandExit = nil
            processEnded(exit)
        }
    }

    /// Type into terminal: once the clean shell has switched bracketed paste on (DECSET 2004, which zsh's line
    /// editor does when it starts), the text goes in as one bracketed paste, carriage returns between lines, no
    /// trailing Return. Never before the helper confirmed the start, never twice.
    private func typeOfferIfReady() {
        guard let command, command.typing == .waitingForShell, command.phase == .running, view.terminal.bracketedPasteMode,
              let process, process.isRunning else { return }
        typeTimeout?.cancel()
        typeTimeout = nil
        var text = command.text
        while let last = text.unicodeScalars.last, last == "\n" || last == "\r" { text.unicodeScalars.removeLast() }
        command.beginPaste()
        view.sendPaste(text)
        command.endPaste()
        command.typed()
        onChange?()
    }

    private func typeTimedOut() {
        typeTimeout = nil
        guard let command, command.typing == .waitingForShell else { return }
        command.notTyped("the shell wasn't ready; use Copy")
        onChange?()
    }

    /// The bar's Stop: SIGINT to the running job, then SIGKILL to the tab's process groups.
    func stopCommand() {
        guard let command, command.role == .run, let process, process.isRunning else { return }
        if command.pressedStop() == 1 { process.interruptForeground() } else { process.killSession() }
        CommandLog.terminal("command tab stop", ["presses": .number(command.stopPresses)])
        onChange?()
    }

    /// Echo and canonical mode of the tab's terminal now (for "asks for hidden input").
    func commandInputModes() -> TerminalInputModes? { process?.inputModes() }

    private static func hint(_ message: String) -> String { "\r\n\u{1b}[2m[\(message)]\u{1b}[0m\r\n" }

    private func bellRang() {
        guard !isSelected, !needsAttention else { return }
        needsAttention = true
        onChange?()
    }

    // MARK: Metadata

    /// Re-reads what runs in the foreground and the folder, and updates the title. Cheap (a few system calls).
    func refreshMetadata() {
        guard state == .running, let process else { return }
        let info = process.inspect()
        var changed = false
        if info != foreground { foreground = info; changed = true }
        if let cwd = info?.cwd, cwd != directory { directory = cwd; changed = true }
        if changed { recomputeTitle(); onChange?() }
    }

    private func recomputeTitle() {
        title = SessionTitle.label(kind: preset.kind, shellName: shellName, presetName: preset.name, foreground: foreground,
                                   directory: directory, home: context.environment.home)
    }

    /// Text for the tab's tooltip.
    var tooltip: String {
        if let command { return command.origin.tooltip }
        var lines = [title]
        if let directory { lines.append(directory.replacingOccurrences(of: context.environment.home, with: "~", options: .anchored)) }
        if let oscTitle, oscTitle != title { lines.append(oscTitle) }
        switch state {
        case .exited(let status): lines.append(status.summary)
        case .failed(let message): lines.append(message)
        default: break
        }
        return lines.joined(separator: "\n")
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let process, process.isRunning else { return }
        let size = view.terminalSize
        process.resize(cols: size.cols, rows: size.rows, pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        let cleaned = SessionTitle.clean(title, limit: 120)
        oscTitle = cleaned.isEmpty ? nil : cleaned
    }

    /// Ignored on purpose: the folder comes from the process itself (an OSC 7 from an ssh session is a remote path).
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let process, process.isRunning {
            process.write(Array(data))
            if let command, command.isPastingOffer { return }   // Pitbox's own paste for Type, not the user's typing
            command?.userTyped()
            onUserInput?()
        } else if hasExited, isRestartable, data.first == 0x0d, data.count == 1 {
            restart()   // Return in an exited tab (never in a command tab: it writes nothing and restarts nothing)
        }
    }

    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// SwiftTerm gives the target only; the text the link shows on screen is read here so a link that shows one
    /// address and leads to another opens nothing.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        context.performLink(LinkPolicy.action(for: link, directory: directory, home: context.environment.home,
                                              shownText: view.shownTexts(ofLink: link)))
    }

    func bell(source: TerminalView) { NSSound.beep() }

    /// OSC 52 write: only when `allowClipboardWrite` is on, and capped.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard context.settings.allowClipboardWrite, content.count <= 1 << 20,
              let text = String(data: content, encoding: .utf8) else { return }
        context.setClipboard(text)
    }

    /// OSC 52 read: never. A program must not be able to read the user's clipboard.
    func clipboardRead(source: TerminalView) -> Data? { nil }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
