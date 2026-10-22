import AppKit
import PitboxKit

/// The sheet's buttons. Each handler runs only from its button's accepted press
/// (`CommandSheetButton.endPress`), checks again what the model allowed, and starts nothing on any doubt.
extension CommandSheetController {
    func wire(_ view: CommandSheetView) {
        var actions = CommandSheetView.Actions()
        actions.run = { [weak self] in self?.runOrType(.run) }
        actions.type = { [weak self] in self?.runOrType(.typeIntoTerminal) }
        actions.copy = { [weak self] in self?.copyPressed(cleaned: false) }
        actions.copyCleaned = { [weak self] in self?.copyPressed(cleaned: true) }
        actions.server = { [weak self] in self?.serverPressed() }
        actions.fetch = { [weak self] in self?.fetchPressed() }
        actions.runInstead = { [weak self] in self?.runInsteadPressed() }
        actions.showInFinder = { [weak self] in self?.showInFinderPressed() }
        actions.openFetched = { [weak self] in self?.openFetchedPressed() }
        actions.cancel = { [weak self] in self?.cancelPressed() }
        actions.close = { [weak self] in self?.cancelPressed() }
        actions.tick = { [weak self] key in self?.toggleTick(key) }
        actions.pickMachine = { [weak self] pick in self?.pickMachine(pick) }
        actions.pickUser = { [weak self] user in self?.pickUser(user) }
        actions.toggle = { [weak self] disclosure in self?.toggle(disclosure) }
        actions.scrolledToEnd = { [weak self] in self?.reachedEnd() }
        actions.touched = { [weak self] in self?.touched() }
        view.actions = actions
    }

    // MARK: Run and Type

    /// Yes, run this / Type into terminal (don't run): the click-time checks (freshness within 300 ms, R22, the
    /// target files, the folder, the terminal), then the frozen copy is consumed once and handed to the terminal. Any
    /// doubt starts nothing and says why.
    func runOrType(_ kind: CommandExecutionDescriptor.Kind) {
        // Only an offer's sheet has text to run or type; a result fetch never does.
        guard let sheet, let offer = sheet.state.offer, let model = sheet.model,
              (kind == .run ? model.run : model.type).state.isOn else { return }
        if kind == .run, refuseRunWhenOff() { return }
        guard isFullyVisible(sheet.panel) else {
            sheet.state.message = .init(text: "The sheet must be fully visible to run anything; look again.", tone: .warning)
            refresh()
            rearm(reassess: false)
            return
        }
        sheet.state.checking = true
        sheet.state.message = nil
        refresh()
        let id = sheet.id
        let offerID = offer.id
        let checker = sheet.freshness
        Task { @MainActor [weak self] in
            let answer = await CommandFreshnessCheck.check(checker, offer: offerID)
            guard let self, let sheet = self.sheet, sheet.id == id else { return }
            sheet.state.checking = false
            switch answer {
            case .stale:
                CommandLog.code("click refused", ["offer": .offer(offerID), "reason": .label(CommandLogWord.stale)])
                self.markStale()
                return
            case .unknown:
                CommandLog.code("click refused", ["offer": .offer(offerID), "reason": .label(CommandLogWord.unknown)])
                sheet.state.message = .init(text: "Couldn't check the session; try again.", tone: .warning)
                self.refresh()
                self.rearm(reassess: false)
                return
            case .superseded(let supersession):
                // Goes on only under a ticked R22 showing exactly these facts.
                guard self.acceptSuperseded(supersession, verb: kind == .run ? "run" : "type") else { return }
            case .fresh:
                break
            }
            // The files once more: a target that appeared since needs its own tick.
            let folder = sheet.state.folder.path
            let options = self.options(for: sheet, offer: offer)
            let first = self.assess(offer.text, offer: offer, folder: folder, facts: [:], options: options)
            let facts = first.localTargets.isEmpty ? [:] : await self.lookUpFacts(first.localTargets)
            guard let current = self.sheet, current.id == id else { return }
            let second = facts.isEmpty ? first : self.assess(offer.text, offer: offer, folder: folder, facts: facts, options: options)
            if second != current.state.assessment {
                CommandLog.code("click refused", ["offer": .offer(offerID), "reason": .label(CommandLogWord.assessment)])
                self.applyAssessment(second, setuid: current.state.setuidPrograms)
                return
            }
            self.finishRunOrType(kind)
        }
    }

