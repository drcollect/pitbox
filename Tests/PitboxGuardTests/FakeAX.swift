import CoreGraphics
import Foundation
import PitboxKit
@testable import PitboxGuard

// The fake-AX harness: fake windows and apps that drive `GuardEngine` without the Accessibility permission.
// Never use the real `AXWindowProvider` or call `WindowGuard.start()` in tests: this machine's test runner may be
// Accessibility-trusted, and the real guard would move real windows.

/// A fake window with the behaviors of real apps that matter to the guard.
struct FakeWindow {
    var id: Int
    var pid: pid_t
    var frame: CGRect
    var role = "AXWindow"
    var subrole = "AXStandardWindow"
    var minimized = false
    var fullScreen = false
    var resizable = true
    var movable = true
    var layer = 0
    /// False: hidden, or on another Space.
    var onScreen = true
    /// False: the window server shows it, but Accessibility does not list it (Electron without AX enabled).
    var listedByAX = true
    /// The app refuses to be narrower than this.
    var appMinWidth: CGFloat = 0
    /// The app ignores position changes.
    var ignoresMoves = false
    /// Right after every change the app puts the window back to this frame (and says so): an app that fights.
    var revertsTo: CGRect?
    /// The app accepts a change but applies it a moment later (Wine, XQuartz, some iPad apps).
    var appliesLate = false
    /// The app accepts any width, then grows the window back to this width a moment later (a minimum size that its
    /// layout enforces after the fact, as auto layout or SwiftUI may).
    var growsBackToWidth: CGFloat?
    /// The app snaps widths to multiples of this (character cells, like Terminal), down unless `snapsUp`.
    var widthStep: CGFloat = 0
    var snapsUp = false

    init(_ id: Int, pid: pid_t = Fixture.textEdit, _ frame: CGRect) {
        self.id = id; self.pid = pid; self.frame = frame
    }
}

final class FakeWindowProvider: AXWindowProviding {
    typealias Window = Int

    var windows: [Int: FakeWindow] = [:]
    var hungPIDs: Set<pid_t> = []
    /// Apps that answer everything in time except "is this attribute settable?".
    var hungCapabilityPIDs: Set<pid_t> = []
    /// Scripted outcomes of the next `setFrame` calls per window: nil succeeds as usual, a failure is returned.
    var setFrameScript: [Int: [AXFailure?]] = [:]
    var apiDisabled = false
    var exposeWindowIDs = true
    /// `enableManualAccessibility` makes the app's hidden windows appear to Accessibility.
    var manualAccessibilityExposes = false
    private(set) var manualAccessibilityRequests: [pid_t] = []
    private(set) var sets: [(id: Int, frame: CGRect)] = []
    private(set) var calls: [String: Int] = [:]
    /// What apps do in response to a change; the simulation applies these right after the tick that caused them.
    private(set) var reactions: [(id: Int, frame: CGRect)] = []

    func takeReactions() -> [(id: Int, frame: CGRect)] {
        defer { reactions.removeAll() }
        return reactions
    }

    init(_ list: [FakeWindow] = []) { for window in list { windows[window.id] = window } }

    /// Round trips to apps (everything except the window-server listing).
    var accessibilityCalls: Int { calls.filter { $0.key != "onScreenWindows" }.values.reduce(0, +) }

    func add(_ window: FakeWindow) { windows[window.id] = window }
    /// The app itself changes a window's frame (zoom, restore, fight).
    func appSets(_ id: Int, _ frame: CGRect) { windows[id]?.frame = frame }

    private func count(_ name: String) { calls[name, default: 0] += 1 }

    func onScreenWindows() -> [OnScreenWindow] {
        count("onScreenWindows")
        return windows.values.sorted { $0.id < $1.id }.filter { $0.onScreen && !$0.minimized }.map {
            OnScreenWindow(windowID: CGWindowID($0.id), pid: $0.pid, bounds: $0.frame, layer: $0.layer, alpha: 1)
        }
    }

    func windows(ofPID pid: pid_t) -> Result<[Int], AXFailure> {
        count("windows")
        if apiDisabled { return .failure(.apiDisabled) }
        if hungPIDs.contains(pid) { return .failure(.cannotComplete) }
        return .success(windows.values.filter { $0.pid == pid && $0.listedByAX }.map(\.id).sorted())
    }

    func pid(of window: Int) -> pid_t? { windows[window]?.pid }

    func windowID(of window: Int) -> CGWindowID? {
        guard exposeWindowIDs, windows[window] != nil else { return nil }
        return CGWindowID(window)
    }

    func info(of window: Int) -> Result<WindowInfo, AXFailure> {
        count("info")
        if apiDisabled { return .failure(.apiDisabled) }
        guard let w = windows[window] else { return .failure(.invalidElement) }
        if hungPIDs.contains(w.pid) { return .failure(.cannotComplete) }
        return .success(WindowInfo(pid: w.pid, frame: w.frame, role: w.role, subrole: w.subrole,
                                   minimized: w.minimized, fullScreen: w.fullScreen))
    }

    func capabilities(of window: Int) -> Result<WindowCapabilities, AXFailure> {
        count("capabilities")
        if apiDisabled { return .failure(.apiDisabled) }
        guard let w = windows[window] else { return .failure(.invalidElement) }
        if hungPIDs.contains(w.pid) || hungCapabilityPIDs.contains(w.pid) { return .failure(.cannotComplete) }
        return .success(WindowCapabilities(resizable: w.resizable, movable: w.movable))
    }

    func serverState(ofWindowID id: CGWindowID) -> ServerWindowState? {
        guard let window = windows[Int(id)] else { return nil }
        return ServerWindowState(layer: window.layer, onScreen: window.onScreen && !window.minimized)
    }

