import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

@MainActor
@Suite("Block model")
struct TileModelTests {
    init() { CodeTileLog.enabled = false }

    @Test func startingWiresTheSourceAndTheParker() {
        let h = TileHarness()
        #expect(h.source.starts == 1 && h.parker.starts == 1)
        #expect(h.source.onChange != nil && h.parker.onChange != nil)
        h.model.stop()
        #expect(h.source.stops == 1 && h.parker.stops == 1)
    }

    @Test func monitorsAreWatchedAndHandedToTheParkerInTheirFixedOrder() {
        let h = TileHarness()
        h.source.runningProfiles = [.a, .b]
        let processes = [ClaudeProcessInfo(pid: 501, profile: .a, bundlePath: "/x/a/Claude.app"),
                         ClaudeProcessInfo(pid: 502, profile: .b, bundlePath: "/x/b/Claude.app")]
        h.source.runningProcesses = processes
        h.parker.parkedSessionIDs = ["local_parked"]
        h.set([tileSession("local_b1", "B", profile: .b), tileSession("local_a1", "A"),
               tileSession("local_parked", "Parked", popout: false), tileSession("local_plain", "Plain", popout: false)])
        #expect(h.parker.updates.last == ["local_a1", "local_parked", "local_b1"])
        // The window side gets the data side's processes (pids for the join, app paths for the deep link).
        #expect(h.parker.processUpdates.last == processes)
        #expect(h.source.watched.last == ["local_a1", "local_parked", "local_b1"])
        #expect(h.model.snapshot.monitors.map(\.id) == ["local_a1", "local_parked", "local_b1"])
        #expect(h.model.snapshot.header.count == 3)
        // An unchanged watched set is not sent again.
        let sent = h.source.watched.count
        h.model.rebuild()
        #expect(h.source.watched.count == sent)
    }

    @Test func aMonitorSeenLaterGoesAfterTheOthersOfItsCopy() {
        let h = TileHarness()
        h.set([tileSession("local_x", "X")])
        h.set([tileSession("local_new", "New"), tileSession("local_x", "X")])
        #expect(h.model.snapshot.monitors.map(\.id) == ["local_x", "local_new"])
    }

    /// The tests' focus names: Acme shows copy A, Globex copy B (`focusProfiles`).
    static var focusSettings: CodeSettings {
        var settings = CodeSettings.withTestProfiles
        settings.focusProfiles = ["Acme": ["A"], "Globex": ["B"]]
        return settings
    }

    @Test func withOneCopyEveryFocusShowsEverything() {
        let h = TileHarness()
        h.set([tileSession("local_a", "A")])
        h.model.setFocus(.named("Globex", in: Self.focusSettings))
        #expect(h.model.snapshot.monitors.map(\.id) == ["local_a"])
    }

    @Test func theFocusFiltersAndTheEmptyStateSaysWhy() {
        let h = TileHarness()
        h.source.runningProfiles = [.a, .c]
        h.set([tileSession("local_a", "A"), tileSession("local_c", "C", profile: .c)])
        h.model.setFocus(.named("Globex", in: Self.focusSettings))
        #expect(h.model.snapshot.monitors.isEmpty)
        #expect(h.model.snapshot.emptyTitle == "Nothing for Globex")
        h.model.setFocus(.named("Acme", in: Self.focusSettings))
        #expect(h.model.snapshot.monitors.map(\.id) == ["local_a"])
        h.model.setFocus(.all)
        #expect(h.model.snapshot.monitors.map(\.id) == ["local_a", "local_c"])
        h.set([])
        #expect(h.model.snapshot.emptyTitle == "No Code pop-outs")
        h.source.runningProfiles = []
        #expect(h.model.snapshot.emptyTitle == "Claude is not running")
    }

    @Test func profileMarksAndTheBannerFollowTheSource() {
        let h = TileHarness()
        h.set([tileSession("local_a", "A")])
        #expect(!h.model.snapshot.showsProfiles)
        h.source.runningProfiles = [.a, .b]
        #expect(h.model.snapshot.showsProfiles)
        #expect(h.model.snapshot.monitors.first?.profileLabel == "A · Claude")
        h.source.banner = "Claude's session files changed (Claude 2.5). Showing titles only."
        #expect(h.model.snapshot.banner == "Claude's session files changed (Claude 2.5). Showing titles only.")
    }

