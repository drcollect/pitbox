import AppKit
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The block as the shell and the app drive it (`PitboxBlock`): its inputs (rows, strip width, focus, visibility,
/// settings, host wake words) and the one-time pit hint. Fakes only.
@MainActor
@Suite("The block", .serialized)
struct BlockTests {
    init() {
        CodeTileLog.enabled = false
        CodeLog.enabled = false
    }

    @Test func rowsComeFromTheShellAndNeverDropBelowOne() {
        let h = TileHarness()
        let block = PitboxBlock(model: h.model)
        #expect(block.rows == 10, "the default until the shell sets the panel's rows")
        block.rows = 14
        #expect(h.model.tileRows == 14 && block.rows == 14)
        block.rows = 0
        #expect(block.rows == 1)
    }

    @Test func theRootViewHoldsTheSummaryAndReadsTheStripWidthFromTheShell() throws {
        let h = TileHarness()
        let block = PitboxBlock(model: h.model)
        let view = try #require(block.makeView() as? CodeMonitorsTileView)
        #expect(view.summaryAccessory is CodeSummaryAccessory)
        #expect(view.readyAccessory == nil, "no Ready list before enableReady")
        // Alone: 2 × 323 + 12 + 2 × 16 = 690 pt; the view holds the two columns (658 pt).
        view.frame = CGRect(x: 0, y: 0, width: 658, height: 700)
        block.stripWidthProvider = { 690 }
        #expect(abs(view.stripColumn - 323) < 0.01)
        // Docked beside a host whose cell is 301.4 pt: the shell hands the width of two such cells.
        view.frame = CGRect(x: 0, y: 0, width: 2 * 301.4 + 12, height: 700)
        block.stripWidthProvider = { 2 * 301.4 + 12 + 32 }
        #expect(abs(view.stripColumn - 301.4) < 0.01)
        // No width, or one that does not fit the view: the view's own width decides.
        block.stripWidthProvider = nil
        #expect(abs(view.stripColumn - 301.4) < 0.01)
        block.stripWidthProvider = { 5000 }
        #expect(abs(view.stripColumn - 301.4) < 0.01)
    }

    @Test func aFocusNameMapsThroughTheSettings() {
        var settings = CodeSettings.withTestProfiles
        settings.focusProfiles = ["Globex": ["B"]]
        let h = TileHarness(settings: settings)
        let block = PitboxBlock(model: h.model)
        h.source.runningProfiles = [.a, .b]
        h.set([tileSession("local_a", "A"), tileSession("local_b", "B", profile: .b)])
        block.setFocus(named: "Globex")
        #expect(block.focus == MonitorFocus(name: "Globex", letters: ["B"]))
        #expect(h.model.snapshot.monitors.map(\.id) == ["local_b"])
        block.setFocus(nil)
        #expect(block.focus.isAll && h.model.snapshot.monitors.count == 2)
        block.setFocus(named: "Unknown")
        #expect(block.focus.isAll, "an unknown name shows every copy")
    }

    @Test func hostWakeWordsJoinNeverSayBeforeAndAfterReady() {
        var settings = CodeSettings()
        settings.neverSay = ["Nova"]
        let h = TileHarness(settings: settings)
        let block = PitboxBlock(model: h.model)
        block.setHostWakeWords(["Orion"])
        let folder = SeamFolder("block-wake")
        defer { withExtendedLifetime(folder) {} }
        block.enableReady(memory: readyStore(folder, clock: ManualClock(tileNow)),
                          environment: CodeReadyEnvironment(clock: { tileNow }, schedule: ReadyScheduler().schedule))
        #expect(h.model.ready?.alerts.neverSay == ["Nova", "Orion"])
        block.setHostWakeWords([])
        #expect(h.model.ready?.alerts.neverSay == ["Nova"], "the host left: only the file's words")
    }

    @Test func settingsUpdatesReachTheMonitorsAndHiddenOrFoldedClosesTheOverlays() {
        let h = TileHarness()
        let block = PitboxBlock(model: h.model)
        h.set([tileSession("local_a", "A")])
        var settings = CodeSettings()
        settings.look = .rows
        block.update(settings: settings)
        #expect(h.model.snapshot.look == .rows && block.settings.look == .rows)
        let generation = h.model.overlayGeneration
        block.dismissOverlays()
        #expect(h.model.overlayGeneration == generation + 1 && h.presenter.dismissals == 1)
        block.setStripVisible(false)
        #expect(h.parker.active.last == false)
        block.deskTagsActive = true
        #expect(h.model.needsWindowPassOffTile)
    }

    @Test func aListedCopysColourMarksItsMonitors() {
        var listed = CodeSettings.Profile.testB
        listed.colour = 0x3366CC
        let profile = CodeProfile(listed)
        #expect(profile.colour == 0x3366CC && profile.name == "B · Acme")
        let h = TileHarness()
        h.source.runningProfiles = [.a, profile]
        h.set([tileSession("local_b", "B", profile: profile)])
        #expect(h.model.snapshot.monitors.first?.profileColour == 0x3366CC)
        #expect(CodeMonitorPalette.profileColor(letter: "B", colour: 0x3366CC) == ThemeColor.srgb(0x3366CC))
        #expect(CodeMonitorPalette.profileColor(letter: "Q") == CodeMonitorPalette.color(CodeMonitorPalette.grey))
    }

    // MARK: The one-time pit hint

    @Test func theFirstPitStopShowsTheHintOnceAndItIsRemembered() throws {
        let folder = SeamFolder("pit-hint")
        let url = folder.file("block-state.json")
        let h = TileHarness()
        h.model.pitHint = CodePitHint(url: url)
        // In the pit since before this run (parked before a restart): no new pit stop, no hint.
        h.parker.parkedSessionIDs = ["local_old"]
        h.parker.statuses["local_old"] = CodeWindowStatus(place: .parked(since: tileNow.addingTimeInterval(-3600)))
        h.set([tileSession("local_old", "Old", popout: false), tileSession("local_a", "A")])
        #expect(h.model.snapshot.hint == nil)
        // A window goes into the pit now: the line shows under the header.
        h.parker.parkedSessionIDs = ["local_old", "local_a"]
        h.parker.statuses["local_a"] = CodeWindowStatus(place: .parked(since: tileNow))
        h.model.rebuild()
        #expect(h.model.snapshot.hint == CodePitHint.text)
        #expect(CodePitHint.text == "In the pit: the window is minimized, the session keeps running. Click it to go back on track.")
        // It goes after a while and never comes back, also after a restart (the state file says so).
        h.model.now = { tileNow.addingTimeInterval(CodePitHint.duration + 1) }
        h.model.rebuild()
        #expect(h.model.snapshot.hint == nil)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["pitHintShown"] as? Bool == true)
        let restarted = CodePitHint(url: url)
        #expect(restarted.wasShown)
        #expect(!restarted.update(parkedSince: [], now: tileNow) && !restarted.update(parkedSince: [tileNow], now: tileNow))
        // A window the user minimized is no pit stop.
        let memoryOnly = CodePitHint(url: nil)
        #expect(!memoryOnly.update(parkedSince: [], now: tileNow))
        #expect(memoryOnly.update(parkedSince: [tileNow.addingTimeInterval(5)], now: tileNow.addingTimeInterval(5)))
    }

    @Test func theHintLineSitsUnderTheHeaderInTheHeadersColour() throws {
        let h = TileHarness()
        h.model.pitHint = CodePitHint(url: nil)
        h.set([tileSession("local_a", "A")])
        h.parker.parkedSessionIDs = ["local_a"]
        h.parker.statuses["local_a"] = CodeWindowStatus(place: .parked(since: tileNow.addingTimeInterval(1)))
        h.model.rebuild()
        let (view, window) = makeTileView(h)
        defer { window.close() }
        #expect(view.bannerLines == [CodePitHint.text])
        #expect(view.contentFrame.minY >= CodeMonitorsTileView.headerHeight + CodeMonitorsTileView.bannerHeight)
    }
}
