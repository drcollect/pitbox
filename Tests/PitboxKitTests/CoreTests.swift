import Testing
import Foundation
import CoreGraphics
@testable import PitboxKit

@Test func gridMetricsOn1280PointStrip() {
    #expect(GridMetrics.columns(forStripWidth: 1280) == 4)
    #expect(abs(GridMetrics.cellWidth(forStripWidth: 1280) - 303) < 0.001)
    #expect(GridMetrics.rowHeight == 69)
    #expect(GridMetrics.gutter == 12)
}

@Test func gridClampsColumnsInNarrowStrip() {
    #expect(GridMetrics.columns(forStripWidth: 420) == 1)
    #expect(GridMetrics.cellWidth(forStripWidth: 420) < 420)
}

@Test func jsonValueRoundTripAndFoundationBridge() throws {
    let v: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": ["d": 2.5]]
    let data = try JSONEncoder().encode(v)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == v)
    let obj = try JSONSerialization.jsonObject(with: data)
    #expect(JSONValue(foundation: obj) == v)
    #expect(v["b"]?[0]?.boolValue == true)
}

@Test func screenSpaceRoundTrip() {
    let r = CGRect(x: 3840, y: 40, width: 1280, height: 1300)
    let q = ScreenSpace.quartz(fromAppKit: r, primaryHeight: 1440)
    #expect(q.minY == 1440 - r.maxY)
    #expect(ScreenSpace.appKit(fromQuartz: q, primaryHeight: 1440) == r)
}

@Test func pathsFollowTheTestOverride() {
    // scripts/test.sh sets PITBOX_APP_SUPPORT, so tests never touch the real folders.
    let override = ProcessInfo.processInfo.environment["PITBOX_APP_SUPPORT"] ?? ""
    if !override.isEmpty {
        #expect(Paths.appSupport.path == URL(fileURLWithPath: override).path)
        #expect(Paths.logsDir.path.hasPrefix(Paths.appSupport.path))
        #expect(Paths.cachesDir.path.hasPrefix(Paths.appSupport.path))
    }
    #expect(Paths.dockSocketPath.hasSuffix("/dock.sock"))
    #expect(Paths.settingsFile.lastPathComponent == "settings.json")
}

@Test func identityHasNoHostName() {
    #expect(AppIdentity.displayName == "Pitbox")
    #expect(AppIdentity.defaultBundleID == "io.github.drcollect.pitbox")
}
