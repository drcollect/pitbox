import ApplicationServices
import CoreGraphics
import Foundation

/// Turns raw window-server dictionaries and Accessibility values into the guard's types. Pure (no IPC), so it is
/// unit-tested with hand-made values.
enum AXParsing {
    /// Read in one round trip by `AXWindowProvider.info(of:)`, in this order. `AXFullScreen` is undocumented but
    /// exposed by AppKit on every window (window managers have relied on it for years).
    static let infoAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute,
        "AXFullScreen",
    ]
    static let frameAttributes: [String] = [kAXPositionAttribute, kAXSizeAttribute]

    /// Values from `AXUIElementCopyMultipleAttributeValues(infoAttributes)`. Missing attributes arrive as AXValues of
    /// type `.axError`; position and size are required.
    static func windowInfo(pid: pid_t, values: [AnyObject]) -> WindowInfo? {
        guard values.count == infoAttributes.count, let frame = frame(position: values[2], size: values[3]) else {
            return nil
        }
        return WindowInfo(pid: pid, frame: frame, role: string(values[0]), subrole: string(values[1]),
                          minimized: bool(values[4]) ?? false, fullScreen: bool(values[5]) ?? false)
    }

    /// Values from `AXUIElementCopyMultipleAttributeValues(frameAttributes)`.
    static func frame(values: [AnyObject]) -> CGRect? {
        guard values.count == frameAttributes.count else { return nil }
        return frame(position: values[0], size: values[1])
    }

    static func frame(position: AnyObject, size: AnyObject) -> CGRect? {
        guard let origin = point(position), let extent = self.size(size) else { return nil }
        let rect = CGRect(origin: origin, size: extent)
        return Placement.isUsable(rect) ? rect : nil
    }

    static func point(_ value: AnyObject) -> CGPoint? {
        guard let ax = axValue(value, .cgPoint) else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(ax, .cgPoint, &p), p.x.isFinite, p.y.isFinite else { return nil }
        return p
    }

    static func size(_ value: AnyObject) -> CGSize? {
        guard let ax = axValue(value, .cgSize) else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(ax, .cgSize, &s), s.width.isFinite, s.height.isFinite else { return nil }
        return s
    }

    static func string(_ value: AnyObject) -> String? {
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    static func bool(_ value: AnyObject) -> Bool? {
        guard CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func axValue(_ value: AnyObject, _ type: AXValueType) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeDowncast(value, to: AXValue.self)
        return AXValueGetType(ax) == type ? ax : nil
    }

    /// One entry of `CGWindowListCopyWindowInfo`. Window names are not read (they need Screen Recording and are
    /// private).
    static func onScreenWindow(from entry: [String: Any]) -> OnScreenWindow? {
        guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value, number != 0,
              let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0,
              let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              Placement.isUsable(bounds) else { return nil }
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        return OnScreenWindow(windowID: number, pid: pid, bounds: bounds, layer: layer, alpha: alpha)
    }
}

extension AXParsing {
    /// Level and on-screen flag of one `CGWindowListCopyWindowInfo` entry.
    static func serverState(from entry: [String: Any]) -> ServerWindowState? {
        guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue else { return nil }
        let onScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        return ServerWindowState(layer: layer, onScreen: onScreen)
    }
}

extension AXFailure {
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