    func setFrame(_ target: CGRect, of window: Int, from current: CGRect) -> Result<CGRect, AXFailure> {
        count("setFrame")
        if apiDisabled { return .failure(.apiDisabled) }
        guard var w = windows[window] else { return .failure(.invalidElement) }
        if hungPIDs.contains(w.pid) { return .failure(.cannotComplete) }
        if var script = setFrameScript[window], !script.isEmpty {
            let outcome = script.removeFirst()
            setFrameScript[window] = script
            if let failure = outcome { return .failure(failure) }
        }
        sets.append((window, target))
        var next = w.frame
        if w.resizable {
            var width = max(target.width, w.appMinWidth)
            if w.widthStep > 0 { width = (width / w.widthStep).rounded(w.snapsUp ? .up : .down) * w.widthStep }
            next.size = CGSize(width: width, height: target.height)
        }
        if w.movable && !w.ignoresMoves { next.origin = target.origin }
        if w.appliesLate {
            reactions.append((window, next))
            return .success(w.frame)
        }
        w.frame = next
        windows[window] = w
        if let back = w.revertsTo { reactions.append((window, back)) }
        if let minimum = w.growsBackToWidth, next.width < minimum {
            reactions.append((window, CGRect(x: next.minX, y: next.minY, width: minimum, height: next.height)))
        }
        return .success(w.frame)
    }

    func enableManualAccessibility(pid: pid_t) -> Bool {
        manualAccessibilityRequests.append(pid)
        if manualAccessibilityExposes {
            for (id, window) in windows where window.pid == pid { windows[id]?.listedByAX = true }
        }
        return true
    }
}

/// Screens and strips used across tests (a 5120x1440 display, menu bar 30 pt, Dock 98 pt).
enum Fixture {
    static let main = GuardDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 5120, height: 1440),
                                   visibleFrame: CGRect(x: 0, y: 30, width: 5120, height: 1312))
    static var visible: CGRect { main.visibleFrame }
    static let rightStrip = ReservedRegion(displayID: 1, rect: CGRect(x: 3840, y: 30, width: 1280, height: 1312),
                                           edge: .right)
    static let leftStrip = ReservedRegion(displayID: 1, rect: CGRect(x: 0, y: 30, width: 1280, height: 1312),
                                          edge: .left)
    static let textEdit: pid_t = 100
    static let chrome: pid_t = 200
    static let unmanaged: pid_t = 300
    static let ownPID: pid_t = 1
    static let apps: [pid_t: String] = [textEdit: "TextEdit", chrome: "Chrome"]
    /// The zoomed / maximized frame.
    static var zoomed: CGRect { visible }
    /// Where a zoomed window belongs next to the right strip.
    static var besideRightStrip: CGRect { CGRect(x: 0, y: 30, width: 3840, height: 1312) }
}

/// Mouse state and log lines seen by the engine.
final class SimInputs {
    var mouseDown = false
    var logs: [String] = []
}

/// Drives a `GuardEngine` over fake windows with a fake clock, the way `GuardCore` does: `tick` at every wake-up.
final class Simulation {
    let provider: FakeWindowProvider
    let inputs: SimInputs
    let engine: GuardEngine<FakeWindowProvider>
    private(set) var now: TimeInterval = 0

    init(_ windows: [FakeWindow], options: GuardOptions = GuardOptions(),
         regions: [ReservedRegion] = [Fixture.rightStrip], displays: [GuardDisplay] = [Fixture.main],
         apps: [pid_t: String] = Fixture.apps) {
        provider = FakeWindowProvider(windows)
        let inputs = SimInputs()
        engine = GuardEngine(provider: provider, options: options, ownPID: Fixture.ownPID,
                             isMouseDown: { inputs.mouseDown }, log: { _, line in inputs.logs.append(line) })
        self.inputs = inputs
        engine.setDisplays(displays, now: 0)
        engine.setRegions(regions, now: 0)
        for (pid, name) in apps { engine.addApp(pid: pid, name: name) }
    }

    var mouseDown: Bool {
        get { inputs.mouseDown }
        set { inputs.mouseDown = newValue }
    }
    var logs: [String] { inputs.logs }
    var sets: [(id: Int, frame: CGRect)] { provider.sets }

    func frame(_ id: Int) -> CGRect? { provider.windows[id]?.frame }

    /// Runs every wake-up up to `time`.
    func run(until time: TimeInterval) {
        var steps = 0
        while let wake = engine.nextWake(now: now), wake.at <= time, steps < 100_000 {
            now = max(now, wake.at)
            engine.tick(now: now)
            for reaction in provider.takeReactions() { appChanges(reaction.id, to: reaction.frame) }
            steps += 1
        }
        now = max(now, time)
    }

    func run(for seconds: TimeInterval) { run(until: now + seconds) }

    /// What `GuardCore` does after every event it hands the engine: tick right away, not only at the next wake-up.
    func pump() {
        engine.tick(now: now)
        for reaction in provider.takeReactions() { appChanges(reaction.id, to: reaction.frame) }
    }

    /// An Accessibility notification for window `id` (moved / resized / created ...).
    func notify(_ id: Int) { engine.windowChanged(id, now: now) }

    /// The app changes the window and tells Accessibility about it.
    func appChanges(_ id: Int, to frame: CGRect) {
        provider.appSets(id, frame)
        notify(id)
    }

    /// The user lets go of the mouse (the monitor event).
    func releaseMouse() {
        inputs.mouseDown = false
        engine.mouseReleased(now: now)
    }
}

/// Stands in for Shell's panel controller.
final class FakeRegionSource: ReservedRegionSource {
    var regions: [ReservedRegion] = []
    var onRegionsChanged: (() -> Void)?
}
