import AppKit
import CoreGraphics
import PitboxKit
import Testing
@testable import PitboxGuard

// Two guards side by side over ONE fake window world (docs/DOCK_PROTOCOL.md §7): the host app's guard keeps windows out
// of its strip at the screen edge, Pitbox's guard out of the block docked directly beside it, on the window side. Both
// run `GuardEngine` on the same fake clock and the same `FakeWindowProvider`; a correction by one is a move the other's
// Accessibility observer sees. The host's real guard picks the direction by the midpoint, which for a strip touching
// the edge and at most 50% of the display wide is the edge's direction (checked in `DockLayout`), so the edge rule
// models it.

/// Which guard: the host's (its strip at the edge) or Pitbox's (the block beside it).
enum GuardSide: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case host, pitbox
    var testDescription: String { "\(rawValue) ticks first" }
}

/// One docked arrangement: the host's strip at the display's edge, the block directly beside it on the window side,
/// both spanning the visible height (the block takes the host's top and bottom).
struct DockLayout: Sendable, CustomTestStringConvertible {
    var name: String
    var display: GuardDisplay
    var edge: Edge
    var hostWidth: CGFloat
    var blockWidth: CGFloat
    static let railWidth: CGFloat = 24

    var testDescription: String { name }
    var visible: CGRect { display.visibleFrame }

    var host: ReservedRegion {
        let x = edge == .right ? visible.maxX - hostWidth : visible.minX
        return region(x: x, width: hostWidth)
    }
    /// The block unfolded (two columns).
    var block: ReservedRegion { blockRegion(width: blockWidth) }
    /// The block folded: the 24 pt rail.
    var rail: ReservedRegion { blockRegion(width: Self.railWidth) }

    func blockRegion(width: CGFloat) -> ReservedRegion {
        region(x: edge == .right ? host.rect.minX - width : host.rect.maxX, width: width)
    }

    private func region(x: CGFloat, width: CGFloat) -> ReservedRegion {
        ReservedRegion(displayID: display.id, rect: CGRect(x: x, y: visible.minY, width: width, height: visible.height),
                       edge: edge)
    }

    /// The same layout at the right edge: scenario frames are written for it and mirrored with `place`.
    var atRight: DockLayout {
        var layout = self
        layout.edge = .right
        return layout
    }

    /// A frame written for the right-edge layout, mirrored across the visible frame for a left-edge one.
    func place(_ r: CGRect) -> CGRect {
        guard edge == .left else { return r }
        return CGRect(x: visible.minX + visible.maxX - r.maxX, y: r.minY, width: r.width, height: r.height)
    }

    /// True when a hop moved the window toward the window side (away from the edge), never back toward it.
    func isTowardWindowSide(_ hop: Hop) -> Bool {
        switch edge {
        case .right: return hop.to.maxX <= hop.from.maxX + 0.5 && hop.to.minX <= hop.from.minX + 0.5
        case .left: return hop.to.minX >= hop.from.minX - 0.5 && hop.to.maxX >= hop.from.maxX - 0.5
        }
    }

    /// Out of the host's strip and the whole block (as unfolded), within the guards' tolerance.
    func isClear(_ frame: CGRect) -> Bool {
        !Placement.overlaps(frame, host.rect) && !Placement.overlaps(frame, block.rect)
    }

    /// The host's real guard decides by the midpoint; for this strip that gives the edge's direction.
    var hostMidpointAgreesWithEdge: Bool {
        edge == .right ? host.rect.midX >= visible.midX : host.rect.midX < visible.midX
    }

    /// A 5120x1440 display, the host at 31% (1587 pt), the block two columns (631 pt): the docked area is 43%.
    static let wide = DockLayout(name: "wide: 5120 pt, host 1587 + block 631", display: Fixture.main, edge: .right,
                                 hostWidth: 1587, blockWidth: 631)
    /// A 14-inch notebook (1512 pt): the docked area (1101 pt) is wider than half the display, so the block's middle
    /// lies left of the display's middle.
    static let narrow = DockLayout(name: "narrow: 1512 pt, host 470 + block 631", display: notebook, edge: .right,
                                   hostWidth: 470, blockWidth: 631)
    /// The notebook with the host on the left edge.
    static let narrowLeft = DockLayout(name: "narrow, left edge: 1512 pt, host 470 + block 631", display: notebook,
                                       edge: .left, hostWidth: 470, blockWidth: 631)
    static let all = [wide, narrow, narrowLeft]

