import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PitboxKit

// The production seams of the window join and the parker. Tests never use these:
// they replace every one with a fake, so no test touches a real window, Accessibility or another app.

/// The window server through `CGWindowListCopyWindowInfo` (no permission; window names are never read: they would need
/// Screen Recording and are private).
final class CodeLiveWindowServer: CodeWindowServer {
    func windows(ofPIDs pids: Set<pid_t>) -> [CodeServerWindow] {
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap(Self.parse).filter { pids.contains($0.pid) }
    }

    func window(number: CGWindowID) -> CodeServerWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]] else { return nil }
        return list.lazy.compactMap(Self.parse).first { $0.number == number }
    }

    static func parse(_ entry: [String: Any]) -> CodeServerWindow? {
        guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value, number != 0,
              let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0,
              let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let onScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        return CodeServerWindow(number: number, pid: pid, bounds: bounds, layer: layer, isOnScreen: onScreen)
    }
}

/// Accessibility, used only on the parker's thread. Every element gets a 2 s messaging timeout of its own; the
/// process-wide value (the system-wide element) is the window guard's and is never touched here.
final class CodeLiveAccessibility: CodeAccessibility {
    static let messagingTimeout: Float = 2
    private var apps: [pid_t: AXUIElement] = [:]

    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// `_AXUIElementGetWindow`: private, looked up at run time (the guard's way). If it ever disappears, numbers come
    /// from equal bounds instead.
    private static let getWindowFunction: GetWindowFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    private static let infoAttributes: [String] = [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                                   kAXMinimizedAttribute, kAXRoleAttribute, kAXSubroleAttribute]

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    private func app(_ pid: pid_t) -> AXUIElement {
        if let element = apps[pid] { return element }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        apps[pid] = element
        return element
    }

    func forget(pid: pid_t) { apps[pid] = nil }

