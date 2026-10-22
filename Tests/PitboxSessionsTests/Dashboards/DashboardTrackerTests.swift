import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// A scanner that records what it was asked and runs nothing (or runs the scan in place).
final class RecordingScanner: DashboardScanning, @unchecked Sendable {
    struct Start: Equatable {
        var sessionID: String
        var index: Int
        var transcript: CarefulPath
    }

    private let lock = NSLock()
    private var startsSeen: [Start] = []
    private(set) var tickets: [DashboardScanTicket] = []
    /// Run the real scan on the caller's thread.
    var runInPlace = false

    func start(sessionID: String, index: Int, transcript: CarefulPath, owner: uid_t,
               memory: CodeMemoryStore, sites: CodeDashboardSites) -> DashboardScanTicket {
        let ticket = DashboardScanTicket()
        lock.withLock {
            startsSeen.append(Start(sessionID: sessionID, index: index, transcript: transcript))
            tickets.append(ticket)
        }
        if runInPlace {
            DashboardScanner.scan(sessionID: sessionID, index: index, transcript: transcript, owner: owner, memory: memory,
                                  sites: sites, ticket: ticket, limits: TranscriptMarkerScan.Limits(), wallClock: { fixtureNow })
        }
        return ticket
    }

    var starts: [Start] { lock.withLock { startsSeen } }
}

/// Dashboards from the digest, the store and the scan's mark.
@Suite("Dashboard tracker", .serialized)
struct DashboardTrackerTests {
    let t0 = fixtureNow.addingTimeInterval(-7200)
    let link = "https://dash.example.com/dash/polar-shore/"
    /// The test site's key, as records name it.
    let key = CodeDashboardSite.test.key

    init() { CodeLog.enabled = false }

