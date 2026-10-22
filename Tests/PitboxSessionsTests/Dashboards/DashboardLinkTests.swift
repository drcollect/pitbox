import Foundation
import Testing
@testable import PitboxSessions

/// The dashboard link grammar: invented handles in the forms measured in real transcripts.
@Suite("Dashboard links")
struct DashboardLinkTests {
    @Test func handlesFollowTheGrammar() {
        for handle in ["polar-shore", "quiet-fjord-lane", "3f2a9c1b", "a", String(repeating: "a", count: 64)] {
            #expect(CodeDashboard.isValidHandle(handle), "\(handle)")
        }
        for handle in ["Polar-Shore", "-x", "x-", "a--b", "", String(repeating: "a", count: 65), "polar_shore", "polar.shore"] {
            #expect(!CodeDashboard.isValidHandle(handle), "\(handle)")
        }
    }

    static let accepted: [String] = [
        "Dashboard: https://dash.example.com/dash/polar-shore/",
        "Dashboard: dash.example.com/dash/polar-shore/",
        "See https://dash.example.com/dash/polar-shore for progress",
        "Open https://dash.example.com/dash/polar-shore/index.html now",
        "Report at dash.example.com/dash/polar-shore/report.html.",
        "The dashboard is at `https://dash.example.com/dash/polar-shore/`.",
        "**https://dash.example.com/dash/polar-shore/**",
        "[dashboard](https://dash.example.com/dash/polar-shore/)",
        "[dash.example.com/dash/polar-shore/](https://example.invalid/elsewhere)",
        "Live at https://dash.example.com/dash/polar-shore/.",
        "Live at https://dash.example.com/dash/polar-shore.",
        "(https://dash.example.com/dash/polar-shore/?refresh=10#top)",
        "“dash.example.com/dash/polar-shore/”",
        "<https://dash.example.com/dash/polar-shore/>",
    ]

    @Test(arguments: accepted)
    func acceptedForms(_ text: String) {
        #expect(DashboardLink.handles(in: text, sites: .test) == ["polar-shore"], "\(text)")
        // The address is rebuilt from the handle, never taken from the text.
        #expect(DashboardWords.url(handle: "polar-shore", site: .test)?.absoluteString == "https://dash.example.com/dash/polar-shore/")
        // No site configured: the feature is off, nothing is found.
        #expect(DashboardLink.handles(in: text, sites: .none).isEmpty, "\(text)")
    }

    static let refused: [String] = [
        "http://dash.example.com/dash/polar-shore/",
        "https://dash.example.com.evil.test/dash/polar-shore/",
        "https://dash.example.com@evil.test/dash/polar-shore/",
        "https://evil.test@dash.example.com/dash/polar-shore/",
        "https://dash.example.com:8443/dash/polar-shore/",
        "https://dash.example.com/dash/../x/",
        "https://dash.example.com/dash/Polar-Shore/",
        "https://dash.example.com/dash/polar--shore/",
        "https://evil.dash.example.com/dash/polar-shore/",
        "https://Dash.example.com/dash/polar-shore/",
        "ftp://dash.example.com/dash/polar-shore/",
        "https://example.invalid/dash.example.com/dash/polar-shore/",
        "https://dash.example.com/dash/polar-shore/assets/x.png",
        "https://dash.example.com/dash/polar-shore.html",
        "https://dash.example.com/dash/polar%2Dshore/",
        "https://dash.example.com/dash/polar-shoré/",
        "https://dash.example.com/dash/",
    ]

    @Test(arguments: refused)
    func refusedForms(_ text: String) {
        #expect(DashboardLink.handles(in: text, sites: .test).isEmpty, "\(text)")
    }

    @Test func theNewestLinkInATextWins() {
        let text = "Old: https://dash.example.com/dash/polar-shore/ — new: https://dash.example.com/dash/amber-reef/"
        #expect(DashboardLink.handles(in: text, sites: .test) == ["polar-shore", "amber-reef"])
        #expect(DashboardLink.newestLink(in: text, sites: .test)?.handle == "amber-reef")
        #expect(DashboardWords.url(handle: "Polar", site: .test) == nil && DashboardWords.url(handle: "a/../b", site: .test) == nil)
    }

    // MARK: Sites from the settings file

    @Test func everySiteIsAnExactAllowlistEntryAndLinksKeepTheirOrder() throws {
        let other = try #require(CodeDashboardSite(host: "board.example.org", pathPrefix: "/"))
        let sites = CodeDashboardSites([.test, other])
        let text = "A: board.example.org/amber-reef/ then https://dash.example.com/dash/polar-shore/ and "
            + "https://x.board.example.org/quiet-fjord/"
        let links = DashboardLink.links(in: text, sites: sites)
        #expect(links.map(\.handle) == ["amber-reef", "polar-shore"])
        #expect(links.map(\.site.key) == ["board.example.org/", "dash.example.com/dash/"])
        #expect(other.url(handle: "amber-reef")?.absoluteString == "https://board.example.org/amber-reef/")
    }

    @Test func aHandlePatternNarrowsTheGrammar() throws {
        let site = try #require(CodeDashboardSite(host: "dash.example.com", pathPrefix: "/dash/", handlePattern: "[a-z]+-[a-z]+"))
        let sites = CodeDashboardSites([site])
        #expect(DashboardLink.handles(in: "dash.example.com/dash/polar-shore/ dash.example.com/dash/3f2a9c1b/",
                                      sites: sites) == ["polar-shore"])
        // The pattern never widens the grammar: upper case stays refused even when it matches.
        let wide = try #require(CodeDashboardSite(host: "dash.example.com", pathPrefix: "/dash/", handlePattern: ".*"))
        #expect(!wide.isValidHandle("Polar") && wide.isValidHandle("polar"))
    }

    @Test func badSitesAreRefused() {
        for (host, prefix) in [("Dash.example.com", "/"), ("localhost", "/"), ("dash.example.com:8443", "/"),
                               ("dash..example.com", "/"), ("-dash.example.com", "/"), ("dash.example.com", "dash/"),
                               ("dash.example.com", "/dash"), ("dash.example.com", "/../"), ("dash.example.com", "//"),
                               ("user@dash.example.test", "/")] {
            #expect(CodeDashboardSite(host: host, pathPrefix: prefix) == nil, "\(host) \(prefix)")
        }
        #expect(CodeDashboardSite(host: "dash.example.com", pathPrefix: "/", handlePattern: "(") == nil)
        #expect(CodeDashboardSites(CodeSettings()).isEmpty, "no site by default: the feature is off")
    }
}
