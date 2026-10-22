import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

@Suite("Monitor items")
struct BuilderTests {
    private func inputs(_ sessions: [CodeSessionSnapshot], statuses: [String: CodeWindowStatus] = [:], hide: Bool = false,
                        showText: [String: Bool] = ["A": true, "B": true, "C": true], profiles: Bool = false,
                        runs: CodeOfferRunBook = CodeOfferRunBook()) -> CodeMonitorBuilder.Inputs {
        CodeMonitorBuilder.Inputs(sessions: sessions, statuses: statuses, runs: runs, hideText: hide, showText: showText,
                                  showsProfiles: profiles, homeDirectory: "/Users/alex", now: tileNow)
    }

    private func item(_ session: CodeSessionSnapshot, _ status: CodeWindowStatus? = CodeWindowStatus(place: .onDesk),
                      hide: Bool = false, profiles: Bool = false, runs: CodeOfferRunBook = CodeOfferRunBook()) -> CodeMonitorItem {
        CodeMonitorBuilder.item(session, position: 1, total: 1,
                                inputs: inputs([session], statuses: status.map { [session.id: $0] } ?? [:], hide: hide,
                                               profiles: profiles, runs: runs))
    }

    // MARK: Which, and in which order

    @Test func onlyPopOutsAndParkedSessionsGetMonitors() {
        let popped = tileSession("local_a", "Popped")
        let plain = tileSession("local_b", "Not popped", popout: false)
        let parked = tileSession("local_c", "Parked, pop-out file gone", popout: false)
        let members = CodeMonitorBuilder.members([popped, plain, parked], parked: ["local_c"])
        #expect(members.map(\.id) == ["local_a", "local_c"])
    }