    @Test func onlyTheSessionsOwnWritingCounts() {
        var cache = DashboardTextCache()
        let digest = digestOf([
            Line.user("Have a look at https://dash.example.com/dash/user-said/", uuid: "u1", at: t0),
            SeamLine.bash("cat notes", description: "read notes", id: "toolu_b1", uuid: "b1", at: t0.addingTimeInterval(10)),
            SeamLine.result("toolu_b1", uuid: "r1", at: t0.addingTimeInterval(11),
                            content: "notes: https://dash.example.com/dash/tool-said/"),
            Line.text("Built it: \(link)", uuid: "a1", stop: "tool_use", at: t0.addingTimeInterval(20)),
            SeamLine.agent("dashboard-builder", id: "toolu_d1", uuid: "d1", at: t0.addingTimeInterval(30),
                           prompt: "Rebuild https://dash.example.com/dash/amber-reef/ with the new tasks"),
            SeamLine.result("toolu_d1", uuid: "r2", at: t0.addingTimeInterval(31), content: "launched",
                            toolUseResult: ["status": "async_launched", "agentId": "agentd1"]),
            Line.text("Rebuilding.", uuid: "a2", at: t0.addingTimeInterval(40)),
            SeamLine.noticeTurn(noticeText(taskID: "agentd1") + " https://dash.example.com/dash/notice-said/",
                                uuid: "n1", at: t0.addingTimeInterval(600)),
            Line.text("Done.", uuid: "a3", at: t0.addingTimeInterval(610)),
        ])
        let found = DashboardTracker.sightings(in: digest, sites: .test, cache: &cache)
        #expect(found.links.map(\.handle) == ["polar-shore", "amber-reef"], "never user text, tool results or notices")
        #expect(found.lastBuilderCallAt == t0.addingTimeInterval(30))
        let merged = DashboardTracker.merge(stored: nil, scan: nil, digest: found, sites: .test, now: fixtureNow)
        #expect(merged == DashboardRecord(handle: "amber-reef", site: key, firstSeen: t0.addingTimeInterval(30),
                                          lastBuilderCallAt: t0.addingTimeInterval(30)), "the newest handle wins")
        // A builder prompt in another subagent type is no source.
        let other = digestOf([Line.user("x", uuid: "u1", at: t0),
                              SeamLine.agent("general-purpose", id: "toolu_g", uuid: "g1", at: t0, prompt: link)])
        #expect(DashboardTracker.sightings(in: other, sites: .test, cache: &cache).links.isEmpty)
    }

    @Test func storedScannedAndTailedDashboardsMerge() {
        let stored = DashboardRecord(handle: "polar-shore", site: key, firstSeen: t0, lastBuilderCallAt: t0.addingTimeInterval(60))
        // Nothing in the tail: the stored one stands.
        #expect(DashboardTracker.merge(stored: stored, scan: nil, digest: DigestDashboards(), sites: .test, now: fixtureNow) == stored)
        // The same handle again, and a newer builder call: firstSeen stays, updated moves.
        let again = DigestDashboards(links: [DashboardSighting(handle: "polar-shore", site: key, at: t0.addingTimeInterval(900))],
                                     lastBuilderCallAt: t0.addingTimeInterval(1200))
        #expect(DashboardTracker.merge(stored: stored, scan: nil, digest: again, sites: .test, now: fixtureNow)
            == DashboardRecord(handle: "polar-shore", site: key, firstSeen: t0, lastBuilderCallAt: t0.addingTimeInterval(1200)))
        // Another handle: it switches, from its own first sighting; a builder call before it reads as that moment.
        let switched = DigestDashboards(links: [DashboardSighting(handle: "polar-shore", site: key, at: t0.addingTimeInterval(900)),
                                                DashboardSighting(handle: "amber-reef", site: key, at: t0.addingTimeInterval(1000)),
                                                DashboardSighting(handle: "amber-reef", site: key, at: t0.addingTimeInterval(1100))])
        #expect(DashboardTracker.merge(stored: stored, scan: nil, digest: switched, sites: .test, now: fixtureNow)
            == DashboardRecord(handle: "amber-reef", site: key, firstSeen: t0.addingTimeInterval(1000),
                               lastBuilderCallAt: t0.addingTimeInterval(1000)))
        // Only the scan knows: its handle and times.
        let scan = DashboardScanRecord(at: fixtureNow, found: true, bytes: 90 << 20, handle: "quiet-fjord",
                                       linkAt: t0.addingTimeInterval(-3600), builderAt: t0.addingTimeInterval(-60))
        #expect(DashboardTracker.merge(stored: nil, scan: scan, digest: DigestDashboards(), sites: .test, now: fixtureNow)
            == DashboardRecord(handle: "quiet-fjord", site: key, firstSeen: t0.addingTimeInterval(-3600),
                               lastBuilderCallAt: t0.addingTimeInterval(-60)))
        // A scan's handle that fails the grammar never becomes a dashboard.
        var bad = scan
        bad.handle = "Quiet-Fjord"
        #expect(DashboardTracker.merge(stored: nil, scan: bad, digest: DigestDashboards(), sites: .test, now: fixtureNow) == nil)
        #expect(DashboardTracker.merge(stored: nil, scan: DashboardScanRecord(at: fixtureNow, found: false, bytes: 1),
                                       digest: DigestDashboards(), sites: .test, now: fixtureNow) == nil)
    }

    @Test func aForkShowsItsParentsDashboardUntilItPostsItsOwn() {
        var cache = DashboardTextCache()
        let copied = [Line.user("Parent's ask", uuid: "u1", at: t0), Line.text("Parent's board: \(link)", uuid: "a1", at: t0)]
        let fork = digestOf(copied + [Line.user("Fork's ask", uuid: "u2", at: t0.addingTimeInterval(60)),
                                      Line.text("Working.", uuid: "a2", at: t0.addingTimeInterval(70))])
        #expect(DashboardTracker.sightings(in: fork, sites: .test, cache: &cache).links.last?.handle == "polar-shore")
        let own = digestOf(copied + [Line.user("Fork's ask", uuid: "u2", at: t0.addingTimeInterval(60)),
                                     Line.text("Mine: dash.example.com/dash/birch-lane/", uuid: "a2",
                                               at: t0.addingTimeInterval(70))])
        #expect(DashboardTracker.sightings(in: own, sites: .test, cache: &cache).links.last?.handle == "birch-lane")
    }

    @Test func theDeriverKeepsTheDashboardAcrossARestartAndScansOnlyWhenNothingIsKnown() throws {
        let clock = ManualClock(fixtureNow)
        let memory = ProgressMemory(clock: clock)
        let scanner = RecordingScanner()
        let deriver = DashboardDeriver(sites: .test, scanner: scanner)
        let transcript = try #require(CarefulPath(root: "/nonexistent-root", components: ["t.jsonl"]))
        let withLink = digestOf([Line.user("Go", uuid: "u1", at: t0), Line.text("Board: \(link)", uuid: "a1", at: t0)])
        let fields = derived(deriver, deriveInput(progressSnapshot(), digest: withLink, now: clock.now, memory: memory.store,
                                                  transcript: transcript))
        let dashboard = try #require(fields.dashboard)
        #expect(dashboard.handle == "polar-shore" && dashboard.firstSeen == t0 && dashboard.lastBuilderCallAt == nil)
        #expect(dashboard.url?.absoluteString == link && scanner.starts.isEmpty, "the tail knew it: no scan")
        #expect(DashboardWords.times(dashboard, clock: clockUTC) == "since 12:37")

        // A restart: a new store on the file, a fresh deriver, a tail without the link.
        let store = memory.restarted()
        let fresh = DashboardDeriver(sites: .test, scanner: scanner)
        let tail = digestOf([Line.user("More", uuid: "u9", at: fixtureNow), Line.text("ok", uuid: "a9", at: fixtureNow)])
        let after = derived(fresh, deriveInput(progressSnapshot(), digest: tail, now: clock.now, memory: store,
                                               transcript: transcript))
        #expect(after.dashboard?.handle == "polar-shore" && scanner.starts.isEmpty)

        // A session with nothing known starts exactly one scan, and none once its mark is stored.
        let other = progressSnapshot(sessionB, index: 4)
        _ = derived(fresh, deriveInput(other, digest: tail, now: clock.now, memory: store, transcript: transcript))
        _ = derived(fresh, deriveInput(other, digest: tail, now: clock.now, memory: store, transcript: transcript))
        #expect(scanner.starts == [RecordingScanner.Start(sessionID: sessionB, index: 4, transcript: transcript)])
        store.write(.dashboardScan, session: sessionB, value: DashboardScanRecord(at: clock.now, found: false, bytes: 10))
        _ = derived(fresh, deriveInput(other, digest: tail, now: clock.now, memory: store, transcript: transcript))
        #expect(fresh.scanningSessions.isEmpty && scanner.starts.count == 1)
        // Unfollowed while a scan runs: it is cancelled.
        let third = progressSnapshot(sessionC, index: 5)
        _ = derived(fresh, deriveInput(third, digest: tail, now: clock.now, memory: store, transcript: transcript))
        fresh.sessionLeft(sessionC)
        #expect(scanner.tickets.last?.isCancelled == true)
    }

    @Test func aDashboardCountsOnlyWhileItsSiteIsConfigured() throws {
        let other = try #require(CodeDashboardSite(host: "board.example.org", pathPrefix: "/"))
        // A record from before sites were named belongs to the first site.
        let old = DashboardRecord(handle: "polar-shore", firstSeen: t0)
        #expect(DashboardTracker.merge(stored: old, scan: nil, digest: DigestDashboards(), sites: .test, now: fixtureNow)
            == DashboardRecord(handle: "polar-shore", site: key, firstSeen: t0))
        // A record of a site no longer in the settings is not shown; neither is anything without a site at all.
        let elsewhere = DashboardRecord(handle: "polar-shore", site: other.key, firstSeen: t0)
        #expect(DashboardTracker.merge(stored: elsewhere, scan: nil, digest: DigestDashboards(), sites: .test,
                                       now: fixtureNow) == nil)
        #expect(DashboardTracker.merge(stored: old, scan: nil, digest: DigestDashboards(), sites: .none, now: fixtureNow) == nil)
        // The same handle on another site is another link: it switches.
        let stored = DashboardRecord(handle: "polar-shore", site: key, firstSeen: t0)
        let moved = DigestDashboards(links: [DashboardSighting(handle: "polar-shore", site: other.key,
                                                               at: t0.addingTimeInterval(500))])
        #expect(DashboardTracker.merge(stored: stored, scan: nil, digest: moved, sites: CodeDashboardSites([.test, other]),
                                       now: fixtureNow)
            == DashboardRecord(handle: "polar-shore", site: other.key, firstSeen: t0.addingTimeInterval(500)))
        // No site configured: no deriver at all.
        #expect(CodeDeriverSet.dashboards(sites: .none).perSession.isEmpty)
        #expect(CodeDeriverSet.dashboards(sites: .test).perSession.count == 1)
    }
}
