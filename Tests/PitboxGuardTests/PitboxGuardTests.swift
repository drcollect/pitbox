import ApplicationServices
import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxGuard

@Suite("Fight tracker")
struct FightTrackerTests {
    private func tracker() -> FightTracker<Int> {
        FightTracker(threshold: 3, window: 10, cooldown: 60, maxCooldown: 900)
    }

    @Test func threeFightsInTheWindowStartACooldown() {
        var t = tracker()
        #expect(t.record(1, now: 0, countsAsFight: true) == nil)
        #expect(t.record(1, now: 4, countsAsFight: true) == nil)
        #expect(t.record(1, now: 8, countsAsFight: true) == 68)
        #expect(t.cooldownEnd(1, now: 30) == 68)
        #expect(t.cooldownEnd(1, now: 68) == nil)
        #expect(t.coolingDownCount(now: 30) == 1)
        #expect(t.nextCooldownEnd(after: 30) == 68)
        #expect(t.cooldownEnd(2, now: 30) == nil)
    }

    @Test func spreadOutCorrectionsAreNotAFight() {
        var t = tracker()
        for time in stride(from: 0.0, through: 110, by: 11) {
            #expect(t.record(1, now: time, countsAsFight: true) == nil)
        }
    }

    @Test func userCausedCorrectionsCountOnlyTowardTheHardLimit() {
        var t = tracker()
        for time in 0..<5 { #expect(t.record(1, now: Double(time), countsAsFight: false) == nil) }
        #expect(t.record(1, now: 5, countsAsFight: false) == 65, "six corrections in 10 s, whatever caused them")
        var spread = tracker()
        for time in stride(from: 0.0, through: 60, by: 2.5) {
            #expect(spread.record(1, now: time, countsAsFight: false) == nil, "at most five within any 10 s")
        }
    }

    @Test func repeatedFightsDoubleTheCooldownUpToTheCap() {
        var t = tracker()
        var now = 0.0
        var lengths: [Double] = []
        for _ in 0..<6 {
            _ = t.record(1, now: now, countsAsFight: true)
            _ = t.record(1, now: now + 1, countsAsFight: true)
            if let end = t.record(1, now: now + 2, countsAsFight: true) { lengths.append(end - (now + 2)); now = end + 1 }
        }
        #expect(lengths == [60, 120, 240, 480, 900, 900])
    }

    @Test func aLongQuietPeriodResetsTheEscalation() {
        var t = tracker()
        for time in [0.0, 1, 2] { _ = t.record(1, now: time, countsAsFight: true) }
        for time in [70.0, 71, 72] { _ = t.record(1, now: time, countsAsFight: true) }
        let later = 72 + 120 + 1900.0
        _ = t.record(1, now: later, countsAsFight: true)
        _ = t.record(1, now: later + 1, countsAsFight: true)
        #expect(t.record(1, now: later + 2, countsAsFight: true) == later + 2 + 60)
    }

    @Test func pruneAndForget() {
        var t = tracker()
        _ = t.record(1, now: 0, countsAsFight: true)
        _ = t.record(2, now: 0, countsAsFight: true)
        t.forget(1)
        #expect(t.entries[1] == nil)
        t.prune(now: 5000)
        #expect(t.entries.isEmpty)
    }
}

@Suite("Window policy")
struct WindowPolicyTests {
    private let base = WindowInfo(pid: 1, frame: CGRect(x: 100, y: 100, width: 800, height: 600), role: "AXWindow",
                                  subrole: "AXStandardWindow", minimized: false, fullScreen: false)

    private func reason(_ change: (inout WindowInfo) -> Void) -> String? {
        var info = base
        change(&info)
        return WindowPolicy.ineligibility(of: info, options: GuardOptions(), displays: [Fixture.main])
    }

    @Test func standardWindowsAndDialogsAreManaged() {
        #expect(reason { _ in } == nil)
        #expect(reason { $0.subrole = "AXDialog" } == nil)
    }

