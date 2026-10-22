import AppKit
import PitboxKit

/// The Fetch file sheet on the same panel, with the same rules and arming as the ordinary sheet, using the Fetch
/// runner through `FetchRunning` (`Fetch/FetchRunning.swift`). The plan is made when the sheet opens and again when the
/// user changes the login user; Fetch file starts it after the click-time checks. The same sheet serves an offer's
/// Fetch file and a result fetch (`presentFetch`); they differ in where the request comes from (the reader's or the
/// result's) and in the click-time check (`freshness(of:)` or `freshness(ofResultFetch:toolUseID:path:)`).
extension CommandSheetController {
    /// The runner the app's sheet uses: `FetchRunner` on the live environment. Without a runner a Fetch file offer
    /// opens the ordinary sheet with the "skips Fetch file's protections" line first, and a result fetch says Fetch
    /// file is not available.
    static func defaultFetchRunner() -> FetchRunning? { FetchRunner() }

    /// Why a result fetch's Fetch file is off without a runner.
    static let fetchUnavailableWords = "Fetch file isn't available in this build of \(AppIdentity.displayName)."

    /// Builds (or rebuilds) the plan for the sheet's own Fetch file request; `loginUser` nil means the config's user.
    func planFetch(loginUser: String?) {
        guard let sheet, sheet.state.mode == .fetch else { return }
        guard let runner = fetchRunner, let request = sheet.state.fetchRequest else {
            if sheet.state.resultFetch != nil {
                // No command to fall back to: Fetch file stays off and says why.
                sheet.state.fetch?.phase = .refused(Self.fetchUnavailableWords)
                refresh()
            } else {
                switchToOrdinary()
            }
            return
        }
        sheet.fetchGeneration += 1
        let generation = sheet.fetchGeneration
        let id = sheet.id
        sheet.state.fetch?.phase = .planning
        refresh()
        Task { @MainActor [weak self] in
            let result = await runner.plan(for: request, loginUser: loginUser)
            guard let self, let sheet = self.sheet, sheet.id == id, sheet.fetchGeneration == generation else { return }
            switch result {
            case .success(let plan):
                sheet.state.fetch?.phase = .planned(plan)
                sheet.state.fetch?.configUser = plan.configUser
                // A result fetch logs in as the configured user only: no reply named another one.
                let replyUser = sheet.state.resultFetch == nil ? (plan.replyUser ?? request.replyUser) : nil
                sheet.state.fetch?.replyUser = replyUser
            case .failure(let refusal):
                sheet.state.fetch?.phase = .refused(refusal.words)
                CommandLog.code("fetch plan refused", ["offer": sheet.state.logSubject])
            }
            self.refresh()
            self.rearm(reassess: false)
        }
    }

    /// "Log in as": the config's user or the reply's; a change makes a new plan and re-arms.
    func pickUser(_ user: String) {
        guard let sheet, var fetch = sheet.state.fetch, let choice = sheet.model?.loginChoice else { return }
        if case .fetching = fetch.phase { return }
        let chosen = user == choice.config ? nil : user
        guard chosen != fetch.chosenUser, user == choice.config || user == choice.reply else { return }
        fetch.chosenUser = chosen
        sheet.state.fetch = fetch
        rearm(reassess: false, byChoice: true)
        planFetch(loginUser: chosen)
    }

