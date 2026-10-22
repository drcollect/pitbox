import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PitboxKit

// The production seams of desk tags. Tests never use these: they replace every
// one with a fake, so no test reads a real window, registers an observer on another app or orders a panel in front.

/// The window server through `CGWindowListCopyWindowInfo` (no permission; window names are never read: they would need
/// Screen Recording and are private).
final class DeskTagLiveWindowServer: DeskTagWindowServer, @unchecked Sendable {
    func window(number: CGWindowID) -> DeskTagServerWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]] else { return nil }
        return list.lazy.compactMap(Self.parse).first { $0.number == number }
    }

    func onScreenFrontToBack() -> [DeskTagServerWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap(Self.parse)
    }

    static func parse(_ entry: [String: Any]) -> DeskTagServerWindow? {
        guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value, number != 0,
              let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0,
              let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let onScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        return DeskTagServerWindow(number: number, pid: pid, bounds: bounds, layer: layer, isOnScreen: onScreen, alpha: alpha)
    }
}

/// The left button through `CGEventSource.buttonState` (permission-free, any thread).
final class DeskTagLiveButton: DeskTagButton, @unchecked Sendable {
    func isLeftButtonDown() -> Bool { CGEventSource.buttonState(.combinedSessionState, button: .left) }
}

/// Displays, the pointer, activation and the system notifications, on the main thread.
@MainActor
final class DeskTagLiveSystem: DeskTagSystem {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func displays() -> [DeskTagDisplay] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let height = primary.frame.height
        return screens.map { screen in
            DeskTagDisplay(id: ScreenSpace.displayID(of: screen),
                        frame: ScreenSpace.quartz(fromAppKit: screen.frame, primaryHeight: height),
                        visibleFrame: ScreenSpace.quartz(fromAppKit: screen.visibleFrame, primaryHeight: height))
        }
    }

    var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    func pointerLocation() -> CGPoint { NSEvent.mouseLocation }

    func isOwnAppActive() -> Bool { NSApp?.isActive ?? false }

    func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func start(_ handler: @escaping @MainActor (DeskTagSystemEvent) -> Void) {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        add(workspace, NSWorkspace.activeSpaceDidChangeNotification) { _ in handler(.spaceChanged) }
        add(workspace, NSWorkspace.didActivateApplicationNotification) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let pid = app?.processIdentifier { handler(.appActivated(pid)) }
        }
        add(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { _ in handler(.screensChanged) }
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name,
                     _ handler: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handler(note) }
        }
        tokens.append((center, token))
    }

    func addEscapeMonitor(_ handler: @escaping @MainActor () -> Bool) -> AnyObject? {
        // A local monitor sees only events sent to the app, so only while it is the active app.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            return MainActor.assumeIsolated { handler() } ? nil : event
        }
        return monitor.map { $0 as AnyObject }
    }

    func removeEscapeMonitor(_ token: AnyObject) {
        NSEvent.removeMonitor(token)
    }
}

/// Orders the real panels.
@MainActor
final class DeskTagLiveWindowing: DeskTagWindowing {
    func show(_ panel: NSPanel, frame: CGRect, level: NSWindow.Level, above number: CGWindowID?, reorder: Bool) {
        if panel.level != level { panel.level = level }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        guard reorder || !panel.isVisible else { return }
        if let number {
            panel.order(.above, relativeTo: Int(number))
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide(_ panel: NSPanel) {
        if panel.isVisible { panel.orderOut(nil) }
    }
}

/// Main-run-loop timers (common modes, so they keep going while a menu is open) and the monotonic clock.
@MainActor
final class DeskTagLiveScheduler: DeskTagScheduler {
    private final class Token: DeskTagTimer {
        let timer: Timer
        init(_ timer: Timer) { self.timer = timer }
        func cancel() { timer.invalidate() }
    }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> DeskTagTimer {
        let timer = Timer(timeInterval: max(0, seconds), repeats: false) { _ in MainActor.assumeIsolated { work() } }
        timer.tolerance = min(0.02, max(0, seconds) * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        return Token(timer)
    }
}
