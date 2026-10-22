import AppKit
import CoreGraphics
import Foundation
import PitboxKit
@testable import PitboxSessions

// Fakes for drag-to-park's controller: the system calls (pointer, button, window server, monitors, timers, clock), the
// window side, the claims registry and the label. Nothing here reads a real window, installs a real monitor or shows a
// window on screen.

/// A hand-driven system: the test moves the pointer and windows, presses and releases, and advances the clock, which
/// fires the timers and delayed calls that are due, in time order.
@MainActor
final class FakeDragSystem: CodeDragSystem {
    var now: TimeInterval = 50
    var pointerAt = CGPoint.zero
    var buttonDown = false
    /// On screen, front to back.
    var windows: [CodeDragWindow] = []
    let primaryHeight: CGFloat = 1440
    private(set) var listings = 0
    private(set) var boundsReads = 0

    private struct Scheduled {
        var id: Int
        var due: TimeInterval
        var interval: TimeInterval?
        var work: @MainActor () -> Void
    }
    private var scheduled: [Scheduled] = []
    private var nextID = 0
    private var down: (@MainActor (CGPoint) -> Void)?
    private var up: (@MainActor () -> Void)?

    var monitorsInstalled: Bool { down != nil }
    var repeatingTimers: [TimeInterval] { scheduled.compactMap(\.interval).sorted() }
    var pendingCalls: Int { scheduled.filter { $0.interval == nil }.count }

    func pointer() -> CGPoint { pointerAt }
    func isLeftButtonDown() -> Bool { buttonDown }
    func appKitPoint(fromQuartz point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }
    func quartzPoint(fromAppKit point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }

    func onScreenWindows() -> [CodeDragWindow] {
        listings += 1
        return windows
    }

    func onScreenBounds(of windowNumber: UInt32) -> CGRect? {
        boundsReads += 1
        return windows.first { $0.number == windowNumber }?.bounds
    }

    func addMouseMonitors(down: @escaping @MainActor (CGPoint) -> Void, up: @escaping @MainActor () -> Void) -> CodeDragToken {
        self.down = down
        self.up = up
        return CodeDragToken { [weak self] in
            MainActor.assumeIsolated {
                self?.down = nil
                self?.up = nil
            }
        }
    }

    func every(_ interval: TimeInterval, tolerance: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CodeDragToken {
        schedule(due: now + interval, interval: interval, work)
    }

    func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CodeDragToken {
        schedule(due: now + delay, interval: nil, work)
    }

    private func schedule(due: TimeInterval, interval: TimeInterval?, _ work: @escaping @MainActor () -> Void) -> CodeDragToken {
        nextID += 1
        let id = nextID
        scheduled.append(Scheduled(id: id, due: due, interval: interval, work: work))
        return CodeDragToken { [weak self] in
            MainActor.assumeIsolated { self?.scheduled.removeAll { $0.id == id } }
        }
    }

    /// Runs everything due up to `now + seconds`, in time order.
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = scheduled.filter({ $0.due <= end + 1e-9 }).min(by: { $0.due < $1.due }) {
            now = max(now, next.due)
            if let interval = next.interval, let index = scheduled.firstIndex(where: { $0.id == next.id }) {
                scheduled[index].due = next.due + interval
            } else {
                scheduled.removeAll { $0.id == next.id }
            }
            next.work()
        }
        now = end
    }

    // MARK: the user's hand

    /// The window `number` (with the pointer on it) moves by (dx, dy) along with the pointer.
    func move(_ number: UInt32, dx: CGFloat, dy: CGFloat = 0) {
        pointerAt.x += dx
        pointerAt.y += dy
        if let index = windows.firstIndex(where: { $0.number == number }) {
            windows[index].bounds = windows[index].bounds.offsetBy(dx: dx, dy: dy)
        }
    }

    func press(at point: CGPoint) {
        pointerAt = point
        buttonDown = true
        down?(appKitPoint(fromQuartz: point))
    }

    /// Releases the button; `reported: false` loses the mouse-up event (only the poll can notice).
    func release(reported: Bool = true) {
        buttonDown = false
        if reported { up?() }
    }
}

/// The window side: desk pop-outs as the test sets them (what `deskWindows` and the sessions give in production); parks
/// wait until the test answers them.
@MainActor
final class FakeDropParker: CodeDropParking {
    var deskPopouts: [CodeDropPopout] = []
    private(set) var parks: [(sessionID: String, frame: CGRect, done: @MainActor (CodeDropParkResult) -> Void)] = []