    // MARK: The fold rail's counts (the `attention` message, docs/DOCK_PROTOCOL.md §5.11)

    @Test func theRailCountsNeedYouFinishedAndRunning() throws {
        let h = TileHarness()
        h.set([tileSession("local_a", "A", state: .needsYou), tileSession("local_b", "B", state: .working)])
        #expect(h.attention.last == CodeAttentionCounts(needsYou: 1, finished: 0, running: 1))
        // Problem asks too; done work with an open Finished item counts as finished.
        var done = tileSession("local_c", "C", state: .done)
        done.finished = CodeFinishedMark(replyUUID: "f1", at: tileNow, ranSeconds: 600)
        h.set([tileSession("local_a", "A", state: .needsYou), tileSession("local_b", "B", state: .problem), done])
        #expect(h.attention.last == CodeAttentionCounts(needsYou: 2, finished: 1, running: 0))
        // Nobody asks any more: zero.
        h.set([tileSession("local_a", "A", state: .done), tileSession("local_b", "B", state: .done)])
        #expect(h.attention.last == CodeAttentionCounts())
        #expect(h.model.snapshot.header.needYou == 0)
    }

    @Test func aMonitorTheFocusHidesIsNotCounted() {
        let h = TileHarness()
        h.source.runningProfiles = [.a, .b]
        h.set([tileSession("local_a", "A"), tileSession("local_b", "B", profile: .b)])
        h.model.setFocus(.named("Acme", in: Self.focusSettings))
        h.set([tileSession("local_a", "A"), tileSession("local_b", "B", profile: .b, state: .needsYou)])
        #expect(h.attention.last?.needsYou == 0)
        // Switching the focus to it counts it.
        h.model.setFocus(.all)
        #expect(h.attention.last?.needsYou == 1)
    }

    @Test func theBlockHandsCountsOutAtMostOnceASecond() {
        var now: TimeInterval = 100
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        var sent: [CodeAttentionCounts] = []
        let throttle = CodeAttentionThrottle(interval: 1, clock: { now }, schedule: { scheduled.append(($0, $1)) },
                                             deliver: { sent.append($0) })
        throttle.note(CodeAttentionCounts(needsYou: 1))
        #expect(sent == [CodeAttentionCounts(needsYou: 1)], "the first change goes out at once")
        throttle.note(CodeAttentionCounts(needsYou: 1))
        #expect(sent.count == 1 && scheduled.isEmpty, "unchanged counts are not sent again")
        now += 0.2
        throttle.note(CodeAttentionCounts(needsYou: 2))
        throttle.note(CodeAttentionCounts(needsYou: 3, running: 1))
        #expect(sent.count == 1 && scheduled.count == 1 && abs(scheduled[0].0 - 0.8) < 0.001, "one call at the second's end")
        now += 0.8
        scheduled.removeFirst().1()
        #expect(sent.last == CodeAttentionCounts(needsYou: 3, running: 1), "with the newest counts")
        // A change that goes back to what was sent before the timer fires sends nothing.
        now += 0.1
        throttle.note(CodeAttentionCounts(needsYou: 4))
        throttle.note(CodeAttentionCounts(needsYou: 3, running: 1))
        now += 0.9
        scheduled.removeFirst().1()
        #expect(sent.count == 2)
    }

    @Test func theBlocksCallbackGetsTheCountsAsATuple() {
        let h = TileHarness()
        let block = PitboxBlock(model: h.model)
        var got: [String] = []
        block.onAttentionChanged = { counts in got.append("\(counts.needsYou) \(counts.finished) \(counts.running)") }
        #expect(got == ["0 0 0"], "the current counts once it is set on a started block")
        h.set([tileSession("local_a", "A", state: .needsYou)])
        #expect(got.count == 1, "a second change within the second waits for the timer")
    }

