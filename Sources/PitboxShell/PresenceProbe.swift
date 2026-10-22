import CoreGraphics
import Foundation

/// Is someone at the Mac? Two cheap reads for the presence rules (Ready, the away recap, when to speak).
public enum PresenceProbe {
    /// Seconds since the last keyboard, mouse or trackpad event in the HID system state (`kCGAnyInputEventType`).
    /// Not proof of a person at the desk: events other software posts at the HID tap (remote control, automation,
    /// mouse jigglers) reset it too.
    public static func hidIdleSeconds() -> TimeInterval {
        if let any = CGEventType(rawValue: ~0) {
            return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        }
        let kinds: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
                                    .leftMouseDragged]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    /// True while the screen is locked or the session is switched out (fast user switching). Fails closed: when the
    /// window server gives no session dictionary, it counts as locked.
    public static func screenLocked() -> Bool {
        sessionLocked(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// `screenLocked()`'s rule over a session dictionary: none is locked; off the console is locked; otherwise the
    /// lock flag (absent while unlocked).
    static func sessionLocked(_ info: [String: Any]?) -> Bool {
        guard let info else { return true }
        if info["kCGSSessionOnConsoleKey"] as? Bool == false { return true }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