    @Test func theOrderIsFixedByCopyThenFirstSeenNeverByAttention() {
        let b1 = tileSession("local_b1", "B one", profile: .b, state: .needsYou)
        let a2 = tileSession("local_a2", "A two", state: .done)
        let a1 = tileSession("local_a1", "A one", state: .working)
        let c1 = tileSession("local_c1", "C one", profile: .c, state: .problem)
        let first: [String: Int] = ["local_a1": 1, "local_b1": 2, "local_a2": 3, "local_c1": 4]
        let ordered = CodeMonitorBuilder.ordered([b1, a2, a1, c1], firstSeen: first, byCopy: true)
        #expect(ordered.map(\.id) == ["local_a1", "local_a2", "local_b1", "local_c1"])
        // A state change does not move anything.
        var changed = a2
        changed.state = .needsYou
        #expect(CodeMonitorBuilder.ordered([b1, changed, a1, c1], firstSeen: first, byCopy: true).map(\.id) == ordered.map(\.id))
        // With one copy running the copy plays no part: first seen, then the session id.
        #expect(CodeMonitorBuilder.ordered([b1, a2, a1, c1], firstSeen: first, byCopy: false).map(\.id)
                    == ["local_a1", "local_b1", "local_a2", "local_c1"])
        let unseen = CodeMonitorBuilder.ordered([tileSession("local_z", "Z"), tileSession("local_m", "M")], firstSeen: [:], byCopy: false)
        #expect(unseen.map(\.id) == ["local_m", "local_z"])
    }

    @Test func theFocusShowsItsCopiesAndEveryCopyUnderAll() {
        let a = tileSession("local_a", "A"), b = tileSession("local_b", "B", profile: .b), c = tileSession("local_c", "C", profile: .c)
        var settings = CodeSettings.withTestProfiles
        settings.focusProfiles = ["Acme": ["A"], "Globex": ["B"]]
        func shown(_ name: String, several: Bool = true) -> [String] {
            let focus = MonitorFocus.named(name, in: settings)
            return [a, b, c].filter { CodeMonitorBuilder.passes($0, focus: focus, severalCopies: several) }.map(\.id)
        }
        #expect(shown("all") == ["local_a", "local_b", "local_c"])
        #expect(shown("Acme") == ["local_a"])
        #expect(shown("Globex") == ["local_b"], "C shows under All only")
        // A focus the settings do not name shows every copy (as an unknown company key did).
        #expect(shown("Initech") == ["local_a", "local_b", "local_c"])
        // One copy running: every focus shows every session.
        #expect(shown("Globex", several: false) == ["local_a", "local_b", "local_c"])
        #expect(MonitorFocus.named("Globex", in: settings) == MonitorFocus(name: "Globex", letters: ["B"]))
        #expect(MonitorFocus.named("ALL", in: settings).isAll)
    }

    @Test func mediumAndSmallMonitorsGetTheirShortWords() {
        let todos = CodeSessionTodos(items: [.init(text: "a", status: .completed), .init(text: "b", status: .inProgress),
                                             .init(text: "c", status: .pending), .init(text: "d", status: .pending)])
        let working = item(tileSession("local_x", "X", state: .working, now: "running tests", todos: todos))
        #expect(working.statusCompact == "working · opus")
        #expect(working.compactLine == "working" && working.compactTone == nil)
        #expect(working.progress == 0.25)
        let done = item(tileSession("local_x", "X", state: .done, minutesAgo: 25))
        #expect(done.statusCompact == "done · 25 min" && done.progress == nil)
        let offers = item(tileSession("local_x", "X", offers: [tileOffer("a", number: 1, total: 2), tileOffer("b", number: 2, total: 2)]))
        #expect(offers.compactLine == "▶ 2" && offers.compactTone == .offer)
        #expect(offers.pip == CodeMonitorPip(symbol: "▶", count: 2, action: .openPeek))
        let fetch = item(tileSession("local_x", "X", offers: [tileOffer("scp x", commandClass: .fetchFile)]))
        #expect(fetch.compactLine == "⤓ 1" && fetch.pip?.symbol == "⤓")
        var book = CodeOfferRunBook()
        let entry = tileOffer("swift test")
        book.record(.finished(runID: UUID(), exitStatus: 1, seconds: 12), offer: entry.offer, sessionID: "local_x", at: tileNow)
        let ran = item(tileSession("local_x", "X", offers: [entry]), runs: book)
        #expect(ran.compactLine == "✕ exit 1" && ran.compactTone == .failed)
        // Hidden text hides offers on every size.
        let hidden = item(tileSession("local_x", "X", offers: [entry]), hide: true)
        #expect(hidden.pip == nil && hidden.compactLine == "done")
    }

    // MARK: Words and marks

    @Test func everyStateHasItsWordLEDAndGlow() {
        let expectations: [(CodeSessionState, UInt32, CodeMonitorLED.Form, Bool, UInt32?)] = [
            (.needsYou, CodeMonitorPalette.amber, .filled, false, CodeMonitorPalette.amber),
            (.problem, CodeMonitorPalette.red, .filled, false, CodeMonitorPalette.red),
            (.working, CodeMonitorPalette.working, .filled, true, nil),
            (.maybeNeedsYou, CodeMonitorPalette.amber, .filled, false, nil),
            (.quietUnfinished, CodeMonitorPalette.working, .filled, false, nil),
            (.reviewReady, CodeMonitorPalette.green, .filled, false, nil),
            (.done, CodeMonitorPalette.white, .filled, false, nil),
            (.doneNoSummary, CodeMonitorPalette.white, .ring, false, nil),
            (.unknown, CodeMonitorPalette.grey, .hollow, false, nil),
        ]
        for (state, color, form, pulses, glow) in expectations {
            let monitor = item(tileSession("local_x", "X", state: state))
            #expect(monitor.led == CodeMonitorLED(color: color, form: form, pulses: pulses), "\(state)")
            #expect(monitor.glow == glow, "\(state)")
            #expect(monitor.stateWord == state.word)
        }
        var stopped = tileSession("local_x", "X", state: .problem)
        stopped.stateWord = "stopped"
        #expect(item(stopped).status.hasPrefix("stopped · "))
    }

    @Test func theBottomBarReadsStateAgeAndModel() {
        #expect(item(tileSession("local_x", "X", state: .done, minutesAgo: 6)).status == "done · 6 min · opus")
        #expect(item(tileSession("local_x", "X", state: .done, minutesAgo: 6)).statusShort == "done · 6 min")
        #expect(item(tileSession("local_x", "X", state: .working, minutesAgo: 0.2)).status == "working · just now · opus")
        #expect(item(tileSession("local_x", "X", state: .reviewReady, model: "claude-sonnet-5-5", minutesAgo: 130)).status
                    == "review ready · 2 h · sonnet")
        #expect(item(tileSession("local_x", "X", state: .done, model: nil, minutesAgo: 6)).status == "done · 6 min")
    }

    @Test func aQuietFinishedSessionDimsAndSaysHowLong() {
        let quiet = item(tileSession("local_x", "X", state: .done, minutesAgo: 40, quiet: true))
        #expect(quiet.quiet)
        #expect(quiet.status == "done · quiet 40 min · opus")
        // An unfinished quiet turn keeps its own words and is not dimmed.
        let unfinished = item(tileSession("local_x", "X", state: .quietUnfinished, minutesAgo: 40, quiet: true))
        #expect(!unfinished.quiet)
        #expect(unfinished.status == "quiet · turn not finished · 40 min · opus")
    }

    @Test func workingShowsNowWithTodos() {
        let todos = CodeSessionTodos(items: [.init(text: "a", status: .completed), .init(text: "b", status: .completed),
                                             .init(text: "c", status: .inProgress), .init(text: "d", status: .pending)])
        let working = item(tileSession("local_x", "X", state: .working, tldr: "Old summary", now: "running tests", todos: todos))
        #expect(working.now == "Now: running tests · 2/4 todos")
        #expect(working.tldr == "Old summary")
        #expect(item(tileSession("local_x", "X", state: .done, now: "running tests")).now == nil)
    }

    @Test func profileMarksShowOnlyWhenMoreThanOneCopyRuns() {
        #expect(item(tileSession("local_x", "X")).profileLabel == nil)
        #expect(item(tileSession("local_x", "X"), profiles: true).profileLabel == "A · Claude")
        #expect(item(tileSession("local_x", "X", profile: .b), profiles: true).peek.profile == "B · Acme")
        #expect(item(tileSession("local_x", "X")).peek.profile == nil)
    }

    @Test func hideTextBlanksScreensToHeadlineAndState() {
        let session = tileSession("local_x", "Secret client deal", state: .needsYou, tldr: "the price is 4M", ask: "Approve?",
                                  offers: [tileOffer("open ~/x")])
        let hidden = item(session, hide: true)
        #expect(hidden.textHidden)
        #expect(hidden.headline == "Secret client deal")
        #expect(hidden.tldr == nil && hidden.ask == nil && hidden.nickname == nil && hidden.offer == nil && hidden.now == nil)
        #expect(hidden.status.hasPrefix("needs you"))
        #expect(hidden.peek.tldr == nil && hidden.peek.offers.isEmpty && hidden.peek.steps.isEmpty && hidden.peek.place == nil)
        #expect(hidden.peek.title == "Secret client deal")
        // `showText` false for one copy hides it for good.
        let perCopy = CodeMonitorBuilder.item(session, position: 1, total: 1,
                                              inputs: inputs([session], showText: ["A": false]))
        #expect(perCopy.textHidden && perCopy.tldr == nil)
    }

    @Test func sessionTextGoesThroughTheRenderer() {
        let session = tileSession("local_x", "evil\u{202E}title", nickname: "calm\u{200B}otter", tldr: "line one\nline two\u{0007}")
        let monitor = item(session)
        #expect(monitor.headline == "evil⟨U+202E⟩title")
        #expect(monitor.nickname == "calm⟨U+200B⟩otter")
        #expect(monitor.tldr == "line one line two⟨U+0007⟩")
    }

    @Test func theWindowChipAndClickComeFromTheParker() {
        let session = tileSession("local_x", "X")
        let parked = item(session, CodeWindowStatus(place: .parked(since: tileNow.addingTimeInterval(-12 * 60))))
        #expect(parked.chip == "in the pit 12 min" && parked.click == .restore)
        let busy = item(session, CodeWindowStatus(place: .onDesk, busy: .parking))
        #expect(busy.busy && busy.click == CodeWindowClick.none && busy.chip == "pitting…")
        let failed = item(session, CodeWindowStatus(place: .onDesk, problem: "couldn't pit (Claude didn't answer)"))
        #expect(failed.chipIsProblem && failed.chip == "couldn't pit (Claude didn't answer)")
        let unknown = item(session, nil)
        #expect(unknown.chip.isEmpty && unknown.click == CodeWindowClick.none)
    }

    // MARK: Peek content

    @Test func thePeekSaysWhereItRunsAndTheLastSteps() {
        let local = item(tileSession("local_x", "X", cwd: "/Users/alex/my project"))
        #expect(local.peek.place == "this Mac · ~/my project")
        #expect(local.peek.stateLine == "done · 6 min · opus · high · auto")
        #expect(local.peek.steps.map(\.words) == ["editing CodeMonitorView.swift", "running: swift test"])
        #expect(local.peek.steps.map(\.ago) == ["5 min ago", "1 min ago"])
        let ssh = item(tileSession("local_x", "X", place: .ssh, sshHost: "buildbox", cwd: "/home/buildbox/projects/x"))
        #expect(ssh.peek.place == "buildbox · ~/projects/x")
        let unknown = item(tileSession("local_x", "X", place: .unknown))
        #expect(unknown.peek.place == "where it runs is unknown")
        #expect(local.peek.link == "claude://claude.ai/epitaxy/local_x")
    }

    @Test func thePeekShowsUpToSixTodosAroundTheCurrentOne() {
        let todos = CodeSessionTodos(items: (1...10).map { .init(text: "step \($0)", status: $0 < 8 ? .completed : ($0 == 8 ? .inProgress : .pending)) })
        let monitor = item(tileSession("local_x", "X", state: .working, todos: todos))
        #expect(monitor.peek.todosTitle == "7 of 10 todos")
        #expect(monitor.peek.todos.count == 6)
        #expect(monitor.peek.todos.contains { $0.text == "step 8" && $0.mark == .current })
    }

    @Test func thePeekButtonsFollowTheWindow() {
        let session = tileSession("local_x", "X")
        #expect(item(session, CodeWindowStatus(place: .onDesk)).peek.windowButton == "Pit")
        #expect(item(session, CodeWindowStatus(place: .minimized)).peek.windowButton == "Back on track")
        #expect(item(session, CodeWindowStatus(place: .parked(since: tileNow))).peek.windowClick == .restore)
        #expect(item(session, CodeWindowStatus(place: .closed)).peek.windowButton == "Open in main window")
        #expect(item(session, CodeWindowStatus(place: .notMatched)).peek.windowButton == nil)
        #expect(item(session, CodeWindowStatus(place: .onDesk, busy: .parking)).peek.windowButton == nil)
    }

    @Test func thePeekListsTheOffersWithChipsAndCopyRules() {
        let offers = [tileOffer("scp 'alex@buildbox:/home/alex/drafts/release-notes.md' ~/Downloads/", number: 1, total: 3,
                                commandClass: .fetchFile, machine: .thisMac),
                      tileOffer("rm -rf build", number: 2, total: 3, commandClass: .risky),
                      tileOffer("echo \u{202E}x", number: 3, total: 3, commandClass: .blocked, block: .b1)]
        var session = tileSession("local_x", "X", offers: offers, place: .ssh, sshHost: "buildbox")
        session.offersNotShown = 4
        let rows = item(session).peek.offers
        #expect(rows.map(\.classChip) == ["Fetch file", "Risky", "Blocked"])
        #expect(rows.map(\.machineChip) == ["This Mac", "This Mac", "This Mac"])
        #expect(rows.map(\.canCopy) == [true, true, false])
        #expect(rows[2].firstLine == "echo ⟨U+202E⟩x")
        #expect(item(session).peek.offersNote == "3 of 7 commands; the rest are in the session")
    }
}

