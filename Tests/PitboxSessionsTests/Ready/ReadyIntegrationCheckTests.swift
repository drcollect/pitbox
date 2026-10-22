import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The Ready list in the block's Ready slot, the unread dot in the marks slot, the summary hooks, the desk tags'
/// suppression and the card actions, through the real block, model and root view.
@MainActor
@Suite("Ready in the block (integration check)", .serialized)
struct ReadyIntegrationCheckTests {
    let folder = SeamFolder("ready-integration")
    let clock = ManualClock(readyNow)

    init() {
        CodeTileLog.enabled = false
        CodeLog.enabled = false
    }

    @Test func theBlockFillsTheSlotsAndWiresTheHooks() async throws {
        let h = TileHarness()
        let opened = Shared<[URL]>([])
        let block = PitboxBlock(model: h.model, dashboardOpener: CodeDashboardOpener { opened.value.append($0) })
        let suppressed = Shared<[DeskTagSuppressed]>([])
        block.onReadySuppressionChange = { suppressed.value.append($0) }
        let scheduler = ReadyScheduler()
        block.enableReady(memory: readyStore(folder, clock: clock),
                            environment: CodeReadyEnvironment(clock: { tileNow }, schedule: scheduler.schedule))
        let ready = try #require(h.model.ready)

        let earlier = tileOffer("ls -la", session: 1, reply: "older")
        var parked = tileSession("local_s1", "Toy Cube · checkout", index: 1, offers: [tileOffer("echo ok", session: 1)])
        parked.earlierOffers = [earlier]
        parked.unread = true
        parked.finished = CodeFinishedMark(replyUUID: "f1", at: tileNow.addingTimeInterval(-60), ranSeconds: 900)
        parked.dashboard = CodeDashboard(handle: "toy-cube", site: .test, firstSeen: tileNow.addingTimeInterval(-3600))
        h.parker.parkedSessionIDs = ["local_s1"]
        h.parker.statuses = ["local_s1": CodeWindowStatus(place: .parked(since: tileNow))]
        h.set([parked], onDesk: false)

        // The unread dot in the chip slot; the Ready counts on the bucket badge (the latest reply's offer and the
        // earlier one).
        let marks = try #require(h.model.snapshot.monitors.first?.marks)
        #expect(marks.contains { $0.place == .cornerDot && $0.id == nil })
        #expect(ready.counts(for: "local_s1") == (commands: 2, files: 0))

        // A block of 12 rows (the panel's height): the list in the Ready slot; the summary counts its Finished item.
        block.rows = 12
        let view = try #require(block.makeView() as? CodeMonitorsTileView)
        #expect(h.model.tileRows == 12)
        let list = try #require(view.readyAccessory as? CodeReadyListView)
        let summary = try #require(view.summaryAccessory as? CodeSummaryAccessory)
        #expect(list.accessoryHeight(forWidth: 992) > 0)
        // Buckets come first: laid out, the list starts below the last bucket, not at the top.
        view.frame = CGRect(x: 0, y: 0, width: 1002, height: 2000)
        let lastBucket = try #require(view.placedBuckets.last)
        #expect(list.frame.minY >= lastBucket.area.maxY && list.frame.minY > 0 && !list.isHidden)
        #expect(summary.justFinished?([parked]) == 1 && summary.ownActivityOnly().isEmpty)

        // Dismiss: the desk tags hear of it at once; the badge follows on the next turn of the main queue.
        let key = try #require(ready.list.snapshot.entries.first { $0.item.offerID == parked.offers[0].id }?.item.id)
        ready.list.press(.dismiss(key))
        #expect(suppressed.value.last?.offers.contains(parked.offers[0].id) == true)
        await settle()
        #expect(h.model.snapshot.sections.first?.counts.commands == 1)

        // The earlier reply's Review… opens the sheet; its run comes back to the list as a result row.
        ready.list.press(.openSheet(earlier.id, sessionID: "local_s1"))
        let sheet = try #require(h.presenter.presented.last)
        #expect(sheet.offer.id == earlier.id)
        sheet.events(.started(runID: UUID()))
        #expect(ready.list.snapshot.entries.contains { if case .result = $0.style { return true } else { return false } })

        // Show monitor, the dashboard through its opener, Open window (restore) through the parker.
        ready.list.press(.showMonitor(sessionID: "local_s1"))
        #expect(h.model.revealRequest?.sessionID == "local_s1")
        ready.list.press(.openDashboard(sessionID: "local_s1"))
        #expect(opened.value.map(\.absoluteString) == ["https://dash.example.com/dash/toy-cube/"])
        ready.list.press(.openWindow(sessionID: "local_s1"))
        #expect(h.parker.performed.last.map { $0.0 == .restore && $0.1 == "local_s1" } == true)
        #expect(summary.justFinished?([parked]) == 0, "Open window closed the Finished item")
    }
}
