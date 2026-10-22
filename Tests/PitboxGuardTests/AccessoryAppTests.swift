import AppKit
import CoreGraphics
import PitboxKit
import Testing
@testable import PitboxGuard

// docs/DOCK_PROTOCOL.md §7: Pitbox stays an accessory app (`LSUIElement`) and a guard never moves an accessory app's
// windows, on layer 0 or any other, so the host's guard leaves Pitbox's panels alone and Pitbox's guard the host's.
// Apps reach the engine through the same policy `GuardCore.track` uses (`WindowPolicy.manages`, `GuardEngine.track`).

private let accessoryPID: pid_t = 400

private func app(_ policy: NSApplication.ActivationPolicy, pid: pid_t = accessoryPID,
                 bundleID: String? = "com.example.dockhost") -> AppSnapshot {
    AppSnapshot(pid: pid, bundleID: bundleID, name: "Dock host", activationPolicy: policy, isChromium: false)
}

private let textEdit = AppSnapshot(pid: Fixture.textEdit, bundleID: "com.apple.TextEdit", name: "TextEdit",
                                   activationPolicy: .regular, isChromium: false)
private let chrome = AppSnapshot(pid: Fixture.chrome, bundleID: "com.google.Chrome", name: "Chrome",
                                 activationPolicy: .regular, isChromium: true)

@Suite("Accessory apps are never moved")
struct AccessoryAppTests {
    @Test func onlyRegularAppsAreManaged() {
        let options = GuardOptions()
        func manages(_ snapshot: AppSnapshot) -> Bool {
            WindowPolicy.manages(snapshot, ownPID: Fixture.ownPID, options: options)
        }
        #expect(!app(.accessory).isRegular)
        #expect(!app(.prohibited).isRegular)
        #expect(app(.regular).isRegular)
        #expect(!manages(app(.accessory)), "LSUIElement apps (Pitbox, a dock host) are never managed")
        #expect(!manages(app(.prohibited)))
        #expect(manages(app(.regular)))
        #expect(!manages(app(.regular, pid: Fixture.ownPID)), "never the guard's own process")
        #expect(!manages(app(.regular, bundleID: "com.apple.dock")), "never an exempt app")
        #expect(!manages(app(.regular, bundleID: AppIdentity.bundleID)), "never Pitbox, by bundle id too")
    }

    @Test func anAccessoryAppsWindowsAreNeverMovedOnAnyLayer() {
        var panel = FakeWindow(10, pid: accessoryPID, Fixture.rightStrip.rect)   // its strip, at level 2
        panel.layer = 2
        let plain = FakeWindow(11, pid: accessoryPID, Fixture.zoomed)            // a window of it at layer 0
        var floating = FakeWindow(12, CGRect(x: 4000, y: 200, width: 400, height: 300))
        floating.layer = 3                                                        // a regular app's "always on top"
        let control = FakeWindow(13, pid: Fixture.chrome, Fixture.zoomed)
        let sim = Simulation([panel, plain, floating, control], apps: [:])
        for snapshot in [app(.accessory), textEdit, chrome] { sim.engine.track(snapshot) }
        sim.run(until: 0.5)
        #expect(sim.frame(13) == Fixture.besideRightStrip, "the guard is working")
        for id in [10, 11, 12] { sim.notify(id) }
        sim.run(for: 0.5)
        sim.appChanges(11, to: CGRect(x: 3600, y: 100, width: 1200, height: 800))  // moved over the strip, and said so
        sim.appChanges(12, to: CGRect(x: 4200, y: 200, width: 400, height: 300))
        sim.run(for: 10)
        #expect(sim.sets.map(\.id) == [13], "the only window ever written is the regular app's layer-0 window")
        #expect(sim.frame(10) == Fixture.rightStrip.rect)
        #expect(sim.frame(11) == CGRect(x: 3600, y: 100, width: 1200, height: 800))
        #expect(sim.frame(12) == CGRect(x: 4200, y: 200, width: 400, height: 300))
        #expect(!sim.engine.isManaged(pid: accessoryPID))
        #expect(sim.engine.cannotFitCount == 0 && sim.engine.fightingCount(now: sim.now) == 0)
    }

    /// `GuardCore.appActivated` re-tracks an app whose activation policy changed.
    @Test func anAppThatTurnsAccessoryIsDropped() {
        let sim = Simulation([FakeWindow(1, pid: accessoryPID, CGRect(x: 100, y: 100, width: 800, height: 600))],
                             apps: [:])
        sim.engine.track(app(.regular))
        sim.run(until: 0.5)
        sim.appChanges(1, to: Fixture.zoomed)
        sim.run(for: 1)
        #expect(sim.frame(1) == Fixture.besideRightStrip, "managed while regular")
        sim.engine.track(app(.accessory))
        #expect(!sim.engine.isManaged(pid: accessoryPID))
        sim.appChanges(1, to: Fixture.zoomed)
        sim.run(for: 5)
        #expect(sim.frame(1) == Fixture.zoomed, "left alone once it is an accessory app")
        #expect(sim.sets.count == 1)
    }

    /// The guard's own windows are skipped by process id, whatever the activation policy says.
    @Test func ownWindowsAreNeverMovedEvenAsARegularApp() {
        let sim = Simulation([FakeWindow(1, pid: Fixture.ownPID, Fixture.zoomed)], apps: [:])
        sim.engine.track(app(.regular, pid: Fixture.ownPID, bundleID: "com.example.renamed"))
        sim.run(for: 5)
        sim.notify(1)
        sim.run(for: 5)
        #expect(sim.sets.isEmpty)
        #expect(!sim.engine.isManaged(pid: Fixture.ownPID))
    }
}