@Suite("Offer line and runs")
struct OfferWordsTests {
    @Test func oneOfferSaysItsClass() {
        func line(_ entry: CodeOfferEntry) -> String? { CodeOfferWords.line(offers: [entry], run: nil, now: tileNow)?.text }
        #expect(line(tileOffer("open ~/x")) == "▶ 1 command")
        #expect(line(tileOffer("rm -rf build", commandClass: .risky)) == "▶ 1 command · risky")
        #expect(line(tileOffer("uptime", commandClass: .forServer, machine: .server)) == "▶ 1 command · for the server")
        #expect(line(tileOffer("echo \u{202E}", commandClass: .blocked, block: .b1)) == "▶ 1 command · blocked: hidden characters")
        #expect(line(tileOffer("x", commandClass: .partlyRead)) == "▶ 1 command · partly read")
        #expect(line(tileOffer("ssh buildbox 'rm x'", commandClass: .otherMachine, machine: .remote(host: "buildbox")))
                    == "▶ 1 command · runs on buildbox")
        let fetch = FetchFileRequest(alias: "buildbox", replyUser: "alex", remotePath: "/home/alex/drafts/release-notes.md",
                                     destinationName: nil)
        #expect(line(tileOffer("scp …", commandClass: .fetchFile, fetch: fetch)) == "▶ Fetch release-notes.md")
        // One offer opens its sheet; the first command line shows dimmed on a large monitor.
        let single = CodeOfferWords.line(offers: [tileOffer("open ~/Downloads/x.pdf")], run: nil, now: tileNow)
        #expect(single?.action == .openSheet(CommandOffer.ID(sessionIndex: 1, replyUUID: "reply-1", number: 1)))
        #expect(single?.detail == "open ~/Downloads/x.pdf")
    }

    @Test func severalOffersCountTheirWorstClassesAndOpenThePeek() {
        let offers = [tileOffer("a", number: 1, total: 3), tileOffer("b", number: 2, total: 3, commandClass: .risky),
                      tileOffer("c", number: 3, total: 3, commandClass: .risky)]
        let line = CodeOfferWords.line(offers: offers, run: nil, now: tileNow)
        #expect(line?.text == "▶ 3 commands · 2 risky")
        #expect(line?.action == .openPeek)
        #expect(line?.count == 3)
    }

    @Test func runsShowOnTheLineFromTheSheetsEvents() {
        let entry = tileOffer("swift test")
        var book = CodeOfferRunBook()
        let run = UUID()
        book.record(.started(runID: run), offer: entry.offer, sessionID: "local_x", at: tileNow)
        #expect(CodeOfferWords.line(offers: [entry], run: book.latest["local_x"], now: tileNow)?.text == "running…")
        #expect(CodeOfferWords.line(offers: [entry], run: book.latest["local_x"], now: tileNow)?.action == .revealRun(run))
        book.record(.finished(runID: run, exitStatus: 0, seconds: 3.2), offer: entry.offer, sessionID: "local_x", at: tileNow)
        #expect(CodeOfferWords.line(offers: [entry], run: book.latest["local_x"], now: tileNow)?.text == "✓ exit 0 · 3 s")
        book.record(.finished(runID: run, exitStatus: 1, seconds: 12), offer: entry.offer, sessionID: "local_x", at: tileNow)
        #expect(CodeOfferWords.line(offers: [entry], run: book.latest["local_x"], now: tileNow)?.text == "✕ exit 1 · 12 s")
        book.record(.stopped(runID: run, signal: 2, seconds: 4), offer: entry.offer, sessionID: "local_x", at: tileNow)
        #expect(CodeOfferWords.line(offers: [entry], run: book.latest["local_x"], now: tileNow)?.text == "stopped")
        // "ran 4 min ago" for the same text from the same session.
        let later = tileNow.addingTimeInterval(4 * 60)
        #expect(book.ran(sessionID: "local_x", text: "swift test").map { CodeOfferWords.ranNote($0, now: later) } == "ran 4 min ago · stopped")
        #expect(book.ran(sessionID: "local_y", text: "swift test") == nil)
        // A copy or a cancel changes nothing.
        let before = book.latest["local_x"]
        book.record(.copied, offer: entry.offer, sessionID: "local_x", at: later)
        book.record(.cancelled, offer: entry.offer, sessionID: "local_x", at: later)
        #expect(book.latest["local_x"] == before)
    }

    @Test func fetchResultsAndRefusalsAreSaid() {
        let entry = tileOffer("scp x")
        var book = CodeOfferRunBook()
        book.record(.fetched(.saved(fileName: "release-notes.md", bytes: 18_000)), offer: entry.offer, sessionID: "s", at: tileNow)
        #expect(CodeOfferWords.line(offers: [entry], run: book.latest["s"], now: tileNow)?.text == "✓ In Downloads: release-notes.md")
        book.record(.fetched(.failed(reason: "no such file on buildbox")), offer: entry.offer, sessionID: "s", at: tileNow)
        #expect(CodeOfferWords.line(offers: [entry], run: book.latest["s"], now: tileNow)?.text == "✕ fetch failed: no such file on buildbox")
        book.record(.refused(reason: "the folder changed after you looked; review again"), offer: entry.offer, sessionID: "s", at: tileNow)
        #expect(CodeOfferWords.line(offers: [entry], run: book.latest["s"], now: tileNow)?.text
                    == "✕ not started: the folder changed after you looked; review again")
        // A refusal fades after 30 s: the offer shows again.
        #expect(CodeOfferWords.line(offers: [entry], run: book.latest["s"], now: tileNow.addingTimeInterval(31))?.text == "▶ 1 command")
    }

    @Test func aResultOutlivesItsStaleOfferForAWhile() {
        let entry = tileOffer("swift test")
        var book = CodeOfferRunBook()
        book.record(.finished(runID: UUID(), exitStatus: 0, seconds: 61), offer: entry.offer, sessionID: "s", at: tileNow)
        #expect(CodeOfferWords.line(offers: [], run: book.latest["s"], now: tileNow.addingTimeInterval(60))?.text == "✓ exit 0 · 1 min 1 s")
        #expect(CodeOfferWords.line(offers: [], run: book.latest["s"], now: tileNow.addingTimeInterval(31 * 60)) == nil)
        // A new reply's offers take the line over.
        let next = tileOffer("npm test", reply: "reply-next")
        #expect(CodeOfferWords.line(offers: [next], run: book.latest["s"], now: tileNow)?.text == "▶ 1 command")
    }

    @Test func runRecordsHoldAHashNeverTheText() {
        let hash = CodeOfferRunBook.hash("security find-generic-password -s X -w")
        #expect(hash.count == 16)
        #expect(hash.allSatisfy { $0.isHexDigit })
        #expect(CodeOfferWords.duration(3.4) == "3 s")
        #expect(CodeOfferWords.duration(125) == "2 min 5 s")
        #expect(CodeOfferWords.duration(3_700) == "1 h 1 min")
    }
}