    static let notebook = GuardDisplay(id: 2, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       visibleFrame: CGRect(x: 0, y: 38, width: 1512, height: 944))
}

/// One correction by one guard: the window's frame before and after the guard's tick.
struct Hop: Equatable {
    var window: Int
    var side: GuardSide
    var from: CGRect
    var to: CGRect
    var at: TimeInterval
}

/// Log lines of one engine.
final class EngineLog {
    var lines: [String] = []
}

extension GuardEngine {
    /// What `GuardCore.track` does with a running app: managed when the policy says so (regular, not this guard's own
    /// process, not exempt), dropped otherwise.
    func track(_ app: AppSnapshot) {
        if WindowPolicy.manages(app, ownPID: ownPID, options: options) {
            addApp(pid: app.pid, name: app.name)
        } else {
            removeApp(pid: app.pid)
        }
    }
}

/// The host's guard and Pitbox's guard over one fake window world, on one fake clock, with one mouse.
final class DockedSimulation {
    static let hostPID: pid_t = 10
    static let pitboxPID: pid_t = 11
    /// The host's strip panel and Pitbox's panel (accessory apps, level 2), plus a window of each at level 0 lying over
    /// the other's part (a settings window, say): no guard may ever move any of them.
    static let panelIDs = [900, 901, 902, 903]

    let layout: DockLayout
    let provider: FakeWindowProvider
    /// The one mouse both apps watch.
    let inputs: SimInputs
    let host: GuardEngine<FakeWindowProvider>
    let pitbox: GuardEngine<FakeWindowProvider>
    let hostLog: EngineLog
    let pitboxLog: EngineLog
    /// Which guard ticks first when both are due at the same moment.
    let first: GuardSide
    private(set) var now: TimeInterval = 0
    private(set) var hops: [Hop] = []

    init(_ layout: DockLayout, windows: [FakeWindow], first: GuardSide = .host) {
        let provider = FakeWindowProvider(windows + Self.panels(layout))
        let inputs = SimInputs(), hostLog = EngineLog(), pitboxLog = EngineLog()
        self.layout = layout
        self.first = first
        self.provider = provider
        self.inputs = inputs
        self.hostLog = hostLog
        self.pitboxLog = pitboxLog
        host = GuardEngine(provider: provider, options: GuardOptions(), ownPID: Self.hostPID,
                           isMouseDown: { inputs.mouseDown }, log: { _, line in hostLog.lines.append(line) })
        pitbox = GuardEngine(provider: provider, options: GuardOptions(), ownPID: Self.pitboxPID,
                             isMouseDown: { inputs.mouseDown }, log: { _, line in pitboxLog.lines.append(line) })
        for engine in [host, pitbox] { engine.setDisplays([layout.display], now: 0) }
        host.setRegions([layout.host], now: 0)
        pitbox.setRegions([layout.block], now: 0)
        for app in Self.runningApps { track(app) }
    }

    /// TextEdit and Chrome (regular), the host app and Pitbox (both accessory, `LSUIElement`).
    static let runningApps = [
        AppSnapshot(pid: Fixture.textEdit, bundleID: "com.apple.TextEdit", name: "TextEdit",
                    activationPolicy: .regular, isChromium: false),
        AppSnapshot(pid: Fixture.chrome, bundleID: "com.google.Chrome", name: "Chrome", activationPolicy: .regular,
                    isChromium: true),
        AppSnapshot(pid: hostPID, bundleID: "com.example.dockhost", name: "Dock host", activationPolicy: .accessory,
                    isChromium: false),
        AppSnapshot(pid: pitboxPID, bundleID: AppIdentity.defaultBundleID, name: "Pitbox",
                    activationPolicy: .accessory, isChromium: false),
    ]