    // MARK: The sheet

    @Test func theOfferLineOpensTheSheetAndShowsTheRunsResult() throws {
        let h = TileHarness()
        let entry = tileOffer("swift test", commandClass: .risky)
        h.set([tileSession("local_a", "A", offers: [entry])])
        let anchor = CGRect(x: 4100, y: 300, width: 323, height: 219)
        h.model.openSheet(entry.id, sessionID: "local_a", anchor: anchor)
        let sheet = try #require(h.presenter.presented.first)
        #expect(sheet.offer == entry.offer)
        #expect(sheet.anchor == anchor)
        let run = UUID()
        sheet.events(.started(runID: run))
        #expect(h.model.snapshot.monitors.first?.offer?.text == "running…")
        sheet.events(.finished(runID: run, exitStatus: 0, seconds: 3))
        #expect(h.model.snapshot.monitors.first?.offer?.text == "✓ exit 0 · 3 s")
        #expect(h.model.snapshot.monitors.first?.peek.offers.first?.ranNote == "ran just now · exit 0")
        // The block never runs anything itself: only `present` was called.
        #expect(h.presenter.presented.count == 1)
    }

    @Test func anOpenSheetIsToldWhenItsOfferGoesStale() {
        let h = TileHarness()
        let entry = tileOffer("open ~/x")
        h.set([tileSession("local_a", "A", offers: [entry])])
        h.model.openSheet(entry.id, sessionID: "local_a", anchor: .zero)
        // A new user message: the reply's offers are gone.
        h.set([tileSession("local_a", "A", state: .working, offers: [])])
        #expect(h.presenter.stale == [entry.id])
        h.model.rebuild()
        #expect(h.presenter.stale == [entry.id])
    }

    @Test func anOpenSheetIsToldWhenTheSessionRepliedSince() {
        // The offer stays, with a supersession; the sheet switches Run off and adds R22.
        let h = TileHarness()
        let entry = tileOffer("open ~/x")
        h.set([tileSession("local_a", "A", offers: [entry])])
        h.model.openSheet(entry.id, sessionID: "local_a", anchor: .zero)
        var later = entry
        later.offer.supersession = CommandOffer.Supersession(newerReplies: 1, latestAt: tileNow,
                                                             replies: [.init(at: tileNow, origin: .human, head: "Done.")],
                                                             sessionIsWorking: false)
        h.set([tileSession("local_a", "A", offers: [later])])
        #expect(h.presenter.superseded.map(\.0) == [entry.id])
        #expect(h.presenter.stale.isEmpty)
        h.model.rebuild()
        #expect(h.presenter.superseded.count == 1)
        // A further reply is news again.
        later.offer.supersession?.newerReplies = 2
        h.set([tileSession("local_a", "A", offers: [later])])
        #expect(h.presenter.superseded.map(\.1.newerReplies) == [1, 2])
    }

    @Test func aClosedSheetIsNotToldAboutStaleness() {
        let h = TileHarness()
        let entry = tileOffer("open ~/x")
        h.set([tileSession("local_a", "A", offers: [entry])])
        h.model.openSheet(entry.id, sessionID: "local_a", anchor: .zero)
        h.presenter.presented.first?.events(.cancelled)
        h.set([tileSession("local_a", "A", offers: [])])
        #expect(h.presenter.stale.isEmpty)
    }

    @Test func peekCopiesAreConcealedAndRefusedForHiddenCharacters() {
        let h = TileHarness()
        let plain = tileOffer("security add-generic-password -U -a \"$USER\" -s X -w", number: 1, total: 2)
        let hidden = tileOffer("echo \u{202E}x", number: 2, total: 2, commandClass: .blocked, block: .b1)
        h.set([tileSession("local_a", "A", offers: [plain, hidden])])
        #expect(h.model.copyOffer(plain.id, sessionID: "local_a"))
        #expect(!h.model.copyOffer(hidden.id, sessionID: "local_a"))
        #expect(h.pasteboard.copies.count == 1)
        #expect(h.pasteboard.copies.first?.text == plain.offer.text)
        #expect(h.pasteboard.copies.first?.privately == true)
        #expect(h.model.copyLink(sessionID: "local_a"))
        #expect(h.pasteboard.copies.last?.text == "claude://claude.ai/epitaxy/local_a")
    }