    private func finishRunOrType(_ kind: CommandExecutionDescriptor.Kind) {
        guard let sheet, let offer = sheet.state.offer, let frozen = sheet.frozen else { return }
        // Everything the model requires, once more, now.
        let model = CommandSheetModel(sheet.state, now: clock(), home: home, userName: userName)
        guard (kind == .run ? model.run : model.type).state.isOn else {
            refresh()
            return
        }
        // The session's folder, decided again: it may have become a refused root since the sheet opened.
        if let refused = Self.refusedWorkFolder(for: offer, guard: pathGuard(), fs: pathFileSystem) {
            CommandLog.code("click refused", ["offer": .offer(offer.id), "reason": .label(CommandLogWord.folder)])
            markWorkFolderRefused(refused)
            return
        }
        if let problem = frozen.folder?.verify() {
            sheet.state.folder.problem = problem.words
            sheet.state.message = .init(text: problem.words, tone: .problem)
            CommandLog.code("click refused", ["offer": .offer(offer.id), "reason": .label(CommandLogWord.folder)])
            refresh()
            return
        }
        if kind == .run, refuseRunWhenOff() { return }
        let role: CommandTabRole = kind == .run ? .run : .typeIntoTerminal
        if let blocker = host.commandBlocker(role: role) {
            if kind == .run { sheet.state.terminalBlocker = blocker } else { sheet.state.typeBlocker = blocker }
            sheet.state.message = .init(text: blocker, tone: .info)
            CommandLog.code("click refused", ["offer": .offer(offer.id), "reason": .label(CommandLogWord.terminal)])
            refresh()
            return
        }
        let assessed = sheet.state.assessment.machine
        let machine: CommandMachine = assessed == .unclear
            ? (sheet.state.machinePick == .thisMac ? .thisMac : .server) : assessed
        guard let consumed = frozen.consume(kind: kind, machine: machine) else { return }
        sheet.state.consumed = true
        let origin = CommandTabOrigin(headline: offer.source.headline, profileName: offer.source.profileName, machineLabel: "this Mac",
                                      folderShort: sheet.state.folder.shortPath, replyTime: offer.source.replyTime, offer: offer.id)
        var request = CommandTabRequest(role: role, descriptor: consumed.descriptor, folder: consumed.folder, origin: origin,
                                        runID: UUID(), typedText: kind == .typeIntoTerminal ? consumed.descriptor.text : nil)
        // The run policy once more after the console's reveal (0.35 s or more after this click), right before the
        // spawn. A sheet controller that is gone counts as Run off.
        request.runAllowed = { [weak self] in self?.runPolicy() == .run }
        let events = sheet.events
        var refusedAtOnce: String?
        var starting = true
        host.startCommandTab(request) { event in
            if starting, case .refused(let reason) = event { refusedAtOnce = reason }
            events(event)
        }
        starting = false
        if let reason = refusedAtOnce {
            // The sheet stays, saying why; its approval is used up (a new look needs a new sheet).
            sheet.state.message = .init(text: reason, tone: .problem)
            refresh()
            rearm(reassess: false)
            return
        }
        close(reason: kind == .run ? .ran : .typed)
    }

