import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// The window observer's live Accessibility seam. Tests never use it: they replace
// it with a fake, so no test registers an observer on another app.

/// One registration's context (the observer callback's refcon): which app, and which window for `destroyed`.
final class DeskTagAXContext {
    weak var owner: DeskTagLiveAX?
    let pid: pid_t
    let number: CGWindowID?
    /// False once the window was unwatched: a late callback is ignored.
    var active = true

    init(owner: DeskTagLiveAX, pid: pid_t, number: CGWindowID?) {
        self.owner = owner; self.pid = pid; self.number = number
    }
}

/// Accessibility observers on the observer thread's run loop. Registrations are made on each app element (which
/// delivers them for all of the app's windows) and, for `destroyed`, on each watched window's own element. The messaging
/// timeout is set on each app element, never on the system-wide element (the guard owns that). Nothing is ever set or
/// performed on Claude's elements: observers and attribute reads only.
final class DeskTagLiveAX: DeskTagAXObserving {
    static let appNotifications: [(String, CodeWindowNotification)] = [
        (kAXWindowMovedNotification, .moved), (kAXWindowResizedNotification, .resized),
        (kAXWindowMiniaturizedNotification, .miniaturized), (kAXWindowDeminiaturizedNotification, .deminiaturized),
        (kAXFocusedWindowChangedNotification, .focusedWindowChanged), (kAXMainWindowChangedNotification, .mainWindowChanged),
        (kAXApplicationActivatedNotification, .appActivated), (kAXApplicationDeactivatedNotification, .appDeactivated),
        (kAXApplicationHiddenNotification, .appHidden), (kAXApplicationShownNotification, .appShown),
    ]
    /// Without these an app is not observed.
    static let essential: Set<String> = [kAXWindowMovedNotification, kAXWindowResizedNotification]
    /// Unwatched window contexts kept per app before its observer is made again (their registrations die with it).
    static let inactiveContextsMax = 64

    var sink: ((pid_t, CGWindowID?, CodeWindowNotification) -> Void)?

    private let queue: DeskTagQueue
    private var apps: [pid_t: AXUIElement] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var appContexts: [pid_t: Unmanaged<DeskTagAXContext>] = [:]
    private var windowElements: [CodeWindowKey: AXUIElement] = [:]
    private var windowContexts: [pid_t: [Unmanaged<DeskTagAXContext>]] = [:]

    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// `_AXUIElementGetWindow`: private, looked up at run time (the guard's way). Without it no window gets its own
    /// `destroyed` registration or an `AXFullScreen` read; the window server and the backstop pass still see everything.
    private static let getWindowFunction: GetWindowFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    init(queue: DeskTagQueue) {
        self.queue = queue
    }

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    private func app(_ pid: pid_t) -> AXUIElement {
        if let element = apps[pid] { return element }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, DeskTagTuning.messagingTimeout)
        apps[pid] = element
        return element
    }

    func observe(pid: pid_t) -> DeskTagAXFailure? {
        guard observers[pid] == nil else { return nil }
        guard AXIsProcessTrusted() else { return .apiDisabled }
        guard let runLoop = queue.runLoop else { return .notReady }
        var created: AXObserver?
        let error = AXObserverCreate(pid, deskTagObserverCallback, &created)
        guard error == .success, let observer = created else { return Self.failure(error) }
        let context = Unmanaged.passRetained(DeskTagAXContext(owner: self, pid: pid, number: nil))
        let element = app(pid)
        for (name, _) in Self.appNotifications {
            let result = AXObserverAddNotification(observer, element, name as CFString, context.toOpaque())
            if result == .success || result == .notificationAlreadyRegistered { continue }
            if Self.essential.contains(name) {
                // The observer was never added to a run loop: dropping it discards the registrations made so far.
                context.release()
                return Self.failure(result)
            }
        }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        appContexts[pid] = context
        return nil
    }

    /// Removing the run-loop source stops delivery at once; no `AXObserverRemoveNotification` (each would be a round
    /// trip a hung app could stall). The contexts are released after the source is gone, so no callback can reach them.
    func unobserve(pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid), let runLoop = queue.runLoop {
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        appContexts.removeValue(forKey: pid)?.release()
        for context in windowContexts.removeValue(forKey: pid) ?? [] { context.release() }
        windowElements = windowElements.filter { $0.key.pid != pid }
        apps[pid] = nil
    }

    func watch(pid: pid_t, number: CGWindowID) -> Bool {
        guard let observer = observers[pid], let function = Self.getWindowFunction else { return false }
        let key = CodeWindowKey(pid: pid, number: number)
        if windowElements[key] != nil { return true }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return false }
        for element in list {
            var found: CGWindowID = 0
            guard function(element, &found) == .success, found == number else { continue }
            AXUIElementSetMessagingTimeout(element, DeskTagTuning.messagingTimeout)
            let context = Unmanaged.passRetained(DeskTagAXContext(owner: self, pid: pid, number: number))
            let result = AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString,
                                                   context.toOpaque())
            windowContexts[pid, default: []].append(context)
            windowElements[key] = element
            return result == .success || result == .notificationAlreadyRegistered
        }
        return false
    }

    func unwatch(pid: pid_t, number: CGWindowID) {
        let key = CodeWindowKey(pid: pid, number: number)
        guard windowElements.removeValue(forKey: key) != nil else { return }
        for context in windowContexts[pid] ?? [] where context.takeUnretainedValue().number == number {
            context.takeUnretainedValue().active = false
        }
        let inactive = (windowContexts[pid] ?? []).filter { !$0.takeUnretainedValue().active }.count
        if inactive > Self.inactiveContextsMax, observers[pid] != nil {
            // Make the app's observer again so the stale window registrations die with the old one.
            let keep = windowElements.keys.filter { $0.pid == pid }
            unobserve(pid: pid)
            if observe(pid: pid) == nil { for other in keep { _ = watch(pid: pid, number: other.number) } }
        }
    }

    func isFullScreen(pid: pid_t, number: CGWindowID) -> Bool? {
        guard let element = windowElements[CodeWindowKey(pid: pid, number: number)] else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success, let value,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    func focusedWindowNumber(pid: pid_t) -> CGWindowID? {
        guard let function = Self.getWindowFunction else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var number: CGWindowID = 0
        return function(unsafeDowncast(value, to: AXUIElement.self), &number) == .success && number != 0 ? number : nil
    }

    fileprivate func received(_ context: DeskTagAXContext, _ name: String) {
        guard context.active else { return }
        let note: CodeWindowNotification?
        if name == kAXUIElementDestroyedNotification {
            note = .destroyed
        } else {
            note = Self.appNotifications.first { $0.0 == name }?.1
        }
        guard let note else { return }
        sink?(context.pid, note == .destroyed ? context.number : nil, note)
    }

    private static func failure(_ error: AXError) -> DeskTagAXFailure {
        switch error {
        case .apiDisabled: return .apiDisabled
        case .notificationUnsupported, .notImplemented, .actionUnsupported, .attributeUnsupported: return .unsupported
        default: return .notReady
        }
    }
}

/// AXObserver callback (C convention), on the observer thread's run loop. `refcon` is a `DeskTagAXContext`, retained until
/// its app is unobserved (after its run-loop source is gone).
private func deskTagObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                  _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let context = Unmanaged<DeskTagAXContext>.fromOpaque(refcon).takeUnretainedValue()
    context.owner?.received(context, notification as String)
}
