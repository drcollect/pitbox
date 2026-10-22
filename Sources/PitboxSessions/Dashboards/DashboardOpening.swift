import Foundation
import PitboxKit

/// Opens a session's dashboard in the default browser through a closure the
/// composition root injects, `CodeDashboardOpener { NSWorkspace.shared.open($0) }`. The address is always rebuilt from
/// the checked site and handle (`https://<host><pathPrefix><handle>/` through `URLComponents`), never taken from session
/// text; the app never fetches the page. Callers open only on an armed click (`DashboardOpenArming`). Logs
/// `result opened session=#3 kind=dashboard`.
public struct CodeDashboardOpener {
    private let openURL: @MainActor (URL) -> Void

    /// An opener that hands the rebuilt address to `openURL` (the default browser in the app, a recorder in tests).
    public init(openURL: @escaping @MainActor (URL) -> Void) {
        self.openURL = openURL
    }

    /// Opens `dashboard` of the session with local index `sessionIndex`. False when the handle fails the grammar.
    @MainActor @discardableResult
    public func open(_ dashboard: CodeDashboard, sessionIndex: Int) -> Bool {
        open(handle: dashboard.handle, site: dashboard.site, sessionIndex: sessionIndex)
    }

    /// Opens the dashboard of `handle` on `site`, checked again here. False when it fails the grammar.
    @MainActor @discardableResult
    public func open(handle: String, site: CodeDashboardSite, sessionIndex: Int) -> Bool {
        guard let url = site.url(handle: handle) else {
            CodeLog.warn("result refused session=#\(sessionIndex) kind=dashboard")
            return false
        }
        openURL(url)
        CodeLog.info("result opened session=#\(sessionIndex) kind=dashboard")
        return true
    }
}

/// The dashboard's words: the app's own text around a checked handle.
enum DashboardWords {
    /// The address, rebuilt from a handle that passes the site's grammar.
    static func url(handle: String, site: CodeDashboardSite) -> URL? { site.url(handle: handle) }

    /// "dash.example.com/dash/polar-shore/" (the list's address, without the scheme).
    static func address(_ dashboard: CodeDashboard) -> String { "\(dashboard.site.key)\(dashboard.handle)/" }

    /// The tooltip: the full address.
    static func tooltip(_ dashboard: CodeDashboard) -> String { dashboard.url?.absoluteString ?? "dashboard" }

    /// "since 22:40 · updated 23:14", or "since 22:40" before any builder call was seen.
    static func times(_ dashboard: CodeDashboard, clock: CodeClockFormat) -> String {
        var words = "since \(clock.string(dashboard.firstSeen))"
        if let updated = dashboard.lastBuilderCallAt { words += " · updated \(clock.string(updated))" }
        return words
    }

    /// The peek's row as one line: "▦ Open dashboard · since 22:40 · updated 23:14".
    static func peekLine(_ dashboard: CodeDashboard, clock: CodeClockFormat) -> String {
        "▦ Open dashboard · " + times(dashboard, clock: clock)
    }

    /// The list's second line: "dash.example.com/dash/polar-shore/ · updated 23:14" ("since 22:40" before any builder
    /// call); with Hide text the address reads "dashboard".
    static func listLine(_ dashboard: CodeDashboard, hideText: Bool, clock: CodeClockFormat) -> String {
        let address = hideText ? "dashboard" : self.address(dashboard)
        if let updated = dashboard.lastBuilderCallAt { return address + " · updated " + clock.string(updated) }
        return address + " · since " + clock.string(dashboard.firstSeen)
    }

    static let button = "▦ Dashboard"
    static let openButton = "▦ Open dashboard"
    static let open = "Open"
}