    // MARK: Windows

    @Test func aScreenClickDoesWhatTheWindowAllows() {
        let h = TileHarness()
        h.set([tileSession("local_a", "A"), tileSession("local_b", "B")])
        h.parker.statuses["local_b"] = CodeWindowStatus(place: .parked(since: tileNow))
        h.model.clickScreen("local_a")
        h.model.clickScreen("local_b")
        h.parker.statuses["local_a"] = CodeWindowStatus(place: .onDesk, busy: .parking)
        h.model.clickScreen("local_a")
        #expect(h.parker.performed.map(\.0) == [.park, .restore])
        #expect(h.parker.performed.map(\.1) == ["local_a", "local_b"])
    }

    @Test func parkAllDoneParksOnlyFinishedMonitorsOnTheDesk() async {
        let h = TileHarness()
        h.set([tileSession("local_done", "Done", state: .done), tileSession("local_review", "Review", state: .reviewReady),
               tileSession("local_work", "Work", state: .working), tileSession("local_parked", "Parked", state: .done)])
        h.parker.statuses["local_parked"] = CodeWindowStatus(place: .parked(since: tileNow))
        #expect(h.model.snapshot.header.parkAllDone == 2)
        h.parker.parkAllResult = CodeParkAllResult(parked: 1, skippedOtherSpace: 1)
        h.model.parkAllDone()
        for _ in 0..<50 where h.parker.parkAllCalls.isEmpty || h.model.snapshot.header.note == nil { await Task.yield() }
        #expect(h.parker.parkAllCalls == [["local_done", "local_review"]])
        #expect(h.model.snapshot.header.note == "1 into the pit · 1 on another Space, not pitted")
    }

    @Test func hidingTheStripOrArrangingClosesTheSheetAndStopsThePass() {
        let h = TileHarness()
        let owner = NSObject()
        h.model.setViewVisible(true, owner: owner)
        #expect(h.parker.active.last == true)
        #expect(h.source.stripVisible.last == true)
        h.model.setStripVisible(false)
        #expect(h.parker.active.last == false)
        #expect(h.source.stripVisible.last == false)
        #expect(h.presenter.dismissals == 1)
        h.model.setStripVisible(true)
        #expect(h.parker.active.last == true)
        let generation = h.model.overlayGeneration
        PitboxBlock(model: h.model).dismissOverlays()   // the shell folds or hides the block
        #expect(h.presenter.dismissals == 2)
        #expect(h.model.overlayGeneration == generation + 1)
        h.model.stopObserving(owner)
        #expect(h.parker.active.last == false)
    }

    @Test func hideTextIsOneSwitchForEveryMonitor() {
        let h = TileHarness()
        h.set([tileSession("local_a", "A", tldr: "secret"), tileSession("local_b", "B", tldr: "secret too")])
        h.model.toggleHideText()
        #expect(h.model.snapshot.monitors.allSatisfy { $0.textHidden && $0.tldr == nil })
        #expect(h.model.snapshot.header.hideText)
        h.model.toggleHideText()
        #expect(h.model.snapshot.monitors.allSatisfy { !$0.textHidden })
    }

    @Test func statusCountsHoldNoText() throws {
        let h = TileHarness()
        let entry = tileOffer("make")
        h.set([tileSession("local_a", "Secret", state: .needsYou, offers: [entry]), tileSession("local_b", "Other")])
        h.parker.statuses["local_b"] = CodeWindowStatus(place: .parked(since: tileNow))
        h.model.openSheet(entry.id, sessionID: "local_a", anchor: .zero)
        h.presenter.presented.first?.events(.started(runID: UUID()))
        let status = h.model.status()
        #expect(status == CodeMonitorsStatus(monitors: 2, parked: 1, needYou: 1, offers: 1, runningCommands: 1))
        let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        #expect(!json.contains("Secret") && !json.contains("make"))
    }
}