    func parkDropped(sessionID: String, restoreFrame: CGRect, done: @escaping @MainActor (CodeDropParkResult) -> Void) {
        parks.append((sessionID, restoreFrame, done))
    }

    func answer(_ index: Int, _ result: CodeDropParkResult) {
        parks[index].done(result)
    }
}

/// A window side that publishes desk windows (the join's `deskWindows`), for the production drop's reading of them.
@MainActor
final class DeskWindowsParker: CodeWindowParking, CodeDropParking {
    var statuses: [String: CodeWindowStatus] = [:]
    var parkedSessionIDs: Set<String> = []
    var deskWindows: [String: CodeDeskWindow] = [:]
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
    func update(sessions: [CodeSessionSnapshot], processes: [ClaudeProcessInfo]) {}
    func setActive(_ active: Bool) {}
    func perform(_ click: CodeWindowClick, sessionID: String) {}
    func parkAllDone(_ sessionIDs: [String]) async -> CodeParkAllResult { CodeParkAllResult() }
    func parkFrontmostPopout() async -> CodeParkFrontmostResult { .notAPopout }
    func parkDropped(sessionID: String, restoreFrame: CGRect, done: @escaping @MainActor (CodeDropParkResult) -> Void) {
        done(.failed(reason: CodeDropWords.parkFailure))
    }
}

/// Records every registry call in order; grants claims unless told not to.
final class RecordingClaims: CodeDropClaiming, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var grants = true

    var log: [String] { lock.withLock { calls } }

    func setClaimablePIDs(_ pids: Set<pid_t>) { record("claimable \(pids.sorted())") }
    func claim(pid: pid_t, windowNumber: UInt32) -> Bool {
        record("claim \(pid) \(windowNumber)")
        return grants
    }
    func noteMouseUp() { record("mouseUp") }
    func release(pid: pid_t, windowNumber: UInt32, parked: Bool) { record("release \(pid) \(windowNumber) parked=\(parked)") }

    private func record(_ line: String) { lock.withLock { calls.append(line) } }
}

/// Records what the label showed.
@MainActor
final class FakeDropLabel: CodeDropLabelPresenting {
    private(set) var shown: (text: String, failure: Bool, at: CGPoint)?
    private(set) var history: [String] = []
    var windowNumber: UInt32? = 900

    func show(_ text: String, failure: Bool, at point: CGPoint) {
        shown = (text, failure, point)
        if history.last != text { history.append(text) }
    }

    func hide() { shown = nil }
}

/// A controller over the fakes with one Claude pop-out on the desk, left of the strip.
@MainActor
struct DragRig {
    let system = FakeDragSystem()
    let parker = FakeDropParker()
    let claims = RecordingClaims()
    let label = FakeDropLabel()
    let controller: CodeDragToPark
    let slots = SlotBox()
    var processes: [ClaudeProcessInfo] = [ClaudeProcessInfo(pid: 4242, profile: .a)]

    static let strip = ReservedRegion(displayID: 1, rect: DropFixture.strip, edge: .right)

    init(conditions: CodeDragToParkConditions = CodeDragToParkConditions(dragToPark: true, stripShown: true),
         processes: [ClaudeProcessInfo] = [ClaudeProcessInfo(pid: 4242, profile: .a),
                                           ClaudeProcessInfo(pid: 5151, profile: .unknown(folderName: "Claude-X"))]) {
        self.processes = processes
        let list = processes
        let parker = self.parker
        controller = CodeDragToPark(claims: claims, parker: parker, desk: { parker.deskPopouts }, processes: { list },
                                    stripRegions: { [Self.strip] }, conditions: conditions, system: system, label: label)
        system.windows = [CodeDragWindow(number: 77, pid: 4242, bounds: DropFixture.desk, layer: 0, alpha: 1)]
        parker.deskPopouts = [DropFixture.popout]
        let slots = self.slots
        controller.ownBucket = { _ in DropFixture.unsorted }
        controller.onSlotChange = { slots.changes.append($0) }
        controller.onParked = { id, target in slots.parked.append((id, target)) }
        controller.refresh()
    }

    /// Presses the title bar, drags the window into the strip and holds it there for `hold` seconds.
    func dragIntoStrip(hold: TimeInterval = 0.4) {
        system.press(at: DropFixture.grab)
        for _ in 0..<12 {
            system.move(77, dx: (3900 - DropFixture.grab.x) / 12)
            system.advance(1.0 / 30)
        }
        system.advance(hold)
    }
}

@MainActor
final class SlotBox {
    var changes: [CodeDropSlot?] = []
    var parked: [(String, CodeDropTarget)] = []
}
