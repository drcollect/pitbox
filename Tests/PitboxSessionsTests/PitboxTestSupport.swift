import Foundation
@testable import PitboxSessions

// Invented Claude copies and dashboard site for the tests. Only the default copy (A, folder "Claude") is built into the
// app; B and C stand for copies a user lists in the settings file's `profiles`.

extension CodeSettings.Profile {
    /// A second copy, "B · Acme" in `~/Library/Application Support/Claude-Work`.
    static let testB = CodeSettings.Profile(folder: "Claude-Work", letter: "B", name: "Acme")
    /// A third copy, "C · Globex" in `~/Library/Application Support/Claude-Lab`.
    static let testC = CodeSettings.Profile(folder: "Claude-Lab", letter: "C", name: "Globex")
}

extension CodeProfile {
    /// The listed copy B of the tests.
    static let b = CodeProfile(.testB)
    /// The listed copy C of the tests.
    static let c = CodeProfile(.testC)
}

extension CodeSettings {
    /// Default settings that list the tests' copies B and C.
    static var withTestProfiles: CodeSettings {
        var settings = CodeSettings()
        settings.profiles = [.testB, .testC]
        return settings
    }
}

extension CodeProfiles {
    /// The default copy and the tests' B and C.
    static let test = CodeProfiles(listed: [.testB, .testC])
}

extension CodeDashboardSite {
    /// The tests' dashboard site: `https://dash.example.com/dash/<handle>/`.
    static let test: CodeDashboardSite = {
        guard let site = CodeDashboardSite(host: "dash.example.com", pathPrefix: "/dash/") else {
            preconditionFailure("the test dashboard site must be valid")
        }
        return site
    }()
}

extension CodeDashboardSites {
    /// The tests' one dashboard site.
    static let test = CodeDashboardSites([.test])
}