    /// Fetch file: the same click-time checks as Run, then the runner starts the frozen plan. An offer's sheet asks
    /// `freshness(of:)`; a result fetch asks `freshness(ofResultFetch:toolUseID:path:)` with the tool_use and the path
    /// exactly as the request has them, and starts only on `fresh`.
    func fetchPressed() {
        guard let sheet, sheet.model?.fetch.state.isOn == true, let runner = fetchRunner,
              case .planned(let plan)? = sheet.state.fetch?.phase else { return }
        guard isFullyVisible(sheet.panel) else {
            sheet.state.message = .init(text: "The sheet must be fully visible to fetch; look again.", tone: .warning)
            refresh()
            rearm(reassess: false)
            return
        }
        sheet.state.checking = true
        sheet.state.message = nil
        refresh()
        let id = sheet.id
        let subject = sheet.state.subject
        let logSubject = sheet.state.logSubject
        let checker = sheet.freshness
        Task { @MainActor [weak self] in
            let answer: CommandOfferFreshness
            switch subject {
            case .offer(let offer):
                answer = await CommandFreshnessCheck.check(checker, offer: offer.id)
            case .resultFetch(let result):
                if let toolUseID = result.request.sourceToolUseID {
                    answer = await CommandFreshnessCheck.check(checker, resultFetch: result.sessionIndex, toolUseID: toolUseID,
                                                               path: result.request.remotePath)
                } else {
                    answer = .unknown
                }
            }
            guard let self, let sheet = self.sheet, sheet.id == id else { return }
            sheet.state.checking = false
            switch answer {
            case .stale:
                CommandLog.code("click refused", ["offer": logSubject, "reason": .label(CommandLogWord.stale)])
                self.markStale()
                return
            case .unknown:
                CommandLog.code("click refused", ["offer": logSubject, "reason": .label(CommandLogWord.unknown)])
                sheet.state.message = .init(text: "Couldn't check the session; try again.", tone: .warning)
                self.refresh()
                self.rearm(reassess: false)
                return
            case .superseded(let supersession):
                guard sheet.state.resultFetch == nil else {
                    // Not an answer a result's check gives (fresh, stale or unknown): nothing starts, for good.
                    CommandLog.code("click refused", ["offer": logSubject, "reason": .label(CommandLogWord.superseded)])
                    self.markStale()
                    return
                }
                guard self.acceptSuperseded(supersession, verb: "fetch") else { return }
            case .fresh:
                break
            }
            guard case .planned(let current)? = sheet.state.fetch?.phase, current == plan,
                  CommandSheetModel(sheet.state, now: self.clock(), home: self.home, userName: self.userName).fetch.state.isOn else {
                self.refresh()
                return
            }
            let events = sheet.events
            sheet.fetchStarted = true
            sheet.state.fetch?.phase = .fetching(plan, bytes: 0)
            sheet.fetchHandle = runner.start(plan, progress: { [weak self] bytes in
                guard let sheet = self?.sheet, sheet.id == id, case .fetching(let running, _)? = sheet.state.fetch?.phase else { return }
                sheet.state.fetch?.phase = .fetching(running, bytes: bytes)
                self?.refresh()
            }, completion: { [weak self] outcome in
                events(.fetched(outcome))
                self?.fetchFinished(id, outcome)
            })
            CommandLog.code("fetch started", ["offer": logSubject])
            self.refresh()
        }
    }

    private func fetchFinished(_ id: UUID, _ outcome: FetchFileOutcome) {
        backgroundFetches[id] = nil
        let label: String
        switch outcome {
        case .saved: label = "saved"
        case .failed: label = "failed"
        case .cancelled: label = "cancelled"
        }
        CommandLog.code("fetch finished", ["outcome": .label(FetchOutcomeLabel(logLabel: label))])
        guard let sheet, sheet.id == id else { return }
        sheet.fetchHandle = nil
        sheet.state.fetch?.phase = .done(outcome)
        if case .saved(let name, _) = outcome {
            // Open for documents, Preview for web documents (only with a preview), else nothing more.
            let opening = fetchedFileOpening(name)
            sheet.state.fetch?.opening = opening == .preview && previewFetchedFile == nil ? .showInFinderOnly : opening
        }
        refresh()
        rearm(reassess: false)
    }

    /// "Run in terminal instead": the ordinary sheet for the original command, its warning line first; it then
    /// needs everything an ordinary run needs.
    func runInsteadPressed() {
        // A result fetch has no command to run instead.
        guard let sheet, let offer = sheet.state.offer, sheet.model?.runInstead.state.isOn == true else { return }
        switchToOrdinary()
        CommandLog.code("fetch sheet to ordinary", ["offer": .offer(offer.id)])
    }

    private func switchToOrdinary() {
        guard let sheet, sheet.state.offer != nil else { return }
        sheet.fetchGeneration += 1
        sheet.state.mode = .ordinary(fromFetch: true)
        sheet.state.fetch = nil
        sheet.state.scrolledToEnd = false
        refresh()
        rearm(reassess: true)
    }

    /// Open or Preview after a saved fetch: the file in Downloads by its saved name, only while it is
    /// still a regular file of the user's with one link (nothing swapped in since); it keeps its quarantine value.
    func openFetchedPressed() {
        guard let sheet, case .done(.saved(let name, _))? = sheet.state.fetch?.phase, !name.contains("/"),
              let opening = sheet.state.fetch?.opening, opening != .showInFinderOnly else { return }
        let url = URL(fileURLWithPath: home).appendingPathComponent("Downloads").appendingPathComponent(name)
        guard FetchedFileOpening.isPlainFile(url) else {
            sheet.state.message = .init(text: "The file changed in Downloads; use Show in Finder.", tone: .warning)
            refresh()
            return
        }
        if opening == .open { openFetchedFile(url) } else { previewFetchedFile?(url, sheet.panel.frame) }
        CommandLog.code("fetched file opened", ["kind": .label(FetchOutcomeLabel(logLabel: opening.rawValue))])
    }

    /// Show in Finder after a saved fetch: reveals the file, never opens it.
    func showInFinderPressed() {
        guard let sheet, case .done(.saved(let name, _))? = sheet.state.fetch?.phase, !name.contains("/") else { return }
        revealInFinder(URL(fileURLWithPath: home).appendingPathComponent("Downloads").appendingPathComponent(name))
    }
}

/// A fixed log label for a fetch's outcome.
struct FetchOutcomeLabel: CommandLogLabel {
    let logLabel: String
}