    private static func panels(_ layout: DockLayout) -> [FakeWindow] {
        var hostPanel = FakeWindow(900, pid: hostPID, layout.host.rect)
        hostPanel.layer = 2
        var pitboxPanel = FakeWindow(901, pid: pitboxPID, layout.block.rect)
        pitboxPanel.layer = 2
        let inBlock = layout.block.rect.insetBy(dx: 100, dy: 200)
        let inHost = layout.host.rect.insetBy(dx: 60, dy: 200)
        return [hostPanel, pitboxPanel, FakeWindow(902, pid: hostPID, inBlock), FakeWindow(903, pid: pitboxPID, inHost)]
    }

    func engine(_ side: GuardSide) -> GuardEngine<FakeWindowProvider> { side == .host ? host : pitbox }
    var order: [GuardSide] { first == .host ? [.host, .pitbox] : [.pitbox, .host] }

    /// Both guards learn about a running app, as their cores would.
    func track(_ app: AppSnapshot) {
        host.track(app)
        pitbox.track(app)
    }

    func frame(_ id: Int) -> CGRect? { provider.windows[id]?.frame }

    /// Runs every wake-up of either guard up to `time`. At each one both guards tick (in `order`), and every frame a
    /// tick changed is a hop and a notification to both guards' observers.
    func run(until time: TimeInterval) {
        var steps = 0
        while steps < 100_000, let wake = nextWake(), wake <= time {
            now = max(now, wake)
            for side in order { tick(side) }
            steps += 1
        }
        now = max(now, time)
    }

    func run(for seconds: TimeInterval) { run(until: now + seconds) }

    private func nextWake() -> TimeInterval? {
        [host, pitbox].compactMap { $0.nextWake(now: now)?.at }.min()
    }

    private func tick(_ side: GuardSide) {
        let before = provider.windows.mapValues(\.frame)
        engine(side).tick(now: now)
        for id in provider.windows.keys.sorted() {
            guard let from = before[id], let to = provider.windows[id]?.frame, from != to else { continue }
            hops.append(Hop(window: id, side: side, from: from, to: to, at: now))
            notify(id)
        }
        for reaction in provider.takeReactions() { appChanges(reaction.id, to: reaction.frame) }
    }

    /// An Accessibility notification about window `id`, seen by both guards.
    func notify(_ id: Int) {
        host.windowChanged(id, now: now)
        pitbox.windowChanged(id, now: now)
    }

    /// The app changes the window (zoom, a new window, a move) and says so.
    func appChanges(_ id: Int, to frame: CGRect) {
        provider.appSets(id, frame)
        notify(id)
    }

    /// The user lets go of the mouse: both apps' monitors see it.
    func releaseMouse() {
        inputs.mouseDown = false
        host.mouseReleased(now: now)
        pitbox.mouseReleased(now: now)
    }

    /// The user drags window `id` by its title bar to `target` (ten moves, 20 ms apart), holds still 0.5 s and lets go.
    func drag(_ id: Int, to target: CGRect) {
        guard let start = frame(id) else { return }
        inputs.mouseDown = true
        for step in 1...10 {
            let t = CGFloat(step) / 10
            appChanges(id, to: CGRect(x: (start.minX + (target.minX - start.minX) * t).rounded(),
                                      y: (start.minY + (target.minY - start.minY) * t).rounded(),
                                      width: start.width, height: start.height))
            run(for: 0.02)
        }
        run(for: 0.5)
        releaseMouse()
    }

    /// Pitbox publishes its region: the block, the rail, or nothing (hidden).
    func setBlock(_ region: ReservedRegion?) {
        pitbox.setRegions(region.map { [$0] } ?? [], now: now)
    }

    /// Hops of window `id` from hop number `mark` on.
    func hops(of id: Int, since mark: Int = 0) -> [Hop] {
        hops[mark...].filter { $0.window == id }
    }

    /// Windows on a fight cooldown, in either guard.
    var cooldowns: Int { host.fightingCount(now: now) + pitbox.fightingCount(now: now) }

    /// Any "keeps ending up over the block" line in either guard's log.
    var foughtLines: Int {
        (hostLog.lines + pitboxLog.lines).filter { $0.contains("keeps ending up over the block") }.count
    }
}