    @Test func everythingElseIsLeftAlone() {
        #expect(reason { $0.subrole = "AXFloatingWindow" } == "subrole AXFloatingWindow")
        #expect(reason { $0.subrole = "AXSystemDialog" } != nil)
        #expect(reason { $0.subrole = "AXUnknown" } != nil)
        #expect(reason { $0.subrole = nil } == "subrole none")
        #expect(reason { $0.role = "AXSheet" } == "role AXSheet")
        #expect(reason { $0.minimized = true } == "minimized")
        #expect(reason { $0.fullScreen = true } == "full screen")
        #expect(reason { $0.frame = Fixture.main.frame } == "covers its display")
        #expect(reason { $0.frame = CGRect(x: 9000, y: 0, width: 100, height: 100) } == "on no display")
        #expect(reason { $0.frame = CGRect(x: 0, y: 0, width: 0, height: 100) } == "empty frame")
    }
}

@Suite("Parsing Accessibility and window-server values")
struct ParsingTests {
    @Test func windowInfoFromAccessibilityValues() throws {
        var point = CGPoint(x: 10, y: 20)
        var size = CGSize(width: 300, height: 200)
        var error = AXError.attributeUnsupported
        let position = try #require(AXValueCreate(.cgPoint, &point))
        let extent = try #require(AXValueCreate(.cgSize, &size))
        let missing = try #require(AXValueCreate(.axError, &error))
        let values: [AnyObject] = ["AXWindow" as CFString, "AXStandardWindow" as CFString, position, extent,
                                   kCFBooleanTrue, missing]
        let info = AXParsing.windowInfo(pid: 42, values: values)
        #expect(info == WindowInfo(pid: 42, frame: CGRect(x: 10, y: 20, width: 300, height: 200), role: "AXWindow",
                                   subrole: "AXStandardWindow", minimized: true, fullScreen: false))
    }

    @Test func missingPositionOrSizeMeansNoInfo() throws {
        var size = CGSize(width: 300, height: 200)
        var error = AXError.noValue
        let extent = try #require(AXValueCreate(.cgSize, &size))
        let missing = try #require(AXValueCreate(.axError, &error))
        let values: [AnyObject] = ["AXWindow" as CFString, missing, missing, extent, kCFBooleanFalse, missing]
        #expect(AXParsing.windowInfo(pid: 1, values: values) == nil)
        #expect(AXParsing.windowInfo(pid: 1, values: []) == nil)
        #expect(AXParsing.frame(values: [extent, extent]) == nil, "a size is not a position")
    }

    @Test func windowServerEntries() {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 400)
        let entry: [String: Any] = [
            kCGWindowNumber as String: 7, kCGWindowOwnerPID as String: 123, kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0, kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
        #expect(AXParsing.onScreenWindow(from: entry)
                == OnScreenWindow(windowID: 7, pid: 123, bounds: bounds, layer: 0, alpha: 1))
        var noNumber = entry
        noNumber[kCGWindowNumber as String] = nil
        #expect(AXParsing.onScreenWindow(from: noNumber) == nil)
        var noPID = entry
        noPID[kCGWindowOwnerPID as String] = 0
        #expect(AXParsing.onScreenWindow(from: noPID) == nil)
        var badBounds = entry
        badBounds[kCGWindowBounds as String] = "nope"
        #expect(AXParsing.onScreenWindow(from: badBounds) == nil)
    }

    @Test func windowServerStateOfOneWindow() {
        let visible: [String: Any] = [kCGWindowLayer as String: 0, kCGWindowIsOnscreen as String: true]
        #expect(AXParsing.serverState(from: visible) == ServerWindowState(layer: 0, onScreen: true))
        let floating: [String: Any] = [kCGWindowLayer as String: 3]
        #expect(AXParsing.serverState(from: floating) == ServerWindowState(layer: 3, onScreen: false))
        #expect(AXParsing.serverState(from: [:]) == nil)
    }

    @Test func accessibilityErrorsMapToWhatTheGuardReactsTo() {
        #expect(AXFailure(.invalidUIElement) == .invalidElement)
        #expect(AXFailure(.cannotComplete) == .cannotComplete)
        #expect(AXFailure(.apiDisabled) == .apiDisabled)
        #expect(AXFailure(.attributeUnsupported) == .unsupported)
        #expect(AXFailure(.notImplemented) == .unsupported)
        #expect(AXFailure(.failure) == .other(AXError.failure.rawValue))
    }

    @Test func chromiumAndElectronDetection() throws {
        #expect(ChromiumDetector.isChromium(bundleID: "com.google.Chrome", bundleURL: nil))
        #expect(ChromiumDetector.isChromium(bundleID: "com.google.Chrome.app.abcdef", bundleURL: nil))
        #expect(!ChromiumDetector.isChromium(bundleID: "com.apple.TextEdit",
                                             bundleURL: URL(fileURLWithPath: "/nonexistent/TextEdit.app")))
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("guard-test-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(ChromiumDetector.isChromium(bundleID: "com.example.chat", bundleURL: bundle))
    }
}