    private func element(_ window: CodeAXElement) -> AXUIElement? {
        guard CFGetTypeID(window.raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(window.raw, to: AXUIElement.self)
    }

    private func wrap(_ element: AXUIElement) -> CodeAXElement {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return CodeAXElement(raw: element)
    }

    func windows(ofPID pid: pid_t) -> Result<[CodeAXElement], CodeAXFailure> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app(pid), kAXWindowsAttribute as CFString, &value)
        if error == .noValue { return .success([]) }
        guard error == .success else { return .failure(CodeAXFailure(error)) }
        guard let list = value as? [AXUIElement] else { return .success([]) }
        return .success(list.map(wrap))
    }

    func info(of window: CodeAXElement) -> Result<CodeAXWindowInfo, CodeAXFailure> {
        guard let element = element(window) else { return .failure(.invalidElement) }
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, Self.infoAttributes as CFArray,
                                                           AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard error == .success else { return .failure(CodeAXFailure(error)) }
        guard let list = values as? [AnyObject], list.count == Self.infoAttributes.count else { return .failure(.unsupported) }
        let frame: CGRect? = {
            guard let origin = Self.point(list[1]), let size = Self.size(list[2]), size.width > 0, size.height > 0 else { return nil }
            return CGRect(origin: origin, size: size)
        }()
        return .success(CodeAXWindowInfo(title: Self.string(list[0]), frame: frame, minimized: Self.bool(list[3]) ?? false,
                                         role: Self.string(list[4]), subrole: Self.string(list[5])))
    }

    func isMinimized(_ window: CodeAXElement) -> Result<Bool, CodeAXFailure> {
        guard let element = element(window) else { return .failure(.invalidElement) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value)
        guard error == .success, let value else { return .failure(CodeAXFailure(error)) }
        return .success(Self.bool(value) ?? false)
    }

    func windowNumber(of window: CodeAXElement) -> CGWindowID? {
        guard let function = Self.getWindowFunction, let element = element(window) else { return nil }
        var number: CGWindowID = 0
        return function(element, &number) == .success && number != 0 ? number : nil
    }

    func setMinimized(_ minimized: Bool, of window: CodeAXElement) -> CodeAXFailure? {
        guard let element = element(window) else { return .invalidElement }
        let error = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                                 (minimized ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
        return error == .success ? nil : CodeAXFailure(error)
    }

    func setFrame(_ frame: CGRect, of window: CodeAXElement) -> CodeAXFailure? {
        guard let element = element(window) else { return .invalidElement }
        var size = frame.size
        var origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else { return .other(-1) }
        let first = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let second = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue)
        // Some apps clamp the size to the display the window was on: once more after the move.
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        if first != .success { return CodeAXFailure(first) }
        return second == .success ? nil : CodeAXFailure(second)
    }

    func raise(_ window: CodeAXElement) -> CodeAXFailure? {
        guard let element = element(window) else { return .invalidElement }
        let error = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        return error == .success ? nil : CodeAXFailure(error)
    }

    func setMain(_ window: CodeAXElement) -> CodeAXFailure? {
        guard let element = element(window) else { return .invalidElement }
        let error = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        return error == .success ? nil : CodeAXFailure(error)
    }

    func focusedWindow(ofPID pid: pid_t) -> Result<CodeAXElement?, CodeAXFailure> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app(pid), kAXFocusedWindowAttribute as CFString, &value)
        if error == .noValue { return .success(nil) }
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return error == .success ? .success(nil) : .failure(CodeAXFailure(error))
        }
        return .success(wrap(unsafeDowncast(value, to: AXUIElement.self)))
    }

    func setFrontmost(pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
    }

    // MARK: Values

    private static func string(_ value: AnyObject) -> String? {
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    private static func bool(_ value: AnyObject) -> Bool? {
        guard CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func axValue(_ value: AnyObject, _ type: AXValueType) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeDowncast(value, to: AXValue.self)
        return AXValueGetType(ax) == type ? ax : nil
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard let ax = axValue(value, .cgPoint) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ax, .cgPoint, &point), point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard let ax = axValue(value, .cgSize) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ax, .cgSize, &size), size.width.isFinite, size.height.isFinite else { return nil }
        return size
    }
}

extension CodeAXFailure {
    init(_ error: AXError) {
        switch error {
        case .invalidUIElement, .invalidUIElementObserver: self = .invalidElement
        case .cannotComplete: self = .cannotComplete
        case .apiDisabled: self = .apiDisabled
        case .attributeUnsupported, .actionUnsupported, .notificationUnsupported, .notImplemented, .noValue,
             .parameterizedAttributeUnsupported:
            self = .unsupported
        default: self = .other(error.rawValue)
        }
    }
}

/// Activation and URLs through NSWorkspace and NSRunningApplication.
final class CodeLiveWorkspace: CodeWorkspace, @unchecked Sendable {
    @MainActor func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    @MainActor func isHidden(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
    }

    /// `NSRunningApplication` is thread safe (its header says so); a reused pid of another app does not count.
    func isClaudeRunning(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated && app.bundleIdentifier == "com.anthropic.claudefordesktop"
    }

    func activate(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate() ?? false
    }

    func open(_ url: URL, withApplicationAt appURL: URL, done: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // That copy's own app: no profile chooser, no Apple Event, and the link reaches the running copy.
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { app, error in
                done(app != nil && error == nil)
            }
        }
    }
}

/// The displays in Quartz coordinates, from NSScreen (main thread).
@MainActor
final class CodeLiveScreens: CodeScreens {
    func displays() -> [CodeDisplay] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let height = primary.frame.height
        return screens.map { screen in
            CodeDisplay(id: ScreenSpace.displayID(of: screen),
                        frame: ScreenSpace.quartz(fromAppKit: screen.frame, primaryHeight: height),
                        visibleFrame: ScreenSpace.quartz(fromAppKit: screen.visibleFrame, primaryHeight: height))
        }
    }
}
