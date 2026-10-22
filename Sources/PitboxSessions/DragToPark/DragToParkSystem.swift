import AppKit
import CoreGraphics
import Foundation
import PitboxKit

/// One on-screen window as drag-to-park reads it from the window server (no permission; names are never read).
struct CodeDragWindow: Equatable, Sendable {
    var number: UInt32
    var pid: pid_t
    /// Quartz global coordinates (top-left origin, y down).
    var bounds: CGRect
    var layer: Int
    var alpha: Double
}

/// Cancels what it stands for (a timer, a delayed call, event monitors) once; also when it is released.
final class CodeDragToken {
    private var cancelAction: (() -> Void)?

    init(_ cancel: @escaping () -> Void) { cancelAction = cancel }

    func cancel() {
        let action = cancelAction
        cancelAction = nil
        action?()
    }

    deinit { cancel() }
}

/// The system calls drag-to-park makes, none of which needs a permission: the
/// pointer, the left button, window-server bounds and order, mouse monitors, timers and the clock. Main thread.
/// Tests replace it, so no test ever reads a real window or installs an event monitor.
@MainActor
protocol CodeDragSystem: AnyObject {
    /// Monotonic seconds (`MonotonicClock`, the claims registry's own clock by default).
    var now: TimeInterval { get }
    /// `NSEvent.mouseLocation`, in Quartz coordinates.
    func pointer() -> CGPoint
    /// `CGEventSource.buttonState(.combinedSessionState, .left)`.
    func isLeftButtonDown() -> Bool
    func appKitPoint(fromQuartz point: CGPoint) -> CGPoint
    func quartzPoint(fromAppKit point: CGPoint) -> CGPoint
    /// On-screen windows of the current Space, front to back, in one window-server call.
    func onScreenWindows() -> [CodeDragWindow]
    /// One window's bounds while it is on screen; nil when it is gone, minimized or elsewhere.
    func onScreenBounds(of windowNumber: UInt32) -> CGRect?
    /// Global and local left mouse-down (with the AppKit screen point) and mouse-up monitors, until the token goes.
    func addMouseMonitors(down: @escaping @MainActor (CGPoint) -> Void, up: @escaping @MainActor () -> Void) -> CodeDragToken
    /// A repeating main-run-loop timer (common modes).
    func every(_ interval: TimeInterval, tolerance: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CodeDragToken
    /// A delayed call on the main queue.
    func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CodeDragToken
}

/// The production system calls.
@MainActor
final class CodeLiveDragSystem: CodeDragSystem {
    var now: TimeInterval { MonotonicClock.now() }

    func pointer() -> CGPoint { quartzPoint(fromAppKit: NSEvent.mouseLocation) }

    func isLeftButtonDown() -> Bool { CGEventSource.buttonState(.combinedSessionState, button: .left) }

    func appKitPoint(fromQuartz point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: ScreenSpace.primaryHeight - point.y)
    }

    func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: ScreenSpace.primaryHeight - point.y)
    }

    func onScreenWindows() -> [CodeDragWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap(Self.parse)
    }

    func onScreenBounds(of windowNumber: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowNumber) as? [[String: Any]],
              let entry = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowNumber }),
              (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true else { return nil }
        return Self.parse(entry)?.bounds
    }

    func addMouseMonitors(down: @escaping @MainActor (CGPoint) -> Void, up: @escaping @MainActor () -> Void) -> CodeDragToken {
        // Mouse monitors need no permission (unlike key monitors or an event tap); handlers run on the main thread.
        var monitors: [Any] = []
        let pressed: (NSEvent) -> Void = { event in
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
            MainActor.assumeIsolated { down(point) }
        }
        let released: () -> Void = { MainActor.assumeIsolated { up() } }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: pressed) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { pressed($0); return $0 }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { _ in released() }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { released(); return $0 }) {
            monitors.append(monitor)
        }
        return CodeDragToken {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
        }
    }

    func every(_ interval: TimeInterval, tolerance: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CodeDragToken {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { work() } }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return CodeDragToken { timer.invalidate() }
    }

    func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CodeDragToken {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return CodeDragToken { item.cancel() }
    }

    static func parse(_ entry: [String: Any]) -> CodeDragWindow? {
        guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value, number != 0,
              let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0,
              let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        return CodeDragWindow(number: number, pid: pid, bounds: bounds, layer: layer, alpha: alpha)
    }
}