@Suite("Options and status")
struct OptionsAndStatusTests {
    @Test func defaultsAreSane() {
        let options = GuardOptions()
        #expect(options.reconcileInterval == 1)
        #expect(options.managedSubroles == ["AXStandardWindow", "AXDialog"])
        #expect(options.minimumWindowSize == CGSize(width: 320, height: 200))
        #expect(options.manualAccessibility == .whenWindowsMissing)
        #expect(!options.dryRun)
        #expect(options.exemptBundleIDs.contains(AppIdentity.bundleID))
    }

    @Test func environmentTurnsOnDryRunAndAddsExemptions() {
        let options = GuardOptions.fromEnvironment(["PITBOX_GUARD_DRYRUN": "1",
                                                    "PITBOX_GUARD_EXEMPT": " com.a.b , com.c.d,, "])
        #expect(options.dryRun)
        #expect(options.exemptBundleIDs.isSuperset(of: ["com.a.b", "com.c.d", "com.apple.dock"]))
        #expect(!options.exemptBundleIDs.contains(""))
        #expect(!GuardOptions.fromEnvironment(["PITBOX_GUARD_DRYRUN": "0"]).dryRun)
        #expect(!GuardOptions.fromEnvironment([:]).dryRun)
    }

    @Test func statusJSONHasTheDocumentedKeys() {
        let status = GuardStatus(trusted: true, running: true, paused: false, dryRun: true, regionCount: 1,
                                 correctedCount: 5, fightingWindows: 1, cannotFitWindows: 2, observedApps: 12)
        let json = status.json
        #expect(json["trusted"] == .bool(true))
        #expect(json["running"] == .bool(true))
        #expect(json["paused"] == .bool(false))
        #expect(json["regions"] == .number(1))
        #expect(json["corrected"] == .number(5))
        #expect(json["fighting"] == .number(1))
        #expect(json["dryRun"] == .bool(true))
        #expect(json["cannotFit"] == .number(2))
        #expect(json["observedApps"] == .number(12))
        #expect(json["lastError"] == .null)
    }
}

// The facade is tested without `start()`: starting would use the real Accessibility API (see FakeAX.swift).
@Suite("WindowGuard facade (never started)")
@MainActor
struct WindowGuardFacadeTests {
    @Test func existingRegionHandlerIsKeptAndStatusFollowsTheStrips() {
        let source = FakeRegionSource()
        var shellCalls = 0
        source.onRegionsChanged = { shellCalls += 1 }
        let guardian = WindowGuard(regions: source)
        var seen: [GuardStatus] = []
        guardian.onStatusChange = { seen.append($0) }
        source.regions = [Fixture.rightStrip]
        source.onRegionsChanged?()
        #expect(shellCalls == 1)
        #expect(guardian.status.regionCount == 1)
        #expect(seen.last?.regionCount == 1)
    }

    @Test func pauseStopAndOptionsBeforeStartAreHarmless() {
        let guardian = WindowGuard(regions: FakeRegionSource())
        guardian.setPaused(true)
        #expect(guardian.status.paused)
        guardian.stop()
        #expect(!guardian.status.running)
        guardian.setPaused(false)
        #expect(!guardian.status.paused)
        guardian.options.dryRun = true
        #expect(guardian.status.dryRun)
    }
}
