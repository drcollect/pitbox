import Darwin
import Foundation
import PitboxKit

/// The dashboards deriver, order `CodeDeriveOrder.dashboards` (300): it fills `dashboard`.
///
/// - Every pass reads the digest's assistant texts and `dashboard-builder` prompts (`DashboardTracker.sightings`); the
///   newest link wins, a stored one stands while the digest has none.
/// - `code-memory.json` keeps `dashboard {handle, firstSeen, lastBuilderCallAt}` for the session's life (this deriver
///   is its only writer) and the scan's mark `dashboardScan` (only the scan writes it).
/// - **The one-time scan** (a link posted long ago is seldom in the tail): when a followed session has no dashboard and
///   no scan mark, the whole transcript is scanned once for the link (`TranscriptMarkerScan`) on the scanner's own
///   queue; its mark (with what it found) brings the engine back here through the store's change notice. Cancelled when
///   the session stops being followed.
/// - Nothing is fetched; the address is rebuilt from the checked handle (`CodeDashboard.url`).
///
/// Logs: `dashboard found session=#3 source=tail|scan`, and the scanner's `dashboard scan session=#3 bytes=… ms=…
/// found=… stop=…` (labels and numbers only, never a handle or a URL).
final class DashboardDeriver: CodeSessionDeriver {
    let label = "dashboards"
    let order = CodeDeriveOrder.dashboards

    private let scanner: DashboardScanning
    private let sites: CodeDashboardSites
    private var scans: [String: DashboardScanTicket] = [:]
    private var caches: [String: DashboardTextCache] = [:]

    /// A deriver for the configured `sites` whose one-time scans run on `scanner` (the production one by default).
    init(sites: CodeDashboardSites, scanner: DashboardScanning = DashboardScanner()) {
        self.sites = sites
        self.scanner = scanner
    }

    func derive(_ input: CodeDeriveInput, into fields: inout CodeDerivedFields) {
        let id = input.sessionID
        var cache = caches[id] ?? DashboardTextCache()
        let sightings = DashboardTracker.sightings(in: input.digest, sites: sites, cache: &cache)
        caches[id] = cache
        let stored: DashboardRecord? = input.memory.read(.dashboard, session: id)
        let mark: DashboardScanRecord? = input.memory.read(.dashboardScan, session: id)
        let merged = DashboardTracker.merge(stored: stored, scan: mark, digest: sightings, sites: sites, now: input.now)
        if let merged, merged != stored {
            input.memory.write(.dashboard, session: id, value: merged)
            if merged.handle != stored?.handle || merged.site != stored?.site {
                let source = sightings.links.last?.isSameLink(handle: merged.handle, site: merged.site) == true ? "tail" : "scan"
                CodeLog.info("dashboard found session=#\(input.snapshot.index) source=\(source)")
            }
        }
        if let merged, let site = sites.site(key: merged.site) {
            fields.dashboard = CodeDashboard(handle: merged.handle, site: site, firstSeen: merged.firstSeen,
                                             lastBuilderCallAt: merged.lastBuilderCallAt)
        }
        // The one-time scan: only while nothing is known and it never ran (its mark says so).
        if mark != nil {
            scans[id] = nil
        } else if merged == nil, scans[id] == nil, let transcript = input.transcript {
            scans[id] = scanner.start(sessionID: id, index: input.snapshot.index, transcript: transcript,
                                      owner: input.owner, memory: input.memory, sites: sites)
        }
    }

    func sessionLeft(_ sessionID: String) {
        scans.removeValue(forKey: sessionID)?.cancel()
        caches[sessionID] = nil
    }

    /// Tests: the sessions with a scan started and not yet marked.
    var scanningSessions: Set<String> { Set(scans.keys) }
}

public extension CodeDeriverSet {
    /// Dashboards: the dashboard of each followed session (`dashboard`) on the configured `sites`, with the
    /// one-time scan of the whole transcript. Register it with the other sets, built once at start from the settings:
    /// `engine.register(… + .dashboards(sites: CodeDashboardSites(settings)) + …, memory: memory)`. No site (the
    /// default): no deriver at all, the feature is off.
    static func dashboards(sites: CodeDashboardSites) -> CodeDeriverSet {
        sites.isEmpty ? CodeDeriverSet() : CodeDeriverSet(perSession: [DashboardDeriver(sites: sites)])
    }
}