    /// At the click: reads the run policy again; when Run is off now, the sheet loses its Run button, says so, and
    /// nothing starts. Returns true when the click is refused.
    func refuseRunWhenOff() -> Bool {
        guard let sheet else { return true }
        guard sheet.state.runPolicy == .run, runPolicy() == .run else {
            _ = runPolicyTurnedOff()
            sheet.state.message = .init(text: CommandSheetModel.runOffWords, tone: .info)
            CommandLog.code("click refused", ["offer": sheet.state.logSubject, "reason": .label(CommandLogWord.runOff)])
            refresh()
            rearm(reassess: false)
            return true
        }
        return false
    }

    /// Reads the run policy again while a sheet is open: `run` can turn into `copyOnly` (Run disappears), never the other
    /// way (switching Run on needs a new sheet). True when it just turned off.
    func runPolicyTurnedOff() -> Bool {
        guard let sheet, sheet.state.runPolicy == .run, runPolicy() != .run else { return false }
        sheet.state.runPolicy = .copyOnly
        CommandLog.code("run turned off", ["offer": sheet.state.logSubject])
        return true
    }

    // MARK: Copy, server, choices

    func copyPressed(cleaned: Bool) {
        guard let sheet, let model = sheet.model else { return }
        if cleaned {
            guard model.copyCleaned.state.isOn, let text = model.cleaned?.text else { return }
            CommandPasteboard.copy(text, to: pasteboard)
            sheet.state.copiedCleanedUntil = clock() + Self.confirmationTime
        } else {
            // A result fetch has no command to copy.
            guard model.copy.state.isOn, let offer = sheet.state.offer else { return }
            CommandPasteboard.copy(offer.text, to: pasteboard)
            sheet.state.copiedUntil = clock() + Self.confirmationTime
        }
        CommandLog.code("copied", ["offer": sheet.state.logSubject, "cleaned": .flag(cleaned)])
        sheet.events(.copied)
        refresh()
    }

    func serverPressed() {
        guard let sheet, sheet.model?.server.state.isOn == true, let alias = sheet.state.serverAlias,
              !sheet.serverTabPending else { return }
        sheet.serverTabPending = true
        let id = sheet.id
        // The console reads the SSH config off the main thread; one press, one tab.
        host.openServerTab(alias: alias) { [weak self] reason in
            guard let self, let sheet = self.sheet, sheet.id == id else { return }
            sheet.serverTabPending = false
            if let reason {
                sheet.state.message = .init(text: reason, tone: .problem)
            } else {
                sheet.state.openedServerUntil = self.clock() + Self.confirmationTime
                sheet.state.message = .init(text: "Opened a terminal on \(alias); nothing was typed into it. Copy the command to paste it there.",
                                            tone: .info)
            }
            self.refresh()
        }
    }

    func toggleTick(_ key: String) {
        guard let sheet, sheet.model?.redLines.contains(where: { $0.key == key }) == true else { return }
        if sheet.state.ticked.contains(key) { sheet.state.ticked.remove(key) } else { sheet.state.ticked.insert(key) }
        refresh()
        rearm(reassess: false, byChoice: true)
    }

    func pickMachine(_ pick: CommandSheetState.MachinePick) {
        guard let sheet, sheet.model?.showsMachinePicker == true else { return }
        sheet.state.machinePick = pick
        refresh()
        rearm(reassess: false, byChoice: true)
    }

    func toggle(_ disclosure: CommandSheetState.Disclosure) {
        guard let sheet else { return }
        if sheet.state.open.contains(disclosure) { sheet.state.open.remove(disclosure) } else { sheet.state.open.insert(disclosure) }
        refresh()
        rearm(reassess: false)
    }

    func reachedEnd() {
        guard let sheet, !sheet.state.scrolledToEnd else { return }
        sheet.state.scrolledToEnd = true
        refresh()
    }

    func cancelPressed() {
        guard let sheet else { return }
        if case .fetching = sheet.state.fetch?.phase {
            close(reason: .fetchCancelled)
        } else {
            close(reason: .cancel)
        }
    }
}
